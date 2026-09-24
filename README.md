# Archeion.jl

[![docs: dev](https://img.shields.io/badge/docs-dev-purple.svg)](https://qatlashub.github.io/Archeion.jl/dev/)
[![Julia](https://img.shields.io/badge/julia-v1.12+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)

[![codecov](https://codecov.io/gh/QAtlasHub/Archeion.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/QAtlasHub/Archeion.jl)
[![Build Status](https://github.com/QAtlasHub/Archeion.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/QAtlasHub/Archeion.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![registry format](https://img.shields.io/badge/registry-%2F2-1a7f37.svg)](SPEC.md)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A registry of rendered research results: plain files in a git repository, one directory per
record, one frozen directory per revision, and nothing that has to be running for them to be read.
The format is [`SPEC.md`](SPEC.md) (`spec = "registry/2"`, stable). This package is one
implementation of it and depends on the standard library only.

**What it is, which registries it supports, and how to deploy a result into one** are one page in
the [documentation](https://qatlashub.github.io/Archeion.jl/dev/).

```julia
using Archeion

Archeion.init("path/to/registry"; title = "The Registry")   # once: its directories and its config
Archeion.validate("path/to/registry")          # (; errors, warnings, summary)
Archeion.build("path/to/registry")             # a static site in _site/, relative links only
```

`init` writes `registry.toml`, whose `[site]` is what a reader meets first — the banner's title,
its tagline, the links that become a menu on a narrow screen, and a footer:

```toml
[site]
title = "The Registry"
tagline = "one question per record"
footer = ""

[[site.links]]
text = "The lab"
url = "https://example.org"
```

Nothing there is required: a registry that says none of it is titled after itself.

From a shell, the same two as a CI job would run them:

```sh
julia -m Archeion init path/to/registry --title="The Registry"
julia -m Archeion validate path/to/registry    # exit 1 on any error
julia -m Archeion build path/to/registry       # exit non-zero if a link in the site is broken
```

## Reading it

A registry is files, so the plainest way to read one is to open them. The catalogue — everything
indexed, each record's revisions, each revision's report — is what `build` writes, and it is
derived: never committed, rebuilt from the tree whenever it is wanted.

**As a site (the usual way).** One command writes the workflows that build and publish it on every
push, pinned to the Archeion version that wrote them:

```sh
julia -m Archeion pages path/to/registry       # then: Settings -> Pages -> Source: GitHub Actions
```

A **private repository's Pages site is public** on every plan but Enterprise Cloud. For a registry
that must not be, build it on a machine you reach and read it over SSH:

```sh
julia -m Archeion pages path/to/registry \
      --runner='[self-hosted, my-box]' --site=/home/me/site/my-registry
```

Every push then builds the catalogue into that directory — built beside it and renamed into place,
so a reader never meets a half-written site — and nothing is published. Open it with
[ssh-browser](https://github.com/QAtlasHub/ssh-browser), which gives those files a real http
origin:

```sh
ssh-browser my-box /home/me/site/my-registry/index.html
```

`julia -m Archeion build path/to/registry` does the same by hand, into `_site/`. The catalogue's
own search needs no origin, so `file://` works too; anything that fetches does not.

## What the catalogue shows

One page: every project with its record and revision counts and when it was last frozen, the
months revisions were frozen in, and a card per record. The search reads what a record *says* —
every revision's title, the question and claim it states, its tags, its identifiers, and the
comments left on it — so a word from a comment finds the record it was left on. Words narrow:
two of them means both.

## Adding a result

A record is created once and gets revisions after that. The two are separate operations, so a
copied script cannot silently continue another record:

```julia
using Archeion, Pinax

new_binding(".registry/bindings/phase.toml";      # once; commit the file it writes
            root = "../my-registry", slug = "phase-diagram",
            project = "c0ffee00-1111-4222-8333-444444444444")   # the UUID in projects/<slug>.toml

# ... build the document with @page / @section / @figure, then render both faces ...
render(; out = "out/gallery")
render(; theme = :agent, out = "out/agent")

deposit(".registry/bindings/phase.toml";          # every time: a new revision of that record
        gallery = "out/gallery", agent = "out/agent", source_repo = pwd(),
        doc = Archeion.doc_fields(Pinax.current_document(); tags = ["..."]))
```

`doc_fields` reads the document that was rendered, not its output. `deposit` writes the revision
beside the registry, validates the whole registry with it in place, takes it back out if that
fails, and otherwise commits that one path and pushes.

### From a vault, in one call

With Pinax **and** DataVault loaded, `publish` is that whole path — render both faces, deposit
them with the table of which bytes each parameter point contributed, and send the commit to the
shared registry — so a study writes its recipe and nothing else:

```julia
using Archeion, Pinax, DataVault

Archeion.publish(vault, recipe;
                 binding = ".registry/bindings/phase.toml",
                 title = "The phase diagram", out = "out/report/phase",
                 status = :trial,             # required: `final` presents the claims (SPEC §5.4)
                 source_repo = pwd(),
                 remote = :pr)                # :pr | :push | :local
```

Before anything is written it brings the registry clone to its remote (refusing a dirty tree or a
history that is not a fast-forward), and warns when the commit that rendered the report is not yet
on the remote's default branch — the revision cites it, and a squash merge would leave that
citation unresolvable.

[QAtlasHub/archeion-demo](https://github.com/QAtlasHub/archeion-demo) is a registry with one record
made this way.

## Before 0.4

Up to v0.3.3 Archeion was a different package: a registry with an SQLite index, a Node web app and
an FTPS deploy. 0.4 keeps none of it and is not compatible with it. Code that calls the 0.3 API
should pin `rev = "v0.3.3"`.
