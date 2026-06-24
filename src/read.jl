# read.jl — read the ANNOTATION layer back from the registry DB (the human → LLM direction).
#
# `ingest` WRITES content (records/figures/runs, ingest-owned); the web app WRITES annotations
# (comments, tags, importance/archived, project para/description/tags/todos, all app-owned). These
# readers pull that app-owned layer back so an LLM steering loop can see the human's feedback. They
# are READ-ONLY and mirror web/src/db.js (the same DB, the same schema is the contract). Each takes an
# open `SQLite.DB` OR a db PATH (opened + closed per call). To read a *remotely* annotated registry,
# fetch the deployed DB first with `pull` (see deploy.jl), then point these at the local copy.

_withdb(f, db::SQLite.DB) = f(db)
function _withdb(f, db::AbstractString)
    conn = SQLite.DB(db)
    try
        return f(conn)
    finally
        DBInterface.close!(conn)
    end
end

# True if `t` is a table in the open DB — lets readers tolerate a DB that predates a table (e.g. a live
# DB pulled before record_versions / project_tags existed; ingest's CREATE IF NOT EXISTS adds them on
# the next publish). Without this, reading an older registry would throw "no such table".
_has_table(conn::SQLite.DB, t::AbstractString) = !isempty(
    collect(
        DBInterface.execute(
            conn, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (t,)
        ),
    ),
)

"""
    record_comments(db, rid) -> Vector{@NamedTuple{author::String, body_md::String, created_at::String}}

The web-app discussion on a record (oldest-first). Empty when the record has no comments.
"""
record_comments(db, rid) = _withdb(db) do conn
    [
        (;
            author=String(r.author),
            body_md=String(r.body_md),
            created_at=String(r.created_at),
        ) for r in DBInterface.execute(
            conn,
            """
            SELECT c.body_md, c.created_at, COALESCE(u.name,'anon') AS author
            FROM comments c LEFT JOIN users u ON u.id = c.user_id
            WHERE c.record_id = ? ORDER BY c.id
            """,
            (rid,),
        )
    ]
end

"""
    record_tags(db, rid) -> Vector{String}

The record's app-owned tags (sorted).
"""
record_tags(db, rid) = _withdb(db) do conn
    [
        String(r.name) for r in DBInterface.execute(
            conn,
            "SELECT t.name FROM tags t JOIN record_tags rt ON rt.tag_id = t.id WHERE rt.record_id = ? ORDER BY t.name",
            (rid,),
        )
    ]
end

"""
    record_annotations(db, rid) -> NamedTuple

The full app-owned annotation of a record: `(; exists, importance, archived, title, project, tags,
comments)`. `importance` is 0..3 (shared "notable"); `archived` is a `Bool` — together the human's
"status". `exists` is `false` when the id isn't in the registry (everything else defaulted).
"""
record_annotations(db, rid) = _withdb(db) do conn
    # extract scalars INSIDE the loop — a SQLite.Row is only valid during iteration
    found = false
    importance = 0
    archived = false
    title = ""
    project = ""
    for r in DBInterface.execute(
        conn, "SELECT importance, archived, title, project FROM records WHERE id = ?", (rid,)
    )
        found = true
        importance = Int(r.importance)
        archived = r.archived != 0
        title = String(r.title)
        project = String(r.project)
    end
    found || return (;
        exists=false,
        importance=0,
        archived=false,
        title="",
        project="",
        tags=String[],
        comments=NamedTuple[],
    )
    return (;
        exists=true,
        importance=importance,
        archived=archived,
        title=title,
        project=project,
        tags=record_tags(conn, rid),
        comments=record_comments(conn, rid),
    )
end

"""
    project_annotations(db, name) -> NamedTuple

A project's app-owned filing: `(; exists, para, description, tags, todos)`. `para` is the PARA bucket
(Projects/Areas/Resources/Archives), `description` the human note, `tags` the project tags, `todos` a
`(; body, done)` checklist. `name` is the canonical slug. `exists` is `false` if unknown.
"""
project_annotations(db, name) = _withdb(db) do conn
    found = false
    para = ""
    description = ""
    for r in DBInterface.execute(
        conn, "SELECT para, description FROM projects WHERE name = ?", (name,)
    )
        found = true
        para = String(r.para)
        description = String(r.description)
    end
    found ||
        return (; exists=false, para="", description="", tags=String[], todos=NamedTuple[])
    tags =
        _has_table(conn, "project_tags") ?
        [
            String(r.name) for r in DBInterface.execute(
                conn,
                "SELECT t.name FROM project_tags pt JOIN tags t ON t.id = pt.tag_id WHERE pt.project = ? ORDER BY t.name",
                (name,),
            )
        ] : String[]
    todos =
        _has_table(conn, "project_todos") ?
        [
            (; body=String(r.body), done=r.done != 0) for r in DBInterface.execute(
                conn,
                "SELECT body, done FROM project_todos WHERE project = ? ORDER BY done, ord, id",
                (name,),
            )
        ] : NamedTuple[]
    return (;
        exists=true,
        para=para,
        description=description,
        tags=tags,
        todos=todos,
    )
end

"""
    feedback_md(db, rid) -> String

A clean Markdown digest of a record's human annotations — status, tags, the project's PARA bucket /
description / tags, and the discussion. Drop it into an LLM prompt next to the `agent.json` so the
steering loop sees the human's feedback. Says so plainly when nothing has been annotated yet.
"""
feedback_md(db, rid) = _withdb(db) do conn
    a = record_annotations(conn, rid)
    a.exists || return string("# `", rid, "`\n\n_Not in the registry._\n")
    io = IOBuffer()
    println(io, "# Human feedback — ", a.title, " (`", rid, "`)\n")
    println(
        io,
        "- status: ",
        a.archived ? "archived" : "active",
        " · importance ",
        a.importance,
        "/3",
    )
    isempty(a.tags) || println(io, "- tags: ", join(map(t -> "#" * t, a.tags), " "))
    p = project_annotations(conn, a.project)
    if p.exists && (!isempty(p.description) || !isempty(p.tags))
        println(io, "- project `", a.project, "` [", p.para, "]: ", p.description)
        isempty(p.tags) ||
            println(io, "  project tags: ", join(map(t -> "#" * t, p.tags), " "))
    end
    println(io)
    if isempty(a.comments)
        println(io, "_No discussion yet._")
    else
        println(io, "## Discussion")
        for c in a.comments
            println(io, "- **", c.author, "** (", c.created_at, "): ", c.body_md)
        end
    end
    return String(take!(io))
end

"""
    record_versions(db, rid) -> Vector{@NamedTuple{version::Int, title::String, ingested_at::String, git_commit::String, date::String}}

The content version history of a record (oldest-first) — one entry per distinct content state (ingest
appends one when title/body_md/run-set/git change). `title` is the minimal snapshot (the record's title
at that version). Empty for records ingested before versioning.
"""
record_versions(db, rid) = _withdb(db) do conn
    _has_table(conn, "record_versions") || return NamedTuple[]
    [
        (;
            version=Int(r.version),
            title=String(r.title),
            ingested_at=String(r.ingested_at),
            git_commit=r.git_commit === missing ? "" : String(r.git_commit),
            date=r.date === missing ? "" : String(r.date),
        ) for r in DBInterface.execute(
            conn,
            "SELECT version, title, ingested_at, git_commit, date FROM record_versions WHERE record_id = ? ORDER BY version",
            (rid,),
        )
    ]
end
