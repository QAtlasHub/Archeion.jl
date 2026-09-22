# validate.jl — check a registry against SPEC.md (spec = "registry/1").
#
# Errors fail a registry; warnings are reported and do not. Section numbers refer to SPEC.md.

const SPEC = "registry/1"
const B32 = "[0-9a-hjkmnp-tv-z]"                       # Crockford base32, lower case (R5)
const PROJECT_ID = Regex("^p_$(B32){8}\$")
const RECORD_DIR = Regex("^(\\d{4}-\\d{2}-\\d{2})-([a-z0-9-]+)-(r_$(B32){8})\$")
const REV_DIR = Regex("^(\\d{8}T\\d{6}Z)-($(B32){4})\$")
const EVENT_FILE = r"^(\d{8}T\d{6}Z)-([a-z0-9]+)-([a-z0-9_.-]+)\.toml$"
const SEGMENT = r"^[A-Za-z0-9_.-]+$"                     # R1
const RESERVED = Set([
    "con", "prn", "aux", "nul", ("com$i" for i in 1:9)..., ("lpt$i" for i in 1:9)...
])   # R4
const FORBIDDEN_KEYS = Set(["completed", "available", "missing", "done", "exists"])  # §8
const EVENT_KINDS = Set(["comment", "yank", "supersede", "capability.verified"])     # §7
const PATH_TIME = dateformat"yyyymmdd\THHMMSS\Z"

struct Report
    root::String
    errors::Vector{String}
    warnings::Vector{String}
end
Report(root) = Report(root, String[], String[])
rel(r::Report, path) = relpath(path, r.root)
err!(r::Report, path, msg) = push!(r.errors, "$(rel(r, path)): $msg")
warn!(r::Report, path, msg) = push!(r.warnings, "$(rel(r, path)): $msg")

# ── parsing ───────────────────────────────────────────────────────────────────────────────────

# Julia's TOML reads `…Z` and a zone-less time into the same DateTime, and rejects any other
# offset, so R7 is checked on the text: every unquoted date-time must end in `Z`.
function zone_less_times(text)
    unquoted = replace(
        text,
        r"\"\"\"[\s\S]*?\"\"\"" => "",
        r"'''[\s\S]*?'''" => "",
        r"\"(?:[^\"\\\n]|\\.)*\"" => "",
        r"'[^'\n]*'" => "",
        r"#[^\n]*" => "",
    )
    pattern = r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(?![\dZz.])"
    return [m.match for m in eachmatch(pattern, unquoted)]
end

function load(r::Report, path)
    isfile(path) || (err!(r, path, "missing"); return nothing)
    text = read(path, String)
    for t in zone_less_times(text)
        err!(
            r, path, "time `$t` has no `Z`; times inside files are UTC with a Z suffix (R7)"
        )
    end
    try
        return TOML.parse(text)
    catch e
        msg = first(split(sprint(showerror, e), '\n'))
        occursin("offset date-time", sprint(showerror, e)) &&
            (msg = "a time carries an offset other than Z (R7)")
        err!(r, path, "does not parse: $msg")
        return nothing
    end
end

function getpath(d, keys...)
    return foldl((x, k) -> x isa AbstractDict ? get(x, k, nothing) : nothing, keys; init=d)
end

function require(r, path, d, keys...; type=Any)
    v = getpath(d, keys...)
    name = join(keys, ".")
    v === nothing && (err!(r, path, "required field `$name` is missing"); return nothing)
    v isa type ||
        (err!(r, path, "`$name` must be a $(type), got $(typeof(v))"); return nothing)
    return v
end

function check_spec(r, path, d)
    return get(d, "spec", nothing) == SPEC || err!(r, path, "`spec` must be \"$SPEC\"")
end

# ── §1 names and paths ────────────────────────────────────────────────────────────────────────

