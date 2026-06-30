# transport.jl — the registry-sync SEAM (backend-neutral). The registry DB + content live on a remote
# host; `ingest` and the readers (read.jl) work on a LOCAL copy. A `RemoteTransport` moves the registry
# to/from that host, and the backend is PLUGGABLE behind `pull` / `push`, resolved from config — the
# hosting choice (FTPS today; Cloudflare / rsync / local later) never leaks into Archeion's logic.
# Same neutral-seam style as `config.toml` / `agent.json` elsewhere in the stack.
#
# To add a backend: `struct XTransport <: RemoteTransport`, implement `pull_file` + `push_dir`, and a
# `kind` branch in `transport(config)`. Nothing else in Archeion changes.

"A backend that moves the registry to/from its host. Implement `pull_file(t, relpath, local)` and `push_dir(t, dir; delete)`."
abstract type RemoteTransport end

# ===================== FTPS backend (Lolipop) — wraps DeployTarget + lftp =====================
struct FTPSTransport <: RemoteTransport
    target::DeployTarget
end

# lftp script to GET one remote file → local (pure; the password lands only in a 0600 temp script).
function _lftp_get_script(t::FTPSTransport, remote::AbstractString, dest::AbstractString)
    g = t.target
    return """
    set ftp:ssl-force $(g.tls)
    set ftp:ssl-protect-data $(g.tls)
    set ssl:verify-certificate $(g.tls_verify)
    set ftp:passive-mode true
    set net:timeout 30
    set net:max-retries 2
    open ftp://$(g.host)
    user $(g.user) $(g.password)
    get $(remote) -o $(dest)
    bye
    """
end

# remote path of a file under the docroot: absolute as-is, else joined to the FTPS remote_dir.
function _ftps_remote(t::FTPSTransport, rel::AbstractString)
    return startswith(rel, "/") ? String(rel) : rstrip(t.target.remote_dir, '/') * "/" * rel
end

function pull_file(t::FTPSTransport, rel::AbstractString, dest::AbstractString)
    remote = _ftps_remote(t, rel)
    mkpath(dirname(abspath(dest)))
    _run_lftp(_lftp_get_script(t, remote, dest))
    isfile(dest) ||
        error("pull_file: nothing fetched to $(dest) — check the remote path '$(remote)'.")
    return dest
end

function push_dir(t::FTPSTransport, dir::AbstractString; delete::Bool=true)
    return (_run_lftp(_lftp_script(t.target, dir; delete=delete)); true)
end

# ===================== Local backend (a non-remote host + tests) =====================
"A backend that mirrors to/from a local directory (`root`). Used when a host's deploy target is local
(hostname dispatch) and as a credential-free transport in tests."
struct LocalTransport <: RemoteTransport
    root::String
end
function pull_file(t::LocalTransport, rel::AbstractString, dest::AbstractString)
    src = startswith(rel, "/") ? String(rel) : joinpath(t.root, rel)
    isfile(src) || error("pull_file(local): not found: $(src)")
    mkpath(dirname(abspath(dest)))
    cp(src, dest; force=true)
    return dest
end
function push_dir(t::LocalTransport, dir::AbstractString; delete::Bool=true)
    mkpath(t.root)
    if delete
        # mirror exactly: drop local-root files not present in `dir`
        keep = Set(relpath(joinpath(r, f), dir) for (r, _, fs) in walkdir(dir) for f in fs)
        for (r, _, fs) in walkdir(t.root), f in fs
            rel = relpath(joinpath(r, f), t.root)
            rel in keep || rm(joinpath(t.root, rel); force=true)
        end
    end
    for (r, _, fs) in walkdir(dir), f in fs
        s = joinpath(r, f)
        d = joinpath(t.root, relpath(s, dir))
        mkpath(dirname(d))
        cp(s, d; force=true)
    end
    return true
end

# ===================== config resolution (kind-dispatched) =====================

