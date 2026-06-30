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
function _has_table(conn::SQLite.DB, t::AbstractString)
    return !isempty(
        collect(
            DBInterface.execute(
                conn, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (t,)
            ),
        ),
    )
end

"""
    record_comments(db, rid) -> Vector{@NamedTuple{author::String, body_md::String, created_at::String}}

The web-app discussion on a record (oldest-first). Empty when the record has no comments.
"""
function record_comments(db, rid)
    _withdb(db) do conn
        return [
            (;
                author=String(r.author),
                body_md=String(r.body_md),
                created_at=String(r.created_at),
            ) for r in DBInterface.execute(
                conn,
                """
                SELECT c.body_md, c.created_at, COALESCE(u.name,'anon') AS author
                FROM annotations c LEFT JOIN users u ON u.id = c.user_id
                WHERE c.record_id = ? AND c.target_kind = 'record' ORDER BY c.id
                """,
                (rid,),
            )
        ]
    end
end

"""
    record_tags(db, rid) -> Vector{String}

The record's app-owned tags (sorted).
"""
function record_tags(db, rid)
    _withdb(db) do conn
        return [
            String(r.name) for r in DBInterface.execute(
                conn,
                "SELECT t.name FROM tags t JOIN record_tags rt ON rt.tag_id = t.id WHERE rt.record_id = ? ORDER BY t.name",
                (rid,),
            )
        ]
    end
end

"""
    record_annotation_list(db, rid) -> Vector{NamedTuple}

Every comment/annotation on a record, each WITH its LOCATION — the traceable comment list. One entry per
`annotations` row (oldest-first): `(; id, kind, page, target, anchor, body_md, author, created_at)`,
`kind ∈ record/figure/section/passage`, `target` = figure id / section heading ("" for record/passage),
`anchor` = the passage's text-quote JSON ("" otherwise). So an LLM can read each comment and exactly
where it points from one query.
"""
function record_annotation_list(db, rid)
    _withdb(db) do conn
        out = NamedTuple[]
        for r in DBInterface.execute(
            conn,
            """
            SELECT a.id, a.target_kind, a.page, a.target_id, a.anchor, a.body_md, a.created_at,
                   COALESCE(u.name,'anon') AS author
            FROM annotations a LEFT JOIN users u ON u.id = a.user_id
            WHERE a.record_id = ? ORDER BY a.id
            """,
            (rid,),
        )
            push!(
                out,
                (;
                    id=Int(r.id),
                    kind=String(r.target_kind),
                    page=String(r.page),
                    target=String(r.target_id),
                    anchor=r.anchor === missing ? "" : String(r.anchor),
                    body_md=String(r.body_md),
                    author=String(r.author),
                    created_at=String(r.created_at),
                ),
            )
        end
        return out
    end
end

"""
    record_annotations(db, rid) -> NamedTuple

The full app-owned annotation of a record: `(; exists, importance, archived, title, project, tags,
comments, annotations)`. `importance` is 0..3 (shared "notable"); `archived` is a `Bool` — together the
human's "status". `comments` is the record-level discussion (back-compat); `annotations` is the FULL
location-tagged list (record/figure/section/passage — see `record_annotation_list`). `exists` is `false`
when the id isn't in the registry (everything else defaulted).
"""
function record_annotations(db, rid)
    _withdb(db) do conn
        # extract scalars INSIDE the loop — a SQLite.Row is only valid during iteration
        found = false
        importance = 0
        archived = false
        title = ""
        project = ""
        for r in DBInterface.execute(
            conn,
            "SELECT importance, archived, title, project FROM records WHERE id = ?",
            (rid,),
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
            annotations=NamedTuple[],
        )
        return (;
            exists=true,
            importance=importance,
            archived=archived,
            title=title,
            project=project,
            tags=record_tags(conn, rid),
            comments=record_comments(conn, rid),
            annotations=record_annotation_list(conn, rid),
        )
    end
end

"""
    project_annotations(db, name) -> NamedTuple

A project's app-owned filing: `(; exists, para, description, tags, todos)`. `para` is the PARA bucket
(Projects/Areas/Resources/Archives), `description` the human note, `tags` the project tags, `todos` a
`(; body, done)` checklist. `name` is the canonical slug. `exists` is `false` if unknown.
"""
function project_annotations(db, name)
    _withdb(db) do conn
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
        found || return (;
            exists=false, para="", description="", tags=String[], todos=NamedTuple[]
        )
        tags = if _has_table(conn, "project_tags")
            [
                String(r.name) for r in DBInterface.execute(
                    conn,
                    "SELECT t.name FROM project_tags pt JOIN tags t ON t.id = pt.tag_id WHERE pt.project = ? ORDER BY t.name",
                    (name,),
                )
            ]
        else
            String[]
        end
        todos = if _has_table(conn, "project_todos")
            [
                (; body=String(r.body), done=r.done != 0) for r in DBInterface.execute(
                    conn,
                    "SELECT body, done FROM project_todos WHERE project = ? ORDER BY done, ord, id",
                    (name,),
                )
            ]
        else
            NamedTuple[]
        end
        return (; exists=true, para=para, description=description, tags=tags, todos=todos)
    end
end

