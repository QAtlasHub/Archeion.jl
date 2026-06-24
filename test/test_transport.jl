# Transport-seam tests (CI-safe — no live FTP). The backend-neutral push/pull seam: config-driven
# resolution, the FTPS GET-script builder, and docroot-relative path joining. The live FTPS pull is
# verified manually with real creds (like the deploy mirror).
using Archeion
using Test

@testset "transport: backend-neutral pull seam" begin
    tmp = mktempdir()
    cfg = joinpath(tmp, "deploy.local.toml")
    write(
        cfg,
        """
        [archeion.remote]
        kind = "ftps"
        db_path = "data/archeion.db"
        [ftp]
        host = "ftp.example.com"
        user = "acct"
        password = "secret"
        remote_dir = "/web/docroot"
        """,
    )

    t = Archeion.transport(cfg)
    @test t isa Archeion.FTPSTransport
    @test t.target.host == "ftp.example.com"
    @test t.target.remote_dir == "/web/docroot"

    # default kind = ftps when [archeion.remote] is absent (backward compatible with [ftp]-only)
    cfg2 = joinpath(tmp, "noremote.toml")
    write(cfg2, "[ftp]\nhost=\"h\"\nuser=\"u\"\npassword=\"p\"\nremote_dir=\"/d\"\n")
    @test Archeion.transport(cfg2) isa Archeion.FTPSTransport
    @test Archeion._config_db_relpath(cfg2) == "data/archeion.db"   # default

    # unknown kind → a clear error pointing at how to add a backend
    cfg3 = joinpath(tmp, "rsync.toml")
    write(cfg3, "[archeion.remote]\nkind=\"rsync\"\n[ftp]\nhost=\"h\"\nuser=\"u\"\npassword=\"p\"\n")
    @test_throws ErrorException Archeion.transport(cfg3)
    @test_throws ErrorException Archeion.pull(cfg3)                  # pull propagates the dispatch error

    # config db relpath
    @test Archeion._config_db_relpath(cfg) == "data/archeion.db"

    # remote path join: docroot-relative vs absolute
    @test Archeion._ftps_remote(t, "data/archeion.db") == "/web/docroot/data/archeion.db"
    @test Archeion._ftps_remote(t, "/abs/x.db") == "/abs/x.db"

    # the lftp GET script is well-formed (pure)
    s = Archeion._lftp_get_script(t, "/web/docroot/data/archeion.db", "/tmp/local.db")
    @test occursin("open ftp://ftp.example.com", s)   # explicit FTPS (ftp:// + ssl-force), not ftps://
    @test occursin("user acct secret", s)
    @test occursin("get /web/docroot/data/archeion.db -o /tmp/local.db", s)
    @test occursin("set ftp:ssl-force true", s)
end