# Build a transport from an already-parsed config Dict (the agent holds the decrypted config in memory,
# not a path). Hostname dispatch: a per-host table [archeion.hosts.<hostname>] overrides `kind`/`path`;
# else the flat [archeion.remote] / [ftp]. This is how `initialize` on panza → Lolipop, on another host
# → a local dir, from the SAME config — the host is read at deploy time.
function _transport_from(cfg::AbstractDict)
    arche = get(cfg, "archeion", Dict{String,Any}())
    rem = get(arche, "remote", Dict{String,Any}())
    host = gethostname()
    hostcfg = get(get(arche, "hosts", Dict{String,Any}()), host, Dict{String,Any}())
    hostcfg isa AbstractDict || (hostcfg = Dict{String,Any}())
    kind = lowercase(string(get(hostcfg, "kind", get(rem, "kind", "ftps"))))
    if kind == "local"
        return LocalTransport(string(get(hostcfg, "path", get(rem, "path", ""))))
    elseif kind in ("ftps", "ftp")
        f = get(cfg, "ftp", Dict{String,Any}())
        return FTPSTransport(
            DeployTarget(
                string(f["host"]),
                string(f["user"]),
                string(get(f, "password", "")),
                string(get(f, "remote_dir", "/")),
                get(f, "tls", true),
                get(f, "tls_verify", true),
            ),
        )
    end
    return error("_transport_from: unknown remote kind '$(kind)'")
end
"""
    transport(config) -> RemoteTransport

Build the remote transport from `config`'s `[archeion.remote].kind` (default `"ftps"`). FTPS reads its
credentials from `[ftp]` (see `read_deploy_target`). Other backends plug in via a new `kind` branch.
"""
function transport(config::AbstractString)
    d = TOML.parsefile(config)
    rem = get(get(d, "archeion", Dict{String,Any}()), "remote", Dict{String,Any}())
    kind = lowercase(String(get(rem, "kind", "ftps")))
    kind in ("ftps", "ftp") && return FTPSTransport(read_deploy_target(config))
    return error(
        "transport: remote kind '$(kind)' not implemented — supported: ftps. " *
        "Add a RemoteTransport backend (struct + pull_file/push_dir + a kind branch) for '$(kind)'.",
    )
end

# the DB's path relative to the remote docroot — [archeion.remote].db_path (default "data/archeion.db").
function _config_db_relpath(config::AbstractString)
    d = TOML.parsefile(config)
    rem = get(get(d, "archeion", Dict{String,Any}()), "remote", Dict{String,Any}())
    return String(get(rem, "db_path", "data/archeion.db"))
end

"""
    pull(config; out=joinpath(tempdir(), "archeion.db"), remote_db=nothing) -> local_db_path

Fetch the LIVE registry DB from the remote host to `out`, so the annotation readers (`record_comments`,
`record_annotations`, `feedback_md`, …) see the web app's latest human annotations. Backend-neutral —
dispatches on `[archeion.remote].kind`. `remote_db` overrides the DB's remote (docroot-relative) path.
"""
function pull(
    config::AbstractString;
    out::AbstractString=joinpath(tempdir(), "archeion.db"),
    remote_db=nothing,
)
    t = transport(config)
    rel = remote_db === nothing ? _config_db_relpath(config) : String(remote_db)
    return pull_file(t, rel, out)
end

"""
    publish(doc; config, project, source, site, runs=[], html_dir="",
            db=joinpath(site, "data", "archeion.db"), content_dir=dirname(db),
            remote_db=nothing, delete=true) -> NamedTuple

The annotation-SAFE registry round-trip for a REMOTE registry: **pull** the live DB → **ingest** `doc`
into it (content UPSERTs by stable id; the human annotations already in it — comments / tags / status /
project notes — are preserved by the content/annotation split) → **push** `site` (the DB + figures)
back. Use this instead of `ingest` + `deploy` when humans annotate on the remote, so a redeploy never
clobbers their work. On the first publish (no remote DB yet) it ingests fresh and pushes. Returns the
`ingest` result.
"""
function publish(
    doc;
    config::AbstractString,
    project::AbstractString,
    source::AbstractString,
    site::AbstractString,
    runs=Tuple{String,String}[],
    html_dir::AbstractString="",
    db::AbstractString=joinpath(site, "data", "archeion.db"),
    content_dir::AbstractString=dirname(db),
    remote_db=nothing,
    delete::Bool=true,
)
    mkpath(dirname(db))
    try
        pull(config; out=db, remote_db=remote_db)
        @info "publish: pulled the live registry DB (annotations preserved)" db
    catch e
        e isa InterruptException && rethrow()
        @warn "publish: could not pull a remote DB (first publish?) — ingesting fresh" exception =
            e
    end
    res = ingest(
        doc;
        db=db,
        project=project,
        source=source,
        runs=runs,
        html_dir=html_dir,
        content_dir=content_dir,
    )
    push_dir(transport(config), site; delete=delete)   # backend-neutral push (symmetric with pull)
    @info "publish: pushed the registry" record = res.record site
    return res
end
