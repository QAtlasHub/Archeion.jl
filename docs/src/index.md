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

## Getting started

### If you are starting a new registry

```julia
using Archeion
Archeion.init("path/to/registry"; title = "The Registry")
```

That writes the directories and `registry.toml`, where `[site]` is what a reader meets first — the
banner's title, its tagline, its links, and the colour scheme they get before choosing one. Edit
it now rather than later; it is the only part of a registry that is about you.

Then add a project — a line of work that records belong to. Projects are written by hand on
purpose: naming one is a decision, not a side effect. `projects/<slug>.toml` wants four fields:

```toml
spec = "registry/2"
uuid = "247b870f-4313-4ae6-aa32-5d309fe806e1"   # julia -e 'using UUIDs; println(uuid4())'
name = "Chaotic attractors"
created = 2026-09-24T12:40:00Z
```

Run [`validate`](@ref) whenever you are unsure. It names everything that is wrong at once, and
when the index has fallen behind the tree it says which command fixes it.

### If you already have a `registry/1` registry

```julia
Archeion.migrate!("path/to/registry")
```

Commit everything first. The conversion is all-or-nothing: it either finishes and validates, or
it puts your tree back exactly as it was — and "putting it back" is git's job, which is why it
needs a clean working tree to start from. A registry that is not under git is told it has no undo
rather than being left half converted.

Nothing else is supported, and `validate` says so by name rather than guessing.

## Publishing a result

Two steps, and the first happens only once per record.

**Once — give the record a name.**

```julia
Archeion.new_binding(".registry/bindings/henon.toml";
                     root = "path/to/registry",
                     project = "247b870f-…",
                     slug = "henon-correlation-dimension")
```

The binding lives in the repository that *renders* the report, not in the registry, and it is the
one file that says which record your script writes to. Commit it. You will not touch it again.

!!! warning "The slug is not checked for collisions here"
    A name already used by another record of the same year is accepted by `new_binding` and
    refused at your first [`deposit`](@ref). The refusal is clear and your registry is left
    untouched, but you are left with a committed binding that points at nothing: delete it and
    make another. (It cannot be checked earlier — a record is filed under the year it is *frozen*,
    which is not known yet.)

**Every time — deposit the answer.**

```julia
deposit(BINDING;
        gallery = …, agent = …,                    # the two faces Pinax rendered
        source_repo = @__DIR__,
        doc = Archeion.doc_fields(Pinax.current_document()))
```

The first revision and the tenth are the same call. `deposit` works out for itself whether it is
creating the record or adding to it, and links the new revision to the one before. If anything
goes wrong it leaves the registry as it found it — there is no half-deposited state to clean up.

Both calls have a worked example in the demonstration repository:
[`scripts/build.jl`](https://github.com/QAtlasHub/archeion-demo/blob/master/scripts/build.jl)
renders with Pinax and deposits, and
[`scripts/lorenz.jl`](https://github.com/QAtlasHub/archeion-demo/blob/master/scripts/lorenz.jl)
goes through [`publish`](@ref) from a DataVault vault — which is the same path with both ends
attached: it syncs the registry, checks your rendering commit is pushed, renders, deposits, and
opens a pull request.

## Publishing the catalogue

```julia
Archeion.build("path/to/registry")   # -> _site/
```

`_site` is rebuilt from scratch every time and never committed. Because it is a copy, it can carry
things the frozen revisions cannot: a report you published before this package had a dark mode
gets one in the site's copy, while the revision itself stays byte-identical under its checksums.

[`setup_pages`](@ref) writes the GitHub Actions workflows that validate on every pull request and
publish the site on every push.

## Reading a registry without any of this

Open `registry.toml`: it lists every project and record by UUID, with a path. Follow the path.
Each record says what it is in `record.toml`; each revision holds its report, an `entry.toml`, a
`README.md` and a `SHA256SUMS`. `sha256sum -c SHA256SUMS` verifies one on any machine with
coreutils.

[The demonstration repository's tree](https://github.com/QAtlasHub/archeion-demo/tree/master/records/2026/logistic-map)
is the shortest way to check that this is true.
