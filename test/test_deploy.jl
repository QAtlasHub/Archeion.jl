# Deploy-path tests (CI-safe — no live FTP). Cover config parsing, the lftp script builder,
# and Basic-auth file generation; the live FTPS mirror is verified manually with real creds.
using Archeion
using Test

@testset "deploy: config parsing" begin
    tmp = mktempdir()
    cfg = joinpath(tmp, "deploy.local.toml")
    write(
        cfg,
        """
        [ftp]
        host = "ftp.example.com"
        user = "acct"
        password = "secret"
        remote_dir = "/web/data"
        """,
    )
    t = Archeion.read_deploy_target(cfg)
    @test t.host == "ftp.example.com"
    @test t.user == "acct"
    @test t.password == "secret"
    @test t.remote_dir == "/web/data"
    @test t.tls == true && t.tls_verify == true

    withenv("ARCHEION_FTP_PASSWORD" => "envpw") do
        @test Archeion.read_deploy_target(cfg).password == "envpw"  # env overrides the file
    end

    nopw = joinpath(tmp, "nopw.toml")
    write(nopw, "[ftp]\nhost = \"h\"\nuser = \"u\"\n")
    withenv("ARCHEION_FTP_PASSWORD" => nothing) do
        @test_throws ErrorException Archeion.read_deploy_target(nopw)
    end
    @test_throws ErrorException Archeion.read_deploy_target(joinpath(tmp, "missing.toml"))
end

@testset "deploy: lftp script is well-formed" begin
    t = Archeion.DeployTarget("ftp.example.com", "acct", "secret", "/web/data", true, true)
    s = Archeion._lftp_script(t, "/tmp/site"; delete=true)
    @test occursin("open ftps://ftp.example.com", s)
    @test occursin("user acct secret", s)
    @test occursin("mirror -R --delete", s)
    @test occursin("/web/data", s)
    @test occursin("set ftp:ssl-force true", s)
    # delete=false drops the --delete flag
    @test !occursin("--delete", Archeion._lftp_script(t, "/tmp/site"; delete=false))
end

@testset "deploy: write_basic_auth" begin
    if Sys.which("openssl") === nothing
        @info "openssl not found — skipping Basic-auth test"
    else
        site = mktempdir()
        Archeion.write_basic_auth(site; user="viewer", password="pw", realm="Reg")
        ht = read(joinpath(site, ".htpasswd"), String)
        @test startswith(ht, "viewer:")
        @test occursin(r"\$apr1\$", ht)              # apr1-hashed, not plaintext
        @test !occursin("pw\n", ht)                  # the raw password is not written
        acc = read(joinpath(site, ".htaccess"), String)
        @test occursin("Require valid-user", acc)
        @test occursin("AuthName \"Reg\"", acc)
    end
end

@testset "deploy: guards" begin
    @test_throws ErrorException Archeion.deploy(joinpath(mktempdir(), "nope"))  # missing site dir
end
