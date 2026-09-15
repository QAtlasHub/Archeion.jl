# Tags after the fact. A tag is a judgement that arrives later than the result it is about: you
# learn that two studies belong together only once the second one exists. So `deposit` takes tags,
# and these take them again, editing `record.toml` in place and leaving the rendered artifact alone.
#
# The static dashboard cannot write back, and that is the point: the file is the truth, an editor
# is one way to change it, and this is another. Both leave the same one line in `record.toml`.

# Locate a record by its id (`project/source`), with the known ids in the error: a typo here is
# otherwise a silent no-op on a registry the caller cannot see.
function _record_dir(root::AbstractString, id::AbstractString)
    want = String(id)
    for dir in record_dirs(root)
        read_record(dir).id == want && return dir
    end
    known = [read_record(d).id for d in record_dirs(root)]
    return error(
        "no record `$(want)` in `$(root)`. " * (
            if isempty(known)
                "The registry holds none yet."
            else
                "It holds: " * join(known, ", ") * "."
            end
        )
    )
end

function _retag!(
    root::AbstractString,
    id::AbstractString,
    f::Function;
    index::Bool,
    commit::Bool,
    search::Bool,
)
    dir = _record_dir(root, id)
    rec = read_record(dir)
    tags = f(copy(rec.tags))
    if tags == rec.tags
        return rec                                   # nothing to write, nothing to commit
    end
    updated = Record(;
        id=rec.id,
        project=rec.project,
        title=rec.title,
        gallery=rec.gallery,
        summary=rec.summary,
        date=rec.date,
        tags=tags,
        bookmark=rec.bookmark,
        thumbnail=rec.thumbnail,
        git_commit=rec.git_commit,
        git_dirty=rec.git_dirty,
        julia_version=rec.julia_version,
        data_keys=rec.data_keys,
    )
    write_record(updated, dir)
    idx = index ? reindex(root; search=search) : ""
    if commit
        paths = [relpath(joinpath(dir, "record.toml"), root)]
        isempty(idx) || push!(paths, relpath(idx, root))
        isfile(joinpath(root, "index.json")) && push!(paths, "index.json")
        _commit_deposit(root, paths, "tag $(rec.id): " * join(tags, ", "))
    end
    return updated
end

"""
    tag!(id, tags...; root=registry_root(), index=true, commit=true, search=true) -> Record

Add `tags` to the record `id` (`project/source`) and return it as written. Adding a tag a record
already carries changes nothing, and writes nothing.

The dashboard is rebuilt so the chip appears, and in a git-backed registry the edit is committed on
its own — a tag is a judgement, and it is worth being able to see when it was made.

```julia
Archeion.tag!("openboundary/report", "entanglement", "for-the-paper")
```
"""
function tag!(
    id::AbstractString,
    tags::AbstractString...;
    root::AbstractString=registry_root(),
    index::Bool=true,
    commit::Bool=true,
    search::Bool=true,
)
    add = String[strip(String(t)) for t in tags]
    any(isempty, add) && error("tag!: an empty tag is not a tag.")
    return _retag!(
        root, id, cur -> sort!(union(cur, add)); index=index, commit=commit, search=search
    )
end

"""
    untag!(id, tags...; root=registry_root(), index=true, commit=true, search=true) -> Record

Remove `tags` from the record `id` and return it as written. Removing a tag it does not carry
changes nothing, and writes nothing — the same shape as [`tag!`](@ref).
"""
function untag!(
    id::AbstractString,
    tags::AbstractString...;
    root::AbstractString=registry_root(),
    index::Bool=true,
    commit::Bool=true,
    search::Bool=true,
)
    drop = String[strip(String(t)) for t in tags]
    return _retag!(
        root,
        id,
        cur -> filter(t -> !(t in drop), cur);
        index=index,
        commit=commit,
        search=search,
    )
end
