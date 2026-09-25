# restore.jl — rebuild what a revision holds, and recompute from it (SPEC.md §5.5, §6).
#
# A revision's `repro/` holds, per observation, an inventory of the files a process could see and
# the contents of those it kept: the study, the packages developed beside it, and (from DataVault
# 0.8.7, at run-start) every package the process loaded from a depot. `restore` lays those out as
# a study, a depot and an environment. `verify` runs the study from that and nothing else — an
# empty depot, an empty HOME, the network off where the host allows it — and compares the result
# files with the ones the revision's points name. Only a match earns `capability.verified`.

const RESTORED_FILE = "RESTORED.toml"
const COVERAGE_FILE = r"\.jl\.\d+\.(cov|mem)$"      # what `--code-coverage`/`--track-allocation` leave

# ── git's tree hash, which is what a Manifest pins a package to ───────────────────────────────

_git_object(kind, bytes) = sha1(vcat(Vector{UInt8}("$kind $(length(bytes))\0"), bytes))

# The raw tree id of `dir`, or `nothing` for a directory with no files (git has no empty trees).
function _git_tree(dir)
    entries = Tuple{String,Vector{UInt8}}[]                    # (sort key, "mode name\0" * id)
    for name in readdir(dir)
        name == ".git" && continue
        p = joinpath(dir, name)
        st = lstat(p)
        if islink(st)
            mode, id = "120000", _git_object("blob", Vector{UInt8}(readlink(p)))
        elseif isdir(st)
            id = _git_tree(p)
            id === nothing && continue
            mode = "40000"
        else
            mode = (st.mode & 0o111) != 0 ? "100755" : "100644"
            id = _git_object("blob", read(p))
        end
        key = isdir(st) && !islink(st) ? name * "/" : name
        push!(entries, (key, vcat(Vector{UInt8}("$mode $name\0"), id)))
    end
    isempty(entries) && return nothing
    return _git_object("tree", reduce(vcat, last.(sort!(entries; by=first))))
end

"""
    git_tree_hash(dir) -> String

The git tree id of `dir` — the value a Manifest's `git-tree-sha1` pins a package to — computed
from the files alone, so a restored package can be checked against its pin without git or Pkg.
"""
git_tree_hash(dir) = bytes2hex(something(_git_tree(dir), _git_object("tree", UInt8[])))

# ── restore ───────────────────────────────────────────────────────────────────────────────────

_rows(tsv) = [split(l, '\t') for l in readlines(tsv)[2:end] if !isempty(l)]

# ── what a revision may name, before any of it becomes a path ─────────────────────────────────
#
# A revision restored here may come from someone else's registry, and `validate` does not read a
# snapshot's rows. So every name that is about to become part of a path is checked first: a
# token, a snapshot id, a blob digest, and each part of a root's name; and every file's path must
# stay inside its root. A revision that names something else is refused, not tidied.

const PKG_NAME = r"^[A-Za-z_][A-Za-z0-9_]*$"
const TREE = r"^[0-9a-f]{40}$"

function _refuse(what, value, revdir)
    return error("$revdir names $what $(repr(value)), which cannot be restored safely")
end

# `rel` is inside its root: relative, no `..`, no empty or `.` segment that hides one.
function _inside_root(rel)
    (isempty(rel) || isabspath(rel) || occursin('\0', rel)) && return false
    return all(s -> !(s in ("", ".", "..")), split(rel, '/'))
end

# A symlink at `rel` pointing at `target` resolves inside its root.
function _link_inside(rel, target)
    (isempty(target) || isabspath(target)) && return false
    depth = 0
    for s in vcat(split(dirname(rel), '/'; keepempty=false), split(target, '/'))
        s in ("", ".") && continue
        depth += s == ".." ? -1 : 1
        depth < 0 && return false
    end
    return true
end

# The observations the points were computed under, all of one source state: a sweep run across
# processes has one observation per process, and they are the same code. More than one source
# state among them is a revision whose points came from different code, and restoring one of
# them would say otherwise.
function _compute_observations(revdir)
    prov = TOML.parsefile(joinpath(revdir, "provenance.toml"))
    tokens = unique(
        r[5] for r in _rows(joinpath(revdir, prov["points_file"])) if r[5] != "unknown"
    )
    isempty(tokens) &&
        error("no point in $revdir names the observation it was computed under")
    by_source = Dict{String,Vector{String}}()
    for t in tokens
        occursin(TOKEN, t) || _refuse("the observation", t, revdir)
        f = joinpath(revdir, "repro", "observations", "$t.toml")
        isfile(f) || error("observation $t is not held in $revdir")
        push!(get!(by_source, TOML.parsefile(f)["source"], String[]), t)
    end
    length(by_source) == 1 || error(
        "the points of $revdir were computed from $(length(by_source)) source states; " *
        "restore one by naming its observation (`token`): $(join(tokens, ", "))",
    )
    return sort(only(values(by_source)))
