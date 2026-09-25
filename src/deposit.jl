# deposit.jl — add a revision to a registry/2 record.
#
# Called by the script that renders a report, which holds the document model and passes what the
# entry needs as values (SPEC.md §5.1): nothing here parses the rendered output. Two operations,
# deliberately separate (a copied script must not silently continue someone else's record):
#
#     new_binding(path; root, project, slug)       # once: choose a new record id, write the binding
#     deposit(binding; gallery, agent, doc, ...)   # every time: add a revision to that record
#
# The binding is a small TOML file committed in the repository whose code renders the report.

const SKIP = Set([".pinax-manifest.toml"])                        # render-cache bookkeeping

utcnow() = floor(now(Dates.UTC), Second)

function git(dir, args...; ok=false)
    # `ignorestatus` forgives a nonzero exit; it does nothing about a process that cannot be
    # spawned at all, which is what happens when there is no `git` on PATH — `run` throws a bare
    # `IOError` naming neither the registry nor the operation. Checked once, here, because every
    # other git call in the package goes through this function.
    Sys.which("git") === nothing &&
        error("no `git` on PATH, so `git $(join(args, ' '))` cannot run in $dir")
    out = IOBuffer()
    err = IOBuffer()
    proc = run(pipeline(ignorestatus(`git -C $dir $args`); stdout=out, stderr=err))
    success(proc) ||
        ok ||
        error("git $(join(args, ' ')) failed in $dir:\n$(String(take!(err)))")
    return success(proc) ? strip(String(take!(out))) : nothing
end

# Whether `dir` is inside a git repository. Named because three places ask, and because what they
# do with the answer differs: `check_settled` has nothing to check, `rollback!` has no undo to
# offer, and `deposit` has a revision it can still write but no commit to make of it.
under_git(dir) = git(dir, "rev-parse", "--git-dir"; ok=true) !== nothing

# ── binding ───────────────────────────────────────────────────────────────────────────────────

"""
    new_binding(path; root, project, slug, kind = "report") -> (; record)

Choose a new record identifier and write the binding file at `path`. Refuses if `path` exists: a
binding is created once and committed, and every later `deposit` through it adds a revision to the
same record. `root` is the registry, stored relative to the binding file's directory. `kind` is what the
record holds — `"report"` for a rendered result, `"note"` for a lab note — and is fixed with the
record, because a record answers one question in one way (§4).
"""
function new_binding(path; root, project, slug, kind=DEFAULT_KIND)
    ispath(path) &&
        error("$path exists; a binding is created once. Use another path for a new record.")
    is_slug(slug) || error("slug must be lower-case words joined by `-` (R6)")
    is_uuid(project) || error("$project is not a UUID (R5)")
    kind in RECORD_KINDS || error("kind must be one of $(sort(collect(RECORD_KINDS)))")
    haskey(first(scan(root)), project) ||
        error("project $project is not in $(joinpath(root, "projects"))")
    id = new_uuid()
    mkpath(dirname(abspath(path)))
    open(path, "w") do io
        return TOML.print(
            io,
            Dict(
                "spec" => SPEC,
                "registry" => relpath(abspath(root), dirname(abspath(path))),
                "project" => project,
                "record" => id,
                "slug" => slug,
                "kind" => kind,
            );
            sorted=true,
        )
    end
    # A NamedTuple, and `record` is what `deposit` calls the same value: one vocabulary for the
    # two calls that make a record, and room to say more later without breaking a caller.
    return (; record=id)
end

# What the registry itself holds, uncommitted. Not the whole working tree: `_site/`, a binding
# under `.registry/`, a scratch file beside them are none of a deposit's business.
const REGISTRY_CONTENT = ("records", "projects", INDEX_FILE)

