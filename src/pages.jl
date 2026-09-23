# pages.jl — the first route a reader takes: the catalogue, built by GitHub Actions on every push,
# served as a site nobody has to run anything to read.
#
# The workflow is short enough to write by hand, which is the problem: the Archeion version in it
# has to be the one `registry.toml` names, and a copied file drifts. So it is generated, pinned to
# the version that generated it, and the same generator writes the validate workflow that guards
# the tree the site is built from.

const PAGES_WORKFLOW = "pages.yml"
const VALIDATE_WORKFLOW = "validate.yml"

_version() = string(pkgversion(@__MODULE__))

# Written as one string with its indentation spelled out: a triple-quoted block would be dedented
# to its own margin, and YAML is indentation.
function _setup_steps(version)
    return join(
        [
            "      - uses: julia-actions/setup-julia@v2",
            "        with:",
            "          version: \"1.12\"",
            "      - name: Install Archeion into a throwaway environment",
            "        run: julia --startup-file=no -e 'using Pkg; Pkg.activate(\"archeion-env\"); " *
            "Pkg.add(url=\"https://github.com/QAtlasHub/Archeion.jl\", rev=\"v$version\")'",
        ],
        "\n",
    )
end

function _pages_yml(version, branch)
    return """
name: pages

# The catalogue built from the registry/1 tree. The site is derived and never committed: every
# push rebuilds it with the Archeion version `registry.toml` names. Written by
# `julia -m Archeion pages`; run that again when the version changes.
on:
  push:
    branches: [$branch]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
$(_setup_steps(version))
      - run: julia --startup-file=no --project=archeion-env -m Archeion build .
      - uses: actions/upload-pages-artifact@v3
        with:
          path: _site
  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: \${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
"""
end

function _validate_yml(version)
    return """
name: validate

# The same commands run locally: nothing here is CI-only. Written by `julia -m Archeion pages`.
on:
  push:
  pull_request:

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
$(_setup_steps(version))
      - run: julia --startup-file=no --project=archeion-env -m Archeion validate .
      - run: julia --startup-file=no --project=archeion-env -m Archeion build .
"""
end

"""
    setup_pages(root; version = this version, branch = "master", validate = true) -> Vector{String}

Write the workflows that publish `root` as a GitHub Pages site and check it on every push, and
return the paths written, relative to `root`. The Archeion version is pinned to the one writing
them, which is what `registry.toml` should name.

A **private repository's Pages site is public** on every plan but Enterprise Cloud. Use this for a
registry anyone may read; read a private one locally ([`build`](@ref)) or serve it where access is
controlled.
"""
function setup_pages(root; version=_version(), branch="master", validate::Bool=true)
    dir = joinpath(root, ".github", "workflows")
    mkpath(dir)
    written = String[]
    write(joinpath(dir, PAGES_WORKFLOW), _pages_yml(version, branch))
    push!(written, joinpath(".github", "workflows", PAGES_WORKFLOW))
    if validate
        write(joinpath(dir, VALIDATE_WORKFLOW), _validate_yml(version))
        push!(written, joinpath(".github", "workflows", VALIDATE_WORKFLOW))
    end
    return written
end

# The version a registry says it is read with, or nothing when it does not say.
function implementation_named(root)
    path = joinpath(root, "registry.toml")
    isfile(path) || return nothing
    return get(TOML.parsefile(path), "implementation", nothing)
end

# What the person still has to do, which no file can do for them.
function pages_instructions(io, root, written, version)
    foreach(p -> println(io, "wrote ", p), written)
    println(io, "pinned to Archeion v", version)
    named = implementation_named(root)
    named === nothing ||
        occursin(version, named) ||
        println(io, "note: registry.toml says \"$named\" — make the two agree")
    println(io)
    println(io, "next: commit these, then under the repository's Settings -> Pages")
    println(io, "      set Source to \"GitHub Actions\". The next push builds the site.")
    println(
        io, "note: a PRIVATE repository's Pages site is PUBLIC on every plan but Enterprise"
    )
    println(io, "      Cloud. Read a private registry locally: julia -m Archeion build .")
    return nothing
end
