# provenance.jl — per-point provenance in a revision (SPEC.md §5.5), and its checks.
#
# A revision that holds `provenance.toml` says, for each parameter point its report used, which
# bytes the report read and what the computation recorded when it wrote them, and it carries the
# observations those points name: the source snapshot each computing process saw, and how far that
# process's loaded code was checked against it. Nothing here claims more than the observations do.

const PROVENANCE_SCHEMA = "registry.provenance/1"
const POINT_COLUMNS = (
    "key", "file", "read_sha256", "result_sha256", "observation", "completed_at"
)
const BINDINGS = Set(["loaded-matches-disk", "loaded-differs-from-disk", "unverified"])

# A match cannot be shown from inside the computing process (code defined in a script, a closure,
# or a method added to Base leaves no trace to check), and DataVault 0.8.6 no longer writes one. An
# earlier observation's `loaded-matches-disk` is therefore counted as what it can support.
_counted(binding) = binding == "loaded-matches-disk" ? "unverified" : binding
const POINTS_FILE = "provenance/points.tsv"

# Content-addressed names are cut to 32 hex (128 bits) in paths, so they stay within R3 (64 per
# segment, 180 per path); the full digest stays in the files, and the checks use all of it.
_short(hex) = hex[1:min(end, 32)]
function _snapshot_dir(revdir, id)
    return joinpath(revdir, "repro", "sources", _short(last(split(id, "-"))))
end
_blob_path(revdir, sha) = joinpath(revdir, "repro", "blobs", _short(sha))

_known(s) = s != "unknown" && !isempty(s)

# A token or snapshot id becomes a file name, so one that is not of the form DataVault writes is
# refused rather than joined into a path.
const TOKEN = r"^obs[0-9]+-[0-9A-Za-z-]{1,58}$"
const SNAPSHOT = r"^src1-[0-9a-f]{64}$"
const SHA_HEX = r"^[0-9a-f]{64}$"
_escape_cell(s) = escape_string(string(s))

function _points_tsv(reads)::String
    rows = sort(
        [[_escape_cell(getproperty(r, Symbol(c))) for c in POINT_COLUMNS] for r in reads];
        by=first,
    )
    io = IOBuffer()
    println(io, join(POINT_COLUMNS, '\t'))
    foreach(row -> println(io, join(row, '\t')), rows)
    return String(take!(io))
end

function _read_points(path)
    lines = readlines(path)
    isempty(lines) && return nothing, Vector{Vector{String}}()
    return lines[1], [String.(split(l, '\t')) for l in lines[2:end]]
end

_relation(read, result) =
    if !_known(result) || !_known(read)
        "unknown"
    elseif read == result
        "matches"
    else
        "differs"
    end

function _copy_if_absent(src, dest)
    isfile(dest) && return nothing
    mkpath(dirname(dest))
    cp(src, dest)
    return nothing
end

