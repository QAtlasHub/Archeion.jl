# The registry is a directory TREE, and `record.toml` is the only file this package parses in
# it. Everything else under a record's directory is a sidecar: written by Pinax, by a viewer,
# by a human, or by a tool that does not exist yet. Two properties hold the design together:
#
#   * the index is DERIVED from the tree (`read_records` -> `build_index`), so a record that
#     any tool dropped in shows up without this package knowing that tool exists; and
#   * a deposit removes only files a PREVIOUS deposit wrote (see `DEPOSIT_MANIFEST`), so
#     re-rendering a study cannot destroy a sidecar that something else owns.
#
# That is the same content/annotation split `ingest` makes inside SQLite, moved out to the
# filesystem: browsing (`index.html`) and search (Pagefind, `add_search`) then need no server,
# which is what lets the registry be read straight off the machine that computed it.

"Environment variable naming the registry root when neither an argument nor a config gives one."
const REGISTRY_ENV = "ARCHEION_REGISTRY"

"Per-record list of the files the last `deposit` wrote: the only files a later deposit may remove."
const DEPOSIT_MANIFEST = ".deposit.toml"

"""
    registry_root(; root="", config=nothing) -> String

Absolute path of the registry root, resolved in this order:

1. the explicit `root` argument;
2. `[archeion] root` in `config` (a path to a TOML file, or an already-parsed `Dict`);
3. `ENV["ARCHEION_REGISTRY"]`;
4. `~/registry`.

The default deliberately sits OUTSIDE any repository: a deposit that landed inside a git
checkout would be swept into someone's next commit. Set the environment variable once per
machine, or `[archeion] root` per project, and every call agrees without passing paths around.
"""
function registry_root(; root::AbstractString="", config=nothing)
    isempty(root) || return abspath(expanduser(String(root)))
    if config !== nothing
        cfg = config isa AbstractString ? TOML.parsefile(String(config)) : config
        r = String(get(get(cfg, "archeion", Dict{String,Any}()), "root", ""))
        isempty(r) || return abspath(expanduser(r))
    end
    e = get(ENV, REGISTRY_ENV, "")
    isempty(e) || return abspath(expanduser(String(e)))
    return joinpath(homedir(), "registry")
end

"""
    read_records(root=registry_root()) -> Vector{Record}

Every record under `root`, newest first. A record is any directory holding a `record.toml`, at
any depth, so the `<project>/<source>/` layout [`deposit`](@ref) writes is a convention rather
than a requirement: a record placed by hand, or by a tool this package has never heard of, is
picked up by being on disk.

Returns an empty vector when `root` does not exist yet.
"""
function read_records(root::AbstractString=registry_root())
    recs = Record[]
    isdir(root) || return recs
    for (dir, _, files) in walkdir(root)
        "record.toml" in files || continue
        push!(recs, read_record(dir))
    end
    sort!(recs; by=r -> (r.date, r.id), rev=true)
    return recs
end

"""
    reindex(root=registry_root(); title="", search=false) -> path

Rebuild `root/index.html` from the records currently on disk and return its path. The title
defaults to the registry's declared name ([`registry_info`](@ref)), or to `"Archeion"` when the
root is not a declared registry. With `search=true`, refresh the Pagefind index too
([`add_search`](@ref)).

Idempotent and cheap: it reads the `record.toml` files and re-renders one page. Call it after
anything changes the tree, including a record you added by hand.
"""
function reindex(
    root::AbstractString=registry_root(); title::AbstractString="", search::Bool=false
)
    # A catalogue titled "Archeion" tells a reader which tool made it, not which registry they are
    # looking at; the declared name does, when there is one.
    if isempty(title)
        title = is_registry(root) ? registry_info(root).name : "Archeion"
    end
    path = build_index(read_records(root); out=root, title=title)
    search && add_search(root)
    return path
end

# Copy every file under `src` into `dest`, returning the relative paths written. File by file
# rather than `cp(src, dest)` on purpose: a whole-directory copy has to clear `dest` first, and
# `dest` is exactly where the sidecars live.
function _mirror(src::AbstractString, dest::AbstractString)
    written = String[]
    for (d, _, files) in walkdir(src)
        rel = relpath(d, src)
        for f in files
            r = rel == "." ? f : joinpath(rel, f)
            target = joinpath(dest, r)
            mkpath(dirname(target))
            cp(joinpath(d, f), target; force=true)
            push!(written, r)
        end
    end
    return sort!(written)
end

# Remove the files the LAST deposit wrote that this one did not. Reading the manifest is what
# makes this safe: a file this package never wrote is not listed, so it is never a candidate.
function _prune_previous(recdir::AbstractString, written::AbstractVector{<:AbstractString})
    path = joinpath(recdir, DEPOSIT_MANIFEST)
    isfile(path) || return String[]
    prev = String.(get(TOML.parsefile(path), "files", String[]))
    stale = sort!(setdiff(prev, written))
    for r in stale
        p = joinpath(recdir, r)
        isfile(p) && rm(p; force=true)
    end
    return stale
end

