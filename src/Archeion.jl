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

From a shell: `julia -m Archeion validate [root]`, `julia -m Archeion build [root] [out]`.
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

export deposit, new_binding
public validate, build, anchors, doc_fields, provenance_from, main

function usage(io=stderr)
    println(io, "usage: julia -m Archeion validate [root]")
    println(io, "       julia -m Archeion build [root] [out]")
    return 2
end

"""
    main(args) -> exit code

The command line: `validate [root]` prints the records and every warning and error, and returns 1
when there is an error; `build [root] [out]` writes the site (by default to `<root>/_site`).
"""
function (@main)(args)
    isempty(args) && return usage()
    cmd, rest = args[1], args[2:end]
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
    end
    return usage()
end

end
