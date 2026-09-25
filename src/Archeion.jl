"""
    Archeion

A registry of rendered research results, kept as plain files in a git repository and read with
nothing but a text viewer if need be. The format is `SPEC.md` (`spec = "registry/2"`); this
package is one implementation of it, depending on the standard library only.

- [`validate`](@ref) checks a registry against the format.
- [`build`](@ref) renders it as a static site with relative links only.
- [`new_binding`](@ref) and [`deposit`](@ref) add a record, then revisions of it.
- [`doc_fields`](@ref) (with Pinax loaded) takes what an entry needs from a rendered document.
- [`provenance_from`](@ref) (with DataVault loaded) takes per-point provenance from a vault.

- [`init`](@ref) starts a registry: its directories, its `registry.toml`, its workflows.
- [`setup_pages`](@ref) writes the workflows that publish the catalogue as a site.

From a shell: `julia -m Archeion init [root]`, `validate [root]`, `build [root] [out]`,
`pages [root] [--branch=B] [--runner=R] [--site=DIR]`, `reindex [root]`, `migrate [root]`.
"""
module Archeion

using Dates
using Random
using SHA
using TOML

include("ids.jl")
include("index.jl")
include("validate.jl")
include("appearance.jl")
include("dark.jl")
include("build.jl")
include("provenance.jl")
include("deposit.jl")
include("remote.jl")
include("restore.jl")
include("pages.jl")
include("init.jl")
include("migrate.jl")

"""
    doc_fields(doc; tags = String[], question = nothing, claim = nothing) -> NamedTuple

What [`deposit`](@ref) needs from a document model: `title`, `status`, `stable` and `positional`
anchors, and the optional fields given. The method for a `Pinax.Document` is defined when Pinax is
loaded, and reads the document that was rendered, never its output.
"""
function doc_fields end

"""
    provenance_from(vault, report; allow_mismatch = false, source_contents = true) -> NamedTuple

What [`deposit`](@ref)'s `provenance` needs, from a DataVault `vault` and the result of
`Pinax.report`: the points it read, where the vault keeps its observations and source snapshots,
and the render observation. The method for a `DataVault.Vault` is defined when DataVault is loaded.
"""
function provenance_from end

"""
    publish(vault, recipe; binding, title, out, status, source_repo, remote = :pr, ...) -> NamedTuple

Render a vault through `recipe`, deposit both faces as a new revision of the binding's record with
the table of what was read, and send that commit to the shared registry. The one call a study
makes; the method is defined when both Pinax and DataVault are loaded.

`status` (`:trial` or `:final`) is required: what a revision vouches for is the author's to state
(SPEC §5.4), not a default to inherit. `remote` is `:pr` (a branch and a pull request), `:push`
(straight onto the current branch, rebasing once if the remote moved) or `:local` (commit only).
Before anything is written the registry clone is brought to its remote, and the commit that
rendered the report is checked for being published — a revision cites it.
"""
function publish end

export deposit, new_binding
publicvalidate,reindex!,registry_of,sync!,check_source_published,publish_revision!,migrate!,build,anchors,doc_fields,provenance_from,publish,setup_pages,init,restore,verify,git_tree_hash,main

function usage(io=stderr)
    println(io, "usage: julia -m Archeion init [root] [--name=N] [--title=T] [--tagline=S]")
    println(io, "       julia -m Archeion validate [root]")
    println(io, "       julia -m Archeion reindex [root]     # the index, from the tree")
    println(io, "       julia -m Archeion migrate [root]     # registry/1 -> registry/2")
    println(io, "       julia -m Archeion build [root] [out]")
    println(
        io, "       julia -m Archeion pages [root] [--branch=B] [--runner=R] [--site=DIR]"
    )
    println(
        io, "         writes the workflows that publish the catalogue: GitHub Pages, or"
    )
    println(io, "         with --site a directory on the runner's machine, read over SSH")
    println(io, "       julia -m Archeion restore <revision> <dest>")
    println(io, "       julia -m Archeion verify <revision> <dest> [--entry=F] [--julia=J]")
    println(io, "         recompute a revision from what it holds, in a sealed directory")
    return 2
end

# `--flag=value` anywhere among the arguments, and whatever is left of them.
function flags(rest)
    opts = Dict{String,String}()
    positional = String[]
    for a in rest
        m = match(r"^--([a-z-]+)=(.*)$", a)
        m === nothing ? push!(positional, a) : (opts[m[1]] = String(m[2]))
    end
    return opts, positional
