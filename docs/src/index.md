```@meta
CurrentModule = Archeion
```

# Archeion

**Archeion is the registry manager for [Pinax](https://github.com/QAtlasHub/Pinax.jl).**

Pinax renders one study into a self-contained report. Archeion is where those reports go: a
registry that keeps them, keeps them findable, and keeps the old ones exactly as they were when
you published them.

A registry is a git repository of plain files — one directory per record, one frozen directory per
revision. Nothing has to be running for it to be read. A result you can only open through a
service is a result that expires when the service does; here, a reader with `ls` and a browser can
follow the whole thing, and Archeion is a convenience for *writing* it rather than a requirement
for reading it.

!!! tip "A demonstration repository"
    [**archeion-demo**](https://github.com/QAtlasHub/archeion-demo) is a small public registry,
    built by Archeion on every push. It is the quickest way to see what this produces.

    [The site it builds](https://qatlashub.github.io/archeion-demo/) — the page you land on is the
    catalogue; the
    [logistic map record](https://qatlashub.github.io/archeion-demo/records/2026/logistic-map/)
    is a record with a history behind it, and
    [its current revision](https://qatlashub.github.io/archeion-demo/records/2026/logistic-map/revisions/20260922T060556Z-t8c9/gallery/)
    is one frozen answer.

    Worth reading in the other order, though: the files first, then the site. The files are the
    registry; the site is made from them.

## What you get

| | |
|---|---|
| **a record** | one question you keep coming back to |
| **a revision** | one answer to it, frozen — checksummed, never edited, naming the answer it came after |
| **a catalogue** | a static site built from the tree, every link relative, readable over `file://` |

A record accumulates revisions instead of being overwritten, so "what did we think in September"
stays answerable. A revision is covered by its own `SHA256SUMS`, so a digest you cited in a paper
keeps meaning what it meant.

Names live in the paths, identity lives in the files: every record and project carries a UUID, and
the directory is named by a slug. That is why renaming a record breaks nothing, and why two
registries can use the same slug for different things.

The exact rules are in [the format](@ref The-format). You do not need them to use this — they are
there so that somebody who finds your registry in ten years does not need this package either.

## How to use it

The step-by-step is its own section, in the order you meet it:

| | |
|---|---|
| [Create a registry](@ref Create-a-registry) | the tree, a project, and the CI that keeps it honest |
| [Publish a result](@ref Publish-a-result) | bind a record once, then deposit a revision each time |
| [Correct or withdraw](@ref Correct-or-withdraw-a-result) | what to do when an answer was wrong — revisions are never edited |
| [Everything else](@ref Everything-else) | the command line, shared registries, migration, provenance |

In short: [`init`](@ref) once for the registry, [`new_binding`](@ref) once per record, and
[`deposit`](@ref) every time you have a new answer. The first revision and the tenth are the same
call.

## Reading a registry without any of this

Open `registry.toml`: it lists every project and record by UUID, with a path. Follow the path.
Each record says what it is in `record.toml`; each revision holds its report, an `entry.toml`, a
`README.md` and a `SHA256SUMS`. `sha256sum -c SHA256SUMS` verifies one on any machine with
coreutils.

[The demonstration repository's tree](https://github.com/QAtlasHub/archeion-demo/tree/master/records/2026/logistic-map)
is the shortest way to check that this is true.
