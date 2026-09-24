# migrate.jl — convert a registry/1 tree to registry/2 (SPEC.md §11).
#
# The conversion is renaming and four fields: identifiers become UUIDs and leave the paths, a
# project file is named by its slug, a record directory by its own, and the index is generated.
# A revision is never written — its files, `SHA256SUMS` included, are carried across untouched,
# which is what makes this safe to run on a registry that already holds frozen answers. One is
# read, to recover the title `registry/1` kept only in its entry.

const RECORD_DIR_1 = r"^(\d{4}-\d{2}-\d{2})-([a-z0-9-]+)-(r_[0-9a-hjkmnp-tv-z]{8})$"

# The same TOML with every old identifier replaced by its UUID, at any depth.
function converted(d::AbstractDict, ids::AbstractDict)
    out = Dict{String,Any}()
    for (k, v) in d
        out[k] = if v isa AbstractDict
            converted(v, ids)
        elseif v isa AbstractVector
            [x isa AbstractDict ? converted(x, ids) : get(ids, string(x), x) for x in v]
        else
            get(ids, string(v), v)
        end
    end
    haskey(out, "spec") && (out["spec"] = SPEC)
    return out
end

write_toml(path, d) = open(io -> TOML.print(io, d; sorted=true), path, "w")

# Put the tree back as it was before the conversion touched it. Only possible under git, which is
# exactly why a conversion demands a clean working tree: `checkout` restores what was rewritten and
# `clean` removes what was renamed into place, and between them nothing of the original is left
# changed. Returns whether it could.
function rollback!(root)
    git(root, "rev-parse", "--git-dir"; ok=true) === nothing && return false
    git(root, "checkout", "--", "."; ok=true)
    git(root, "clean", "-qfd"; ok=true)
    return true
end

# Under git, uncommitted work would be indistinguishable from what a failed conversion left.
function isdirty(root)
    git(root, "rev-parse", "--git-dir"; ok=true) === nothing && return false
    return !isempty(something(git(root, "status", "--porcelain"; ok=true), ""))
end

# What the record was called, taken from the revision a reader would have been shown. A registry
# that validates always has one to read: §4 requires a record to hold at least one revision and
# §5.1 requires `doc.title` in every entry, and `migrate!` validates what it produced — so a record
# this could not name would fail the conversion anyway, and the `fallback` is only ever reached on
# a tree that was already broken.
function current_title(recdir, fallback)
    revs = entries(joinpath(recdir, "revisions"))
    isempty(revs) && return fallback
    entry = joinpath(recdir, "revisions", last(revs), "entry.toml")
    isfile(entry) || return fallback
    d = readable(entry)
    d === nothing && return fallback
    title = getpath(d, "doc", "title")
    return title === nothing ? fallback : string(title)
end

