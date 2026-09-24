using Archeion
using Documenter

# Archeion depends on the standard library only, and so do its docs: no Literate, no plotting
# backend, nothing to compile. The whole build is three pages, and that is the point — a registry
# is meant to be readable without its tools, and its documentation should be too.

DocMeta.setdocmeta!(Archeion, :DocTestSetup, :(using Archeion); recursive=true)

# `SPEC.md` is the normative document and it lives at the repository root, where someone who
# cloned the registry tooling will look for it. The site needs it too, so it is copied in at build
# time rather than kept as a second file: two copies of a specification are one copy and one
# thing that used to be the specification.
let spec = read(joinpath(@__DIR__, "..", "SPEC.md"), String)
    write(
        joinpath(@__DIR__, "src", "spec.md"),
        """
        # The format

        Below is `SPEC.md` from the repository, verbatim and generated into this page at build
        time. It is the normative document: Archeion.jl is one implementation of it, and a
        registry that satisfies it can be read without this package at all.

        """ * spec,
    )
end

makedocs(;
    modules=[Archeion],
    sitename="Archeion.jl",
    authors="sota shimozono",
    format=Documenter.HTML(;
        # Measured 2026-09-24: `/dev/` serves 200 and `/stable/` 404s, because `versions.js` on
        # gh-pages is empty — no tag has ever been built with docs. (What is under `/v0.2/` and
        # `/v0.3/` there is the pre-0.4 package, which shared only the name.) `/stable/` is still
        # the right canonical target: it is the URL that will keep meaning "the released docs"
        # once a tag builds, and `/dev/` is a moving target.
        canonical="https://qatlashub.github.io/Archeion.jl/stable/",
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link="main",
    ),
    pages=[
        "Archeion" => "index.md",
        "How to use" => [
            "Create a registry" => "guide/registry.md",
            "Publish a result" => "guide/publish.md",
            "Correct or withdraw" => "guide/correct.md",
            "Everything else" => "guide/everything-else.md",
        ],
        "Architecture" => "architecture.md",
        "The format" => "spec.md",
        "API References" => "api.md",
    ],
    checkdocs=:none,   # the internals carry docstrings too; the API page lists what is public
)

deploydocs(; repo="github.com/QAtlasHub/Archeion.jl", devbranch="main", push_preview=true)