function _write_deposit_manifest(
    recdir::AbstractString, written::AbstractVector{<:AbstractString}
)
    path = joinpath(recdir, DEPOSIT_MANIFEST)
    open(io -> TOML.print(io, Dict("files" => collect(written))), path, "w")
    return path
end

"""
    deposit(dir; project, source, title="", doc=nothing, root="", config=nothing, srcdir="",
            strict=false, summary="", tags=String[], data_keys=String[], thumbnail=nothing,
            date="", index=true, search=false) -> (; dir, record, index, pruned)

Deposit the built directory `dir` into the registry as one record.

`dir` is any directory with an `index.html` at its top: a Pinax render output, but equally a
slide deck or a hand-written page. Pass `doc` (a rendered Pinax document) only to take the
title from it.

Written under `<root>/<project>/<source>/`:

* the contents of `dir`, copied file by file;
* `repro/`, when `srcdir` is given -- see [`capture_repro`](@ref) for what it snapshots and for
  `strict`, which refuses a source tree with uncommitted changes;
* `record.toml` -- the [`Record`](@ref), and the only file the index reads.

Files a PREVIOUS deposit wrote and this one did not are removed, and nothing else in the record
directory is touched: a sidecar (an annotation store, a note, a PDF someone dropped in) survives
a re-render.

An untitled record is refused. Every card in the index is labelled by the title, so a record
without one cannot be told from any other, and `Pinax.render` leaves it empty unless asked.

Heavy data is NOT copied: reference it through `data_keys` (DataVault keys), the same way
[`Record`](@ref) does.

When the registry root is a git repository, the deposit is committed (the record directory and the
index, by explicit path, never `git add -A`) and the short SHA comes back as `commit`. Re-depositing
an unchanged render stages nothing and returns `""` rather than failing. `commit = false` writes the
files and leaves staging alone.
"""
function deposit(
    dir::AbstractString;
    project::AbstractString,
    source::AbstractString,
    title::AbstractString="",
    doc=nothing,
    root::AbstractString="",
    config=nothing,
    srcdir::AbstractString="",
    strict::Bool=false,
    summary::AbstractString="",
    tags::AbstractVector{<:AbstractString}=String[],
    data_keys::AbstractVector{<:AbstractString}=String[],
    thumbnail::Union{Nothing,AbstractString}=nothing,
    date::AbstractString="",
    index::Bool=true,
    search::Bool=false,
    commit::Bool=true,
)
    isdir(dir) || error("deposit: `$(dir)` is not a directory")
    isempty(title) && doc !== nothing && (title = String(doc.meta.title))
    isempty(title) && error(
        "deposit: this record has no title. Pass `title=`, or give the rendered document one " *
        "(`Pinax.render(…; title=…)` / `Pinax.report(…; title=…)`). The index labels every " *
        "card by it, so an untitled record cannot be told from any other.",
    )

    reg = registry_root(; root=root, config=config)
    id = joinpath(_slug(project), _slug(source))
    recdir = joinpath(reg, id)
    src, dst = abspath(dir), abspath(recdir)
    (startswith(src, dst) || startswith(dst, src)) && error(
        "deposit: `dir` ($(src)) and the record directory ($(dst)) are nested; deposit copies " *
        "INTO the registry, so render elsewhere and deposit the result.",
    )
    mkpath(recdir)

    # Provenance is captured BEFORE anything is written into the registry, for two reasons: a
    # `strict` refusal then leaves no half-written record, and when the registry IS the source tree
    # (a registry that carries the script building it), copying the render in first would make the
    # tree dirty by construction and the capture would report it.
    #
    # Named `gitsha`, not `commit`: the `commit` kwarg is a Bool, and a local of the same name would
    # shadow it (the kind of rebinding that shows up as `non-boolean used in boolean context` three
    # statements later).
    gitsha, dirty = "unknown", false
    if !isempty(srcdir)
        cfgpath = config isa AbstractString ? String(config) : nothing
        bundle = capture_repro(srcdir, recdir; config=cfgpath, strict=strict)
        gitsha, dirty = bundle.git_commit, bundle.git_dirty
    end

    written = _mirror(dir, recdir)
    pruned = _prune_previous(recdir, written)
    _write_deposit_manifest(recdir, written)

    rec = Record(;
        id=id,
        project=_slug(project),
        title=title,
        gallery=joinpath(id, "index.html"),
        summary=summary,
        date=isempty(date) ? string(Dates.now()) : date,
        tags=String.(tags),
        thumbnail=thumbnail === nothing ? nothing : String(thumbnail),
        git_commit=gitsha,
        git_dirty=dirty,
        data_keys=String.(data_keys),
    )
    write_record(rec, recdir)

    idx = index ? reindex(reg; search=search) : ""

    sha = ""
    if commit
        paths = [relpath(recdir, reg)]
        isempty(idx) || push!(paths, relpath(idx, reg))
        sha = _commit_deposit(reg, paths, "deposit $(rec.id): $(rec.title)")
    end
    return (; dir=recdir, record=rec, index=idx, pruned=pruned, commit=sha)
end
