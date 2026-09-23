# index.jl — the table of what a registry holds (SPEC.md §2.1).
#
# `registry.toml` lists every project and record by UUID, as General's `[packages]` does. Every
# line of it is already in the tree, which is the point: the index is a convenience a reader may
# trust because a validator checks it, and a writer that meets a conflict in it — the one file
# every deposit touches — regenerates it instead of resolving by hand.

const INDEX_FILE = "registry.toml"

registry_file(root) = joinpath(root, INDEX_FILE)

function read_registry_toml(root)
    path = registry_file(root)
    return isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()
end

spec_of(root) = get(read_registry_toml(root), "spec", nothing)

# Walk the tree and say what is in it: `uuid => (name, path)` per project and record. This is the
# definition of the index; everything else compares against what this returns.
function scan(root)
    projects = Dict{String,Any}()
    for f in entries(joinpath(root, "projects"))
        endswith(f, ".toml") || continue
        d = TOML.parsefile(joinpath(root, "projects", f))
        haskey(d, "uuid") || continue
        projects[string(d["uuid"])] = Dict{String,Any}(
            "name" => string(get(d, "name", splitext(f)[1])), "path" => "projects/$f"
        )
    end
    records = Dict{String,Any}()
    base = joinpath(root, "records")
    for year in (isdir(base) ? entries(base) : String[])
        isdir(joinpath(base, year)) || continue
        for slug in entries(joinpath(base, year))
            file = joinpath(base, year, slug, "record.toml")
            isfile(file) || continue
            d = TOML.parsefile(file)
            haskey(d, "uuid") || continue
            records[string(d["uuid"])] = Dict{String,Any}(
                "name" => string(get(d, "title", slug)), "path" => "records/$year/$slug"
            )
        end
    end
    return projects, records
end

"""
    reindex!(root) -> NamedTuple

Rewrite `registry.toml`'s `[projects]` and `[records]` from the tree, leaving the rest of the file
alone. This is what resolves a conflict in the index: take either side, run this, and the answer is
the tree's rather than a hand-merged guess.
"""
function reindex!(root)
    reg = read_registry_toml(root)
    projects, records = scan(root)
    reg["projects"] = projects
    reg["records"] = records
    write_registry_toml(root, reg)
    return (; projects=length(projects), records=length(records))
end

# TOML.print would write a table per entry; the index wants one line each, sorted by UUID, so that
# two deposits touch two different lines and git merges them without being asked.
function write_registry_toml(root, reg)
    head = Dict{String,Any}(k => v for (k, v) in reg if !(k in ("projects", "records")))
    io = IOBuffer()
    TOML.print(io, head; sorted=true)
    for key in ("projects", "records")
        listed = get(reg, key, Dict{String,Any}())
        isempty(listed) && continue
        println(io)
        println(io, "[$key]")
        for uuid in sort(collect(keys(listed)))
            e = listed[uuid]
            println(
                io,
                uuid,
                " = { name = ",
                repr(string(e["name"])),
                ", path = ",
                repr(string(e["path"])),
                " }",
            )
        end
    end
    write(registry_file(root), String(take!(io)))
    return nothing
end

"What the index says that the tree does not, and the other way round."
function index_disagreements(root)
    reg = read_registry_toml(root)
    projects, records = scan(root)
    out = String[]
    for (key, found) in (("projects", projects), ("records", records))
        listed = get(reg, key, Dict{String,Any}())
        for uuid in sort(collect(setdiff(keys(found), keys(listed))))
            push!(out, "$key: $(found[uuid]["path"]) is not in the index ($uuid)")
        end
        for uuid in sort(collect(setdiff(keys(listed), keys(found))))
            push!(out, "$key: the index lists $uuid, which is not in the tree")
        end
        for uuid in sort(collect(intersect(keys(found), keys(listed))))
            for field in ("name", "path")
                a = string(get(listed[uuid], field, ""))
                b = string(found[uuid][field])
                a == b || push!(
                    out, "$key: $uuid has $field $(repr(b)), the index says $(repr(a))"
                )
            end
        end
    end
    return out
end
