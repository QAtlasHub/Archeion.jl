# deposit.jl — add a revision to a registry/1 record.
#
# Called by the script that renders a report, which holds the document model and passes what the
# entry needs as values (SPEC.md §5.1): nothing here parses the rendered output. Two operations,
# deliberately separate (a copied script must not silently continue someone else's record):
#
#     new_binding(path; registry, project, slug)   # once: choose a new record id, write the binding
#     deposit(path; gallery, agent, doc, ...)      # every time: add a revision to that record
#
# The binding is a small TOML file committed in the repository whose code renders the report.

const ALPHABET = collect("0123456789abcdefghjkmnpqrstvwxyz")    # R5
const SKIP = Set([".pinax-manifest.toml"])                        # render-cache bookkeeping

token(n) = String(rand(Random.RandomDevice(), ALPHABET, n))
utcnow() = floor(now(Dates.UTC), Second)

function git(dir, args...; ok=false)
    out = IOBuffer()
    err = IOBuffer()
    proc = run(pipeline(ignorestatus(`git -C $dir $args`); stdout=out, stderr=err))
    success(proc) ||
        ok ||
        error("git $(join(args, ' ')) failed in $dir:\n$(String(take!(err)))")
    return success(proc) ? strip(String(take!(out))) : nothing
end

# ── binding ───────────────────────────────────────────────────────────────────────────────────

"""
    new_binding(path; registry, project, slug) -> record id

Choose a new record identifier and write the binding file at `path`. Refuses if `path` exists: a
binding is created once and committed, and every later `deposit` through it adds a revision to the
same record. `registry` is stored relative to the binding file's directory.
"""
function new_binding(path; registry, project, slug)
    ispath(path) &&
        error("$path exists; a binding is created once. Use another path for a new record.")
    occursin(r"^[a-z0-9]+(-[a-z0-9]+)*$", slug) ||
        error("slug must be lower-case words joined by `-`")
    occursin(PROJECT_ID, project) || error("$project is not a project identifier")
    isfile(joinpath(registry, "projects", "$project.toml")) ||
        error("project $project is not in $(joinpath(registry, "projects"))")
    id = "r_" * token(8)
    mkpath(dirname(abspath(path)))
    open(path, "w") do io
        return TOML.print(
            io,
            Dict(
                "spec" => SPEC,
                "registry" => relpath(abspath(registry), dirname(abspath(path))),
                "project" => project,
                "record" => id,
                "slug" => slug,
            );
            sorted=true,
        )
    end
    return id
end

function find_record(reg, id)
    base = joinpath(reg, "records")
    hits = [
        joinpath(base, y, d) for y in readdir(base) for
        d in readdir(joinpath(base, y)) if endswith(d, "-" * id)
    ]
    return isempty(hits) ? nothing : only(hits)
end

# ── what the revision says ────────────────────────────────────────────────────────────────────

# The code state, read now. Labelled "publish" because that is when it is read (SPEC.md §5.3).
function source_now(repo, role)
    commit = git(repo, "rev-parse", "HEAD")
    dirty = !isempty(git(repo, "status", "--porcelain", "--untracked-files=normal"))
    r = Dict{String,Any}("role" => role, "commit" => commit, "dirty" => dirty)
    url = git(repo, "remote", "get-url", "origin"; ok=true)
    url === nothing || (r["url"] = url)
    return Dict{String,Any}("captured" => "publish", "repo" => [r])
end

