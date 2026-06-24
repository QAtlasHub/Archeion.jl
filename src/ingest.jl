# Ingest a Pinax Document into the registry DB (the `:db` side). A record = one Pinax generation
# source; figures are FIRST-CLASS (keyed by Pinax's stable figure id). Re-ingest UPSERTs content
# BY STABLE ID and never touches annotations (importance/archived/tags/bookmarks/comments) — the
# content/annotation split. The caller (an app's build script) supplies the DataVault context
# (project, runs) that agent.json/the doc don't carry. See web/DESIGN.md / web/db/schema.sql.

_default_schema() = joinpath(dirname(@__DIR__), "web", "db", "schema.sql")

# Split a SQL script into statements (no triggers in v3 → simple `;` split, comments skipped).
function _split_sql(sql::AbstractString)
    stmts = String[]
    buf = IOBuffer()
    for line in eachline(IOBuffer(sql))
        startswith(strip(line), "--") && continue
        write(buf, line, "\n")
        if endswith(strip(line), ";")
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

# Every figure in a doc, in declaration order, across pages + their sections (mirrors agent.jl).
function _doc_figures(doc)
    out = Any[]
    for pg in doc.pages
        for f in pg.figures
            push!(out, f)
        end
        for sec in pg.sections, f in sec.figures
            push!(out, f)
        end
    end
    return out
end

# The record's searchable / RAG-portable body_md, assembled from the doc's text (title, page &
# section descriptions, figure captions) + a provenance header.
function _doc_body_md(doc, project, runs, git)
    io = IOBuffer()
    println(io, "# ", doc.meta.title, "\n")
    prov = string("project: `", project, "`")
    isempty(runs) || (prov *= " · runs: " * join(runs, ", "))
    isempty(git) || (prov *= " · " * git)
    println(io, prov, "\n")
    for pg in doc.pages
        println(io, "## ", pg.title)
        pg.desc === nothing || println(io, pg.desc.source)
        for sec in pg.sections
            println(io, "### ", sec.title)
            sec.desc === nothing || println(io, sec.desc.source)
        end
    end
    for f in _doc_figures(doc)
        isempty(f.caption) || println(io, "- ", f.caption)
    end
    return String(take!(io))
end

_img_path(f) = (imgs = filter(a -> !endswith(lowercase(a), ".csv"), f.assets);
isempty(imgs) ? "" : imgs[1])

# Copy a figure asset into the content store (content_dir/figures/<safe-figid>.<ext>) and return
# the path RELATIVE to content_dir (what the web app serves). With no content_dir, keep the raw path.
function _store_fig(src, fid, content_dir)
    (isempty(src) || isempty(content_dir)) && return src
    rel = joinpath("figures", replace(fid, r"[^A-Za-z0-9_-]" => "_") * lowercase(splitext(src)[2]))
    dest = joinpath(content_dir, rel)
    mkpath(dirname(dest))
    isfile(src) && cp(src, dest; force=true)
    return rel
end

# Copy the Pinax render output dir (index.html + its assets) into the content store under
# pages/<safe-rid>/, returning the path RELATIVE to content_dir of its index.html. This is the
# CANONICAL view the dashboard links to — Archeion indexes the run; it must not re-render it.
function _store_pages(src_dir, rid, content_dir)
    (isempty(src_dir) || isempty(content_dir) || !isdir(src_dir)) && return ""
    safe = replace(rid, r"[^A-Za-z0-9_-]" => "_")
    destdir = joinpath(content_dir, "pages", safe)
    mkpath(joinpath(content_dir, "pages"))
    rm(destdir; force=true, recursive=true)
    cp(src_dir, destdir)
    idx = joinpath(destdir, "index.html")
    isfile(idx) || return ""
    # inject the Archeion overlay (inject.js): metaproperty panel + discussion + section folding,
    # added to the run's own Pinax page (no iframe). It reads the record id from window.ARCHEION_RECORD.
    inj = string(
        "<link rel=\"stylesheet\" href=\"/inject.css\">",
        "<script>window.ARCHEION_RECORD=", repr(rid), ";</script>",
        "<script src=\"/inject.js\"></script>",
    )
    write(idx, replace(read(idx, String), "</body>" => inj * "</body>"; count=1))
    return joinpath("pages", safe, "index.html")
end

