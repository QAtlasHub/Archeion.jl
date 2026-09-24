# pages.jl — the first route a reader takes: the catalogue, built by GitHub Actions on every push,
# served as a site nobody has to run anything to read.
#
# The workflow is short enough to write by hand, which is the problem: the Archeion version in it
# has to be the one `registry.toml` names, and a copied file drifts. So it is generated, pinned to
# the version that generated it, and the same generator writes the validate workflow that guards
# the tree the site is built from.

const PAGES_WORKFLOW = "pages.yml"
const VALIDATE_WORKFLOW = "validate.yml"
const SITE_WORKFLOW = "site.yml"

_version() = string(pkgversion(@__MODULE__))

"""
    default_branch(root) -> String

The branch the workflows should watch: the one `root` is on, or what its remote calls default.
Asked rather than assumed — GitHub has created repositories on `main` since 2020, and a workflow
whose `on: push: branches:` names a branch that does not exist never runs and never says so.
"""
function default_branch(root)
    for args in (
        ("symbolic-ref", "--short", "refs/remotes/origin/HEAD"),
        ("rev-parse", "--abbrev-ref", "HEAD"),
    )
        b = git(root, args...; ok=true)
        b === nothing || isempty(b) || return String(last(split(b, '/')))
    end
    return "main"
end

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

# The catalogue built from the registry tree. The site is derived and never committed: every
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

function _validate_yml(version, runner="ubuntu-latest")
    return """
name: validate

# The same commands run locally: nothing here is CI-only. Written by `julia -m Archeion pages`.
on:
  push:
  pull_request:

jobs:
  validate:
    runs-on: $runner
    steps:
      - uses: actions/checkout@v4
$(_setup_steps(version))
      - run: julia --startup-file=no --project=archeion-env -m Archeion validate .
      - run: julia --startup-file=no --project=archeion-env -m Archeion build .
"""
end

# A registry whose site may not be public is still read as a site: built on a machine you reach,
# into a directory that does not move, and opened over SSH. ssh-browser gives those files a real
# http origin, which `file://` does not — the catalogue's own search works either way, but a page
# that fetches anything needs one. The build lands by rename, so a reader never meets a
# half-written site.
function _site_yml(version, branch, runner, out)
    return """
name: site

# Builds the catalogue into $out on every push, for reading over SSH. The site is derived and
# never committed. Written by `julia -m Archeion pages`; run that again when the version changes.
on:
  push:
    branches: [$branch]
  workflow_dispatch:

jobs:
  site:
    runs-on: $runner
    steps:
      - uses: actions/checkout@v4
$(_setup_steps(version))
      - run: julia --startup-file=no --project=archeion-env -m Archeion validate .
      - name: Build into the directory it is read from
        run: |
          set -eu
          # Both scratch names are cleared first: `mv a b` puts a *inside* b when b is a
          # directory, so a previous build left where it stands would nest the next one
          # inside it, and the one after that would fail outright.
          rm -rf "$out.new" "$out.previous"
          julia --startup-file=no --project=archeion-env -m Archeion build . "$out.new"
          if [ -d "$out" ]; then mv "$out" "$out.previous"; fi
          mv "$out.new" "$out"
"""
end

"""
    setup_pages(root; version = this version, branch = default_branch(root), validate = true,
                runner = "ubuntu-latest", site = nothing) -> (; written, skipped)

Write the workflows that publish `root` as a site and check it on every push. Returns the paths
`written` and those `skipped`, relative to `root`. The Archeion version is pinned to the one writing them, which is what
`registry.toml` should name.

By default the site is **GitHub Pages**. A **private repository's Pages site is public** on every
plan but Enterprise Cloud, so for a registry that must not be, pass `site` — a directory on the
machine `runner` names, built into on every push and read from there over SSH — and the Pages
workflow is not written at all.
"""
function setup_pages(
    root;
    version=_version(),
    branch=default_branch(root),
    validate::Bool=true,
    runner="ubuntu-latest",
    site=nothing,
)
    dir = joinpath(root, ".github", "workflows")
    mkpath(dir)
    written, skipped = String[], String[]
    if site === nothing
        write(joinpath(dir, PAGES_WORKFLOW), _pages_yml(version, branch))
        push!(written, joinpath(".github", "workflows", PAGES_WORKFLOW))
    else
        write(joinpath(dir, SITE_WORKFLOW), _site_yml(version, branch, runner, site))
        push!(written, joinpath(".github", "workflows", SITE_WORKFLOW))
    end
    if validate
        write(joinpath(dir, VALIDATE_WORKFLOW), _validate_yml(version, runner))
        push!(written, joinpath(".github", "workflows", VALIDATE_WORKFLOW))
    else
        push!(skipped, joinpath(".github", "workflows", VALIDATE_WORKFLOW))
    end
    return (; written, skipped)
end

# The version a registry says it is read with, or nothing when it does not say.
function implementation_named(root)
    isfile(registry_file(root)) || return nothing
    return get(read_registry_toml(root), "implementation", nothing)
end

# What the person still has to do, which no file can do for them.
function pages_instructions(io, root, written, version; site=nothing)
    foreach(p -> println(io, "wrote ", p), written)
    println(io, "pinned to Archeion v", version)
    named = implementation_named(root)
    named === nothing ||
        occursin(version, named) ||
        println(io, "note: registry.toml says \"$named\" — make the two agree")
    println(io)
    if site === nothing
        println(io, "next: commit these, then under the repository's Settings -> Pages")
        println(
            io, "      set Source to \"GitHub Actions\". The next push builds the site."
        )
        println(
            io,
            "note: a PRIVATE repository's Pages site is PUBLIC on every plan but Enterprise",
        )
        println(io, "      Cloud. For one that must not be: --site=DIR, read over SSH.")
    else
        println(io, "next: commit these. Every push builds the catalogue into")
        println(io, "      $site on the runner's machine; nothing is published.")
        println(
            io, "      Read it over SSH — ssh-browser gives those files an http origin:"
        )
        println(io, "      ssh-browser <host> $site/index.html")
    end
    return nothing
end
