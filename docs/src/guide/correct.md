```@meta
CurrentModule = Archeion
```

# Correct or withdraw a result

Start with the part that surprises people:

!!! danger "A revision is never edited and never deleted"
    Once deposited, a revision's files are covered by its own `SHA256SUMS`. Changing one breaks a
    checksum somebody may already have cited, and `validate` will refuse the registry until you
    put it back. This is not a rail you can switch off — it is the only reason a digest in a paper
    keeps meaning what it meant.

So "editing" and "deleting" happen a different way: you **add** something that changes what the
record currently says.

| you want to | you do |
|---|---|
| fix a mistake, add data, redo the analysis | deposit a new revision |
| say an answer was wrong and should not be used | write a `yank` event |
| say one revision replaces another that is not its parent | write a `supersede` event |
| leave a remark on a record or a revision | write a `comment` event |
| remove a record entirely | see [below](@ref Removing-a-record) |

## Correcting: deposit again

The ordinary case needs nothing special. Re-run your script:

```julia
deposit(BINDING; gallery = …, agent = …, source_repo = @__DIR__, doc = …)
```

The new revision names the old one as its parent, and the record's **current** revision becomes
the new one. The old revision stays where it is, still readable, still checksummed — which is the
point. A reader who followed a link to it last year still lands on what they read.

## Withdrawing: a `yank` event

There is **no API for this**. Events are written by hand into the record's `events/` directory;
`deposit` only reads them, to work out which revision is current. The file name and the fields
are fixed by the format:

```
records/2026/henon-correlation-dimension/events/20260925T101500Z-loc-a7f3.toml
```

```toml
spec = "registry/2"
kind = "yank"
at = 2026-09-25T10:15:00Z
reason = "the scaling region was chosen after seeing the answer"

[subject]
record = "9c53a959-6d1e-44d4-8e7e-d24cd8d402c7"
rev = "20260924T130223Z-axz9"
```

The name is `<YYYYMMDDTHHMMSSZ>-<origin>-<key>.toml`; use `loc` as the origin for an event you
write yourself, and four random lowercase characters as the key. Required: `spec`, `kind`, `at`,
and `subject.record`, which must be *this* record's UUID. `subject.rev` narrows it to one
revision — leave it out to speak about the record as a whole.

Then check it:

```julia
Archeion.validate("path/to/registry")
```

`validate` checks the file name, the kind, and that `subject.rev` exists. A subject that does not
exist is a **warning**, not an error: an event may legitimately outlive what it talks about.

The four kinds `registry/2` knows are `comment`, `yank`, `supersede` and `capability.verified`.
An unknown kind is also a warning — a reader counts and shows it rather than dropping it — so a
later version of the format can add kinds without invalidating your registry.

### What a yank does to "current"

```
live   = revisions not named by a yank event
heads  = live revisions that are not a parent of another live revision,
         and are not superseded by a live revision
```

  * exactly one head → that is the current revision
  * **no heads** → the record is **withdrawn**. It stays in the registry and its history stays
    readable, but nothing is current
  * more than one head → the record is **in conflict**, and nothing is chosen by date. You resolve
    it with a `supersede` event, or with a new revision naming both heads as parents

That last case is the one to watch: it is what happens when two people deposit from the same
parent.

## Superseding

The same shape, with `kind = "supersede"`, and the subject is the revision being *replaced*:

```toml
spec = "registry/2"
kind = "supersede"
at = 2026-09-25T10:20:00Z

[subject]
record = "9c53a959-6d1e-44d4-8e7e-d24cd8d402c7"
rev = "20260922T060556Z-t8c9"
```

Use it when the replacement is not a descendant — a fresh analysis rather than a revision of the
old one. If the new revision *is* a child of the old, its `parents` already says so and no event
is needed.

## Events are also never edited

Changed your mind about a yank? Write another event. A record's history is the sequence of what
was said, not the last thing said.

## Removing a record

There is no supported way to remove a record, and that is deliberate: the point of depositing
something is that the link keeps working.

If you truly must — a record deposited into the wrong registry, or one containing something that
should never have been published — it is a git operation, not an Archeion one: delete the
directory, run [`reindex!`](@ref), run [`validate`](@ref), commit. Be clear about what you are
accepting:

  * anyone who cloned or forked the registry still has it
  * any link or digest that named it now points at nothing
  * if a later revision cited one of its revisions as a parent, the history has a hole, and
    `validate` will say so

A `yank` is almost always the honest answer instead. It says *this was here and should not be
used*, which is true; deletion says nothing at all.