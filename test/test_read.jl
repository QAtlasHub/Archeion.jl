# Read tests: the ANNOTATION layer (app-owned: comments, tags, importance/archived, project
# para/description/tags/todos) read back into Julia — the human → LLM direction. Content is ingested,
# then web-app annotations are simulated with raw SQL, then the readers must return them.
using Archeion
using Test
using Pinax
using SQLite
using DBInterface

@testset "read: annotation layer back to Julia (comments/tags/status/project + feedback_md)" begin
    tmp = mktempdir()
    img = joinpath(tmp, "p.svg")
    write(img, "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")

    Pinax.@pinaxsetup title = "Read report" assets = :inline
    Pinax.@page :main "Main" begin
        Pinax.@section :r "R" begin
            Pinax.@figure img caption = "fig" id = :f1
        end
    end
    Pinax.render(; out=joinpath(tmp, "out"))
    doc = Pinax.current_document()

    db = joinpath(tmp, "archeion.db")
    res = Archeion.ingest(doc; db=db, project="My Project", source="phase1")
    rid = res.record                       # "my-project/phase1" (slug)
    proj = "my-project"

    # --- simulate the WEB APP writing the annotation layer ---
    conn = SQLite.DB(db)
    DBInterface.execute(
        conn, "UPDATE records SET importance=2, archived=1 WHERE id=?", (rid,)
    )
    DBInterface.execute(conn, "INSERT INTO tags (name) VALUES ('mps')")
    DBInterface.execute(conn, "INSERT INTO tags (name) VALUES ('tpq')")
    DBInterface.execute(
        conn,
        "INSERT INTO record_tags (record_id, tag_id) SELECT ?, id FROM tags WHERE name='mps'",
        (rid,),
    )
    DBInterface.execute(
        conn,
        "INSERT INTO record_tags (record_id, tag_id) SELECT ?, id FROM tags WHERE name='tpq'",
        (rid,),
    )
    DBInterface.execute(conn, "INSERT INTO users (name) VALUES ('alice')")
    DBInterface.execute(
        conn,
        "INSERT INTO annotations (record_id, target_kind, user_id, body_md) SELECT ?, 'record', id, 'looks converged' FROM users WHERE name='alice'",
        (rid,),
    )
    # a figure-anchored comment too → record_annotation_list should surface it with its location
    DBInterface.execute(
        conn,
        "INSERT INTO annotations (record_id, target_kind, page, target_id, user_id, body_md) SELECT ?, 'figure', 'eq.html', ?, id, 'noisy' FROM users WHERE name='alice'",
        (rid, rid * ":fig1"),
    )
    DBInterface.execute(
        conn,
        "UPDATE projects SET para='Areas', description='thermal study' WHERE name=?",
        (proj,),
    )
    DBInterface.execute(
        conn,
        "INSERT INTO project_tags (project, tag_id) SELECT ?, id FROM tags WHERE name='mps'",
        (proj,),
    )
    DBInterface.execute(
        conn,
        "INSERT INTO project_todos (project, body, done) VALUES (?, 'rerun at larger N', 0)",
        (proj,),
    )
    DBInterface.close!(conn)

    # --- read back (path form opens + closes per call) ---
    cmts = Archeion.record_comments(db, rid)
    @test length(cmts) == 1
    @test cmts[1].author == "alice"
    @test occursin("converged", cmts[1].body_md)

    @test Archeion.record_tags(db, rid) == ["mps", "tpq"]

    a = Archeion.record_annotations(db, rid)
    @test a.exists
    @test a.importance == 2
    @test a.archived == true
    @test a.tags == ["mps", "tpq"]
    @test length(a.comments) == 1                    # record-level discussion (back-compat field)
    # the unified location-tagged list: record discussion + the figure-anchored comment
    @test length(a.annotations) == 2
    fig = only(filter(x -> x.kind == "figure", a.annotations))
    @test fig.target == rid * ":fig1" && fig.page == "eq.html" && fig.body_md == "noisy"
    @test Archeion.record_annotation_list(db, rid) == a.annotations

    p = Archeion.project_annotations(db, proj)
    @test p.exists
    @test p.para == "Areas"
    @test p.description == "thermal study"
    @test p.tags == ["mps"]
    @test length(p.todos) == 1
    @test p.todos[1].body == "rerun at larger N"
    @test p.todos[1].done == false

    md = Archeion.feedback_md(db, rid)
    @test occursin("importance 2/3", md)
    @test occursin("archived", md)
    @test occursin("#mps", md)
    @test occursin("alice", md)
    @test occursin("Annotations (by location)", md)   # the figure comment, tagged with where it points
    @test occursin("figure `" * rid * ":fig1`", md)
    @test occursin("converged", md)
    @test occursin("thermal study", md)   # project description folded in

    # missing record → graceful (no throw)
    miss = Archeion.record_annotations(db, "nope/nope")
    @test miss.exists == false
    @test isempty(miss.comments)
    @test occursin("Not in the registry", Archeion.feedback_md(db, "nope/nope"))
end