end

function _julia_for(obs)
    j = get(obs, "julia", Dict{String,Any}())
    want = get(j, "executable_sha256", nothing)
    exe = joinpath(get(j, "bindir", ""), Base.julia_exename())
    want === nothing && return (nothing, "the observation records no Julia binary digest")
    isfile(exe) || return (nothing, "the recorded Julia binary $exe is not on this host")
    bytes2hex(open(sha256, exe)) == want ||
        return (nothing, "$exe is not the recorded binary (its digest differs)")
    return (exe, "")
end

"""
    restore(revdir, dest; token = nothing) -> NamedTuple

Lay out what revision `revdir` holds for the observation its points were computed under (or
`token`): the study under `dest/study`, packages developed beside it under `dest/dev/<name>`, the
packages it loaded from a depot under `dest/depot/packages/<name>/<slug>`, and the environment,
with its Manifest's `path` entries pointed at the restored packages (the recorded bytes are kept
beside it as `Manifest.recorded.toml`).

Nothing is resolved or downloaded. What the revision does not hold is listed in `missing`, and each
depot package is checked against the tree its Manifest pins: `trees` maps its name to whether it
matched. `julia` is the recorded binary when it is on this host and hashes as recorded.
"""
function restore(revdir, dest; token=nothing)
    ispath(dest) && error("$dest exists; restore into a new directory")
    tokens = token === nothing ? _compute_observations(revdir) : [token]
    token = first(tokens)
    occursin(TOKEN, token) || _refuse("the observation", token, revdir)
    repro = joinpath(revdir, "repro")
    obs = TOML.parsefile(joinpath(repro, "observations", "$token.toml"))
    id = obs["source"]
    occursin(SNAPSHOT, id) || _refuse("the snapshot", id, revdir)
    snap = joinpath(repro, "sources", id[6:37])
    roots = Dict(r["name"] => r for r in get(obs, "roots", []))
    blob(sha) = joinpath(repro, "blobs", sha[1:32])       # only ever called on SHA_HEX

    # Where each root goes. Its name is parsed, and every part that becomes a path is checked. An
    # artifact's tree is read from its name rather than its `head`: DataVault 0.8.7 before its
    # last commit wrote `head = "unknown"` for artifacts, and those revisions still restore.
    study = joinpath(dest, "study")
    depot = joinpath(dest, "depot")
    target = Dict{String,String}()
    uuid_dir = Dict{String,String}()
    for (name, r) in roots
        kind = get(r, "kind", "")
        parts = split(name, ':')
        if name == "config"
            target[name] = study
            continue
        end
        (length(parts) == 3 && occursin(PKG_NAME, parts[2]) || kind == "artifact") ||
            _refuse("the root", name, revdir)
        target[name] = if kind == "artifact"
            (length(parts) == 3 && occursin(TREE, parts[3])) ||
                _refuse("the artifact", name, revdir)
            joinpath(depot, "artifacts", parts[3])
        else
            is_uuid(parts[3]) || _refuse("the package", name, revdir)
            if kind == "depot"
                occursin(TREE, get(r, "head", "")) || _refuse("the tree of", name, revdir)
                slug = Base.version_slug(Base.UUID(parts[3]), Base.SHA1(r["head"]))
                joinpath(depot, "packages", parts[2], slug)
            else
                joinpath(dest, "dev", parts[2])
            end
        end
        startswith(name, "pkg:") && (uuid_dir[parts[3]] = target[name])
    end

    missing = String[]
    mkpath(dest)
    for r in _rows(joinpath(snap, "files.tsv"))
        root, rel, type, mode, sha = r[1], unescape_string(r[2]), r[3], r[4], r[6]
        _inside_root(rel) || _refuse("the file", "$root:$rel", revdir)
        dir = get(target, root, nothing)
        if dir === nothing ||
            !(type in ("file", "symlink")) ||
            !occursin(SHA_HEX, sha) ||
            !isfile(blob(sha))
            push!(missing, "$root:$rel ($type)")
            continue
        end
        out = joinpath(dir, rel)
        mkpath(dirname(out))
        if type == "symlink"                              # the blob is the link's target
            target_ = read(blob(sha), String)
            if !_link_inside(rel, target_)
                push!(missing, "$root:$rel (symlink leaving its root)")
                continue
            end
            symlink(target_, out)
        else
            cp(blob(sha), out)
            chmod(out, mode == "x" ? 0o755 : 0o644)
        end
    end

    # Each depot package against its pin. A depot is not as read-only as it looks: running tests
    # with `--code-coverage` writes `<file>.jl.<pid>.cov` beside every source it touched, in the
    # depot's copy too. So a tree that does not match is tried once more without those, and says
    # so; it is not stripped up front, because a package may commit such files itself.
    trees = Dict{String,Bool}()
    stripped = Dict{String,Int}()
    for (name, r) in roots
        get(r, "kind", "") in ("depot", "artifact") || continue
        dir = target[name]
        pin = get(r, "kind", "") == "artifact" ? split(name, ':')[end] : r["head"]
        if !isdir(dir)
            trees[name] = false
        elseif git_tree_hash(dir) == pin
            trees[name] = true
        else
            junk = [
                joinpath(d, f) for (d, _, fs) in walkdir(dir) for
                f in fs if occursin(COVERAGE_FILE, f)
            ]
            foreach(rm, junk)
            trees[name] = !isempty(junk) && git_tree_hash(dir) == pin
            trees[name] && (stripped[name] = length(junk))
        end
    end

    # The environment: the study's own when its Project.toml is the recorded one, else beside it.
    envrec = get(obs, "environment", Dict{String,Any}())
    psha, msha = get(envrec, "project_sha256", nothing),
    get(envrec, "manifest_sha256", nothing)
    own = joinpath(study, "Project.toml")
    project = if psha !== nothing && isfile(own) && bytes2hex(open(sha256, own)) == psha
        study
    else
        joinpath(dest, "env")
    end
    mkpath(project)
    if psha !== nothing && !isfile(joinpath(project, "Project.toml"))
        if isfile(blob(psha))
            cp(blob(psha), joinpath(project, "Project.toml"))
        else
            push!(missing, "environment:Project.toml")
        end
    end
    if msha !== nothing && isfile(blob(msha))
        recorded = read(blob(msha), String)
        write(joinpath(project, "Manifest.recorded.toml"), recorded)
        m = TOML.parse(recorded)
        for (_, entries) in get(m, "deps", Dict{String,Any}()), e in entries
            haskey(e, "path") &&
                haskey(uuid_dir, get(e, "uuid", "")) &&
                (e["path"] = uuid_dir[e["uuid"]])
        end
        open(io -> TOML.print(io, m), joinpath(project, "Manifest.toml"), "w")
    elseif msha !== nothing
        push!(missing, "environment:Manifest.toml")
    end

    julia, why = _julia_for(obs)
    # The study's script: what `julia <file>` ran (`program`, DataVault 0.8.7), else any include
    # from inside the study.
    cfg = get(roots, "config", Dict{String,Any}())
    ran = filter(
        !isempty, vcat([get(obs, "program", "")], get(obs, "main_files", String[]))
    )
    entry = unique([
        relpath(f, cfg["dir"]) for
        f in ran if haskey(cfg, "dir") && startswith(f, cfg["dir"] * "/")
    ])
    summary = Dict{String,Any}(
        "revision" => basename(revdir),
        "observation" => token,
        "source" => id,
        "project" => relpath(project, dest),
        "missing" => missing,
        "trees" => Dict(
            k => if !v
                "differs"
            elseif haskey(stripped, k)
                "matches without $(stripped[k]) coverage file(s) written after install"
            else
                "matches"
            end for (k, v) in trees
        ),
        "julia" => something(julia, ""),
        "julia_note" => why,
        "entry" => entry,
    )
    open(io -> TOML.print(io, summary; sorted=true), joinpath(dest, RESTORED_FILE), "w")
    return (;
        dest,
        study,
        project,
        depot,
        julia,
        julia_note=why,
        entry,
        missing,
        trees,
        stripped,
        token,
        tokens,
        observation=obs,
    )