"""
    migrate!(root) -> NamedTuple

Convert the `registry/1` tree at `root` in place, and validate the result. Every identifier gets a
UUID, which the files keep and the paths lose; every record moves to `records/<year>/<slug>/`; the
index is written. Refuses a tree that is not `registry/1`, so a second run says so rather than
making a mess.

A conversion is not resumable: it renames directories one at a time, and a tree caught between the
two formats is neither. So it is all or nothing, in two halves. Everything that can be known in
advance — the identifiers, the slugs, the collisions among them, whether every project file and
`record.toml` parses — is settled before the first rename. Whether the *result* validates can only be known afterwards, and
if it does not the conversion is undone, which is why a registry under git must have nothing
uncommitted before one starts: that clean tree is what makes undoing possible. A tree not under
git has no undo, and is told so rather than left half converted in silence.
"""
function migrate!(root)
    spec = spec_of(root)
    spec == SPEC_1 ||
        error("$root says spec $(repr(spec)); migrate! converts a $SPEC_1 registry")
    isdirty(root) && error(
        "$root has uncommitted changes; commit them first, so a failed conversion is one " *
        "`git checkout .` from where it started",
    )
    plan = plan_migration(root)                        # every error this can raise, raised here
    at = utcnow()

    for (path, new, d, old_id) in plan.projects
        d["uuid"] = plan.ids[old_id]
        delete!(d, "id")
        d = converted(d, plan.ids)
        d["migrated"] = Dict{String,Any}("spec" => SPEC_1, "id" => old_id, "at" => at)
        write_toml(path, d)
        path == new || mv(path, new)
    end

    for (old_dir, new_dir, d, slug) in plan.records
        old_id = string(d["id"])
        old_project = string(d["project"])
        d["uuid"] = plan.ids[old_id]
        delete!(d, "id")
        haskey(d, "title") || (d["title"] = current_title(old_dir, slug))
        # What this record was called under registry/1. Its revisions still say it, and they are
        # frozen: `SHA256SUMS` covers `entry.toml`, so rewriting one would either break its own
        # checksum or rewrite a digest that a reader may already have cited. `at` is what keeps
        # that licence to the revisions of that day: anything frozen later says `registry/2`.
        d = converted(d, plan.ids)
        d["migrated"] = Dict{String,Any}(
            "spec" => SPEC_1, "id" => old_id, "project" => old_project, "at" => at
        )
        write_toml(joinpath(old_dir, "record.toml"), d)
        mv(old_dir, new_dir)
    end

    set_head!(root, "spec", SPEC)
    haskey(read_registry_toml(root), "uuid") || set_head!(root, "uuid", new_uuid())
    reindex!(root)

    projects, records = length(plan.projects), length(plan.records)
    r = validate(root)
    if !isempty(r.errors)
        # Everything knowable in advance is settled by `plan_migration`, but whether the *result*
        # validates can only be known here — after every rename. Refusing at this point used to
        # leave a fully converted tree behind while saying it had refused, which is not what
        # all-or-nothing means. The clean working tree demanded above is what makes a conversion
        # undoable, so it is undone.
        undone = rollback!(root)
        error(
            "the converted registry does not validate, so the conversion was " *
            (
                if undone
                    "undone"
                else
                    "left in place — this tree is not under git, so it is now part $SPEC_1 " *
                    "and part $SPEC, and has to be repaired by hand"
                end
            ) *
            ":\n  " *
            join(r.errors, "\n  "),
        )
    end
    # `ids` is the conversion's one unrecoverable-by-guessing output: a binding lives in the
    # repository that renders the report, not in the registry, so nothing here can update it, and
    # whoever runs this needs to know which UUID replaced which identifier to do it themselves.
    return (; projects, records, summary=r.summary, ids=plan.ids, at)
end

# What the conversion will do, and every reason it cannot. Nothing here writes: a registry that
# fails this check is still the registry it was.
function plan_migration(root)
    ids = Dict{String,String}()                        # old identifier => UUID
    pdir = joinpath(root, "projects")
    projects = Tuple{String,String,Dict{String,Any},String}[]
    taken = Dict{String,String}()

    for f in entries(pdir)
        endswith(f, ".toml") || continue
        path = joinpath(pdir, f)
        d = readable(path)
        d === nothing &&
            error("$path does not parse; a conversion reads every file it converts")
        haskey(d, "id") || continue
        old_id = string(d["id"])
        haskey(ids, old_id) && error("`id` $old_id names more than one project")
        ids[old_id] = new_uuid()
        slug = slugify(get(d, "name", splitext(f)[1]))
        new = joinpath(pdir, "$slug.toml")
        haskey(taken, slug) &&
            error("two projects would be called $slug ($(taken[slug]), $f); rename one")
        taken[slug] = f
        push!(projects, (path, new, d, old_id))
    end

    base = joinpath(root, "records")
    records = Tuple{String,String,Dict{String,Any},String}[]
    for year in (isdir(base) ? entries(base) : String[])
        ydir = joinpath(base, year)
        byslug = Dict{String,String}()
        for rec in entries(ydir)
            m = match(RECORD_DIR_1, rec)
            m === nothing && error(
                "$(joinpath(ydir, rec)) is not a $SPEC_1 record directory" * (
                    if isdir(joinpath(ydir, rec, "revisions"))
                        "; is it already converted?"
                    else
                        ""
                    end
                ),
            )
            old_dir = joinpath(ydir, rec)
            slug = String(m[2])
            haskey(byslug, slug) &&
                error("two records of $year would be called $slug; rename one")
            byslug[slug] = rec
            old_id = String(m[3])
            haskey(ids, old_id) && error("`id` $old_id names more than one record")
            ids[old_id] = new_uuid()
            d = readable(joinpath(old_dir, "record.toml"))
            d === nothing && error(
                "$old_dir/record.toml does not parse; a conversion reads every file it converts",
            )
            string(get(d, "id", "")) == old_id ||
                error("$old_dir/record.toml says `id` $(repr(get(d, "id", nothing)))")
            push!(records, (old_dir, joinpath(ydir, slug), d, slug))
        end
    end
    return (; ids, projects, records)
end