function readme(e)
    d = e["doc"]
    s = get(e, "source", nothing)
    io = IOBuffer()
    println(io, "# ", d["title"], "\n")
    println(
        io,
        "- Record `",
        e["id"]["record"],
        "`, revision `",
        e["id"]["rev"],
        "`",
        if isempty(e["parents"])
            " (the first)."
        else
            ", revising " * join(("`$p`" for p in e["parents"]), ", ") * "."
        end,
    )
    println(
        io,
        "- Status: ",
        d["status"],
        haskey(d, "tags") ? ". Tags: " * join(d["tags"], ", ") * "." : ".",
    )
    println(io, "- Frozen ", Dates.format(e["time"]["frozen"], "yyyy-mm-ddTHH:MM:SS"), "Z.")
    haskey(d, "question") && println(io, "\nAsked: ", d["question"])
    haskey(d, "claim") && println(io, "\nClaimed: ", d["claim"])
    println(
        io,
        "\nOpen `gallery/index.html` for the report. `agent/agent.json` is the same report for a",
        "\nprogram: each figure as the table of what it plots.",
    )
    if s !== nothing
        println(io, "\n## Where it came from\n")
        for r in s["repo"]
            println(
                io,
                "- ",
                r["role"],
                ": commit `",
                r["commit"],
                "`",
                haskey(r, "url") ? " of " * r["url"] : "",
                r["dirty"] ? ", with uncommitted changes" : ", clean",
                ".",
            )
        end
        println(
            io,
            "\nThe code state was read at ",
            s["captured"],
            ", not necessarily when the report was rendered.",
        )
    end
    ext = get(e["preservation"], "external", String[])
    println(
        io,
        "\n## What it can be trusted for\n\nRead only",
        isempty(ext) ? "." : "; it needs " * join(ext, ", ") * " to display fully.",
        " Rebuilding it is claimed only once a `capability.verified` event records that it worked.",
    )
    return String(take!(io))
end

# A face is a directory; `Pinax.render` and `Pinax.report` return the file they wrote in it
# (`index.html`, `agent.json`), so a file stands for its directory.
face_dir(path) = isfile(path) ? dirname(path) : path

function copy_tree(src, dest)
    isdir(src) || error("$src is not a directory")
    for (dir, _, files) in walkdir(src), f in files
        f in SKIP && continue
        target = joinpath(dest, relpath(joinpath(dir, f), src))
        mkpath(dirname(target))
        cp(joinpath(dir, f), target)
    end
end

function write_sums(revdir)
    files = sort([
        relpath(joinpath(d, f), revdir) for (d, _, fs) in walkdir(revdir) for f in fs
    ])
    open(joinpath(revdir, "SHA256SUMS"), "w") do io
        for f in files
            println(io, bytes2hex(open(sha256, joinpath(revdir, f))), "  ", f)
        end
    end
end

# ── deposit ───────────────────────────────────────────────────────────────────────────────────

