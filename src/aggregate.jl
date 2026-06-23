# Cross-project aggregation — the "Vault of DataVaults" layer. DataVault formalizes a
# per-project directory layout and deliberately leaves cross-outdir aggregation to a higher
# layer (see DataVault.build_master_ledger's docstring). This module discovers every
# (project, study, run) under a set of DataVault output dirs, reads each one's frozen
# discovery anchor (log.toml) + ledger + config snapshot, renders a per-run summary page
# styled by Pinax (its CSS/UI, via Pinax.render), and returns Records ready for build_index.
#
# NOTE: this uses DataVault.open_all, which *attaches* to each study and idempotently
# upserts its log.toml (refreshes [meta].datavault_version). That is the intended read API,
# but it does touch the source anchors — aggregate copies, or a future read-only variant,
# if you must not modify the originals.

# Filesystem/href-safe slug for a project or run name.
_slug(s) = replace(lowercase(string(s)), r"[^a-z0-9._-]+" => "-")

"""
    master_ledger(outdirs) -> Vector{Dict{String,String}}

Concatenate `DataVault.build_master_ledger` across several project `outdirs`. Each row is a
ledger entry enriched by DataVault with `project_name` / `run` / `log_toml`; this is the
cross-project ledger DataVault intentionally leaves to a higher layer.
"""
function master_ledger(outdirs)
    rows = Dict{String,String}[]
    for od in outdirs
        append!(rows, DataVault.build_master_ledger(String(od)))
    end
    return rows
end

# Render the ledger as a Markdown table (capped, so a large sweep doesn't make a giant page).
function _ledger_md_table(rows; limit::Int=50)
    cols = sort(collect(keys(rows[1])))
    io = IOBuffer()
    println(io, "| ", join(cols, " | "), " |")
    println(io, "| ", join(fill("---", length(cols)), " | "), " |")
    shown = min(length(rows), limit)
    for r in @view rows[1:shown]
        cells = [replace(get(r, c, ""), "|" => "\\|") for c in cols]
        println(io, "| ", join(cells, " | "), " |")
    end
    shown < length(rows) &&
        println(io, "\n_(showing first ", shown, " of ", length(rows), " rows)_")
    return String(take!(io))
end

# Split a config snapshot into its leading comment header (the human-readable description —
# job notes, advisor concerns, scope) and the rest (the actual TOML). The header renders as
# prose (`@desc`); the TOML stays verbatim in a code block.
function _config_header_and_body(config::AbstractString)
    lines = split(config, '\n'; keepempty=true)
    i = firstindex(lines)
    header = String[]
    while i <= lastindex(lines)
        l = strip(lines[i])
        if startswith(l, "#")
            push!(header, strip(replace(lines[i], r"^\s*#+\s?" => "")))
            i += 1
        elseif isempty(l)
            i += 1                      # skip blanks inside/after the header block
        else
            break                       # first real TOML line
        end
    end
    return (strip(join(header, "\n")), strip(join(lines[i:end], '\n')))
end

# Build one (study, run) summary as a Pinax document. The run is the `@page`; its provenance,
# DataVault config, and ledger are separate `@section`s (so it reads as the experiment's
# record, ready to gain figure sections when a run has figures). Rendered through Pinax for
# its CSS/UI, self-contained (assets=:inline). Returns the written index.html path.
function _write_run_summary(dest; project, run, info, rows, config::AbstractString="")
    done = count(r -> get(r, "status", "") == "done", rows)
    prov = string(
        "| field | value |\n| --- | --- |\n",
        "| project | `",
        project,
        "` |\n",
        "| run | `",
        run,
        "` |\n",
        "| keys | ",
        length(rows),
        " (",
        done,
        " done) |\n",
        "| julia | ",
        info.julia_version,
        " |\n",
        "| host | ",
        info.hostname,
        " |\n",
        "| created | ",
        info.created_at,
        " |\n",
        "| datavault | ",
        info.datavault_version,
        " |\n",
    )
    header, toml_body = _config_header_and_body(config)
    config_md = if isempty(strip(config))
        "_(no config snapshot)_"
    elseif isempty(header)
        string("```toml\n", toml_body, "\n```")
    else
        string(header, "\n\n```toml\n", toml_body, "\n```")
    end
    ledger_md =
        isempty(rows) ? "_(no ledger yet — run `build_ledger`)_" : _ledger_md_table(rows)

    Pinax.reset!(; title=string(project, " / ", run))
    Pinax.@pinaxsetup assets = :inline
    Pinax.@page :record string(project, " / ", run) begin
        Pinax.@section :provenance "Provenance" begin
            Pinax.@desc Markdown.parse(prov)
        end
        Pinax.@section :config "DataVault config" begin
            Pinax.@desc Markdown.parse(config_md)
        end
        Pinax.@section :ledger "Ledger" begin
            Pinax.@desc Markdown.parse(ledger_md)
        end
    end
    return Pinax.render(; out=dest)
end

"""
    records_from_outdirs(outdirs; site) -> Vector{Record}

Discover every `(project, study, run)` under the DataVault `outdirs` (each containing a
`.datavault/` anchor), render a Pinax-styled summary page for each under
`site/<project>/<run>/`, and return the corresponding Records (provenance from the
log.toml + ledger).
"""
function records_from_outdirs(outdirs; site::AbstractString)
    recs = Record[]
    for od in outdirs
        od = String(od)
        for st in DataVault.open_all(od)
            info = st.info
            rows = DataVault.load_ledger(st.vault)
            cfgfile = joinpath(od, info.config_snapshot)
            config = isfile(cfgfile) ? read(cfgfile, String) : ""
            project = info.project_name
            run = info.run
            slug = joinpath(_slug(project), _slug(run))
            _write_run_summary(
                joinpath(site, slug);
                project=project,
                run=run,
                info=info,
                rows=rows,
                config=config,
            )
            done = count(r -> get(r, "status", "") == "done", rows)
            git = isempty(rows) ? "unknown" : get(rows[end], "git_hash", "unknown")
            date = isempty(rows) ? "" : get(rows[end], "completed_at", "")
            push!(
                recs,
                Record(;
                    id=slug,
                    project=project,
                    title=string(project, " / ", run),
                    summary=string(length(rows), " keys, ", done, " done"),
                    gallery=joinpath(slug, "index.html"),
                    tags=[project],
                    git_commit=git,
                    date=isempty(date) ? string(Dates.now()) : date,
                ),
            )
        end
    end
    return recs
end

"""
    discover(outdirs; out, title="Archeion") -> Vector{Record}

End-to-end cross-project aggregation: discover all `(project, study, run)` under `outdirs`,
write per-run summaries + the cross-run index into `out`, add Pagefind search, and return
the Records. `outdirs` are DataVault output directories (each containing `.datavault/`).
"""
function discover(outdirs; out::AbstractString, title::AbstractString="Archeion")
    recs = records_from_outdirs(outdirs; site=out)
    build_index(recs; out=out, title=title)
    add_search(out)
    return recs
end
