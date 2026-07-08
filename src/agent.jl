# agent.jl — the "ssh-agent for the deploy config". A human starts it once in an interactive REPL
# (`Archeion.initialize`): it decrypts the config, holds the deploy TARGET + CREDS in PROCESS MEMORY,
# and serves a local UNIX socket (0600). Archeion's `deploy`/`pull`/`status` (which the LLM runs in
# separate, non-interactive processes) connect to that socket and REQUEST operations — the agent does
# the FTP with its in-memory creds and returns only results. The protocol has NO op that returns the
# config or creds, so the caller can USE the deploy but can never READ the secret. The socket is the
# host-local default: any process on the host resolves it via ~/.archeion/active.toml.

# ── host-local paths (overridable for tests via ARCHEION_HOME) ──────────────────────────────────────
_archeion_home() = get(ENV, "ARCHEION_HOME", joinpath(homedir(), ".archeion"))
agent_socket() = joinpath(_archeion_home(), "agent.sock")
active_path() = joinpath(_archeion_home(), "active.toml")

# the local mirror dir the agent pushes (the agent controls WHAT reaches the hidden remote) + the
# remote DB's docroot-relative path, both from the held config.
_content_dir(cfg) = string(get(get(cfg, "archeion", Dict{String,Any}()), "content_dir", ""))
function _db_relpath(cfg)
    rem = get(get(cfg, "archeion", Dict{String,Any}()), "remote", Dict{String,Any}())
    return string(get(rem, "db_path", "data/archeion.db"))
end

# ── server side (runs in the human's REPL; holds the secret) ────────────────────────────────────────
# Handle one request Dict → reply Dict. Secret-using ops (push/pull) call the transport built from the
# in-memory config. There is deliberately NO "reveal"/"config" op.
function _handle(req::AbstractDict, cfg)
    op = String(get(req, "op", ""))
    if op == "ping"
        return Dict{String,Any}("ok" => true, "host" => gethostname())
    elseif op == "push"
        # A caller-supplied `site` (an absolute local dir) wins, so any project's STAGE can be
        # deployed through the agent (creds stay here) — symmetric with the explicit
        # `deploy(site; config)`. Falls back to the config's `[archeion].content_dir`.
        site = String(get(req, "site", _content_dir(cfg)))
        isempty(site) && return Dict{String,Any}(
            "ok" => false,
            "error" => "push: no `site` given and no [archeion].content_dir in config",
        )
        isdir(site) || return Dict{String,Any}(
            "ok" => false, "error" => "push: site dir not found: $(site)"
        )
        push_dir(_transport_from(cfg), site; delete=Bool(get(req, "delete", false)))
        return Dict{String,Any}("ok" => true, "pushed" => site)
    elseif op == "pull"
        dest = String(get(req, "dest", ""))
        isempty(dest) &&
            return Dict{String,Any}("ok" => false, "error" => "pull needs a local dest")
        pull_file(_transport_from(cfg), _db_relpath(cfg), dest)
        return Dict{String,Any}("ok" => true, "dest" => dest)
    end
    return Dict{String,Any}("ok" => false, "error" => "unknown op: $(op)")
end

function _serve_conn(conn, cfg)
    try
        req = deserialize(conn)
        serialize(
            conn,
            if req isa AbstractDict
                _handle(req, cfg)
            else
                Dict("ok" => false, "error" => "bad request")
            end,
        )
    catch e
        try
            serialize(
                conn, Dict{String,Any}("ok" => false, "error" => sprint(showerror, e))
            )
        catch
        end
    finally
        close(conn)
    end
end

# Listen on the 0600 socket and serve forever (BLOCKS — meant to run in a dedicated REPL/pane). `cfg` is
# the decrypted config, held only here in memory. Factored out so tests can drive it with a plain Dict
# (no password path), exercising the real socket protocol.
function _serve_loop(cfg::AbstractDict, sock::AbstractString=agent_socket())
    mkpath(dirname(sock))
    ispath(sock) && rm(sock; force=true)   # a socket is NOT a regular file → use ispath, not isfile
    server = listen(sock)
    try
        chmod(sock, 0o600)
    catch
    end
    @info "Archeion agent: serving (config in memory; Ctrl-C to stop)" socket = sock host = gethostname()
    try
        while true
            conn = accept(server)
            @async _serve_conn(conn, cfg)
        end
    finally
        close(server)
        rm(sock; force=true)
    end
end

# ── client side (runs in the LLM's non-interactive processes; never sees the secret) ────────────────
function _agent(req::AbstractDict; sock::AbstractString=agent_socket())
    ispath(sock) || error(
        "Archeion: no agent socket at $(sock) — run `Archeion.initialize(\"config.enc\")` in an " *
        "interactive REPL on this host first.",
    )
    conn = connect(sock)
    try
        serialize(conn, req)
        flush(conn)
        return deserialize(conn)
    finally
        close(conn)
    end
end

"True if a responsive agent is listening on this host's socket."
function agent_up(; sock::AbstractString=agent_socket())
    ispath(sock) || return false
    try
        return Bool(get(_agent(Dict("op" => "ping"); sock=sock), "ok", false))
    catch
        return false
    end
end
