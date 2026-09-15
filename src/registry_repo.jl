# A registry is a git repository, in the same sense a Julia registry is: one repo per registry,
# cloned wherever it is read, brought up to date with `git pull`. `Archeion.toml` at the root is
# its identity, the analogue of a Julia registry's `Registry.toml` (the name is deliberately NOT
# `Registry.toml`, so a clone sitting next to real registries cannot be mis-added to Pkg).
#
# Visibility is a property of the REGISTRY, not of a record: a private registry is a private repo
# (no Pages, read the clone locally), a public registry is a public repo (its gh-pages serves the
# site). Publishing a result means depositing it into the public registry, so there is no per-record
# flag whose omission leaks and none whose presence has to be audited.
#
# Git writes shell out rather than going through LibGit2: a push has to use whatever credential
# helper the machine already configured, and reimplementing that is not this package's job.

"The registry's identity file, at the root of the registry repo."
const REGISTRY_FILE = "Archeion.toml"

_git() = Sys.which("git")

function _require_git(what::AbstractString)
    g = _git()
    g === nothing && error(
        "$(what): the `git` executable was not found. A registry is a git repository; install " *
        "git, or pass `git = false` to keep the tree unversioned.",
    )
    return g
end

# Run a git command in `dir`, returning (ok, output). Never throws on a non-zero exit: callers
# decide whether a failure is fatal, because "nothing to commit" is a normal outcome here.
function _git_try(dir::AbstractString, args::Vector{String})
    g = _git()
    g === nothing && return (false, "git not found")
    out = IOBuffer()
    ok = success(pipeline(`$g -C $dir $args`; stdout=out, stderr=out))
    return (ok, String(take!(out)))
end

"""
    is_registry(root) -> Bool

Whether `root` holds an Archeion registry, i.e. an `Archeion.toml` at its top.
"""
is_registry(root::AbstractString) = isfile(joinpath(root, REGISTRY_FILE))

"""
    registry_info(root=registry_root()) -> (; name, uuid, repo, description, root)

Identity of the registry at `root`, read from `Archeion.toml`. Raises when `root` is not a
registry. [`deposit`](@ref) does not require one: it writes into a plain directory just as
happily, and commits only when the root is a git repository. This is the reader for the
declared identity, used when a registry is replicated or published.
"""
function registry_info(root::AbstractString=registry_root())
    path = joinpath(root, REGISTRY_FILE)
    isfile(path) || error(
        "registry_info: `$(root)` is not an Archeion registry (no $(REGISTRY_FILE)). " *
        "Create one with `create_registry(\"$(root)\"; name = …)`.",
    )
    d = TOML.parsefile(path)
    return (;
        name=String(get(d, "name", basename(abspath(root)))),
        uuid=String(get(d, "uuid", "")),
        repo=String(get(d, "repo", "")),
        description=String(get(d, "description", "")),
        root=abspath(root),
    )
end

# A stable identity for a registry, so two clones of the same registry agree and two registries
# never collide. Derived from name + repo + creation time rather than drawn at random, so the
# same inputs reproduce it (and `UUIDs` stays out of the dependency list for one call).
function _registry_uuid(name::AbstractString, repo::AbstractString, stamp::AbstractString)
    h = bytes2hex(sha256(string(name, "\n", repo, "\n", stamp)))
    return string(h[1:8], "-", h[9:12], "-", h[13:16], "-", h[17:20], "-", h[21:32])
end