function check_paths(r::Report)
    for top in ("projects", "records")
        base = joinpath(r.root, top)
        isdir(base) || continue
        for (dir, dirs, files) in walkdir(base)
            folded = Dict{String,String}()
            for name in vcat(dirs, files)
                other = get!(folded, lowercase(name), name)
                other == name || err!(
                    r,
                    joinpath(dir, name),
                    "differs from `$other` only in case; a case-insensitive filesystem merges them (R1)",
                )
            end
            for name in vcat(dirs, files)
                path = joinpath(dir, name)
                occursin(':', name) && err!(r, path, "`:` in a path (R2)")
                occursin(SEGMENT, name) || err!(
                    r,
                    path,
                    "segment `$name` uses characters outside ASCII [A-Za-z0-9_.-] (R1)",
                )
                length(name) <= 64 ||
                    err!(r, path, "segment longer than 64 characters (R3)")
                length(rel(r, path)) <= 180 ||
                    err!(r, path, "path longer than 180 characters (R3)")
                lowercase(first(split(name, '.'))) in RESERVED &&
                    err!(r, path, "`$name` is a Windows reserved name (R4)")
                endswith(name, ".") && err!(r, path, "segment ends in `.` (R4)")
            end
        end
    end
end

# ── §3 projects ───────────────────────────────────────────────────────────────────────────────

function check_projects(r::Report)
    ids = Set{String}()
    base = joinpath(r.root, "projects")
    isdir(base) || return ids
    for f in sort(readdir(base))
        path = joinpath(base, f)
        endswith(f, ".toml") || (err!(r, path, "not a project file"); continue)
        d = load(r, path)
        d === nothing && continue
        check_spec(r, path, d)
        id = require(r, path, d, "id"; type=String)
        if id !== nothing
            occursin(PROJECT_ID, id) ||
                err!(r, path, "`id` is not a project identifier (R5)")
            id == f[1:(end - 5)] || err!(r, path, "`id` $id does not match the file name")
            push!(ids, id)
        end
        require(r, path, d, "name"; type=String)
        require(r, path, d, "created"; type=DateTime)
    end
    return ids
end

# ── §5 revisions ──────────────────────────────────────────────────────────────────────────────

# §5.1: commits, digests and byte counts have one shape wherever they appear; §8: forbidden keys.
function check_values(r, path, x, where="")
    if x isa AbstractDict
        for (k, v) in x
            key = isempty(where) ? k : "$where.$k"
            k in FORBIDDEN_KEYS && err!(
                r,
                path,
                "`$key`: a revision states what it used, not what is computed (§8)",
            )
            if k == "commit"
                v isa String && occursin(r"^[0-9a-f]{40}$", v) ||
                    err!(r, path, "`$key` must be 40 hexadecimal characters")
            elseif endswith(k, "digest")
                v isa String && occursin(r"^sha256:[0-9a-f]{64}$", v) || err!(
                    r, path, "`$key` must be \"sha256:\" and 64 hexadecimal characters"
                )
            elseif k == "bytes"
                v isa Integer && v > 0 || err!(
                    r, path, "`$key` must be a positive integer (omit it when unknown)"
                )
            end
            check_values(r, path, v, key)
        end
    elseif x isa AbstractVector
        foreach(v -> check_values(r, path, v, where), x)
    end
end

function check_sums(r::Report, revdir)
    sums = joinpath(revdir, "SHA256SUMS")
    isfile(sums) || (
        err!(r, revdir, "no SHA256SUMS: the revision is incomplete (§5.2)");
        return nothing
    )
    listed = Set{String}()
    for (n, line) in enumerate(eachline(sums))
        m = match(r"^([0-9a-f]{64})  (.+)$", line)
        m === nothing && (err!(r, sums, "line $n is not `<sha256>  <path>`"); continue)
        file = String(m[2])
        file in listed && err!(r, sums, "`$file` is listed twice")
        push!(listed, file)
        full = joinpath(revdir, file)
        if !isfile(full)
            err!(r, sums, "`$file` is listed but does not exist")
        elseif bytes2hex(open(sha256, full)) != m[1]
            err!(r, sums, "`$file` does not match its sha256: the revision was changed")
        end
    end
    for (dir, _, files) in walkdir(revdir), f in files
        file = relpath(joinpath(dir, f), revdir)
        file == "SHA256SUMS" ||
            file in listed ||
            err!(r, joinpath(dir, f), "not listed in SHA256SUMS")
    end
end

