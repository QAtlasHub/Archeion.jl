# A Record is one experiment run's publishable metadata, persisted as `record.toml` next
# to its rendered Pinax gallery and repro bundle. It is small and searchable; the heavy raw
# data stays in DataVault, referenced here only by key (never copied into the registry).

"One run's registry metadata. Keyword-constructed; `id`/`project`/`title`/`gallery` required."
Base.@kwdef struct Record
    id::String
    project::String
    title::String
    gallery::String                          # href to the run's rendered Pinax index.html
    summary::String = ""
    date::String = string(Dates.now())
    tags::Vector{String} = String[]
    bookmark::Bool = false
    thumbnail::Union{Nothing,String} = nothing
    git_commit::String = "unknown"
    julia_version::String = string(VERSION)
    data_keys::Vector{String} = String[]     # DataVault keys (references, not the data)
end

"""
    write_record(rec, dir) -> path

Write `rec` to `dir/record.toml`, creating `dir` if needed. Returns the file path.
"""
function write_record(rec::Record, dir::AbstractString)
    mkpath(dir)
    d = Dict{String,Any}(
        "id" => rec.id,
        "project" => rec.project,
        "title" => rec.title,
        "gallery" => rec.gallery,
        "summary" => rec.summary,
        "date" => rec.date,
        "tags" => rec.tags,
        "bookmark" => rec.bookmark,
        "git_commit" => rec.git_commit,
        "julia_version" => rec.julia_version,
        "data_keys" => rec.data_keys,
    )
    rec.thumbnail === nothing || (d["thumbnail"] = rec.thumbnail)
    path = joinpath(dir, "record.toml")
    open(io -> TOML.print(io, d), path, "w")
    return path
end

"""
    read_record(dir) -> Record

Read a [`Record`](@ref) from `dir/record.toml`. Raises with the offending field and file
path if a required field (`id`/`project`/`title`/`gallery`) is missing.
"""
function read_record(dir::AbstractString)
    path = joinpath(dir, "record.toml")
    d = TOML.parsefile(path)
    req(k) = if haskey(d, k)
        d[k]
    else
        error("read_record: missing required field `$(k)` in `$(path)`")
    end
    return Record(;
        id=req("id"),
        project=req("project"),
        title=req("title"),
        gallery=req("gallery"),
        summary=get(d, "summary", ""),
        date=get(d, "date", ""),
        tags=String.(get(d, "tags", String[])),
        bookmark=get(d, "bookmark", false),
        thumbnail=get(d, "thumbnail", nothing),
        git_commit=get(d, "git_commit", "unknown"),
        julia_version=get(d, "julia_version", ""),
        data_keys=String.(get(d, "data_keys", String[])),
    )
end