"""
    check_settled(reg)

Refuse to deposit into a registry whose own content is not committed. A deposit reads the tree to
decide what it is adding to — the current revision it will name as parent, the index it will
rewrite — so anything on disk that git does not have is something the next revision may cite and
nobody else will ever see.

That is not hypothetical: a deposit interrupted between writing a revision and committing it leaves
exactly that, the tree still validates, and the *next* deposit names the orphan as its parent and
commits **that**. One `git clean` later the registry holds a committed revision whose parent
resolves nowhere, and the parent's bytes are gone — not even as an unreferenced object.
"""
function check_settled(reg)
    under_git(reg) || return nothing
    dirty = git(reg, "status", "--porcelain", "--", REGISTRY_CONTENT...; ok=true)
    (dirty === nothing || isempty(dirty)) && return nothing
    return error(
        "$reg has uncommitted changes of its own; commit them before depositing, so that what " *
        "the next revision is built on is what everyone else will see:\n  " *
        replace(dirty, "\n" => "\n  "),
    )
end

"The registry a binding names, as an absolute path: the binding stores it relative to itself."
function registry_of(binding)
    return normpath(
        joinpath(dirname(abspath(binding)), TOML.parsefile(binding)["registry"])
    )
end

# A record is found by its UUID, which lives in the files rather than the path (R5). The index
# answers first; the tree is asked when the index has not caught up with it yet.
function find_record(reg, uuid)
    listed = get(get(read_registry_toml(reg), "records", Dict{String,Any}()), uuid, nothing)
    if listed !== nothing
        dir = joinpath(reg, listed["path"])
        isdir(dir) && return dir
    end
    found = last(scan(reg))
    haskey(found, uuid) || return nothing
    return joinpath(reg, found[uuid]["path"])
end

# ── what the revision says ────────────────────────────────────────────────────────────────────

# The code state, read now. Labelled "publish" because that is when it is read (SPEC.md §5.3).
# `nothing` when `repo` is not under git: a study need not be, and then there is no commit to name
# (§5.1: a value that is not known is omitted). What its code was is then the provenance's to hold.
function source_now(repo, role)
    commit = git(repo, "rev-parse", "HEAD"; ok=true)
    commit === nothing && return nothing
    dirty = !isempty(git(repo, "status", "--porcelain", "--untracked-files=normal"))
    r = Dict{String,Any}("role" => role, "commit" => commit, "dirty" => dirty)
    url = git(repo, "remote", "get-url", "origin"; ok=true)
    url === nothing || (r["url"] = url)
    return Dict{String,Any}("captured" => "publish", "repo" => [r])
end

# Whether a revision being written holds some source: a snapshot's inventory in `repro/sources/`
# and file contents in `repro/blobs/`.
function _holds_source(revdir)
    sources, blobs = joinpath(revdir, "repro", "sources"),
    joinpath(revdir, "repro", "blobs")
    isdir(sources) && isdir(blobs) && !isempty(readdir(blobs)) || return false
    return any(d -> isfile(joinpath(sources, d, "files.tsv")), readdir(sources))
end

function readme(e; held::Bool=false)
    d = e["doc"]
    s = get(e, "source", nothing)
    io = IOBuffer()
    println(io, "# ", d["title"], "\n")
    println(
        io,
        "- Record `",
        e["id"]["record"],
        "`, revision `",
        e["id"]["rev"],
        "`",
        if isempty(e["parents"])
            " (the first)."
        else
            ", revising " * join(("`$p`" for p in e["parents"]), ", ") * "."
        end,
    )
    println(
        io,
        "- Status: ",
        d["status"],
        haskey(d, "tags") ? ". Tags: " * join(d["tags"], ", ") * "." : ".",
    )
    println(io, "- Frozen ", Dates.format(e["time"]["frozen"], "yyyy-mm-ddTHH:MM:SS"), "Z.")
    haskey(d, "question") && println(io, "\nAsked: ", d["question"])
    haskey(d, "claim") && println(io, "\nClaimed: ", d["claim"])
    println(
        io,
        "\nOpen `gallery/index.html` for the report. `agent/agent.json` is the same report for a",
        "\nprogram: each figure as the table of what it plots.",
    )
    if s !== nothing
        println(io, "\n## Where it came from\n")
        for r in s["repo"]
            println(
                io,
                "- ",
                r["role"],
                ": commit `",
                r["commit"],
                "`",
                haskey(r, "url") ? " of " * r["url"] : "",
                r["dirty"] ? ", with uncommitted changes" : ", clean",
                ".",
            )
        end
        println(
            io,
            "\nThe code state was read at ",
            s["captured"],
            ", not necessarily when the report was rendered.",
        )
    elseif held
        println(
            io,
            "\n## Where it came from\n\nNot from a git repository. The files the computing and ",
            "rendering processes could see\nare held in `repro/`; `provenance.toml` names them.",
        )
    end
    ext = get(e["preservation"], "external", String[])
    println(
        io,
        "\n## What it can be trusted for\n\nRead only",
        isempty(ext) ? "." : "; it needs " * join(ext, ", ") * " to display fully.",
        " Rebuilding it is claimed only once a `capability.verified` event records that it worked.",
    )
    return String(take!(io))
