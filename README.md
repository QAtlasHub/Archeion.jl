# Archeion.jl

A registry of rendered research results: plain files in a git repository, one directory per
record, one frozen directory per revision, and nothing that has to be running for them to be read.
The format is [`SPEC.md`](SPEC.md) (`spec = "registry/1"`, draft). This package is one
implementation of it and depends on the standard library only.

```julia
using Archeion

Archeion.validate("path/to/registry")          # (report, summary): errors, warnings, records
Archeion.build("path/to/registry")             # a static site in _site/, relative links only
```

From a shell, the same two as a CI job would run them:

```sh
julia -m Archeion validate path/to/registry    # exit 1 on any error
julia -m Archeion build path/to/registry       # exit non-zero if a link in the site is broken
```

## Adding a result

A record is created once and gets revisions after that. The two are separate operations, so a
copied script cannot silently continue another record:

```julia
using Archeion, Pinax

new_binding(".registry/bindings/phase.toml";      # once; commit the file it writes
            registry = "../my-registry", project = "p_xxxxxxxx", slug = "phase-diagram")

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

[QAtlasHub/archeion-demo](https://github.com/QAtlasHub/archeion-demo) is a registry with one record
made this way.

## Before 0.4

Up to v0.3.3 Archeion was a different package: a registry with an SQLite index, a Node web app and
an FTPS deploy. 0.4 keeps none of it and is not compatible with it. Code that calls the 0.3 API
should pin `rev = "v0.3.3"`.