"""
    deposit(binding; gallery, agent, doc, source_repo, external = [], repro = Dict(),
            parents = nothing, push = true, provenance = nothing) -> NamedTuple

Freeze a new revision of the binding's record: copy `gallery` and `agent`, write `entry.toml`,
`README.md` and `SHA256SUMS`, move it into place, validate the whole registry (and take the
revision back out if that fails), then commit only that path and push.

`doc` carries what the document model knows: `title`, `status` ("trial"/"final"), anchors split
into `stable` and `positional` (written as `anchors.local`), and optionally `tags`, `question`,
`claim`. `parents` defaults to the record's current revision; a record in conflict needs them
named. `repro` maps paths under `repro/` to files.

`provenance` adds per-point provenance (SPEC.md §5.5): the keywords of `write_provenance!`, which
[`provenance_from`](@ref) builds from a DataVault vault and a `Pinax.report` result. A point whose
bytes read differ from what its computation recorded makes the deposit refuse, unless
`allow_mismatch = true`.
"""
function deposit(
    binding;
    gallery,
    agent,
    doc,
    source_repo,
    external=String[],
    repro=Dict{String,String}(),
    parents=nothing,
    push=true,
    provenance=nothing,
)
    isfile(binding) ||
        error("no binding at $binding; create one with new_binding (once per record)")
    b = TOML.parsefile(binding)
    reg = normpath(joinpath(dirname(abspath(binding)), b["registry"]))
    id = b["record"]
    r0, _ = validate(reg)
    isempty(r0.errors) || error(
        "the registry does not validate before depositing:\n  " * join(r0.errors, "\n  "),
    )

    recdir = find_record(reg, id)
    frozen = utcnow()
    new_record = recdir === nothing
    if new_record
        recdir = joinpath(
            reg,
            "records",
            Dates.format(frozen, "yyyy"),
            Dates.format(frozen, "yyyy-mm-dd") * "-" * b["slug"] * "-" * id,
        )
        record = Dict{String,Any}(
            "spec" => SPEC,
            "id" => id,
            "kind" => "report",
            "project" => b["project"],
            "created" => frozen,
        )
    else
        record = TOML.parsefile(joinpath(recdir, "record.toml"))
        record["project"] == b["project"] || error(
            "the binding names project $(b["project"]) but record $id belongs to $(record["project"])",
        )
    end

    revroot = joinpath(recdir, "revisions")
    if parents === nothing
        names = isdir(revroot) ? readdir(revroot) : String[]
        evdir = joinpath(recdir, "events")
        events = isdir(evdir) ? [TOML.parsefile(f) for f in readdir(evdir; join=true)] : []
        revinfo = Dict(
            n => (; parents=TOML.parsefile(joinpath(revroot, n, "entry.toml"))["parents"])
            for n in names
        )
        heads = current(revinfo, events)
        length(heads) > 1 && error(
            "record $id is in conflict ($(join(heads, ", "))); name the parents explicitly",
        )
        parents = heads
    end

    rev = Dates.format(frozen, PATH_TIME) * "-" * token(4)
    entry = Dict{String,Any}(
        "spec" => SPEC,
        "parents" => collect(parents),
        "id" => Dict(
            "project" => b["project"], "record" => id, "rev" => rev, "kind" => "report"
        ),
        "time" => Dict("frozen" => frozen),
        "doc" => Dict{String,Any}("title" => doc.title, "status" => doc.status),
        "anchors" =>
            Dict("stable" => collect(doc.stable), "local" => collect(doc.positional)),
        "source" => source_now(source_repo, "render"),
        "preservation" => Dict{String,Any}("level" => "read"),
    )
    for k in (:tags, :question, :claim)
        haskey(doc, k) && (entry["doc"][string(k)] = doc[k])
    end
    isempty(external) || (entry["preservation"]["external"] = collect(external))

    incoming = joinpath(reg, "_incoming", rev)
    ispath(incoming) && error("$incoming exists")
    mkpath(incoming)
    try
        copy_tree(face_dir(gallery), joinpath(incoming, "gallery"))
        copy_tree(face_dir(agent), joinpath(incoming, "agent"))
        for (dest, src) in repro
            mkpath(dirname(joinpath(incoming, "repro", dest)))
            cp(src, joinpath(incoming, "repro", dest))
        end
        open(
            io -> TOML.print(io, entry; sorted=true), joinpath(incoming, "entry.toml"), "w"
        )
        write(joinpath(incoming, "README.md"), readme(entry))
        provenance === nothing || write_provenance!(incoming; provenance...)
        write_sums(incoming)                              # last: its presence means "complete"
    catch
        rm(incoming; recursive=true, force=true)          # nothing half-written is left behind
        rethrow()
    end

    final = joinpath(revroot, rev)
    mkpath(revroot)
    new_record && open(
        io -> TOML.print(io, record; sorted=true), joinpath(recdir, "record.toml"), "w"
    )
    mv(incoming, final)
    r, _ = validate(reg)
    if !isempty(r.errors)
        rm(final; recursive=true)
        new_record && rm(recdir; recursive=true)
        error(
            "the new revision does not validate, so it was taken back out:\n  " *
            join(r.errors, "\n  "),
        )
    end

    path = relpath(new_record ? recdir : final, reg)
    git(reg, "add", "--", path)
    git(reg, "commit", "-q", "-m", "deposit $id $rev: $(doc.title)", "--", path)
    pushed = false
    if push
        if git(reg, "push", "-q"; ok=true) === nothing
            git(reg, "pull", "-q", "--rebase")            # someone else deposited meanwhile
            git(reg, "push", "-q")
        end
        pushed = true
    end
    return (;
        record=id,
        rev,
        parents=entry["parents"],
        dir=final,
        commit=git(reg, "rev-parse", "HEAD"),
        pushed,
        dirty=entry["source"]["repo"][1]["dirty"],
    )
end

"""
    anchors(ids; auto = r"_(fig|tbl)\\d+\$") -> (; stable, positional)

Split anchor ids into those that keep their meaning across revisions and those Pinax numbered by
position (`<section>_fig<N>`, `<section>_tbl<N>`), which point elsewhere once a figure is inserted.
"""
function anchors(ids; auto=r"_(fig|tbl)\d+$")
    ids = unique(string.(ids))
    return (;
        stable=filter(i -> !occursin(auto, i), ids),
        positional=filter(i -> occursin(auto, i), ids),
    )
end
