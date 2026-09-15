# Archeion.jl

[![docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://qatlashub.github.io/Archeion.jl/stable/)
[![docs: dev](https://img.shields.io/badge/docs-dev-purple.svg)](https://qatlashub.github.io/Archeion.jl/dev/)
[![Julia](https://img.shields.io/badge/julia-v1.12+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)

<a id="badge-top"></a>
[![codecov](https://codecov.io/gh/QAtlasHub/Archeion.jl/graph/badge.svg)](https://codecov.io/gh/QAtlasHub/Archeion.jl)
[![Build Status](https://github.com/QAtlasHub/Archeion.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/QAtlasHub/Archeion.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/main/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Archeion** (ἀρχεῖον, *archive*) is an experiment registry: rendered results accumulate in it,
each one carrying the provenance needed to reproduce it, and the whole thing stays browsable.

## The registry is a directory tree

```
<root>/                            $ARCHEION_REGISTRY, or [archeion] root, or ~/registry
  index.html                       the catalogue, rebuilt from the tree
  pagefind/                        client-side full-text search (optional, no server)
  <project>/<source>/
    record.toml                    the ONLY file this package parses
    repro/                         commit, dirty flag, Project.toml, Manifest.toml, reproduce.sh
    index.html  assets/            the rendered result, exactly as it was built
    <anything else>                sidecars: notes, slides, an annotation store, a PDF
```

Two properties follow from that shape, and they are the reason it is a tree:

- **The index is derived.** `read_records` finds every directory holding a `record.toml`, at any
  depth, so a record another tool wrote appears in the catalogue without this package knowing
  that tool exists.
- **A deposit owns only what it wrote.** Re-rendering a study replaces its files and prunes the
  ones that render no longer produces. Everything else in the record directory is left alone, so
  a sidecar cannot be destroyed by a re-render.

Nothing here needs a server: the catalogue is static HTML and the search index is
[Pagefind](https://pagefind.app/), so the registry can be read straight off the machine that
computed it.

## Quickstart

```julia
using Archeion

Archeion.deposit(
    "report";                       # any built directory with an index.html on top
    project = "OpenBoundary",
    source  = "phase1",
    title   = "Does the environment remove the open boundary?",
    srcdir  = ".",                  # snapshot this tree's commit + environment into repro/
    root    = "/path/to/registry",  # or set ARCHEION_REGISTRY once and drop this
)
```

That copies the directory in, captures the provenance bundle, writes `record.toml`, and rebuilds
the catalogue. `strict = true` refuses a source tree with uncommitted changes; otherwise the
record records `git_dirty` and the card says `+dirty`, because a commit that does not describe
the tree that ran is worse than no commit at all.

Rendering a parameter sweep first is one call up the stack:

```julia
Pinax.report(vault, recipe; title = "…", out = "report")         # gallery + agent.json
Archeion.deposit(
    "report";
    project = "…", source = "phase1", srcdir = ".",
    doc = Pinax.current_document(),      # `report` returns (; gallery, agent, n), not the doc
)
```

Heavy data is never copied into the registry. A record references it by `data_keys` (DataVault
keys), so the registry stays small enough to keep forever.

## Optional layers, on top of the same tree

| layer | what it adds | entry point |
| --- | --- | --- |
| SQLite | FTS5 search, `body_md` for RAG, record ↔ run M:N | `ingest(doc; db, …)` |
| `web/` (Node) | annotation write-back: memos, tags, status, a Zettelkasten note layer | `web/README.md` |
| deploy | push the built tree to a private host over FTPS, creds held by an agent | `deploy`, `publish` |

They read the same records; none of them is on the path between a result and someone reading it.

## Configuration

Archeion ships no project config. A project adds an `[archeion]` section to the SAME `config.toml`
that drives ParamIO / DataVault / ParallelManager; see `config/archeion.example.toml`. The
registry root resolves as: explicit argument → `[archeion] root` → `ENV["ARCHEION_REGISTRY"]` →
`~/registry`.
