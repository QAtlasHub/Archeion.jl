# Ingest tests: a tiny synthetic DataVault study → SQLite, verifying the body_md source-of-
# truth, FTS5 search, and idempotent UPSERT that preserves app-managed state (tags/status).
using Archeion
using Test
using DataVault
using SQLite
using DBInterface

@testset "ingest → SQLite (records + FTS + idempotent UPSERT)" begin
    tmp = mktempdir()
    outdir = joinpath(tmp, "out")
    cfg = joinpath(tmp, "config.toml")
    write(
        cfg,
        """
        [study]
        project_name = "smoke"
        total_samples = 1
        outdir = "$(outdir)"

        [datavault]
        path_keys = ["system.N"]

        [[paramsets]]
        [paramsets.system]
        N = [4, 8]
        """,
    )
    vault = DataVault.Vault(cfg; run="r1", outdir=outdir)
    for k in DataVault.keys(vault; status=:all)
        DataVault.save!(vault, k, Dict("x" => 1.0))
        DataVault.mark_done!(vault, k; tag_value=1.0)
    end
    DataVault.build_ledger(vault)

    db = joinpath(tmp, "archeion.db")
    res = Archeion.ingest([outdir]; db=db)
    @test res.records == 1
    @test isfile(db)

    # Read columns DURING iteration (SQLite.jl rows are cursor views; don't collect-then-read).
    conn = SQLite.DB(db)
    rid = proj = status = tags = body = ""
    for r in
        DBInterface.execute(conn, "SELECT id, project, status, tags, body_md FROM records")
        rid, proj, status, tags, body = r.id, r.project, r.status, r.tags, r.body_md
    end
    @test rid == "smoke/r1"
    @test proj == "smoke"
    @test status == "active"
    @test occursin("smoke", tags)
    @test occursin("## Provenance", body)   # body_md is the Markdown source-of-truth
    @test occursin("## Ledger", body)

    nfts = 0
    for _ in DBInterface.execute(
        conn, "SELECT rowid FROM records_fts WHERE records_fts MATCH 'Provenance'"
    )
        nfts += 1
    end
    @test nfts == 1                          # FTS5 indexes body_md

    # Idempotent UPSERT: user-set state survives re-ingest; no duplicate row.
    DBInterface.execute(
        conn, "UPDATE records SET tags='[\"mytag\"]', status='done' WHERE id=?", (rid,)
    )
    DBInterface.close!(conn)

    Archeion.ingest([outdir]; db=db)

    conn2 = SQLite.DB(db)
    t2 = s2 = ""
    cnt = 0
    for r in
        DBInterface.execute(conn2, "SELECT tags, status FROM records WHERE id=?", (rid,))
        t2, s2 = r.tags, r.status
    end
    for r in DBInterface.execute(conn2, "SELECT count(*) AS c FROM records")
        cnt = r.c
    end
    nfts2 = 0
    for _ in DBInterface.execute(
        conn2, "SELECT rowid FROM records_fts WHERE records_fts MATCH 'Provenance'"
    )
        nfts2 += 1
    end
    DBInterface.close!(conn2)
    @test t2 == "[\"mytag\"]"                # preserved
    @test s2 == "done"                       # preserved
    @test cnt == 1                           # no duplicate
    @test nfts2 == 1                         # FTS stays consistent after re-ingest (upsert path)
end