end

# ── verify ────────────────────────────────────────────────────────────────────────────────────

# Whether this host can run a process with no network: an unprivileged network namespace.
function _can_unshare()
    return Sys.islinux() &&
           Sys.which("unshare") !== nothing &&
           success(
               pipeline(ignorestatus(`unshare -rn true`); stdout=devnull, stderr=devnull)
           )
end

"""
    verify(revdir; dest, entry = nothing, julia = nothing, event = true) -> NamedTuple

[`restore`](@ref) `revdir` into `dest` and run its study there — `julia --project=<restored> <entry>`
with an empty depot of only the restored packages, an empty HOME, Pkg offline, the network
namespace unshared where the host allows it, and the recorded Julia and BLAS thread counts. The
study's DataVault output is redirected (`DATAVAULT_OUTDIR`) to `dest/out`, so a study must not
pass `outdir` itself.

Every point of the revision is then compared by the SHA-256 of its result file. `ok` — and, when
`event`, a `capability.verified` event in the record's `events/` — needs every point to have been
compared and matched: a point whose result digest was never recorded, or that names no
observation of the restored source, is `excluded` and withholds the event rather than being left
out of a count. The event says what was compared and under which conditions: whether the network
was actually unavailable (an offline flag alone does not show it) and how many files the revision
named but did not hold (`not_held`).
"""
function verify(revdir; dest, entry=nothing, julia=nothing, event::Bool=true)
    r = restore(revdir, dest)
    exe = something(julia, r.julia, Some(nothing))
    exe === nothing && error("no Julia to run: $(r.julia_note); pass `julia` explicitly")
    ent = something(entry, length(r.entry) == 1 ? only(r.entry) : nothing, Some(nothing))
    ent === nothing && error(
        "the observation names $(length(r.entry)) script(s) of the study " *
        "($(join(r.entry, ", "))); pass `entry`",
    )
    isempty(r.trees) ||
        all(values(r.trees)) ||
        error(
            "restored packages do not hash to their pins: " *
            join((k for (k, v) in r.trees if !v), ", "),
        )

    home, out = joinpath(dest, "home"), joinpath(dest, "out")
    mkpath(home)
    j = get(r.observation, "julia", Dict{String,Any}())
    env = Dict{String,String}(
        "HOME" => home,
        "PATH" => get(ENV, "PATH", "/usr/bin:/bin"),
        "JULIA_DEPOT_PATH" => r.depot,
        "JULIA_PKG_OFFLINE" => "true",
        "JULIA_PKG_SERVER" => "",
        "DATAVAULT_OUTDIR" => out,
    )
    haskey(j, "threads") && (env["JULIA_NUM_THREADS"] = string(j["threads"]))
    haskey(j, "blas_threads") && (env["OPENBLAS_NUM_THREADS"] = string(j["blas_threads"]))
    netless = _can_unshare()
    base = `$exe --startup-file=no --project=$(r.project) $(joinpath(r.study, ent))`
    cmd = setenv(netless ? `unshare -rn $base` : base, env; dir=r.study)
    log = joinpath(dest, "verify.log")
    ran = open(log, "w") do io
        return success(pipeline(ignorestatus(cmd); stdout=io, stderr=io))
    end

    # Every point of the revision, not only those of one observation: a sweep across processes
    # has one per process. A point that cannot be compared is excluded by name, never dropped.
    prov = TOML.parsefile(joinpath(revdir, "provenance.toml"))
    rows = _rows(joinpath(revdir, prov["points_file"]))
    comparable(x) = x[5] in r.tokens && occursin(SHA_HEX, x[4]) && _inside_root(x[2])
    compared = filter(comparable, rows)
    excluded = [x[1] for x in rows if !comparable(x)]
    matched, differs, absent = String[], String[], String[]
    for x in compared
        f = joinpath(out, unescape_string(x[2]))
        if !isfile(f)
            push!(absent, x[1])
        elseif bytes2hex(open(sha256, f)) == x[4]
            push!(matched, x[1])
        else
            push!(differs, x[1])
        end
    end
    ok =
        ran &&
        !isempty(compared) &&
        isempty(excluded) &&
        length(matched) == length(compared)

    written = nothing
    if ok && event
        recdir = dirname(dirname(revdir))
        record = TOML.parsefile(joinpath(recdir, "record.toml"))["uuid"]
        at = utcnow()
        ev = Dict{String,Any}(
            "spec" => SPEC,
            "kind" => "capability.verified",
            "at" => at,
            "subject" => Dict("record" => record, "rev" => basename(revdir)),
            "capability" => "compute",
            "criterion" => "result-file-sha256",
            "points" => length(compared),
            "matched" => length(matched),
            "observations" => r.tokens,
            "conditions" => Dict{String,Any}(
                "depot" => "restored-only",
                "home" => "empty",
                "network" => netless ? "unshared" : "not-blocked",
                "not_held" => length(r.missing),
                "host" => gethostname(),
                "julia_version" => string(get(j, "version", "")),
                "executable_sha256" => bytes2hex(open(sha256, exe)),
                "julia_as_recorded" => r.julia !== nothing && exe == r.julia,
                "threads" => get(j, "threads", 0),
                "blas_threads" => get(j, "blas_threads", 0),
            ),
        )
        mkpath(joinpath(recdir, "events"))
        written = joinpath(
            recdir, "events", Dates.format(at, PATH_TIME) * "-loc-$(tag()).toml"
        )
        open(io -> TOML.print(io, ev; sorted=true), written, "w")
    end
    return (;
        ok,
        ran,
        compared=length(compared),
        matched,
        differs,
        absent,
        excluded,
        log,
        network=netless ? "unshared" : "not-blocked",
        event=written,
        restored=r,
    )
end
