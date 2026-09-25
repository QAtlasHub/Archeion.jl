# additions.jl — whether a change to a registry only adds to it (SPEC.md §2, §7).
#
# A revision is never changed and an event is never rewritten, so a deposit can only add: a new
# revision, a new event, a new record or project, and the index line that follows from them.
# `validate` says a tree is well formed; it cannot say that nothing already there was touched,
# because it sees one tree. This compares two. It is what lets a deposit be merged without a
# person: a pull request that only adds is one no reader can be surprised by.

# What an addition may be, by path. Everything a deposit writes lives under one of these.
const ADDED_REVISION = r"^records/\d{4}/[a-z0-9-]+/revisions/[^/]+/.+$"
const ADDED_EVENT = r"^records/\d{4}/[a-z0-9-]+/events/[^/]+\.toml$"
const ADDED_RECORD = r"^records/\d{4}/[a-z0-9-]+/record\.toml$"
const ADDED_PROJECT = r"^projects/[a-z0-9-]+\.toml$"

# The index is derived (§2.1): its tables may follow the tree, and nothing else in the file may
# change in a deposit.
function _index_fields(root, ref)
    text = git(root, "show", "$ref:$INDEX_FILE"; ok=true)
    text === nothing && return nothing
    t = TOML.parse(text)
    delete!(t, "projects")
    delete!(t, "records")
    return t
end

"""
    additions(root; base) -> (; ok, added, violations)

Whether the commits in `root` since `base` (a git ref, compared from their merge base) only add
to the registry: new regular files under a record's `revisions/` or `events/`, a new `record.toml`
or project file, and `registry.toml` changed in its index tables alone. Anything else is a
violation, named: a file modified, deleted, renamed or given another mode; an index field other
than the tables; a file outside `records/` and `projects/` (a workflow, a script); and anything
added that is not a regular file — a symbolic link, or a submodule — since a site built from the
tree would carry it as it is. `added` lists the paths added; `ok` also needs at least one.

`validate` says the tree is well formed; this says nothing already in it was touched. A deposit
merged without a person needs both.
"""
function additions(root; base)
    mb = git(root, "merge-base", base, "HEAD"; ok=true)
    mb === nothing && error("$base and HEAD share no history in $root")
    # `--raw` for the modes: a path alone does not say whether what was added is a file.
    out = git(root, "diff", "--raw", "--no-renames", "--no-abbrev", "-z", mb, "HEAD")
    fields = split(something(out, ""), '\0'; keepempty=false)
    added, violations = String[], String[]
    for i in 1:2:(length(fields) - 1)
        meta, path = split(fields[i]), String(fields[i + 1])
        newmode, status = String(meta[2]), String(meta[5])
        if path == INDEX_FILE && status == "M"
            _index_fields(root, mb) == _index_fields(root, "HEAD") || push!(
                violations,
                "$path: changed outside its index tables (only [projects] and [records] follow a deposit)",
            )
        elseif status == "A" && !(newmode in ("100644", "100755"))
            kind = get(
                Dict("120000" => "a symbolic link", "160000" => "a submodule"),
                newmode,
                "mode $newmode",
            )
            push!(violations, "$path: added as $kind, not a regular file")
        elseif status == "A" && any(
            re -> occursin(re, path),
            (ADDED_REVISION, ADDED_EVENT, ADDED_RECORD, ADDED_PROJECT),
        )
            push!(added, path)
        elseif status == "A"
            push!(violations, "$path: added outside what a deposit writes")
        else
            what = get(
                Dict("M" => "modified", "D" => "deleted", "T" => "given another type"),
                status,
                status,
            )
            push!(violations, "$path: $what — a deposit only adds")
        end
    end
    return (; ok=isempty(violations) && !isempty(added), added, violations)
end
