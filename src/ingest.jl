# Ingest discovered records into the web app's SQLite DB (the `:db` deploy target). The Julia
# side WRITES (records + `body_md` = the RAG-portable source of truth); the Node web app
# (Archeion.jl/web) READS. The schema is the shared data contract: web/db/schema.sql.
#
# Re-ingest is idempotent and UPSERTs: it refreshes the ingested fields (title/date/git/
# data_keys/figures/body_md) but PRESERVES app-managed state (tags/status/para/pinned/comments).

_default_schema() = joinpath(dirname(@__DIR__), "web", "db", "schema.sql")

# Split a SQL script into individual statements, treating BEGIN…END (triggers) as atomic so
# their inner `;` don't split them. Comment-only lines are skipped.
function _split_sql(sql::AbstractString)
    stmts = String[]
    buf = IOBuffer()
    depth = 0
    for line in eachline(IOBuffer(sql))
        startswith(strip(line), "--") && continue
        write(buf, line, "\n")
        u = uppercase(line)
        occursin(r"\bBEGIN\b", u) && (depth += 1)
        occursin(r"\bEND\b", u) && (depth = max(0, depth - 1))
        if depth == 0 && endswith(strip(line), ";")
            s = strip(String(take!(buf)))
            isempty(s) || push!(stmts, s)
        end
    end
    s = strip(String(take!(buf)))
    isempty(s) || push!(stmts, s)
    return stmts
end

# Apply the schema (idempotent — every statement is CREATE … IF NOT EXISTS).
function _ensure_db(db_path::AbstractString, schema_path::AbstractString)
    mkpath(dirname(db_path))
    conn = SQLite.DB(db_path)
    try
        for stmt in _split_sql(read(schema_path, String))
            DBInterface.execute(conn, stmt)
        end
    finally
        DBInterface.close!(conn)
    end
    return db_path
end

# The record's Markdown source-of-truth (provenance + DataVault config + ledger). This is
# what goes in `records.body_md` — clean, atomic, embeddable later for RAG.
function _record_markdown(project, run, info, rows, config::AbstractString)
    done = count(r -> get(r, "status", "") == "done", rows)
    io = IOBuffer()
    println(io, "## Provenance\n")
    println(io, "| field | value |")
    println(io, "| --- | --- |")
    println(io, "| project | `", project, "` |")
    println(io, "| run | `", run, "` |")
    println(io, "| keys | ", length(rows), " (", done, " done) |")
    println(io, "| julia | ", info.julia_version, " |")
    println(io, "| host | ", info.hostname, " |")
    println(io, "| created | ", info.created_at, " |")
    println(io, "| datavault | ", info.datavault_version, " |")
    if !isempty(strip(config))
        header, body = _config_header_and_body(config)
        println(io, "\n## DataVault config\n")
        isempty(header) || println(io, header, "\n")
        println(io, "```toml\n", body, "\n```")
    end
    if !isempty(rows)
        println(io, "\n## Ledger (", length(rows), " rows, ", done, " done)\n")
        println(io, _ledger_md_table(rows))
    end
    return String(take!(io))
end

function _json_str_array(xs)
    return string(
        "[", join(("\"" * replace(string(x), "\"" => "\\\"") * "\"" for x in xs), ","), "]"
    )
end

"""
    ingest(outdirs; db, figures="", schema=<web/db/schema.sql>) -> db

Discover every `(project, study, run)` under the DataVault `outdirs` and UPSERT them into the
SQLite database at `db` (creating it from the schema if needed). Writes `body_md` (the
Markdown source-of-truth); re-ingest refreshes provenance/content but preserves app-managed
state (tags/status/pins/comments). The Node web app reads this DB.
"""
function ingest(
    outdirs;
    db::AbstractString,
    figures::AbstractString="",
    schema::AbstractString=_default_schema(),
)
    _ensure_db(db, schema)
    isempty(figures) || mkpath(figures)
    conn = SQLite.DB(db)
    n = 0
    seen = Dict{String,Tuple{String,String}}()   # id -> (project, run): catch slug collisions
    try
        DBInterface.execute(conn, "PRAGMA foreign_keys = ON")   # per-connection, not persisted
        DBInterface.execute(conn, "BEGIN")                      # one transaction: atomic + fast
        try
            for od in outdirs
                od = String(od)
                for st in DataVault.open_all(od)
                    info = st.info
                    rows = DataVault.load_ledger(st.vault)
                    cfgfile = joinpath(od, info.config_snapshot)
                    cfg = isfile(cfgfile) ? read(cfgfile, String) : ""
                    project = info.project_name
                    run = info.run
                    id = joinpath(_slug(project), _slug(run))
                    if get(seen, id, (project, run)) != (project, run)
                        @warn "ingest: slug collision — id maps to multiple runs (later overwrites)" id existing = seen[id] current = (
                            project, run
                        )
                    end
                    seen[id] = (project, run)
                    git = isempty(rows) ? "unknown" : get(rows[end], "git_hash", "unknown")
                    date = if isempty(rows)
                        string(Dates.now(UTC))   # UTC, to match ledger ISO8601 timestamps
                    else
                        get(rows[end], "completed_at", "")
                    end
                    body = _record_markdown(project, run, info, rows, cfg)
                    DBInterface.execute(
                        conn,
                        """
                        INSERT INTO records (id,project,study,run,title,date,status,tags,git_commit,data_keys,figures,body_md,updated_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,datetime('now'))
                        ON CONFLICT(id) DO UPDATE SET
                          title=excluded.title, date=excluded.date, git_commit=excluded.git_commit,
                          data_keys=excluded.data_keys, figures=excluded.figures, body_md=excluded.body_md,
                          updated_at=datetime('now')
                        """,
                        (
                            id,
                            project,
                            project,
                            run,
                            string(project, " / ", run),
                            date,
                            "active",
                            _json_str_array([project]),
                            git,
                            "[]",
                            "[]",
                            body,
                        ),
                    )
                    n += 1
                end
            end
            DBInterface.execute(conn, "COMMIT")
        catch
            DBInterface.execute(conn, "ROLLBACK")
            rethrow()
        end
    finally
        DBInterface.close!(conn)
    end
    return (; db=db, records=n)
end
