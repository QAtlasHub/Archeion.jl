# Deploy the built static site to a private host over FTPS — Lolipop has no SSH, so FTPS
# (via lftp) is the upload path. Credentials + remote target live in a gitignored per-project
# config (deploy.local.toml) or env vars, OR a machine-global config discovered via
# ARCHEION_DEPLOY / ~/.archeion/deploy.toml (see `_resolve_deploy_config` below) — never in the
# repo. Optionally writes .htaccess/.htpasswd for HTTP Basic auth so the published site stays
# private.

struct DeployTarget
    host::String
    user::String
    password::String
    remote_dir::String
    tls::Bool
    tls_verify::Bool
end

"""
    read_deploy_target(config) -> DeployTarget

Read FTPS credentials + remote target from a gitignored TOML `config` with an `[ftp]`
table (`host`, `user`, `password`, `remote_dir`, optional `tls`/`tls_verify`). The password
may instead come from `ENV["ARCHEION_FTP_PASSWORD"]` (preferred — keeps it out of files).
`config` must already be a concrete, resolved path — see `deploy`/`_resolve_deploy_config` for
how that path is discovered (explicit arg → CWD `deploy.local.toml` → `ARCHEION_DEPLOY` env →
machine-global `~/.archeion/deploy.toml`).
"""
function read_deploy_target(config::AbstractString)
    isfile(config) || error("read_deploy_target: config not found: $(config)")
    d = TOML.parsefile(config)
    f = get(d, "ftp", Dict{String,Any}())
    host = get(f, "host", "")
    user = get(f, "user", "")
    pw = get(ENV, "ARCHEION_FTP_PASSWORD", get(f, "password", ""))
    (isempty(host) || isempty(user)) &&
        error("read_deploy_target: [ftp].host and [ftp].user are required in $(config).")
    isempty(pw) && error(
        "read_deploy_target: no FTP password — set [ftp].password in $(config) or the ARCHEION_FTP_PASSWORD env var.",
    )
    return DeployTarget(
        host,
        user,
        String(pw),
        get(f, "remote_dir", "/"),
        get(f, "tls", true),
        get(f, "tls_verify", true),
    )
end

# Apache apr1 (MD5) hash via openssl, with the password fed on stdin so it never appears in
# process arguments / the process list.
function _apr1(password::AbstractString)
    p = open(`openssl passwd -apr1 -stdin`, "r+")
    write(p, password * "\n")
    close(p.in)
    h = strip(read(p, String))
    wait(p)
    return h
end

"""
    write_basic_auth(site; user, password, realm="Archeion") -> nothing

Write `.htaccess` + `.htpasswd` into `site` for HTTP Basic auth (Apache/Lolipop), making the
deployed site private. The password is hashed with `openssl passwd -apr1`. (Alternative:
configure Basic auth via Lolipop's access-restriction panel and skip this.)
"""
function write_basic_auth(
    site::AbstractString;
    user::AbstractString,
    password::AbstractString,
    realm::AbstractString="Archeion",
)
    write(joinpath(site, ".htpasswd"), string(user, ":", _apr1(password), "\n"))
    write(
        joinpath(site, ".htaccess"),
        """
        AuthType Basic
        AuthName "$(realm)"
        AuthUserFile %{DOCUMENT_ROOT}/.htpasswd
        Require valid-user
        """,
    )
    return nothing
end

# Build the lftp script that mirrors `site` to the remote dir. Kept pure for testability;
# the password appears only inside this script (written to a 0600 temp file by `deploy`),
# never in process arguments.
function _lftp_script(t::DeployTarget, site::AbstractString; delete::Bool=true)
    # Explicit FTPS (FTPES) over port 21 via `ftp://` + ssl-force. NOT `ftps://`, which lftp
    # treats as implicit FTPS on port 990 — Lolipop doesn't serve that and it times out.
    return """
    set ftp:ssl-force $(t.tls)
    set ftp:ssl-protect-data $(t.tls)
    set ssl:verify-certificate $(t.tls_verify)
    set ftp:passive-mode true
    set net:timeout 30
    set net:max-retries 2
    set net:reconnect-interval-base 5
    open ftp://$(t.host)
    user $(t.user) $(t.password)
    mirror -R$(delete ? " --delete" : "") --parallel=4 --verbose $(site) $(t.remote_dir)
    bye
    """
end

# Run an lftp script from a 0600 temp file (the password lands only in that file, never in process
# args). Shared by `deploy` (push) and the FTPS transport (push_dir / pull_file in transport.jl).
function _run_lftp(script::AbstractString)
    lftp = Sys.which("lftp")
    lftp === nothing && error("Archeion: `lftp` not found — needed for FTPS.")
    sf = tempname()
    write(sf, script)
    chmod(sf, 0o600)
    try
        run(`$lftp -f $sf`)
    finally
        rm(sf; force=true)
    end
    return nothing