function check_revision(r::Report, revdir, record, revs)
    name = basename(revdir)
    m = match(REV_DIR, name)
    m === nothing && (
        err!(r, revdir, "revision directory is not `<YYYYMMDDTHHMMSSZ>-<tag>`");
        return nothing
    )
    path = joinpath(revdir, "entry.toml")
    e = load(r, path)
    check_sums(r, revdir)
    isfile(joinpath(revdir, "README.md")) || err!(r, revdir, "no README.md (§5.2)")
    e === nothing && return nothing
    check_spec(r, path, e)
    for (k, want) in (
        ("project", get(record, "project", nothing)),
        ("record", get(record, "id", nothing)),
        ("rev", name),
        ("kind", get(record, "kind", nothing)),
    )
        v = require(r, path, e, "id", k; type=String)
        v === nothing || v == want || err!(r, path, "`id.$k` is $v, expected $want")
    end
    parents = require(r, path, e, "parents"; type=AbstractVector)
    for p in something(parents, [])
        p isa String && p in revs && p != name ||
            err!(r, path, "parent $(repr(p)) is not another revision of this record")
    end
    frozen = require(r, path, e, "time", "frozen"; type=DateTime)
    frozen === nothing ||
        frozen == DateTime(m[1], PATH_TIME) ||
        err!(r, path, "`time.frozen` $frozen does not match the directory's time $(m[1])")
    title = require(r, path, e, "doc", "title"; type=String)
    title !== nothing && isempty(strip(title)) && err!(r, path, "`doc.title` is empty")
    status = require(r, path, e, "doc", "status"; type=String)
    status === nothing ||
        status in ("trial", "final") ||
        err!(r, path, "`doc.status` must be \"trial\" or \"final\"")
    stable = require(r, path, e, "anchors", "stable"; type=AbstractVector)
    loc = require(r, path, e, "anchors", "local"; type=AbstractVector)
    if stable !== nothing && loc !== nothing
        both = intersect(Set(stable), Set(loc))
        isempty(both) || err!(
            r, path, "anchors both stable and local: $(join(sort(collect(both)), ", "))"
        )
    end
    level = require(r, path, e, "preservation", "level"; type=String)
    level === nothing ||
        level == "read" ||
        err!(
            r,
            path,
            "`preservation.level` is \"read\"; higher levels are earned by events (§6)",
        )
    src = getpath(e, "source")
    if src !== nothing
        getpath(src, "captured") in ("run-start", "completion", "publish") || err!(
            r,
            path,
            "`source.captured` must be \"run-start\", \"completion\" or \"publish\"",
        )
        for repo in something(getpath(src, "repo"), [])
            get(repo, "role", nothing) in ("compute", "analysis", "render") ||
                err!(r, path, "`source.repo.role` must be compute, analysis or render")
            get(repo, "dirty", nothing) isa Bool ||
                err!(r, path, "`source.repo.dirty` must be a boolean")
        end
    end
    check_values(r, path, e)
    check_provenance(r, revdir)
    return (;
        name,
        parents=something(parents, []),
        anchors=(stable=Set(something(stable, [])), loc=Set(something(loc, []))),
    )
end

# ── §7 events and the current revision ──────────────────────────────────────────────────────

function check_events(r::Report, recdir, recid, revinfo)
    evdir = joinpath(recdir, "events")
    events = Dict{String,Any}[]
    isdir(evdir) || return events
    for f in sort(readdir(evdir))
        path = joinpath(evdir, f)
        occursin(EVENT_FILE, f) || (
            err!(r, path, "event file is not `<YYYYMMDDTHHMMSSZ>-<origin>-<key>.toml`");
            continue
        )
        ev = load(r, path)
        ev === nothing && continue
        check_spec(r, path, ev)
        kind = require(r, path, ev, "kind"; type=String)
        kind === nothing ||
            kind in EVENT_KINDS ||
            warn!(r, path, "event kind `$kind` is not known to registry/1")
        require(r, path, ev, "at"; type=DateTime)
        subj = require(r, path, ev, "subject", "record"; type=String)
        subj === nothing ||
            subj == recid ||
            err!(r, path, "`subject.record` $subj is not this record")
        rev = getpath(ev, "subject", "rev")
        anchor = getpath(ev, "subject", "anchor")
        if rev !== nothing && !haskey(revinfo, rev)
            warn!(r, path, "`subject.rev` $rev does not exist (dangling)")
        elseif rev !== nothing && anchor !== nothing
            a = revinfo[rev].anchors
            anchor in a.stable || warn!(
                r,
                path,
                if anchor in a.loc
                    "`subject.anchor` $anchor is local to its revision"
                else
                    "`subject.anchor` $anchor does not exist in revision $rev (dangling)"
                end,
            )
        end
        push!(events, ev)
    end
    return events
