# Capture a run's reproducibility bundle: the exact code + environment needed to reproduce
# it. Pinax records *figure* provenance (which data produced which figure); this records
# *env/code* provenance (which commit + which dependency versions produced the run).

"Snapshot of a source tree's git + environment state at capture time."
struct ReproBundle
    git_commit::String     # full SHA, or "unknown" if srcdir is not a git repo / has no commits
    git_dirty::Bool        # were there uncommitted changes (including untracked files)?
    julia_version::String
    has_manifest::Bool     # was a Manifest.toml captured (env is pinned only if true)?
end

# Read the git state of `srcdir` via LibGit2 (stdlib): returns `(commit, dirty)`. `commit`
# is the full HEAD SHA, or "unknown" when `srcdir` is not a git repository or has no commits
# yet. `dirty` follows `git status --porcelain` semantics (untracked files count). Using
# LibGit2 keeps "not a repository" a typed, catchable case (GitError), so genuine failures
# (corrupt repo, I/O, permissions) still propagate instead of being silently swallowed.
function _git_state(srcdir::AbstractString)
    repo = try
        LibGit2.GitRepo(srcdir)
    catch e
        e isa LibGit2.GitError && return ("unknown", false)   # not a git repository
        rethrow()
    end
    try
        commit = "unknown"
        try
            commit = string(LibGit2.head_oid(repo))
        catch e
            e isa LibGit2.GitError || rethrow()               # unborn HEAD: no commits yet
        end
        dirty = length(LibGit2.GitStatus(repo)) > 0           # includes untracked, like porcelain
        return (commit, dirty)
    finally
        close(repo)
    end
end

"""
    capture_repro(srcdir, dest; config=nothing, strict=false) -> ReproBundle

Snapshot the reproducibility bundle of the project at `srcdir` into `dest/repro/`: the git
commit + dirty flag, `Project.toml`, `Manifest.toml`, the Julia version, an optional
`config` file, and a runnable `reproduce.sh` recipe.

With `strict=true`, a dirty git tree raises (refuse to record a non-reproducible run);
otherwise the dirty state is recorded and a warning is emitted. A `config` path that does
not exist is warned about (not silently dropped), and a `config` whose filename would
collide with the environment snapshot (`Project.toml`/`Manifest.toml`) raises.
"""
function capture_repro(
    srcdir::AbstractString,
    dest::AbstractString;
    config::Union{Nothing,AbstractString}=nothing,
    strict::Bool=false,
)
    repro = joinpath(dest, "repro")
    mkpath(repro)

    sha, dirty = _git_state(srcdir)
    if dirty
        msg = "capture_repro: `$(srcdir)` has uncommitted changes; this record will not be exactly reproducible."
        strict ? error(msg) : @warn msg
    end

    for f in ("Project.toml", "Manifest.toml")
        p = joinpath(srcdir, f)
        isfile(p) && cp(p, joinpath(repro, f); force=true)
    end
    has_manifest = isfile(joinpath(repro, "Manifest.toml"))
    has_manifest ||
        @warn "capture_repro: no Manifest.toml in `$(srcdir)` — environment is NOT pinned (Project.toml alone is insufficient for Julia reproducibility)."

    # Capture the optional config file. Guard against a name collision with the env
    # snapshot, and warn (don't silently drop) when a path is given but missing.
    config_name = nothing
    if config !== nothing
        if !isfile(config)
            @warn "capture_repro: config path `$(config)` does not exist — not captured."
        elseif basename(config) in ("Project.toml", "Manifest.toml")
            error(
                "capture_repro: config filename `$(basename(config))` collides with the environment snapshot; rename the config file.",
            )
        else
            cp(config, joinpath(repro, basename(config)); force=true)
            config_name = basename(config)
        end
    end

    open(joinpath(repro, "reproduce.sh"), "w") do io
        println(io, "#!/usr/bin/env bash")
        println(io, "# Reproduce this Archeion record. Generated — review before running.")
        println(io, "set -euo pipefail")
        if sha == "unknown"
            println(io, "# WARNING: source was not a git repository at capture time —")
            println(io, "#          no commit to check out; restore the code manually.")
        else
            println(io, "git checkout ", sha)
        end
        println(io, "julia --project=. -e 'using Pkg; Pkg.instantiate()'")
        config_name === nothing || println(io, "# config used: ", config_name)
        return nothing
    end

    return ReproBundle(sha, dirty, string(VERSION), has_manifest)
end
