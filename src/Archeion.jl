"""
    Archeion

A registry of rendered research results, kept as plain files in a git repository and read with
nothing but a text viewer if need be. The format is `SPEC.md` (`spec = "registry/1"`); this
package is one implementation of it, depending on the standard library only.

- [`validate`](@ref) checks a registry against the format.
- [`build`](@ref) renders it as a static site with relative links only.
- [`new_binding`](@ref) and [`deposit`](@ref) add a record, then revisions of it.
- [`doc_fields`](@ref) (with Pinax loaded) takes what an entry needs from a rendered document.
- [`provenance_from`](@ref) (with DataVault loaded) takes per-point provenance from a vault.

- [`setup_pages`](@ref) writes the workflows that publish the catalogue as a site.

From a shell: `julia -m Archeion validate [root]`, `julia -m Archeion build [root] [out]`,
`julia -m Archeion pages [root] [--branch=B] [--runner=R] [--site=DIR]`.
"""
module Archeion

using Dates
using Random
using SHA
using TOML

include("validate.jl")
include("build.jl")
include("provenance.jl")
include("deposit.jl")
include("remote.jl")
include("pages.jl")

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
public validate, build, anchors, doc_fields, provenance_from, publish, setup_pages, main

function usage(io=stderr)
    println(io, "usage: julia -m Archeion validate [root]")
    println(io, "       julia -m Archeion build [root] [out]")
    println(
        io, "       julia -m Archeion pages [root] [--branch=B] [--runner=R] [--site=DIR]"
    )
    println(
        io, "         writes the workflows that publish the catalogue: GitHub Pages, or"
    )
    println(io, "         with --site a directory on the runner's machine, read over SSH")
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

The command line: `validate [root]` prints the records and every warning and error, and returns 1
when there is an error; `build [root] [out]` writes the site (by default to `<root>/_site`).
"""
function (@main)(args)
    isempty(args) && return usage()
    cmd = args[1]
    opts, rest = flags(args[2:end])
    root = isempty(rest) ? pwd() : rest[1]
    if cmd == "validate"
        r, summary = validate(root)
        foreach(s -> println("  ", s), summary)
        foreach(w -> println("warning: ", w), r.warnings)
        foreach(e -> println("error: ", e), r.errors)
        println(
            if isempty(r.errors)
                "ok: $(length(summary)) record(s)"
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
            branch=get(opts, "branch", "master"),
            runner=get(opts, "runner", "ubuntu-latest"),
            site=get(opts, "site", nothing),
        )
        pages_instructions(
            stdout, root, written, _version(); site=get(opts, "site", nothing)
        )
        return 0
    end
    return usage()
end

end