end

# §7.1
function current(revinfo, events)
    targets(k) =
        Set(getpath(ev, "subject", "rev") for ev in events if get(ev, "kind", "") == k)
    live = setdiff(Set(keys(revinfo)), targets("yank"))
    parents = Set(p for v in live for p in revinfo[v].parents if p in live)
    return sort(collect(setdiff(live, parents, targets("supersede"))))
end

# ── §4 records ────────────────────────────────────────────────────────────────────────────────

function check_record(r::Report, recdir, year, projects, seen)
    rec = basename(recdir)
    m = match(RECORD_DIR, rec)
    m === nothing && (
        err!(r, recdir, "record directory is not `<YYYY-MM-DD>-<slug>-<record-id>`");
        return nothing
    )
    startswith(m[1], year) ||
        err!(r, recdir, "created in $(m[1][1:4]) but filed under $year")
    id = String(m[3])
    haskey(seen, id) && err!(r, recdir, "record id $id is also used by $(seen[id])")
    seen[id] = rel(r, recdir)
    path = joinpath(recdir, "record.toml")
    d = load(r, path)
    d === nothing && return nothing
    check_spec(r, path, d)
    rid = require(r, path, d, "id"; type=String)
    rid === nothing ||
        rid == id ||
        err!(r, path, "`id` $rid does not match the directory's $id")
    kind = require(r, path, d, "kind"; type=String)
    kind === nothing ||
        kind == "report" ||
        err!(r, path, "`kind` must be \"report\" in registry/1")
    proj = require(r, path, d, "project"; type=String)
    proj === nothing ||
        proj in projects ||
        err!(r, path, "project $proj is not in projects/")
    created = require(r, path, d, "created"; type=DateTime)
    created === nothing ||
        Dates.format(created, "yyyy-mm-dd") == m[1] ||
        err!(r, path, "created on $(Date(created)) but the directory says $(m[1])")
    revroot = joinpath(recdir, "revisions")
    names = if isdir(revroot)
        sort(filter(n -> isdir(joinpath(revroot, n)), readdir(revroot)))
    else
        String[]
    end
    isempty(names) && err!(r, recdir, "a record has at least one revision")
    revinfo = Dict{String,Any}()
    for n in names
        info = check_revision(r, joinpath(revroot, n), d, Set(names))
        info === nothing || (revinfo[n] = info)
    end
    events = check_events(r, recdir, id, revinfo)
    heads = current(revinfo, events)
    length(heads) > 1 &&
        warn!(r, recdir, "several current revisions; nothing is chosen by time (§7.1)")
    state = if length(heads) == 1
        "current $(only(heads))"
    elseif isempty(heads)
        "withdrawn"
    else
        "in conflict: $(join(heads, ", "))"
    end
    return "$id  $(length(revinfo)) revision(s), $(length(events)) event(s), $state"
end

function validate(root)
    r = Report(abspath(root))
    check_paths(r)
    projects = check_projects(r)
    seen = Dict{String,String}()
    summary = String[]
    base = joinpath(r.root, "records")
    for year in (isdir(base) ? sort(readdir(base)) : String[])
        ydir = joinpath(base, year)
        isdir(ydir) && occursin(r"^\d{4}$", year) ||
            (err!(r, ydir, "not a year directory"); continue)
        for rec in sort(readdir(ydir))
            s = check_record(r, joinpath(ydir, rec), year, projects, seen)
            s === nothing || push!(summary, s)
        end
    end
    return r, summary
end
