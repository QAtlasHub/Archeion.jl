```@meta
CurrentModule = Archeion
```

# Publish a result

Two steps. The first happens once, when a record is born; the second happens every time you have
a new answer to the same question.

## Once — name the record

```julia
using Archeion

Archeion.new_binding(".registry/bindings/henon.toml";
                     root    = "../path/to/registry",
                     project = "247b870f-4313-4ae6-aa32-5d309fe806e1",
                     slug    = "henon-correlation-dimension")
```

This writes a **binding**, and the binding lives in the repository that *renders* your report —
not in the registry:

```toml
spec = "registry/2"
registry = "../path/to/registry"                   # relative to this file
project = "247b870f-4313-4ae6-aa32-5d309fe806e1"
record = "9c53a959-6d1e-44d4-8e7e-d24cd8d402c7"    # minted here, for you
slug = "henon-correlation-dimension"
kind = "report"
```

**Commit it.** It is the only thing that says which record your script writes to, and you will not
edit it again. `new_binding` refuses to overwrite an existing file, so copying a script cannot
silently make it continue somebody else's record.

!!! warning "The slug is not checked for collisions here"
    `new_binding` checks the slug's shape, not whether it is free. A name already used by another
    record of the same year is accepted here and refused at your first `deposit`:

    ```
    …/records/2026/henon-correlation-dimension exists: another record of this
    year is already called henon-correlation-dimension; give this one another slug
    ```

    Your registry is untouched, but you are left holding a committed binding that points at
    nothing. Delete it and make another. (It cannot be checked earlier: a record is filed under
    the year it is *frozen*, which is not known when the binding is written.)

## Every time — deposit

```julia
using Archeion, Pinax

# … build the document with @page / @section / @figure …

Pinax.render(; out = joinpath(OUT, "gallery"))
Pinax.render(; out = joinpath(OUT, "agent"), theme = :agent)

r = deposit(BINDING;
            gallery     = joinpath(OUT, "gallery"),
            agent       = joinpath(OUT, "agent"),
            source_repo = @__DIR__,
            doc         = Archeion.doc_fields(Pinax.current_document();
                                              tags = ["chaos", "dimension"]))
```

Two faces go in: the **gallery** a person reads and the **agent** view a program reads. Pinax
renders both from the same document.

What comes back names what happened:

```julia
r.record    # "9c53a959-6d1e-44d4-8e7e-d24cd8d402c7"
r.rev       # "20260924T130223Z-axz9"
r.parents   # the revision this one answers after
r.dir       # where it landed
r.commit    # the commit that added it
r.pushed    # whether it reached the remote
r.dirty     # whether the rendering repository had uncommitted changes
```

**The first revision and the tenth are the same call.** `deposit` looks up the binding's record
UUID in the registry and works out for itself whether it is creating the record or adding to it.
Parents default to the record's current head, so re-running your script links the new answer to
the one before it without being told.

If anything fails, the registry is left as it was found. There is no half-deposited state to clean
up and nothing to undo by hand.

## One call instead of two

With Pinax **and** DataVault loaded, [`publish`](@ref) is the whole path:

```julia
Archeion.publish(vault, recipe;
                 binding     = BINDING,
                 title       = "The correlation dimension of the Hénon attractor",
                 out         = OUT,
                 status      = :trial,
                 source_repo = @__DIR__,
                 remote      = :pr)
```

It syncs the registry with its remote, warns you if the commit that rendered the report has not
been pushed, renders both faces, deposits, and then — depending on `remote` — opens a pull
request (`:pr`), pushes to the branch (`:push`), or leaves the commit local (`:local`).

`status` is not optional here, and the two values mean different things to a reader: `:trial` is
an answer you are still arguing with, `:final` is one you are prepared to be held to.

## Publish the catalogue

```julia
Archeion.build("path/to/registry")   # -> _site/
```

`_site` is rebuilt from scratch every time and never committed. In practice you will rarely run
this by hand — `pages.yml` does it on every push.

## A worked example

The demonstration repository has both shapes:

  * [`scripts/build.jl`](https://github.com/QAtlasHub/archeion-demo/blob/master/scripts/build.jl)
    — Pinax and `deposit` directly
  * [`scripts/lorenz.jl`](https://github.com/QAtlasHub/archeion-demo/blob/master/scripts/lorenz.jl)
    — `publish` from a DataVault vault

with their bindings committed beside them, under
[`.registry/bindings/`](https://github.com/QAtlasHub/archeion-demo/tree/master/.registry/bindings).

## Then

Something was wrong with it? [Correct or withdraw a result](@ref Correct-or-withdraw-a-result).