"""
    ingest(doc; db, project, source, runs=[], html_path="", pdf_path="", date="", git="") -> NamedTuple

Ingest a rendered Pinax `doc` (get it via `Pinax.current_document()` after `Pinax.render`) as one
registry record. `runs` is a vector of `(project, run)` (the DataVault runs the doc renders). The
record id = `slug(project)/slug(source)` (stable); `project` is stored canonically as `slug(project)`
too, so the viewer's project key (URL/FK/id) never drifts. Figures use Pinax's stable ids. Annotation-
preserving: importance/archived/tags/bookmarks/comments are never overwritten.
"""
function ingest(
    doc;
    db::AbstractString,
    project::AbstractString,
    source::AbstractString,
    runs=Tuple{String,String}[],
    html_path::AbstractString="",
    html_dir::AbstractString="",
    pdf_path::AbstractString="",
    date::AbstractString="",
    git::AbstractString="",
    content_dir::AbstractString="",
)
    _ensure_db(db, _default_schema())
    pslug = _slug(project)                        # canonical project key (same normalization as rid; the viewer keys on it)
    rid = joinpath(pslug, _slug(source))
    # the canonical Pinax page (index.html + assets) → content store; this is what detail views show
    isempty(html_dir) || (html_path = _store_pages(html_dir, rid, content_dir))
    figs = _doc_figures(doc)
    body = _doc_body_md(doc, project, [r[2] for r in runs], git)
    isempty(date) && (date = string(Dates.now(Dates.UTC)))
    gitval = isempty(git) ? "unknown" : git

    conn = SQLite.DB(db)
    try
        DBInterface.execute(conn, "PRAGMA foreign_keys = ON")
        DBInterface.execute(conn, "BEGIN")
        try
            # ensure the project row (FK target), keyed by the canonical slug; para/description are app-owned, preserved
            DBInterface.execute(conn, "INSERT OR IGNORE INTO projects (name) VALUES (?)", (pslug,))
            # record — content only; ON CONFLICT preserves importance/archived (app-owned)
            DBInterface.execute(
                conn,
                """
                INSERT INTO records (id,project,title,pinax_source,html_path,pdf_path,body_md,date,git_commit,updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,datetime('now'))
                ON CONFLICT(id) DO UPDATE SET
                  project=excluded.project, title=excluded.title, pinax_source=excluded.pinax_source,
                  html_path=excluded.html_path, pdf_path=excluded.pdf_path, body_md=excluded.body_md,
                  date=excluded.date, git_commit=excluded.git_commit, updated_at=datetime('now')
                """,
                (rid, pslug, doc.meta.title, source, html_path, pdf_path, body, date, gitval),
            )

            # record_runs — replace for this record (ingest-owned)
            DBInterface.execute(conn, "DELETE FROM record_runs WHERE record_id=?", (rid,))
            for (p, r) in runs
                DBInterface.execute(
                    conn,
                    "INSERT OR IGNORE INTO record_runs (record_id,project,run) VALUES (?,?,?)",
                    (rid, String(p), String(r)),
                )
            end

            # content version history — append a version only when the content fingerprint
            # (title + body_md + run-set + git) changes; a pure re-render is idempotent (no new row).
            runkey = join(sort!([string(p, "/", r) for (p, r) in runs]), ",")
            chash = bytes2hex(sha256(string(doc.meta.title, "\0", body, "\0", runkey, "\0", gitval)))
            lastver = 0
            lasthash = ""
            for r in DBInterface.execute(
                conn,
                "SELECT version, content_hash FROM record_versions WHERE record_id=? ORDER BY version DESC LIMIT 1",
                (rid,),
            )
                lastver = r.version
                lasthash = r.content_hash
            end
            if lasthash != chash
                DBInterface.execute(
                    conn,
                    "INSERT INTO record_versions (record_id,version,title,git_commit,date,content_hash) VALUES (?,?,?,?,?,?)",
                    (rid, lastver + 1, doc.meta.title, gitval, date, chash),
                )
            end

            # figures — UPSERT by stable id (preserve figure importance), then prune removed
            kept = String[]
            for (i, f) in enumerate(figs)
                fid = string(rid, ":", string(f.id))
                push!(kept, fid)
                DBInterface.execute(
                    conn,
                    """
                    INSERT INTO figures (id,record_id,ord,path,caption)
                    VALUES (?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      ord=excluded.ord, path=excluded.path, caption=excluded.caption
                    """,
                    (fid, rid, i, _store_fig(_img_path(f), fid, content_dir), string(f.caption)),
                )
            end
            placeholders = isempty(kept) ? "''" : join(fill("?", length(kept)), ",")
            DBInterface.execute(
                conn,
                "DELETE FROM figures WHERE record_id=? AND id NOT IN ($placeholders)",
                (rid, kept...),
            )

            # search_fts — refresh this record's record+figure rows (comment rows are app-owned)
            DBInterface.execute(
                conn,
                "DELETE FROM search_fts WHERE record_id=? AND kind IN ('record','figure')",
                (rid,),
            )
            DBInterface.execute(
                conn,
                "INSERT INTO search_fts (text,kind,id,record_id) VALUES (?,?,?,?)",
                (string(doc.meta.title, "\n", body), "record", rid, rid),
            )
            for (i, f) in enumerate(figs)
                isempty(f.caption) && continue
                fid = string(rid, ":", string(f.id))
                DBInterface.execute(
                    conn,
                    "INSERT INTO search_fts (text,kind,id,record_id) VALUES (?,?,?,?)",
                    (string(f.caption), "figure", fid, rid),
                )
            end

            DBInterface.execute(conn, "COMMIT")
        catch
            DBInterface.execute(conn, "ROLLBACK")
            rethrow()
        end
    finally
        DBInterface.close!(conn)
    end
    return (; record=rid, figures=length(figs))
end
