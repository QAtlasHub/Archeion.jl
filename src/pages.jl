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
const DEPOSIT_WORKFLOW = "deposit.yml"

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
function _setup_steps(version; env="archeion-env")
    return join(
        [
            "      - uses: julia-actions/setup-julia@v2",
            "        with:",
            "          version: \"1.12\"",
            "      - name: Install Archeion into a throwaway environment",
            "        run: julia --startup-file=no -e 'using Pkg; Pkg.activate(\"$env\"); " *
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

# A deposit's pull request, merged without a person when the registry says it may be: the tree
# validates, and the change only adds (`additions`). Only branches `publish` pushes (`deposit/…`)
# from this repository itself, never a fork. What is merged is the commit that was checked
# (`--match-head-commit`), one at a time. A merge made with the workflow's own token starts no
# other workflow, so the site is asked to rebuild here, by name.
#
# `pull_request_target`, not `pull_request`: the checks are then the default branch's, and a
# deposit branch that edits this file does not edit the checks it is judged by. The branch's
# content is only read, as data, by an Archeion installed from a pinned tag — nothing in it runs —
# so the write token this event carries is not handed to anything the branch wrote. A failure is
# said on the pull request, since nobody is expected to be watching the run. Archeion's environment
# is made outside the checkout: a branch that shipped its own `archeion-env/Manifest.toml` would
# otherwise choose what that environment loads.
const DEPOSIT_ENV = "\${{ runner.temp }}/archeion-env"
function _deposit_yml(version, branch, runner, site_workflow)
    return """
name: deposit

# Merges a deposit's pull request when the registry checks it: the tree validates and the change
# only adds to it. Written by `julia -m Archeion pages --automerge=true`; run that again when the
# version changes.
on:
  pull_request_target:
    branches: [$branch]
    types: [opened, synchronize, reopened]

permissions:
  contents: write
  pull-requests: write
  actions: write

concurrency:
  group: deposit-merge
  cancel-in-progress: false

jobs:
  merge:
    if: startsWith(github.head_ref, 'deposit/') && github.event.pull_request.head.repo.full_name == github.repository
    runs-on: $runner
    steps:
      - uses: actions/checkout@v4
        with:
          ref: \${{ github.event.pull_request.head.sha }}
          fetch-depth: 0
          persist-credentials: false
$(_setup_steps(version; env=DEPOSIT_ENV))
      - name: The tree is well formed
        run: julia --startup-file=no --project=$DEPOSIT_ENV -m Archeion validate .
      - name: Nothing already in it was touched
        run: julia --startup-file=no --project=$DEPOSIT_ENV -m Archeion additions . --base=origin/\${{ github.base_ref }}
      - name: Merge the commit that was checked
        env:
          GH_TOKEN: \${{ github.token }}
        run: >-
          gh pr merge \${{ github.event.pull_request.number }} --merge
          --match-head-commit \${{ github.event.pull_request.head.sha }}
          --repo \${{ github.repository }}
      - name: Rebuild the site from what was merged
        env:
          GH_TOKEN: \${{ github.token }}
        run: gh workflow run $site_workflow --ref $branch --repo \${{ github.repository }}
      - name: Say so on the pull request when any of this failed
        if: failure()
        env:
          GH_TOKEN: \${{ github.token }}
        run: >-
          gh pr comment \${{ github.event.pull_request.number }} --repo \${{ github.repository }}
          --body "deposit.yml did not finish: \${{ github.server_url }}/\${{ github.repository }}/actions/runs/\${{ github.run_id }}"
"""
end

"""
    setup_pages(root; version = this version, branch = default_branch(root), validate = true,
                runner = "ubuntu-latest", site = nothing, automerge = false) -> (; written, skipped)

Write the workflows that publish `root` as a site and check it on every push. Returns the paths
`written` and those `skipped`, relative to `root`. The Archeion version is pinned to the one writing them, which is what
`registry.toml` should name.

By default the site is **GitHub Pages**. A **private repository's Pages site is public** on every
plan but Enterprise Cloud, so for a registry that must not be, pass `site` — a directory on the
machine `runner` names, built into on every push and read from there over SSH — and the Pages
workflow is not written at all.

With `automerge`, a third workflow merges a deposit's pull request (a `deposit/…` branch of this
repository, as `publish` pushes) without a person when the tree validates and the change only adds
to it ([`additions`](@ref)), then asks the site to rebuild. A public registry is public from the
push: this decides only when a deposit is merged, not what may be deposited.
"""
function setup_pages(
    root;
    version=_version(),
    branch=default_branch(root),
    validate::Bool=true,
    runner="ubuntu-latest",
    site=nothing,
    automerge::Bool=false,
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
    if automerge
        site_workflow = site === nothing ? PAGES_WORKFLOW : SITE_WORKFLOW
        write(
            joinpath(dir, DEPOSIT_WORKFLOW),
            _deposit_yml(version, branch, runner, site_workflow),
        )
        push!(written, joinpath(".github", "workflows", DEPOSIT_WORKFLOW))
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
    any(p -> endswith(p, DEPOSIT_WORKFLOW), written) && println(
        io,
        "note: $DEPOSIT_WORKFLOW merges with the workflow's own token: the repository must " *
        "allow merge commits, and Settings -> Actions -> Workflow permissions must allow write",
    )
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
