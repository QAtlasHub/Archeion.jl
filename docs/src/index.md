```@meta
CurrentModule = Archeion
```

# Archeion

A registry of rendered research results: plain files in a git repository, one directory per
record, one frozen directory per revision, and nothing that has to be running for them to be read.

That last clause is the whole design. A result you can only open through a service is a result
that expires when the service does. Here a registry is a directory tree; a reader with `ls` and a
browser can follow it, and Archeion.jl is a convenience for *writing* one — not a precondition for
reading one.

```julia
using Archeion

Archeion.init("path/to/registry"; title = "The Registry")   # once: its directories and its config
Archeion.validate("path/to/registry")                       # (; errors, warnings, summary)
Archeion.build("path/to/registry")                          # a static site in _site/
```

The package depends on the standard library only. Rendering reports and reading measured data are
somebody else's job — [Pinax](https://github.com/QAtlasHub/Pinax.jl) and
[DataVault](https://github.com/QAtlasHub/DataVault.jl) — and Archeion learns about them only
through package extensions, so a registry builds on a machine that has neither.

## What a registry holds

Four kinds of thing, and they nest:

| | what it is | where it lives |
|---|---|---|
| **registry** | the whole tree, and `registry.toml` saying what it is | the repository root |
| **project** | a line of work several records belong to | `projects/<slug>.toml` |
| **record** | one question, asked once and answered repeatedly | `records/<year>/<slug>/` |
| **revision** | one frozen answer, with its own checksums | `records/<year>/<slug>/revisions/<stamp>-<tag>/` |

A **revision never changes.** Its `SHA256SUMS` covers every file in it, `entry.toml` included, so
a digest somebody cited stays true. A record grows by gaining revisions, never by editing one, and
a revision names its parents — so a record is a history rather than a series of replacements.

Identity is a UUID *inside* the files; the paths carry only slugs. That separation is what lets a
record be renamed without breaking what pointed at it, and it is why two registries may use the
same slug for different things without colliding.

The normative description is [the format](@ref The-format) — `SPEC.md`, `spec = "registry/2"`.
Anything on this page that contradicts it is wrong.

## Which registries are supported

Archeion reads and writes **`registry/2`**, and that is the only format it writes.

  * **`registry/2`** — current and stable. `init` creates one; `validate`, `build` and `deposit`
    all require one.
  * **`registry/1`** — read only far enough to convert it. [`migrate!`](@ref) converts in place:
    every identifier becomes a UUID and leaves the paths, each record moves to
    `records/<year>/<slug>/`, the index is generated. It is all-or-nothing — everything knowable
    in advance is settled before the first rename, and if the result fails to validate the
    conversion is undone. That undo is git's, which is why a registry under git must have nothing
    uncommitted before one starts; a tree not under git is told it has no undo rather than left
    half converted.
  * Anything else — `validate` refuses by name rather than guessing.

A registry states its own format, so a second `migrate!` says "this is already `registry/2`"
instead of making a mess.

## How to deploy: putting a result into a registry

The path has two halves that are easy to confuse, because one happens **once per record** and the
other happens **every time there is a new answer**.

### Once, when the registry is new

```julia
Archeion.init("path/to/registry"; title = "The Registry")
```

Then write the project file by hand. There is no `new_project`, deliberately: a project is a line
of work, and naming one should not happen by accident. `projects/<slug>.toml` needs four fields:

```toml
spec = "registry/2"
uuid = "247b870f-4313-4ae6-aa32-5d309fe806e1"   # julia -e 'using UUIDs; println(uuid4())'
name = "Chaotic attractors"
created = 2026-09-24T12:40:00Z
```

`validate` names every missing field at once, and when the index no longer matches the tree it
says so and tells you to run [`reindex!`](@ref). Then commit: every writer refuses to run against
a registry with uncommitted content of its own, because a half-written state is what the next
deposit would build on.

### Once, per record

```julia
Archeion.new_binding(".registry/bindings/henon.toml";
                     root = "path/to/registry",
                     project = "247b870f-…",
                     slug = "henon-correlation-dimension")
```

A **binding** lives in the repository that renders the report, not in the registry, and it is the
only thing that says which record a script writes to. It carries the registry's relative path, the
project UUID, a freshly minted record UUID, the slug and the kind. Commit it.

It is created once and reused forever — `new_binding` refuses to overwrite an existing file, so a
copied script cannot silently continue somebody else's record.

!!! warning "`new_binding` does not check that the slug is free"
    It checks the slug's *shape*, not its availability. A name already taken by another record of
    the same year is accepted here and refused at the first [`deposit`](@ref) — with a clear
    message, and with the registry left byte-for-byte untouched. What remains is a committed
    binding holding a record UUID that names nothing: delete it and make another. The check
    cannot move earlier as things stand, because a record is filed under the year it is *frozen*,
    which is not known when the binding is written.

### Every time, per revision

```julia
deposit(BINDING;
        gallery = …, agent = …,          # the two rendered faces
        source_repo = @__DIR__,
        doc = Archeion.doc_fields(Pinax.current_document()))
```

Nothing changes between the first revision and the tenth: same binding, same call. `deposit`
resolves the binding's record UUID against the registry and decides for itself whether it is
creating a record or adding to one. Parents default to the record's current head, so the history
links itself.

What it does, in order: re-validate the binding (it lives in another repository and is
hand-editable), check the registry is settled and valid, stage the whole revision under
`_incoming/`, write `SHA256SUMS` **last** so that its presence means the revision is complete,
move it into place, reindex, validate again, commit. A failure before the move discards the
staging directory; a failure after it removes the revision and rewrites the index. The registry is
never left half-written.

[`publish`](@ref) is the same thing with both ends attached, available when Pinax and DataVault
are loaded: it syncs the registry to its remote, warns if the rendering commit is not published
yet, renders both faces, deposits, then pushes a branch or opens a pull request.

### Then the site

```julia
Archeion.build("path/to/registry")   # -> _site/
```

`_site` is **derived**: rewritten on every run, never committed. Because it is a copy it can carry
what the revisions cannot — a report frozen before dark mode existed gets a derived dark layer and
a colour-scheme control in the site's copy, while the revision it came from stays byte-identical
under its own checksums. [`setup_pages`](@ref) writes the workflows that build and publish it.

## Reading a registry without any of this

Open `registry.toml`: it lists every project and record by UUID, with a path. Follow the path.
Each record's `record.toml` says what it is; each revision holds `README.md`, `entry.toml`,
`SHA256SUMS` and the rendered report. `sha256sum -c SHA256SUMS` checks a revision on any machine
with coreutils.

That is the promise the rest of this exists to keep.
