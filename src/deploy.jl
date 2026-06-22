# Deploy the built static site to a private host over FTPS — Lolipop has no SSH, so FTPS
# (via lftp) is the upload path. Credentials + remote target live in a gitignored config
# (deploy.local.toml) or env vars; they never enter the repo. Optionally writes
# .htaccess/.htpasswd for HTTP Basic auth so the published site stays private.

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
    scheme = t.tls ? "ftps" : "ftp"
    return """
    set ftp:ssl-force $(t.tls)
    set ssl:verify-certificate $(t.tls_verify)
    open $(scheme)://$(t.host)
    user $(t.user) $(t.password)
    mirror -R$(delete ? " --delete" : "") --verbose $(site) $(t.remote_dir)
    bye
    """
end

"""
    deploy(site; config="deploy.local.toml", delete=true) -> Bool

Mirror the static site at `site` to a private host over FTPS using `config`. Uploads via
`lftp`, passing credentials in a 0600 temp script (password never in process args). With
`delete=true` the remote mirrors the local tree exactly (removes stale remote files).
Returns `true` on success.
"""
function deploy(
    site::AbstractString; config::AbstractString="deploy.local.toml", delete::Bool=true
)
    isdir(site) || error("deploy: site dir not found: $(site)")
    lftp = Sys.which("lftp")
    lftp === nothing && error("deploy: `lftp` not found — needed for the FTPS upload.")
    t = read_deploy_target(config)
    sf = tempname()
    write(sf, _lftp_script(t, site; delete=delete))
    chmod(sf, 0o600)
    try
        run(`$lftp -f $sf`)
        return true
    finally
        rm(sf; force=true)
    end
end