"""
    write_provenance!(revdir; reads, observations_dir, sources_dir, render_observation = nothing,
                      allow_mismatch = false, source_contents = true) -> Dict

Write `provenance.toml`, `provenance/points.tsv` and the observations and source snapshots the
points name into a revision being deposited. `reads` are records with the fields of
`POINT_COLUMNS` (what `Pinax.report` returns). Refuses when a point's read bytes differ from the
bytes its computation recorded, unless `allow_mismatch`, which is then recorded. An observation a
point names that is not in `observations_dir` is listed as missing, never silently dropped.
"""
function write_provenance!(
    revdir;
    reads,
    observations_dir,
    sources_dir,
    render_observation=nothing,
    allow_mismatch::Bool=false,
    source_contents::Bool=true,
)
    reads = collect(reads)
    relations = [_relation(r.read_sha256, r.result_sha256) for r in reads]
    differs = [r.key for (r, rel) in zip(reads, relations) if rel == "differs"]
    !isempty(differs) &&
        !allow_mismatch &&
        error(
            "provenance: the bytes read differ from the bytes the computation recorded for " *
            "$(length(differs)) point(s), e.g. $(first(differs)); pass allow_mismatch=true to " *
            "deposit them anyway (it is recorded)",
        )

    tsv = _points_tsv(reads)
    mkpath(joinpath(revdir, "provenance"))
    write(joinpath(revdir, POINTS_FILE), tsv)

    tokens = Set(r.observation for r in reads if _known(r.observation))
    render_observation === nothing || push!(tokens, render_observation)
    for t in tokens
        occursin(TOKEN, t) || error("provenance: $(repr(t)) is not an observation token")
    end
    present, missing_tokens = String[], String[]
    binding_of_token = Dict{String,String}()
    for t in sort(collect(tokens))
        src = joinpath(observations_dir, "$t.toml")
        if !isfile(src)
            push!(missing_tokens, t)
            continue
        end
        push!(present, t)
        _copy_if_absent(src, joinpath(revdir, "repro", "observations", "$t.toml"))
        obs = TOML.parsefile(src)
        binding_of_token[t] = _counted(get(obs, "binding", "unknown"))
        if source_contents        # the Project/Manifest the process ran with, when it stored them
            for sha in values(get(obs, "environment", Dict()))
                blob = joinpath(sources_dir, "blobs", string(sha))
                occursin(SHA_HEX, string(sha)) &&
                    isfile(blob) &&
                    _copy_if_absent(blob, _blob_path(revdir, sha))
            end
        end
        snapshot = get(obs, "source", nothing)
        snapshot === nothing && continue
        occursin(SNAPSHOT, snapshot) ||
            error("provenance: observation $t names $(repr(snapshot)), not a snapshot id")
        for f in ("files.tsv", "state.toml")
            _copy_if_absent(
                joinpath(sources_dir, snapshot, f),
                joinpath(_snapshot_dir(revdir, snapshot), f),
            )
        end
        source_contents || continue
        for line in
            Iterators.drop(eachline(joinpath(sources_dir, snapshot, "files.tsv")), 1)
            sha = last(split(line, '\t'))
            blob = joinpath(sources_dir, "blobs", sha)
            occursin(SHA_HEX, sha) &&
                isfile(blob) &&
                _copy_if_absent(blob, _blob_path(revdir, sha))
        end
    end

    bindings = Dict{String,Int}()
    for r in reads
        b = get(binding_of_token, r.observation, "unknown")
        bindings[b] = get(bindings, b, 0) + 1
    end
    summary = Dict{String,Any}(
        "schema" => PROVENANCE_SCHEMA,
        "points" => length(reads),
        "points_file" => POINTS_FILE,
        "points_digest" => "sha256:" * bytes2hex(sha256(tsv)),
        "counts" => Dict(
            "read_matches_result" => count(==("matches"), relations),
            "read_differs_from_result" => count(==("differs"), relations),
            "result_unknown" => count(==("unknown"), relations),
        ),
        "bindings" => bindings,
        "observations" => present,
        "missing_observations" => missing_tokens,
        "allow_mismatch" => allow_mismatch,
        "source_contents" => source_contents,
    )
    render_observation === nothing || (summary["render_observation"] = render_observation)
    open(
        io -> TOML.print(io, summary; sorted=true), joinpath(revdir, "provenance.toml"), "w"
    )
    return summary
end

# ── validation (§5.5) ─────────────────────────────────────────────────────────────────────────