end

# A face is a directory; `Pinax.render` and `Pinax.report` return the file they wrote in it
# (`index.html`, `agent.json`), so a file stands for its directory.
face_dir(path) = isfile(path) ? dirname(path) : path

# Remove a revision being built. A failure here must not replace the failure that got us here:
# the caller is about to rethrow what actually went wrong.
function discard!(dir)
    try
        rm(dir; recursive=true, force=true)
    catch e
        @warn "could not remove $dir" exception = e
    end
    return nothing
end

function copy_tree(src, dest)
    isdir(src) || error("$src is not a directory")
    for (dir, _, files) in walkdir(src), f in files
        f in SKIP && continue
        target = joinpath(dest, relpath(joinpath(dir, f), src))
        mkpath(dirname(target))
        cp(joinpath(dir, f), target)
    end
end

# §5.2: every file of the revision except SHA256SUMS itself, which a rewrite would otherwise list
# with the digest it had before this call.
function write_sums(revdir)
    files = sort([
        relpath(joinpath(d, f), revdir) for (d, _, fs) in walkdir(revdir) for
        f in fs if relpath(joinpath(d, f), revdir) != "SHA256SUMS"
    ])
    open(joinpath(revdir, "SHA256SUMS"), "w") do io
        for f in files
            println(io, bytes2hex(open(sha256, joinpath(revdir, f))), "  ", f)
        end
    end
end

# ── deposit ───────────────────────────────────────────────────────────────────────────────────

