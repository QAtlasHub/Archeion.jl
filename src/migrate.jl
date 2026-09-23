# migrate.jl — convert a registry/1 tree to registry/2 (SPEC.md §11).
#
# The conversion is renaming and four fields: identifiers become UUIDs and leave the paths, a
# project file is named by its slug, a record directory by its own, and the index is generated.
# A revision is never opened — its files, `SHA256SUMS` included, are carried across untouched,
# which is what makes this safe to run on a registry that already holds frozen answers.

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

# What the record was called, taken from the revision a reader would have been shown.
function current_title(recdir, fallback)
    revs = entries(joinpath(recdir, "revisions"))
    isempty(revs) && return fallback
    entry = joinpath(recdir, "revisions", last(revs), "entry.toml")
    isfile(entry) || return fallback
    title = getpath(TOML.parsefile(entry), "doc", "title")
    return title === nothing ? fallback : string(title)
end

"""
    migrate!(root) -> NamedTuple

Convert the `registry/1` tree at `root` in place, and validate the result. Every identifier gets a
UUID, which the files keep and the paths lose; every record moves to `records/<year>/<slug>/`; the
index is written. Refuses a tree that is not `registry/1`, so a second run says so rather than
making a mess.
"""
function migrate!(root)
    spec = spec_of(root)
    spec == SPEC_1 ||
        error("$root says spec $(repr(spec)); migrate! converts a $SPEC_1 registry")
    ids = Dict{String,String}()                        # old identifier => UUID
    pdir = joinpath(root, "projects")
    projects = 0

    for f in entries(pdir)
        endswith(f, ".toml") || continue
        d = TOML.parsefile(joinpath(pdir, f))
        haskey(d, "id") || continue
        ids[string(d["id"])] = new_uuid()
    end
    base = joinpath(root, "records")
    years = isdir(base) ? entries(base) : String[]
    for year in years, rec in entries(joinpath(base, year))
        m = match(RECORD_DIR_1, rec)
        m === nothing &&
            error("$(joinpath(base, year, rec)) is not a $SPEC_1 record directory")
        ids[String(m[3])] = new_uuid()
    end

    for f in entries(pdir)
        endswith(f, ".toml") || continue
        path = joinpath(pdir, f)
        d = TOML.parsefile(path)
        haskey(d, "id") || continue
        old_id = string(d["id"])
        d["uuid"] = ids[old_id]
        delete!(d, "id")
        slug = slugify(get(d, "name", splitext(f)[1]))
        new = joinpath(pdir, "$slug.toml")
        ispath(new) &&
            new != path &&
            error("two projects would be called $slug; rename one")
        d = converted(d, ids)
        d["migrated"] = Dict{String,Any}("spec" => SPEC_1, "id" => old_id)
        write_toml(path, d)
        path == new || mv(path, new)
        projects += 1
    end

    records = 0
    for year in years
        ydir = joinpath(base, year)
        for rec in entries(ydir)
            m = match(RECORD_DIR_1, rec)
            m === nothing && continue
            old_dir = joinpath(ydir, rec)
            slug = String(m[2])
            new_dir = joinpath(ydir, slug)
            ispath(new_dir) &&
                error("two records of $year would be called $slug; rename one")
            d = TOML.parsefile(joinpath(old_dir, "record.toml"))
            old_id = string(d["id"])
            old_project = string(d["project"])
            d["uuid"] = ids[old_id]
            delete!(d, "id")
            haskey(d, "title") || (d["title"] = current_title(old_dir, slug))
            # What this record was called under registry/1. Its revisions still say it, and they
            # are frozen: `SHA256SUMS` covers `entry.toml`, so rewriting one would either break
            # its own checksum or rewrite a digest that a reader may already have cited.
            d = converted(d, ids)
            d["migrated"] = Dict{String,Any}(
                "spec" => SPEC_1, "id" => old_id, "project" => old_project
            )
            write_toml(joinpath(old_dir, "record.toml"), d)
            mv(old_dir, new_dir)
            records += 1
        end
    end

    reg = read_registry_toml(root)
    reg["spec"] = SPEC
    haskey(reg, "uuid") || (reg["uuid"] = new_uuid())
    write_registry_toml(root, reg)
    reindex!(root)

    r, summary = validate(root)
    isempty(r.errors) && return (; projects, records, summary, ids=length(ids))
    return error("the converted registry does not validate:\n  " * join(r.errors, "\n  "))
end
