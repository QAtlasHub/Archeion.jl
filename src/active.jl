# active.jl — the host-default "initialized config" + the no-config front door. A human runs
# `initialize` once (interactive REPL): it unlocks the config into the agent (agent.jl) and writes a
# NON-SECRET ~/.archeion/active.toml (socket + local working paths only — never the target/creds). Then
# every Archeion call on the host with no explicit config resolves through active.toml, so even a fresh
# per-project environment defaults to the terminal's initialized config. Secret-using steps (deploy/pull)
# are delegated to the agent; the LLM's processes never hold the creds.

"""
    initialize(config_enc="config.enc")

REPL-ONLY (a human at a terminal). Prompt for the password (hidden), decrypt `config_enc` in memory,
write the NON-SECRET host default `~/.archeion/active.toml` (active project + local working paths +
socket — NO target/creds), then BLOCK serving the agent (run this in a dedicated terminal/tmux pane).

After this, on the same host, `deploy()` / `pull()` / `status()` / `publish(...)` work with no config —
they resolve paths from active.toml and delegate the credentialed FTP to this agent. The decrypted
target + creds live ONLY in this process's memory; nothing on disk or any socket op reveals them.
"""
function initialize(config_enc::AbstractString="config.enc")
    _require_repl("initialize")
    pw = Base.getpass("Config password")
    s = read(pw, String)
    Base.shred!(pw)
    plain = try
        _decrypt_to_string(config_enc, s)
    catch
        s = ""
        error("initialize: decryption failed (wrong password or corrupt $(config_enc)).")
    end
    s = ""
    cfg = TOML.parse(plain)
    plain = ""
    arche = get(cfg, "archeion", Dict{String,Any}())
    study = get(cfg, "study", Dict{String,Any}())
    home = _archeion_home()
    mkpath(home)
    # active.toml = the host default. NON-SECRET: only the socket + LOCAL working paths the LLM needs to
    # render/ingest. The deploy target (host/dir) + creds are NOT here — they stay in the agent's memory.
    active = Dict{String,Any}(
        "socket" => agent_socket(),
        "project" => string(get(arche, "project", get(study, "project_name", ""))),
        "content_dir" => string(get(arche, "content_dir", "")),
        "db" => string(get(arche, "db", "")),
        "out" => string(get(arche, "out", "")),
        "host" => gethostname(),
    )
    open(active_path(), "w") do io
        return TOML.print(io, active)
    end
    try
        chmod(active_path(), 0o644)
    catch
    end
    write(joinpath(home, "agent.pid"), string(getpid()))
    @info "Archeion initialized — this REPL is now the agent (Ctrl-C to stop)" project = active["project"] socket = agent_socket() host = gethostname()
    return _serve_loop(cfg, agent_socket())   # BLOCKS
end

"""
    active() -> Dict

The host's initialized config (the non-secret `active.toml`): `socket`, `project`, `content_dir`, `db`,
`out`, `host`. Errors if the host hasn't been `initialize`d. This is what makes a per-project
environment fall back to the terminal default with no explicit config.
"""
function active()
    p = active_path()
    isfile(p) || error(
        "Archeion: this host isn't initialized — run `Archeion.initialize(\"config.enc\")` in an " *
        "interactive REPL (a dedicated pane) first.",
    )
    return TOML.parsefile(p)
end

"Remove the host default (stops resolving to it; does NOT stop a running agent — Ctrl-C its pane)."
function deinitialize()
    for f in (active_path(), joinpath(_archeion_home(), "agent.pid"))
        rm(f; force=true)
    end
    return nothing
end

# ── no-config front door (the LLM's path; secret ops delegated to the agent) ────────────────────────
"""
    deploy(; site="", delete=false) -> Dict

Push a local content tree to the (agent-held, hidden) remote via the agent — no config/creds in the
caller, the agent does the FTP. `site` is the local docroot-level dir to push; when omitted, the agent
falls back to the config's `[archeion].content_dir`. Passing `site` lets **any** project's STAGE deploy
through the machine-global agent (creds stay in the agent), mirroring the explicit `deploy(site; config)`
form — so the config-file and machine-global paths coexist over the same `[ftp]` config.
"""
function deploy(; site::AbstractString="", delete::Bool=false)
    a = active()
    req = Dict{String,Any}("op" => "push", "delete" => delete)
    isempty(site) || (req["site"] = abspath(site))
    r = _agent(req; sock=String(a["socket"]))
    Bool(get(r, "ok", false)) ||
        error("Archeion.deploy (agent): " * String(get(r, "error", "failed")))
    return r
end

"""
    pull(; dest=<active content_dir>/data/archeion.db) -> dest

Fetch the live registry DB via the agent (credentialed) to a local `dest`. The DB content is non-secret;
the creds that fetch it stay in the agent. Distinct from `pull(config; out)` (the explicit form).
"""
function pull(; dest::AbstractString="")
    a = active()
    isempty(dest) && (dest = joinpath(String(a["content_dir"]), "data", "archeion.db"))
    mkpath(dirname(dest))
    r = _agent(Dict("op" => "pull", "dest" => String(dest)); sock=String(a["socket"]))
    Bool(get(r, "ok", false)) ||
        error("Archeion.pull (agent): " * String(get(r, "error", "failed")))
    return dest
end

"""
    publish(; doc, source, project=active project, html_dir=active out, delete=false) -> NamedTuple

The annotation-safe round-trip with NO config in the caller: pull the live DB via the agent → ingest
`doc` into the active content tree (preserving existing annotations) → push via the agent. The creds
never leave the agent.
"""
function publish(;
    doc,
    source::AbstractString,
    project::AbstractString="",
    html_dir::AbstractString="",
    delete::Bool=false,
)
    a = active()
    content_dir = String(a["content_dir"])
    db = if isempty(String(get(a, "db", "")))
        joinpath(content_dir, "data", "archeion.db")
    else
        String(a["db"])
    end
    isempty(project) && (project = String(a["project"]))
    isempty(html_dir) && (html_dir = String(get(a, "out", "")))
    mkpath(dirname(db))
    try
        pull(; dest=db)
        @info "publish: pulled the live DB via the agent (annotations preserved)" db
    catch e
        e isa InterruptException && rethrow()
        @warn "publish: could not pull a live DB (first publish?) — ingesting fresh" exception =
            e
    end
    res = ingest(
        doc;
        db=db,
        project=project,
        source=source,
        html_dir=html_dir,
        content_dir=content_dir,
    )
    deploy(; delete=delete)
    @info "publish: pushed via the agent" record = res.record
    return res
end
