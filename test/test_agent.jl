# Tests for the secret-agent layer: at-rest config encryption, the REPL-only gate (the LLM, always
# non-interactive here, must be refused), hostname-dispatched transport, the agent request handler, and
# a real local-socket round-trip. The credential never appears in any reply.

using Test
using Archeion
using Sockets: listen, accept
import Archeion:
    _encrypt_file,
    _decrypt_to_string,
    _transport_from,
    _handle,
    _serve_conn,
    _agent,
    agent_socket,
    active_path,
    LocalTransport

@testset "secret: encrypt/decrypt round-trips; wrong password reveals nothing" begin
    dir = mktempdir()
    plain = joinpath(dir, "config.toml")
    write(plain, "[ftp]\nhost=\"ftp.example.com\"\npassword=\"s3cr3t!\"\n")
    enc = joinpath(dir, "config.enc")
    _encrypt_file(plain, enc, "correct horse")
    @test isfile(enc)
    @test !occursin("s3cr3t!", read(enc, String))                 # ciphertext, not plaintext
    @test occursin("s3cr3t!", _decrypt_to_string(enc, "correct horse"))
    @test_throws Exception _decrypt_to_string(enc, "wrong password")  # wrong pw → error, no secret
end

@testset "REPL-only gate: the LLM (non-interactive) cannot init/lock/view" begin
    @test !isinteractive()                                          # the test process IS the LLM's situation
    for f in
        (() -> initialize("x.enc"), () -> lock_config("x.toml"), () -> view_config("x.enc"))
        err = try
            f()
            ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("REPL-only", err)
    end
end

@testset "hostname dispatch: _transport_from picks the right backend" begin
    here = gethostname()
    loc = Dict(
        "archeion" =>
            Dict("hosts" => Dict(here => Dict("kind" => "local", "path" => "/tmp/x"))),
    )
    @test _transport_from(loc) isa LocalTransport
    # flat ftps fallback when no per-host entry matches
    ftp = Dict(
        "ftp" => Dict("host" => "h", "user" => "u", "password" => "p"),
        "archeion" => Dict("remote" => Dict("kind" => "ftps")),
    )
    @test _transport_from(ftp) isa Archeion.FTPSTransport
end

@testset "agent handler: push lands on the (hidden) remote; pull fetches; no reveal op" begin
    dir = mktempdir()
    remote = joinpath(dir, "remote")
    content = joinpath(dir, "content")
    mkpath(joinpath(content, "data"))
    write(joinpath(content, "index.html"), "<html>r</html>")
    write(joinpath(content, "data", "archeion.db"), "STAGED")
    mkpath(joinpath(remote, "data"))
    write(joinpath(remote, "data", "archeion.db"), "LIVE")
    cfg = Dict(
        "archeion" => Dict(
            "content_dir" => content,
            "remote" => Dict(
                "kind" => "local", "path" => remote, "db_path" => "data/archeion.db"
            ),
        ),
    )
    @test _handle(Dict("op" => "ping"), cfg)["ok"]
    @test _handle(Dict("op" => "push", "delete" => false), cfg)["ok"]
    @test read(joinpath(remote, "index.html"), String) == "<html>r</html>"   # landed on the remote
    dest = joinpath(dir, "pulled.db")
    @test _handle(Dict("op" => "pull", "dest" => dest), cfg)["ok"]
    @test read(dest, String) == "STAGED"   # (push overwrote the remote db, then pull fetched it)
    rev = _handle(Dict("op" => "reveal"), cfg)                       # no op exposes the config/creds
    @test !rev["ok"] && occursin("unknown op", rev["error"])
end

@testset "agent push: a caller-supplied `site` overrides content_dir (any STAGE via the agent)" begin
    dir = mktempdir()
    remote = joinpath(dir, "remote")
    content = joinpath(dir, "content")
    mkpath(content)
    write(joinpath(content, "from_content.txt"), "C")
    stage = joinpath(dir, "stage")
    mkpath(stage)
    write(joinpath(stage, "from_stage.txt"), "S")
    cfg = Dict(
        "archeion" => Dict(
            "content_dir" => content,
            "remote" => Dict(
                "kind" => "local", "path" => remote, "db_path" => "data/archeion.db"
            ),
        ),
    )
    # `site` given → THAT dir is pushed, not content_dir (per-project STAGE via the agent)
    @test _handle(Dict("op" => "push", "site" => stage, "delete" => false), cfg)["ok"]
    @test isfile(joinpath(remote, "from_stage.txt"))
    @test !ispath(joinpath(remote, "from_content.txt"))
    # no `site` AND no content_dir → a clear error, never a silent empty push
    nocfg = Dict("archeion" => Dict("remote" => Dict("kind" => "local", "path" => remote)))
    r = _handle(Dict("op" => "push"), nocfg)
    @test !r["ok"] && occursin("no `site`", r["error"])
end

@testset "socket wire: a real connect→serialize→handle→deserialize round-trip" begin
    dir = mktempdir()
    sock = joinpath(dir, "a.sock")
    remote = joinpath(dir, "remote")
    content = joinpath(dir, "content")
    mkpath(content)
    write(joinpath(content, "f.txt"), "payload")
    cfg = Dict(
        "archeion" => Dict(
            "content_dir" => content,
            "remote" => Dict(
                "kind" => "local", "path" => remote, "db_path" => "data/archeion.db"
            ),
        ),
    )
    srv = listen(sock)
    client = @async _agent(Dict("op" => "push", "delete" => false); sock=sock)  # client connects+sends+awaits
    conn = accept(srv)            # server side, synchronous → deterministic (no async-accept race)
    _serve_conn(conn, cfg)
    reply = fetch(client)
    close(srv)
    @test reply["ok"]
    @test read(joinpath(remote, "f.txt"), String) == "payload"   # pushed over the real socket
end
