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
    @test occursin("open ftp://ftp.example.com", s)   # explicit FTPS (ftp:// + ssl-force), not implicit ftps://
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

# Machine-global deploy-config DISCOVERY (`_resolve_deploy_config`) + the 0600 perms guarantee
# (`_check_deploy_config_perms`). Every case runs inside a fresh `cd(mktempdir())` and clears
# ARCHEION_DEPLOY/ARCHEION_HOME via `withenv` first, so none of it can see this machine's real
# ~/.archeion or a stray deploy.local.toml — fully isolated + deterministic. Only DUMMY credentials.
@testset "deploy: config discovery order" begin
    @testset "(a) explicit config= path still works" begin
        cd(mktempdir()) do
            withenv("ARCHEION_DEPLOY" => nothing, "ARCHEION_HOME" => mktempdir()) do
                tmp = mktempdir()
                cfg = joinpath(tmp, "explicit.toml")
                write(cfg, "[ftp]\nhost = \"h\"\nuser = \"u\"\npassword = \"DUMMY\"\n")
                r = Archeion._resolve_deploy_config(cfg)
                @test r.path == cfg
                @test r.machine_global == false
            end
        end
    end

    @testset "(b) deploy.local.toml in CWD still works" begin
        cd(mktempdir()) do
            withenv("ARCHEION_DEPLOY" => nothing, "ARCHEION_HOME" => mktempdir()) do
                write(
                    "deploy.local.toml",
                    "[ftp]\nhost = \"h\"\nuser = \"u\"\npassword = \"DUMMY\"\n",
                )
                r = Archeion._resolve_deploy_config(nothing)
                @test r.path == "deploy.local.toml"
                @test r.machine_global == false
                # an explicit (nonexistent) config still falls back to the CWD file
                r2 = Archeion._resolve_deploy_config(joinpath(mktempdir(), "missing.toml"))
                @test r2.path == "deploy.local.toml"
            end
        end
    end

    @testset "(c) ARCHEION_DEPLOY env is discovered" begin
        cd(mktempdir()) do
            envcfg = joinpath(mktempdir(), "envdeploy.toml")
            write(envcfg, "[ftp]\nhost = \"h\"\nuser = \"u\"\npassword = \"DUMMY\"\n")
            withenv("ARCHEION_DEPLOY" => envcfg, "ARCHEION_HOME" => mktempdir()) do
                r = Archeion._resolve_deploy_config(nothing)
                @test r.path == envcfg
                @test r.machine_global == true    # machine-global source -> perms are checked
            end
        end
    end

    @testset "(d) default ~/.archeion/deploy.toml discovered via ARCHEION_HOME" begin
        cd(mktempdir()) do
            home = mktempdir()
            gcfg = joinpath(home, "deploy.toml")
            write(gcfg, "[ftp]\nhost = \"h\"\nuser = \"u\"\npassword = \"DUMMY\"\n")
            chmod(gcfg, 0o600)
            withenv("ARCHEION_DEPLOY" => nothing, "ARCHEION_HOME" => home) do
                r = Archeion._resolve_deploy_config(nothing)
                @test r.path == gcfg
                @test r.machine_global == true
            end
        end
    end

    @testset "(e) ARCHEION_FTP_PASSWORD overrides a machine-global file password" begin
        cd(mktempdir()) do
            home = mktempdir()
            gcfg = joinpath(home, "deploy.toml")
            write(gcfg, "[ftp]\nhost = \"h\"\nuser = \"u\"\npassword = \"DUMMY\"\n")
            chmod(gcfg, 0o600)
            withenv(
                "ARCHEION_DEPLOY" => nothing,
                "ARCHEION_HOME" => home,
                "ARCHEION_FTP_PASSWORD" => "envpw",
            ) do
                r = Archeion._resolve_deploy_config(nothing)
                t = Archeion.read_deploy_target(r.path)
                @test t.password == "envpw"    # env still wins over the file, even discovered
            end
        end
    end

    @testset "(f) group/other-readable machine-global config warns; 0600 is silent" begin
        cd(mktempdir()) do
            gcfg = joinpath(mktempdir(), "deploy.toml")
            write(gcfg, "[ftp]\nhost = \"h\"\nuser = \"u\"\npassword = \"DUMMY\"\n")

            chmod(gcfg, 0o644)   # group+other readable — must warn, naming the file + the fix
            # \Q..\E = PCRE literal-quote, so the temp path's own characters aren't read as regex syntax
            @test_logs (:warn, Regex("chmod 600 \\Q" * gcfg * "\\E")) Archeion._check_deploy_config_perms(
                gcfg
            )

            chmod(gcfg, 0o600)   # tightened — silent
            @test_logs Archeion._check_deploy_config_perms(gcfg)
        end
    end

    @testset "(g) helpful error when nothing is found" begin
        cd(mktempdir()) do
            home = mktempdir()  # empty — no deploy.toml inside
            withenv("ARCHEION_DEPLOY" => nothing, "ARCHEION_HOME" => home) do
                err = try
                    Archeion._resolve_deploy_config(nothing)
                    ""
                catch e
                    sprint(showerror, e)
                end
                @test occursin("ARCHEION_DEPLOY", err)              # names the env var fix
                @test occursin(".archeion", err) || occursin(home, err)  # names the global default
                @test occursin("chmod 600", err)                    # names the perms fix
            end
        end
    end
end