end

"""
    main(args) -> exit code

The command line. `usage()` prints the same list; in short:

- `init [root]` starts a registry — its directories, `registry.toml`, its workflows
- `validate [root]` prints the records and every warning and error, and returns 1 on any error
- `build [root] [out]` writes the site, by default to `<root>/_site`
- `pages [root]` writes the workflows that publish it, pinned to this version
- `reindex [root]` rewrites `registry.toml`'s index from the tree
- `migrate [root]` converts a `registry/1` tree, and prints which identifier became which UUID
- `restore <revision> <dest>` lays out what a revision holds; `verify <revision> <dest>` also
  recomputes it there and, when every point matches, writes `capability.verified`

Returns the process exit code: 0, 1 for a registry with errors, 2 for a usage problem.
"""
function (@main)(args)
    isempty(args) && return usage()
    cmd = args[1]
    opts, rest = flags(args[2:end])
    root = isempty(rest) ? pwd() : rest[1]
    if cmd == "init"
        name = get(opts, "name", basename(abspath(root)))
        written = init(
            root;
            name=name,
            title=get(opts, "title", name),
            tagline=get(opts, "tagline", ""),
            branch=get(opts, "branch", default_branch(root)),
            runner=get(opts, "runner", "ubuntu-latest"),
            site=get(opts, "site", nothing),
        )
        init_instructions(stdout, root, written.written, name)
        return 0
    elseif cmd == "reindex"
        n = reindex!(root)
        println("indexed $(n.projects) project(s) and $(n.records) record(s)")
        return 0
    elseif cmd == "migrate"
        n = migrate!(root)
        println("converted $(n.projects) project(s) and $(n.records) record(s) to $SPEC")
        foreach(s -> println("  ", s), n.summary)
        # Bindings live in the repositories that render the reports, so this is the one thing the
        # conversion cannot finish by itself. Print what to put in them.
        println("\nwhat each identifier became — update every binding that names one:")
        for old in sort(collect(keys(n.ids)))
            println("  ", old, " -> ", n.ids[old])
        end
        return 0
    elseif cmd == "validate"
        r = validate(root)
        foreach(s -> println("  ", s), r.summary)
        foreach(w -> println("warning: ", w), r.warnings)
        foreach(e -> println("error: ", e), r.errors)
        println(
            if isempty(r.errors)
                "ok: $(length(r.summary)) record(s)"
            else
                "$(length(r.errors)) error(s)"
            end,
        )
        return isempty(r.errors) ? 0 : 1
    elseif cmd == "build"
        res = build(root, length(rest) >= 2 ? rest[2] : joinpath(root, "_site"))
        println(
            "built $(res.records) record(s) into $(res.out) ",
            "($(round(res.bytes / 1024; digits = 1)) KiB)",
        )
        return 0
    elseif cmd == "pages"
        written = setup_pages(
            root;
            branch=get(opts, "branch", default_branch(root)),
            runner=get(opts, "runner", "ubuntu-latest"),
            site=get(opts, "site", nothing),
        )
        pages_instructions(
            stdout, root, written.written, _version(); site=get(opts, "site", nothing)
        )
        return 0
    elseif cmd in ("restore", "verify")
        length(rest) == 2 || return usage()
        if cmd == "restore"
            r = restore(rest[1], rest[2])
            println("restored $(rest[1]) into $(r.dest)")
            println("  project: $(r.project)")
            println("  entry:   $(join(r.entry, ", "))")
            println("  julia:   ", something(r.julia, r.julia_note))
            for (k, v) in sort(collect(r.trees))
                println("  ", v ? "matches " : "DIFFERS ", k)
            end
            isempty(r.missing) || println("  not held: $(length(r.missing)) file(s)")
            return all(values(r.trees)) ? 0 : 1
        end
        v = verify(
            rest[1];
            dest=rest[2],
            entry=get(opts, "entry", nothing),
            julia=get(opts, "julia", nothing),
        )
        println(
            v.ok ? "verified: " : "not verified: ",
            "$(length(v.matched))/$(v.compared) point(s) matched, network $(v.network)",
        )
        isempty(v.differs) || println("  differ: ", join(v.differs, ", "))
        isempty(v.absent) || println("  not produced: ", join(v.absent, ", "))
        v.event === nothing || println("  event: ", v.event)
        println("  log: ", v.log)
        return v.ok ? 0 : 1
    end
    return usage()
end

end
