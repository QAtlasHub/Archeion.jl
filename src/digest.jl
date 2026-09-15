# The registry's machine face. Pinax gives each record two faces (a gallery for a person,
# `agent.json` for a program); this is the same split one level up. A program asking "what has been
# run here" reads `index.json` once instead of opening every record, and the dashboard a person
# reads is rendered FROM the same digest, so the two faces cannot drift apart.
#
# Everything here is derived from files already on disk. A study does not have to produce anything
# new to appear on the dashboard, and a record this package has never heard of still counts.

"Where a record keeps its machine face, relative to the record directory."
const AGENT_CANDIDATES = ("agent/agent.json", "agent.json")

function _agent_rel(recdir::AbstractString)
    for rel in AGENT_CANDIDATES
        isfile(joinpath(recdir, rel)) && return rel
    end
    return ""
end

# Figures and tables can hang off a page or off one of its sections; both shapes carry the same
# fields, so walk them the same way.
function _harvest!(node, state)
    for f in get(node, :figures, ())
        state.figures[] += 1
        get(f, :table, nothing) === nothing || (state.with_data[] += 1)
        for a in get(f, :assets, ())
            push!(state.assets, String(a))
        end
    end
    state.tables[] += length(get(node, :tables, ()))
    return nothing
end

# What a dashboard reports on, pulled from one Pinax `agent.json`.
function _agent_facts(path::AbstractString)
    doc = JSON3.read(read(path, String))
    state = (; figures=Ref(0), with_data=Ref(0), tables=Ref(0), assets=String[])
    sections = String[]
    statuses = String[]
    pages = get(doc, :pages, ())
    for pg in pages
        st = get(pg, :status, nothing)
        st === nothing || push!(statuses, String(st))
        _harvest!(pg, state)
        for sec in get(pg, :sections, ())
            t = get(sec, :title, nothing)
            t === nothing || push!(sections, String(t))
            _harvest!(sec, state)
        end
    end
    # One word for the record: a single trial page makes the whole record provisional, which is the
    # direction that must not be rounded away.
    status = if isempty(statuses)
        ""
    elseif any(==("trial"), statuses)
        "trial"
    else
        first(statuses)
    end
    return (;
        pages=length(pages),
        sections=sections,
        figures=state.figures[],
        figures_with_data=state.with_data[],
        tables=state.tables[],
        status=status,
        assets=state.assets,
    )
end

# A figure path in `agent.json` is written relative to the record, but the agent backend keeps its
# own copies under `agent/`. Try both rather than guessing, and return "" when neither is on disk:
# a thumbnail that 404s is worse than no thumbnail.
function _first_existing(recdir::AbstractString, assets)
    for a in assets
        isfile(joinpath(recdir, a)) && return a
        isfile(joinpath(recdir, "agent", a)) && return joinpath("agent", a)
    end
    return ""
end