"""
    create_registry(root; name="", description="", repo="", git=true) -> String

Create a registry at `root` and return its path: `Archeion.toml` (identity), a `README.md` saying
what the directory is, and, unless `git = false`, a git repository with those files committed.
`repo` is the remote URL; when given it is recorded and set as `origin`.

Refuses to overwrite an existing registry. To adopt a directory that already holds records, create
the registry and then `reindex`; nothing about a record depends on when the registry was declared.
"""
function create_registry(
    root::AbstractString;
    name::AbstractString="",
    description::AbstractString="",
    repo::AbstractString="",
    git::Bool=true,
)
    root = abspath(expanduser(String(root)))
    is_registry(root) && error(
        "create_registry: `$(root)` is already a registry. Read it with `registry_info`.",
    )
    mkpath(root)
    isempty(name) && (name = basename(root))
    stamp = string(Dates.now())

    d = Dict{String,Any}(
        "name" => name,
        "uuid" => _registry_uuid(name, repo, stamp),
        "repo" => repo,
        "description" => description,
        "created" => stamp,
    )
    open(io -> TOML.print(io, d), joinpath(root, REGISTRY_FILE), "w")

    write(
        joinpath(root, "README.md"),
        """
        # $(name)

        An [Archeion](https://github.com/QAtlasHub/Archeion.jl) registry: one directory per record,
        each holding a `record.toml`, the rendered result, and the provenance needed to reproduce it.

        `index.html` is the catalogue and is regenerated from the tree (`Archeion.reindex`); nothing
        in it is edited by hand. A record directory may also hold sidecars (notes, an annotation
        store, a PDF): a deposit removes only the files a previous deposit wrote.
        """,
    )

    if git
        _require_git("create_registry")
        _git_try(root, ["init", "-q"])
        _git_try(root, ["add", "--", REGISTRY_FILE, "README.md"])
        ok, out = _git_try(root, ["commit", "-q", "-m", "Create the $(name) registry"])
        # The usual cause is a machine with no `user.email` / `user.name`. Say so: a registry with
        # a `.git` and no commits looks created and cannot be pushed.
        ok ||
            @warn "create_registry: the registry was written but the first commit failed" output =
                out
        isempty(repo) || _git_try(root, ["remote", "add", "origin", repo])
    end
    return root
end

# Commit one deposit. Paths are listed explicitly: a `git add -A` here would sweep up whatever
# else happens to be in the registry, including another session's half-written deposit.
function _commit_deposit(
    root::AbstractString, paths::Vector{String}, message::AbstractString
)
    isdir(joinpath(root, ".git")) || return ""
    _git() === nothing && return ""
    _git_try(root, vcat(["add", "--"], paths))
    # `git diff --cached --quiet` exits 0 when NOTHING is staged, which is the normal outcome of
    # re-depositing an unchanged render. Ask first rather than reading a failed commit as an error.
    nothing_staged, _ = _git_try(root, ["diff", "--cached", "--quiet"])
    nothing_staged && return ""
    ok, out = _git_try(root, ["commit", "-q", "-m", message])
    ok || (
        @warn "deposit: the record was written but could not be committed" output = out;
        return ""
    )
    _, head = _git_try(root, ["rev-parse", "--short", "HEAD"])
    return String(strip(head))
end

"""
    sync(root=registry_root(); remote="origin", pull=true, push=true) -> Bool

Bring the registry at `root` level with its remote: `git pull --rebase`, then `git push`. Returns
whether every requested step succeeded; a failure warns with git's own output rather than raising,
because a registry that cannot reach its remote is still perfectly readable locally.
"""
function sync(
    root::AbstractString=registry_root();
    remote::AbstractString="origin",
    pull::Bool=true,
    push::Bool=true,
)
    isdir(joinpath(root, ".git")) ||
        error("sync: `$(root)` is not a git repository; create it with `create_registry`.")
    _require_git("sync")
    has_remote, _ = _git_try(root, ["remote", "get-url", remote])
    has_remote || error(
        "sync: the registry at `$(root)` has no remote `$(remote)`. Add one with " *
        "`git -C $(root) remote add $(remote) <url>`, or record it in $(REGISTRY_FILE).",
    )
    ok = true
    if pull
        good, out = _git_try(root, ["pull", "--rebase", remote])
        good || (@warn "sync: pull failed" output = out; ok=false)
    end
    if push
        # A registry's FIRST push has no upstream, and `git push <remote>` refuses in that state.
        # Set it here rather than making the caller know: `sync` is the whole interface.
        tracked, _ = _git_try(
            root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
        )
        args = tracked ? ["push", remote] : ["push", "-u", remote, "HEAD"]
        good, out = _git_try(root, args)
        good || (@warn "sync: push failed" output = out; ok=false)
    end
    return ok
end