"""
    feedback_md(db, rid) -> String

A clean Markdown digest of a record's human annotations — status, tags, the project's PARA bucket /
description / tags, and the discussion. Drop it into an LLM prompt next to the `agent.json` so the
steering loop sees the human's feedback. Says so plainly when nothing has been annotated yet.
"""
function feedback_md(db, rid)
    _withdb(db) do conn
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
        # anchored comments (figure / section / passage), each tagged with WHERE it points
        anchored = filter(x -> x.kind != "record", a.annotations)
        if !isempty(anchored)
            println(io, "\n## Annotations (by location)")
            for x in anchored
                loc = if x.kind == "figure"
                    string("figure `", x.target, "`")
                elseif x.kind == "section"
                    string("section \"", x.target, "\"", isempty(x.page) ? "" : " ($(x.page))")
                else
                    string("passage", isempty(x.page) ? "" : " ($(x.page))")
                end
                println(io, "- [", loc, "] **", x.author, "**: ", x.body_md)
            end
        end
        return String(take!(io))
    end
end

"""
    status(db; io=stdout, print=true) -> NamedTuple
    status(; config=nothing, io=stdout, print=true) -> NamedTuple   # config=nothing → the host's agent; else pull `config`

A one-call overview of the whole registry — so the current state is *queried*, not hand-inspected
with raw SQLite. Returns `(; projects, records, figures, comments, items)` where `items` is one
`(; project, para, id, title, importance, archived, figures, runs, comments, updated_at)` per record
(grouped by PARA bucket then project). With `print=true` it also writes a grouped table to `io`.

`status(db)` reads a local DB (a path or an open `SQLite.DB`). `status(; config=...)` fetches the
deployed DB via `pull` (see transport.jl) and summarizes the LIVE registry in one call.
"""
function status(db; io::IO=stdout, print::Bool=true)
    _withdb(db) do conn
        has_comments = _has_table(conn, "comments")
        has_runs = _has_table(conn, "record_runs")
        has_notes = _has_table(conn, "notes")
        items = NamedTuple[]
        for r in DBInterface.execute(
            conn,
            """
            SELECT r.project AS project, COALESCE(p.para,'?') AS para, r.id AS id, r.title AS title,
                   r.importance AS importance, r.archived AS archived, COALESCE(r.updated_at,'') AS updated_at
            FROM records r LEFT JOIN projects p ON p.name = r.project
            ORDER BY p.para, r.project, r.id
            """,
        )
            # scalars must be read INSIDE the loop (a SQLite.Row is valid only during iteration)
            rid = String(r.id)
            push!(
                items,
                (;
                    project=String(r.project),
                    para=String(r.para),
                    id=rid,
                    title=String(r.title),
                    importance=Int(r.importance),
                    archived=r.archived != 0,
                    figures=_count1(
                        conn, "SELECT COUNT(*) c FROM figures WHERE record_id=?", rid
                    ),
                    runs=if has_runs
                        _count1(
                            conn,
                            "SELECT COUNT(*) c FROM record_runs WHERE record_id=?",
                            rid,
                        )
                    else
                        0
                    end,
                    comments=if has_comments
                        _count1(
                            conn, "SELECT COUNT(*) c FROM comments WHERE record_id=?", rid
                        )
                    else
                        0
                    end,
                    updated_at=String(r.updated_at),
                ),
            )
        end
        nproj = length(unique(it.project for it in items))
        nfig = _count1(conn, "SELECT COUNT(*) c FROM figures")
        ncom = has_comments ? _count1(conn, "SELECT COUNT(*) c FROM comments") : 0
        summary = (;
            projects=nproj,
            records=length(items),
            figures=nfig,
            comments=ncom,
            notes=has_notes ? _count1(conn, "SELECT COUNT(*) c FROM notes") : 0,
            items=items,
        )
        print && _print_status(io, summary)
        return summary
    end
end

function status(; config=nothing, io::IO=stdout, print::Bool=true)
    tmp = joinpath(tempdir(), "archeion-status.db")
    # config===nothing → the host's initialized agent (no creds in the caller); else the explicit config.
    db = config === nothing ? pull(; dest=tmp) : pull(config; out=tmp)
    return status(db; io=io, print=print)
end

_count1(conn, sql, args...) = Int(first(DBInterface.execute(conn, sql, args)).c)

function _print_status(io::IO, s)
    println(
        io,
        "registry: ",
        s.records,
        " records · ",
        s.projects,
        " projects · ",
        s.figures,
        " figures · ",
        s.comments,
        " comments · ",
        s.notes,
        " notes",
    )
    para = ""
    proj = ""
    for it in s.items
        if it.para != para
            para = it.para
            println(io, "\n▸ ", para)
            proj = ""
        end
        if it.project != proj
            proj = it.project
            println(io, "  ", proj)
        end
        flags = string("★"^it.importance, it.archived ? " 🗄" : "")
        println(
            io,
            "    - ",
            it.id,
            "  (",
            it.figures,
            " figs",
            it.runs > 0 ? ", $(it.runs) runs" : "",
            it.comments > 0 ? ", $(it.comments) comments" : "",
            ")",
            isempty(flags) ? "" : "  " * flags,
        )
    end
    return nothing
end

"""
    record_versions(db, rid) -> Vector{@NamedTuple{version::Int, title::String, ingested_at::String, git_commit::String, date::String}}

The content version history of a record (oldest-first) — one entry per distinct content state (ingest
appends one when title/body_md/run-set/git change). `title` is the minimal snapshot (the record's title
at that version). Empty for records ingested before versioning.
"""
function record_versions(db, rid)
    _withdb(db) do conn
        _has_table(conn, "record_versions") || return NamedTuple[]
        return [
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
end