end

# ── machine-global deploy config discovery ──────────────────────────────────────────────────────────
# Resolve WHICH config file `deploy` should read, so a single 0600 file OUTSIDE every repo
# (`<ARCHEION_HOME>/deploy.toml`, default `~/.archeion/deploy.toml` — `_archeion_home` is defined in
# agent.jl) can drive deploy for every project on this machine: no per-project config, no password
# prompt. First hit wins:
#   1. `config`, if given and it exists                            (explicit — backward compat)
#   2. `deploy.local.toml` in the current directory, if it exists  (implicit CWD — backward compat)
#   3. ENV["ARCHEION_DEPLOY"], if set                               (machine-global, explicit path)
#   4. `<ARCHEION_HOME>/deploy.toml`, if it exists                  (machine-global default)
# Returns `(; path, machine_global)`. `machine_global` (true only for sources 3/4) tells `deploy`
# whether to run the 0600 perms check below — an explicit arg or a CWD project file is the caller's
# own business, not machine-wide secret storage, so it's left alone.
function _resolve_deploy_config(config::Union{Nothing,AbstractString})
    cwd_local = "deploy.local.toml"
    env_path = get(ENV, "ARCHEION_DEPLOY", "")
    global_path = joinpath(_archeion_home(), "deploy.toml")

    if config !== nothing && isfile(config)
        return (; path=String(config), machine_global=false)
    elseif isfile(cwd_local)
        return (; path=cwd_local, machine_global=false)
    elseif !isempty(env_path)
        return (; path=env_path, machine_global=true)
    elseif isfile(global_path)
        return (; path=global_path, machine_global=true)
    end
    return error(
        "Archeion: no deploy config found. Tried, in order: " *
        (config === nothing ? "" : "explicit config $(config); ") *
        "./$(cwd_local) (cwd); ENV[\"ARCHEION_DEPLOY\"] (unset or missing); $(global_path) " *
        "(machine-global default). Fix: create a machine-global config at " *
        "~/.archeion/deploy.toml — chmod 600 it! (copy deploy.example.toml) — or set " *
        "ARCHEION_DEPLOY to point at your config file.",
    )
end

# Warn — never hard-error, so we don't break a working deploy — if a MACHINE-GLOBAL config (only
# sources 3/4 above) is readable/writable by group or other. Perms, not encryption, are the whole
# mechanism that keeps a plaintext credential file living outside the repo "hard to see from
# outside", so this is the enforcement point: it reads ONLY the mode bits (`filemode`), never the
# file's contents, and never logs the password or any config contents.
function _check_deploy_config_perms(path::AbstractString)
    try
        mode = filemode(path) & 0o777
        if !iszero(mode & 0o077)
            @warn "Archeion: deploy config is readable/writable by group or other — it may hold " *
                "an FTP password. Fix: chmod 600 $(path)" path = path mode = string(
                mode; base=8
            )
        end
    catch e
        e isa InterruptException && rethrow()
        # advisory only — never let a perms-check failure break a working deploy
        @warn "Archeion: could not check permissions on deploy config" path = path exception =
            e
    end
    return nothing
end

"""
    deploy(site; config=nothing, delete=true) -> Bool

Mirror the static site at `site` to a private host over FTPS using a resolved deploy config.
`config` is resolved by `_resolve_deploy_config`, in order: the explicit `config` arg (if it
exists) → `deploy.local.toml` in the current directory → `ENV["ARCHEION_DEPLOY"]` → the
machine-global default `<ARCHEION_HOME>/deploy.toml` (default `~/.archeion/deploy.toml`). That
lets ONE 0600 file outside every repo drive deploy for every project on a machine — no
per-project config, no password prompt. A machine-global config (the last two sources) that is
group- or other-readable/writable gets a prominent `@warn` naming the file and the `chmod 600`
fix (never a hard error — permissions, not encryption, are what make the secret "hard to see
from outside"). Uploads via `lftp`, passing credentials in a 0600 temp script (password never in
process args). With `delete=true` the remote mirrors the local tree exactly (removes stale
remote files). Returns `true` on success.
"""
function deploy(
    site::AbstractString; config::Union{Nothing,AbstractString}=nothing, delete::Bool=true
)
    isdir(site) || error("deploy: site dir not found: $(site)")
    resolved = _resolve_deploy_config(config)
    resolved.machine_global && _check_deploy_config_perms(resolved.path)
    _run_lftp(_lftp_script(read_deploy_target(resolved.path), site; delete=delete))
    return true
end