"""
    digest(root=registry_root()) -> Dict{String,Any}

Everything the registry knows about itself, in one structure: the registry's identity, per-record
facts (from `record.toml` and, when the record has one, its `agent.json`), and the totals a reader
wants before opening anything.

The totals are deliberately the ones that describe *state*, not size: how many records cannot be
reproduced from what they recorded (`unknown_commit` + `dirty`), and how many carry no machine face
at all. A registry that only counts its records cannot tell you it is rotting.

Written to `index.json` by [`reindex`](@ref), and used to render the dashboard.
"""
function digest(root::AbstractString=registry_root())
    root = abspath(root)
    records = Dict{String,Any}[]
    projects = Dict{String,Int}()
    figures = 0
    with_data = 0
    reproducible = 0
    dirty = 0
    unknown = 0
    without_agent = 0

    for dir in record_dirs(root)
        r = read_record(dir)
        rel = relpath(dir, root)
        agent = _agent_rel(dir)
        facts = isempty(agent) ? nothing : _agent_facts(joinpath(dir, agent))

        if r.git_commit == "unknown"
            unknown += 1
        elseif r.git_dirty
            dirty += 1
        else
            reproducible += 1
        end
        isempty(agent) && (without_agent += 1)
        projects[r.project] = get(projects, r.project, 0) + 1

        entry = Dict{String,Any}(
            "id" => r.id,
            "project" => r.project,
            "title" => r.title,
            "summary" => r.summary,
            "date" => r.date,
            "tags" => r.tags,
            "gallery" => r.gallery,
            "dir" => rel,
            "git_commit" => r.git_commit,
            "git_dirty" => r.git_dirty,
            "julia_version" => r.julia_version,
            "data_keys" => r.data_keys,
            "repro" => isdir(joinpath(dir, "repro")),
            "agent" => isempty(agent) ? nothing : joinpath(rel, agent),
        )
        thumb = r.thumbnail
        if facts !== nothing
            figures += facts.figures
            with_data += facts.figures_with_data
            entry["pages"] = facts.pages
            entry["sections"] = facts.sections
            entry["figures"] = facts.figures
            entry["figures_with_data"] = facts.figures_with_data
            entry["tables"] = facts.tables
            entry["status"] = facts.status
            if thumb === nothing
                hit = _first_existing(dir, facts.assets)
                thumb = isempty(hit) ? nothing : joinpath(rel, hit)
            end
        end
        thumb === nothing || (entry["thumbnail"] = thumb)
        push!(records, entry)
    end

    sort!(records; by=e -> (e["date"], e["id"]), rev=true)
    dates = [e["date"] for e in records if !isempty(e["date"])]
    # An undeclared root has no name of its own; "Archeion" is at least stable, where a temporary
    # directory's basename would put a random string in the page title.
    reg = is_registry(root) ? registry_info(root) : (; name="Archeion", uuid="", repo="")

    return Dict{String,Any}(
        "registry" => Dict{String,Any}(
            "name" => reg.name,
            "uuid" => reg.uuid,
            "repo" => reg.repo,
            "root" => root,
            "generated" => string(Dates.now()),
        ),
        "totals" => Dict{String,Any}(
            "records" => length(records),
            "projects" => length(projects),
            "figures" => figures,
            "figures_with_data" => with_data,
            "reproducible" => reproducible,
            "dirty" => dirty,
            "unknown_commit" => unknown,
            "without_agent" => without_agent,
            "first" => isempty(dates) ? "" : minimum(dates),
            "last" => isempty(dates) ? "" : maximum(dates),
        ),
        "projects" => projects,
        "records" => records,
    )
end

# The card line under each title: when it was deposited, whether it is still provisional, how much
# is in it, and which commit it came from.
function _entry_meta(e::AbstractDict)
    bits = String[]
    pr = String(get(e, "project", ""))
    isempty(pr) || push!(bits, pr)
    d = String(get(e, "date", ""))
    isempty(d) || push!(bits, first(d, 10))
    st = String(get(e, "status", ""))
    isempty(st) || push!(bits, st)
    nf = get(e, "figures", nothing)
    nf === nothing || push!(bits, string(nf, nf == 1 ? " figure" : " figures"))
    sha = String(get(e, "git_commit", "unknown"))
    if sha == "unknown"
        push!(bits, "no commit")
    else
        push!(bits, "@" * first(sha, 7) * (get(e, "git_dirty", false) ? "+dirty" : ""))
    end
    get(e, "agent", nothing) === nothing && push!(bits, "no agent.json")
    return join(bits, "  ·  ")
end

"""
    build_dashboard(dg; out, title="") -> path

Render the registry dashboard from a [`digest`](@ref) to `out/index.html`, and return its path.
Cards are the records, carrying their tags as chips and as what the filter bar matches on; the strip
above them is the registry's state.

`search` mounts the Pagefind UI, and [`reindex`](@ref) passes it only once the index has actually
been built: a search box over an index that does not exist is worse than no box.

Separate from [`build_index`](@ref), which renders a plain card index from `Record`s alone (what
`discover` produces over DataVault outdirs, where there is no `agent.json` to read).
"""
function build_dashboard(
    dg::AbstractDict; out::AbstractString, title::AbstractString="", search::Bool=false
)
    isempty(title) && (title = String(get(get(dg, "registry", Dict()), "name", "Archeion")))
    t = get(dg, "totals", Dict{String,Any}())
    entries = map(get(dg, "records", ())) do e
        items = String.(get(e, "sections", String[]))
        return (;
            title=String(get(e, "title", "")),
            href=String(get(e, "gallery", "")),
            summary=isempty(String(get(e, "summary", ""))) ? nothing : String(e["summary"]),
            thumbnail=get(e, "thumbnail", nothing),
            meta=_entry_meta(e),
            items=items,
            tags=String.(get(e, "tags", String[])),
        )
    end
    stats = [
        "records" => get(t, "records", 0),
        "projects" => get(t, "projects", 0),
        "figures" => get(t, "figures", 0),
        "not reproducible" => get(t, "dirty", 0) + get(t, "unknown_commit", 0),
        "no machine face" => get(t, "without_agent", 0),
    ]
    return Pinax.contents(
        entries; out=out, title=title, level=:rich, stats=stats, search=search
    )
end
