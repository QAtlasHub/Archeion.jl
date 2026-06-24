# Ingest tests: a synthetic Pinax doc → registry DB. Verifies record = Pinax source, figures as
# first-class with STABLE ids, record_runs (M:N), unified FTS, and the foundational property —
# annotation-preserving re-ingest (record + figure importance/archived survive UPSERT by stable id).
using Archeion
using Test
using Pinax
using SQLite
using DBInterface

@testset "ingest(doc) — Pinax doc → registry (figures first-class, annotation-preserving)" begin
    tmp = mktempdir()
    img = joinpath(tmp, "p.svg")
    write(img, "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")

    Pinax.@pinaxsetup title = "Thermal report" assets = :inline
    Pinax.@page :main "Main" begin
        Pinax.@section :results "Results" begin
            Pinax.@figure img caption = "magnetization vs T" id = :mag
            Pinax.@figure img caption = "energy vs T" id = :energy
        end
    end
    Pinax.render(; out=joinpath(tmp, "out"))
    doc = Pinax.current_document()

    db = joinpath(tmp, "archeion.db")
    res = Archeion.ingest(
        doc; db=db, project="thermal", source="report", runs=[("thermal", "r1"), ("thermal", "r2")]
    )
    @test res.record == "thermal/report"
    @test res.figures == 2

    conn = SQLite.DB(db)
    rid = title = body = ""
    for r in DBInterface.execute(conn, "SELECT id, title, body_md FROM records")
        rid, title, body = r.id, r.title, r.body_md
    end
    @test rid == "thermal/report"
    @test title == "Thermal report"
    @test occursin("magnetization vs T", body)   # figure caption folded into the searchable body

    fids = String[]
    for r in DBInterface.execute(conn, "SELECT id FROM figures ORDER BY ord")
        push!(fids, r.id)
    end
    @test fids == ["thermal/report:mag", "thermal/report:energy"]   # first-class, STABLE ids

    nruns = 0
    for _ in DBInterface.execute(conn, "SELECT 1 FROM record_runs WHERE record_id='thermal/report'")
        nruns += 1
    end
    @test nruns == 2

    nfts = 0
    for _ in DBInterface.execute(
        conn, "SELECT 1 FROM search_fts WHERE search_fts MATCH 'magnetization'"
    )
        nfts += 1
    end
    @test nfts >= 1

    # foundational: re-ingest preserves annotations (record + figure) and never duplicates
    DBInterface.execute(
        conn, "UPDATE records SET importance=3, archived=1 WHERE id='thermal/report'"
    )
    DBInterface.execute(
        conn, "UPDATE figures SET importance=2 WHERE id='thermal/report:mag'"
    )
    DBInterface.close!(conn)

    Archeion.ingest(
        doc; db=db, project="thermal", source="report", runs=[("thermal", "r1"), ("thermal", "r2")]
    )

    conn2 = SQLite.DB(db)
    imp = arc = fimp = cnt = -1
    for r in DBInterface.execute(
        conn2, "SELECT importance, archived FROM records WHERE id='thermal/report'"
    )
        imp, arc = r.importance, r.archived
    end
    for r in DBInterface.execute(
        conn2, "SELECT importance FROM figures WHERE id='thermal/report:mag'"
    )
        fimp = r.importance
    end
    for r in DBInterface.execute(conn2, "SELECT count(*) AS c FROM records")
        cnt = r.c
    end
    DBInterface.close!(conn2)
    @test imp == 3     # record importance preserved
    @test arc == 1     # record archived preserved
    @test fimp == 2    # FIGURE importance preserved (the stable-figure-id property)
    @test cnt == 1     # no duplicate
end

@testset "ingest normalizes the project key to slug (no drift, no orphaned PARA)" begin
    # The viewer keys EVERYTHING off records.project / projects.name. If the project were stored raw,
    # a spelling drift ("Logistic Map" → "logistic map") would split the project page and orphan its
    # app-owned PARA filing. ingest must canonicalize the key to slug(project) — same as records.id.
    tmp = mktempdir()
    img = joinpath(tmp, "p.svg")
    write(img, "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")

    Pinax.@pinaxsetup title = "Drift report" assets = :inline
    Pinax.@page :main "Main" begin
        Pinax.@figure img caption = "c" id = :f1
    end
    Pinax.render(; out=joinpath(tmp, "out"))
    doc = Pinax.current_document()

    db = joinpath(tmp, "archeion.db")
    r1 = Archeion.ingest(doc; db=db, project="Logistic Map", source="phase1")
    @test r1.record == "logistic-map/phase1"          # id is the slug

    conn = SQLite.DB(db)
    proj = ""
    for r in DBInterface.execute(conn, "SELECT project FROM records WHERE id='logistic-map/phase1'")
        proj = r.project
    end
    @test proj == "logistic-map"                      # records.project is the CANONICAL slug, not "Logistic Map"

    # the human files this project under a PARA bucket (app-owned annotation on the canonical row)
    DBInterface.execute(conn, "UPDATE projects SET para='Areas' WHERE name='logistic-map'")
    DBInterface.close!(conn)

    # re-ingest under a DIFFERENT spelling of the SAME project — must collapse to the canonical slug:
    # no 2nd project row, PARA filing intact, no duplicate record.
    Archeion.ingest(doc; db=db, project="logistic map", source="phase1")

    conn2 = SQLite.DB(db)
    pcount = nrec = -1
    ppara = ""
    for r in DBInterface.execute(conn2, "SELECT count(*) AS c FROM projects")
        pcount = r.c
    end
    for r in DBInterface.execute(conn2, "SELECT para FROM projects WHERE name='logistic-map'")
        ppara = r.para
    end
    for r in DBInterface.execute(conn2, "SELECT count(*) AS c FROM records")
        nrec = r.c
    end
    DBInterface.close!(conn2)
    @test pcount == 1        # ONE project row — the spelling drift collapsed to the canonical slug
    @test ppara == "Areas"   # PARA filing survived the differently-spelled re-ingest (not orphaned)
    @test nrec == 1          # same record, not a duplicate
end