function check_provenance(r, revdir)
    path = joinpath(revdir, "provenance.toml")
    isfile(path) || return nothing
    p = load(r, path)
    p === nothing && return nothing
    get(p, "schema", nothing) == PROVENANCE_SCHEMA ||
        (err!(r, path, "`schema` must be \"$PROVENANCE_SCHEMA\""); return nothing)
    file = require(r, path, p, "points_file"; type=String)
    file === nothing && return nothing
    points = joinpath(revdir, file)
    isfile(points) || (err!(r, path, "points file $file does not exist"); return nothing)
    get(p, "points_digest", "") == "sha256:" * bytes2hex(open(sha256, points)) ||
        err!(r, path, "`points_digest` does not match $file")
    header, rows = _read_points(points)
    header == join(POINT_COLUMNS, '\t') ||
        err!(r, points, "the header is not `$(join(POINT_COLUMNS, "\\t"))`")
    bad = findfirst(row -> length(row) != length(POINT_COLUMNS), rows)
    if bad !== nothing
        err!(r, points, "row $(bad + 1) does not have $(length(POINT_COLUMNS)) cells")
        return nothing
    end
    get(p, "points", -1) == length(rows) || err!(
        r,
        path,
        "`points` is $(get(p, "points", nothing)) but $file has $(length(rows)) rows",
    )
    point_keys = first.(rows)
    issorted(point_keys) && allunique(point_keys) ||
        err!(r, points, "rows are not sorted by a unique key")

    relations = [_relation(row[3], row[4]) for row in rows]
    counts = get(p, "counts", Dict())
    for (field, rel) in (
        ("read_matches_result", "matches"),
        ("read_differs_from_result", "differs"),
        ("result_unknown", "unknown"),
    )
        get(counts, field, -1) == count(==(rel), relations) ||
            err!(r, path, "`counts.$field` does not match $file")
    end
    n_differs = count(==("differs"), relations)
    n_differs > 0 && warn!(
        r,
        path,
        "$n_differs point(s) read bytes that differ from what their computation recorded" *
        (get(p, "allow_mismatch", false) ? " (deposited with allow_mismatch)" : ""),
    )

    missing_listed = Set(get(p, "missing_observations", String[]))
    tokens = Set(row[5] for row in rows if _known(row[5]))
    haskey(p, "render_observation") && push!(tokens, p["render_observation"])
    binding_of_token = Dict{String,String}()
    for t in sort(collect(tokens))
        occursin(TOKEN, t) ||
            (err!(r, points, "$(repr(t)) is not an observation token"); continue)
        obs_path = joinpath(revdir, "repro", "observations", "$t.toml")
        if !isfile(obs_path)
            if t in missing_listed
                warn!(r, path, "observation $t was not available to deposit")
            else
                err!(r, path, "observation $t is named but not in repro/observations")
            end
            continue
        end
        obs = load(r, obs_path)
        obs === nothing && continue
        binding = get(obs, "binding", nothing)
        binding == "loaded-matches-disk" && warn!(
            r,
            obs_path,
            "`loaded-matches-disk` cannot rule out code defined outside a package (a script, a " *
            "closure, a method added to Base); it is counted as `unverified`",
        )
        binding_of_token[t] = _counted(string(binding))
        binding in BINDINGS || err!(
            r,
            obs_path,
            "`binding` $(repr(binding)) is not one of $(sort(collect(BINDINGS)))",
        )
        snapshot = get(obs, "source", nothing)
        snapshot === nothing && continue
        occursin(SNAPSHOT, snapshot) ||
            (err!(r, obs_path, "`source` $(repr(snapshot)) is not a snapshot id"); continue)
        tsv = joinpath(_snapshot_dir(revdir, snapshot), "files.tsv")
        if !isfile(tsv)
            err!(r, obs_path, "its source snapshot $snapshot is not in repro/sources")
        elseif "src1-" * bytes2hex(open(sha256, tsv)) != snapshot
            err!(r, tsv, "does not hash to its snapshot id $snapshot")
        end
    end
    bindings = Dict{String,Int}()
    for row in rows
        b = get(binding_of_token, row[5], "unknown")
        bindings[b] = get(bindings, b, 0) + 1
    end
    get(p, "bindings", Dict()) == bindings ||
        err!(r, path, "`bindings` does not match the observations the points name")
    return nothing
end