"""
    deposit(binding; gallery, agent, doc, source_repo, external = [], repro = Dict(),
            parents = nothing, push = true, provenance = nothing) -> NamedTuple

Freeze a new revision of the binding's record: copy `gallery` and `agent`, write `entry.toml`,
`README.md` and `SHA256SUMS`, move it into place, validate the whole registry (and take the
revision back out if that fails), then commit only that path and push.

A registry that is not under git still gets its revision: what makes a revision what it is holds
of a directory, and `validate` has just agreed. The commit is what is skipped, `commit` comes back
as `nothing` to say so, and nothing is pushed.

That holds of `deposit` itself. It does not extend through [`publish`](@ref), which syncs with a
remote and pushes — neither of which means anything without git — so `publish` refuses such a
registry up front and says to use `deposit`.

`doc` carries what the document model knows: `title`, `status` ("trial"/"final"), anchors split
into `stable` and `positional` (written as `anchors.local`), and optionally `tags`, `question`,
`claim`. `parents` defaults to the record's current revision; a record in conflict needs them
named. `repro` maps paths under `repro/` to files.

`provenance` adds per-point provenance (SPEC.md §5.5): the keywords of `write_provenance!`, which
[`provenance_from`](@ref) builds from a DataVault vault and a `Pinax.report` result. A point whose
bytes read differ from what its computation recorded makes the deposit refuse, unless
`allow_mismatch = true`.
"""
function deposit(
    binding;
    gallery,
    agent,
    doc,
    source_repo,
    external=String[],
    repro=Dict{String,String}(),
    parents=nothing,
    push=true,
    provenance=nothing,
)
    isfile(binding) ||
        error("no binding at $binding; create one with new_binding (once per record)")
    b = TOML.parsefile(binding)
    # `new_binding` checked these when it wrote the file, but the file is committed in another
    # repository and edited by hand; what names a directory here is checked where it is used.
    is_uuid(get(b, "record", nothing)) ||
        error("$binding: `record` $(repr(get(b, "record", nothing))) is not a UUID (R5)")
    is_uuid(get(b, "project", nothing)) ||
        error("$binding: `project` $(repr(get(b, "project", nothing))) is not a UUID (R5)")
    is_slug(get(b, "slug", nothing)) ||
        error("$binding: `slug` $(repr(get(b, "slug", nothing))) is not a slug (R6)")
    get(b, "kind", DEFAULT_KIND) in RECORD_KINDS || error(
        "$binding: `kind` $(repr(b["kind"])) is not one of $(join(RECORD_KINDS, ", "))"
    )
    reg = registry_of(binding)
    id = b["record"]
    check_settled(reg)
    r0 = validate(reg)
    isempty(r0.errors) || error(
        "the registry does not validate before depositing:\n  " * join(r0.errors, "\n  "),
    )

    recdir = find_record(reg, id)
    frozen = utcnow()
    new_record = recdir === nothing
    # What the record holds is the record's, not the revision's: an existing record keeps the kind
    # it was created with, and a binding written before kinds existed means DEFAULT_KIND.
    kind = if new_record
        get(b, "kind", DEFAULT_KIND)
    else
        get(TOML.parsefile(joinpath(recdir, "record.toml")), "kind", DEFAULT_KIND)
    end
    # The binding's `slug` names a record only when there is not one yet. Afterwards the record's
    # own directory is the name, and it may be renamed without touching the binding (R6): the two
    # disagreeing is not a conflict to resolve, because only the UUID resolves anything.
    if new_record
        recdir = joinpath(reg, "records", Dates.format(frozen, "yyyy"), b["slug"])
        ispath(recdir) && error(
            "$recdir exists: another record of this year is already called $(b["slug"]); " *
            "give this one another slug",
        )
        record = Dict{String,Any}(
            "spec" => SPEC,
            "uuid" => id,
            "kind" => kind,
            "project" => b["project"],
            "title" => doc.title,
            "created" => frozen,
        )
    else
        record = TOML.parsefile(joinpath(recdir, "record.toml"))
        record["project"] == b["project"] || error(
            "the binding names project $(b["project"]) but record $id belongs to $(record["project"])",
        )
    end

    revroot = joinpath(recdir, "revisions")
    if parents === nothing
        names = isdir(revroot) ? readdir(revroot) : String[]
        evdir = joinpath(recdir, "events")
        events = isdir(evdir) ? [TOML.parsefile(f) for f in readdir(evdir; join=true)] : []
        revinfo = Dict(
            n => (; parents=TOML.parsefile(joinpath(revroot, n, "entry.toml"))["parents"])
            for n in names
        )
        heads = current(revinfo, events)
        length(heads) > 1 && error(
            "record $id is in conflict ($(join(heads, ", "))); name the parents explicitly",
        )
        parents = heads
    end

    rev = Dates.format(frozen, PATH_TIME) * "-" * tag()
    entry = Dict{String,Any}(
        "spec" => SPEC,
        "parents" => collect(parents),
        "id" =>
            Dict("project" => b["project"], "record" => id, "rev" => rev, "kind" => kind),
        "time" => Dict("frozen" => frozen),
        "doc" => Dict{String,Any}("title" => doc.title, "status" => doc.status),
        "anchors" =>
            Dict("stable" => collect(doc.stable), "local" => collect(doc.positional)),
        "preservation" => Dict{String,Any}("level" => "read"),
    )
    # Without git, the only record of the code is the source contents the provenance copies in. A
    # revision with neither would say nothing about what produced it, so it is refused: up front
    # when nothing could be copied, and again below from what `repro/` actually came to hold.
    asked = provenance !== nothing && get(provenance, :source_contents, true)
    src = source_now(source_repo, "render")
    no_code(why) = error(
        "$source_repo is not a git repository, and $why: nothing would record what code " *
        "produced this revision",
    )
    if src === nothing
        asked || no_code(
            "no source contents are deposited (pass `provenance` with " *
            "`source_contents = true`)",
        )
    else
        entry["source"] = src
    end
    for k in (:tags, :question, :claim)
        haskey(doc, k) && (entry["doc"][string(k)] = doc[k])
    end
    isempty(external) || (entry["preservation"]["external"] = collect(external))

    incoming = joinpath(reg, "_incoming", rev)
    ispath(incoming) && error("$incoming exists")
    mkpath(incoming)
    try
        copy_tree(face_dir(gallery), joinpath(incoming, "gallery"))
        copy_tree(face_dir(agent), joinpath(incoming, "agent"))
        for (dest, src) in repro
            mkpath(dirname(joinpath(incoming, "repro", dest)))
            cp(src, joinpath(incoming, "repro", dest))
        end
        open(
            io -> TOML.print(io, entry; sorted=true), joinpath(incoming, "entry.toml"), "w"
        )
        provenance === nothing || write_provenance!(incoming; provenance...)
        # What the revision holds, not what was asked for: an observation the store no longer
        # has leaves `repro/` without a snapshot, and then the code is recorded nowhere.
        held = asked && _holds_source(incoming)
        src === nothing &&
            !held &&
            no_code("no source snapshot reached repro/ (its observations are missing)")
        src !== nothing &&
            src["repo"][1]["dirty"] &&
            @warn(
                "$source_repo has uncommitted changes; the revision records `dirty = true`" *
                    (held ? ", and holds the files it could see in repro/" : "")
            )
        write(joinpath(incoming, "README.md"), readme(entry; held))
        write_sums(incoming)                              # last: its presence means "complete"
    catch e
        discard!(incoming)                                # nothing half-written is left behind
        rethrow(e)
    end

    final = joinpath(revroot, rev)
    mkpath(revroot)
    new_record && open(
        io -> TOML.print(io, record; sorted=true), joinpath(recdir, "record.toml"), "w"
    )
    mv(incoming, final)
    reindex!(reg)                                     # the index follows the tree (§2.1)
    r = validate(reg)
    if !isempty(r.errors)
        rm(final; recursive=true)
        new_record && rm(recdir; recursive=true)
        reindex!(reg)
        error(
            "the new revision does not validate, so it was taken back out:\n  " *
            join(r.errors, "\n  "),
        )
    end

    # A registry that is not under git still gets its revision. Everything that makes a revision
    # what it is — the files, their digests, the parent it answers after — is true of a directory,
    # and `validate` has just said so. Refusing at this point used to throw a raw `git add` failure
    # *after* the revision was already in place, which left it written, valid, and reported as a
    # failure. So the commit is the part that is skipped, and `commit === nothing` says it was.
    path = relpath(new_record ? recdir : final, reg)
    committed = if under_git(reg)
        git(reg, "add", "--", path, INDEX_FILE)
        git(
            reg,
            "commit",
            "-q",
            "-m",
            "deposit $id $rev: $(doc.title)",
            "--",
            path,
            INDEX_FILE,
        )
        git(reg, "rev-parse", "HEAD")
    else
        @warn "$reg is not a git repository: the revision is written and validates, but nothing " *
            "was committed, so nothing records when it arrived or what it was added to"
        nothing
    end
    pushed = false
    if push && committed !== nothing
        if git(reg, "push", "-q"; ok=true) === nothing
            rebase_onto_remote!(reg)                      # someone else deposited meanwhile
            git(reg, "push", "-q")
        end
        pushed = true
    end
    return (;
        record=id,
        rev,
        parents=entry["parents"],
        dir=final,
        commit=committed,
        pushed,
        dirty=src === nothing ? nothing : src["repo"][1]["dirty"],
    )
end

# The numbering Pinax gives a figure or table with no explicit id. Named here because it is a
# renderer's convention rather than a fact about registries, and kept as the default because a
# document written by hand follows it too — but the Pinax extension passes it explicitly, so a
# change to Pinax's numbering is a change beside Pinax and not a silent misreading here.
const AUTO_NUMBERED = r"_(fig|tbl)\d+$"

"""
    anchors(ids; auto = r"_(fig|tbl)\\d+\$") -> (; stable, positional)

Split anchor ids into those that keep their meaning across revisions and those Pinax numbered by
position (`<section>_fig<N>`, `<section>_tbl<N>`), which point elsewhere once a figure is inserted.
"""
function anchors(ids; auto=AUTO_NUMBERED)
    ids = unique(string.(ids))
    return (;
        stable=filter(i -> !occursin(auto, i), ids),
        positional=filter(i -> occursin(auto, i), ids),
    )
end