@testset "ingest versioning: one version per distinct content state" begin
    tmp = mktempdir()
    img = joinpath(tmp, "p.svg")
    write(img, "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
    function build(title)
        Pinax.@pinaxsetup title = title assets = :inline
        Pinax.@page :m "M" begin
            Pinax.@section :s "S" begin
                Pinax.@figure img caption = "c" id = :f1
            end
        end
        Pinax.render(; out=joinpath(tmp, "out"))
        return Pinax.current_document()
    end

    db = joinpath(tmp, "v.db")
    Archeion.ingest(build("V one"); db=db, project="p", source="r", git="abc")
    rid = "p/r"
    v1 = Archeion.record_versions(db, rid)
    @test length(v1) == 1
    @test v1[1].version == 1
    @test v1[1].git_commit == "abc"
    @test v1[1].title == "V one"          # minimal snapshot: the title at this version

    # re-ingest IDENTICAL content (same title + git) → idempotent, no new version
    Archeion.ingest(build("V one"); db=db, project="p", source="r", git="abc")
    @test length(Archeion.record_versions(db, rid)) == 1

    # re-ingest CHANGED content (new title + git) → version 2
    Archeion.ingest(build("V two"); db=db, project="p", source="r", git="def")
    v3 = Archeion.record_versions(db, rid)
    @test length(v3) == 2
    @test v3[2].version == 2
    @test v3[2].git_commit == "def"
    @test v3[2].title == "V two"
    # content_hash is a SHA-256 hex digest (stable across Julia versions, unlike Base.hash)
    let conn = SQLite.DB(db), h = ""
        for r in DBInterface.execute(
            conn,
            "SELECT content_hash FROM record_versions WHERE record_id=? LIMIT 1",
            (rid,),
        )
            h = r.content_hash
        end
        DBInterface.close!(conn)
        @test occursin(r"^[0-9a-f]{64}$", h)
    end
end

@testset "re-ingest preserves the full annotation layer (the publish guarantee)" begin
    tmp = mktempdir()
    img = joinpath(tmp, "p.svg")
    write(img, "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
    function build()
        Pinax.@pinaxsetup title = "RT" assets = :inline
        Pinax.@page :m "M" begin
            Pinax.@section :s "S" begin
                Pinax.@figure img caption = "c" id = :f1
            end
        end
        Pinax.render(; out=joinpath(tmp, "out"))
        return Pinax.current_document()
    end

    db = joinpath(tmp, "rt.db")
    Archeion.ingest(build(); db=db, project="proj", source="ph", git="v1")
    rid = "proj/ph"

    # the human annotates on the remote (importance/archived/tags/comment/project description)
    conn = SQLite.DB(db)
    DBInterface.execute(
        conn, "UPDATE records SET importance=3, archived=1 WHERE id=?", (rid,)
    )
    DBInterface.execute(conn, "INSERT INTO tags (name) VALUES ('keep')")
    DBInterface.execute(
        conn,
        "INSERT INTO record_tags (record_id, tag_id) SELECT ?, id FROM tags WHERE name='keep'",
        (rid,),
    )
    DBInterface.execute(conn, "INSERT INTO users (name) VALUES ('bob')")
    DBInterface.execute(
        conn,
        "INSERT INTO annotations (record_id, target_kind, user_id, body_md) SELECT ?, 'record', id, 'good run' FROM users WHERE name='bob'",
        (rid,),
    )
    DBInterface.execute(conn, "UPDATE projects SET description='my proj' WHERE name='proj'")
    DBInterface.close!(conn)

    # re-ingest new content (what `publish` does: ingest into the pulled DB) — annotations must survive
    Archeion.ingest(build(); db=db, project="proj", source="ph", git="v2")

    a = Archeion.record_annotations(db, rid)
    @test a.importance == 3
    @test a.archived == true
    @test a.tags == ["keep"]
    @test length(a.comments) == 1 && a.comments[1].author == "bob"
    @test Archeion.project_annotations(db, "proj").description == "my proj"
    @test length(Archeion.record_versions(db, rid)) == 2   # content changed (git v1→v2) → new version
end

@testset "readers tolerate a DB predating record_versions / project_tags (live pull of an old DB)" begin
    tmp = mktempdir()
    img = joinpath(tmp, "p.svg")
    write(img, "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
    Pinax.@pinaxsetup title = "Old" assets = :inline
    Pinax.@page :m "M" begin
        Pinax.@section :s "S" begin
            Pinax.@figure img caption = "c" id = :f1
        end
    end
    Pinax.render(; out=joinpath(tmp, "out"))
    db = joinpath(tmp, "old.db")
    Archeion.ingest(Pinax.current_document(); db=db, project="proj", source="ph")
    rid = "proj/ph"

    # simulate a registry created before these tables existed
    conn = SQLite.DB(db)
    DBInterface.execute(conn, "DROP TABLE record_versions")
    DBInterface.execute(conn, "DROP TABLE project_tags")
    DBInterface.execute(conn, "DROP TABLE project_todos")
    DBInterface.close!(conn)

    @test isempty(Archeion.record_versions(db, rid))    # graceful — no "no such table"
    p = Archeion.project_annotations(db, "proj")
    @test p.exists                                       # core tables still read
    @test isempty(p.tags) && isempty(p.todos)            # missing tables → empty, not an error
end
