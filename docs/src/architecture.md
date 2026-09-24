```@meta
CurrentModule = Archeion
```

# Architecture

[The format](@ref The-format) says *what* a registry is. This says *why* it is that, and what each
decision costs — the part that is otherwise legible only by reading the source.

## The format is not the implementation

`SPEC.md` is normative; Archeion.jl is one implementation of it. The split is load-bearing rather
than tidy: a registry has to outlive the tool that wrote it, so the tool must not be where the
rules live.

Concretely, `validate`, `build` and the index never invoke git, and nothing in the format requires
it — a registry read off a disk, over SSH, or out of a backup is the same registry. Only the
writers use git, and for the two things git is good at: making a deposit a commit, and making a
failed conversion undoable.

## Identity is inside the file; the path is a name

Every project and record carries a UUID in its own TOML, and its directory is named by a slug. So:

  * a record can be renamed without breaking anything that referred to it
  * two registries may use the same slug for different things
  * the index can be rebuilt from the tree, because identity travels with the content

The cost lands in one place. A **binding** names a record by UUID but a registry by *relative
path*, and bindings live in the repositories that render reports — which a registry cannot reach.
That is why [`migrate!`](@ref) returns its `ids` table instead of fixing bindings itself, and why
the unit of retirement has to be a whole registry rather than a record (`SPEC.md` §10).

## A revision is frozen, so withdrawal is an addition

Every file of a revision is covered by its `SHA256SUMS`, `entry.toml` included. A digest somebody
cited keeps meaning what it meant, and `validate` refuses a registry where one no longer matches.

That forbids editing, so everything that would have been an edit becomes an addition:

| | |
|---|---|
| correcting | a new revision, naming the old one as parent |
| withdrawing | a `yank` event |
| replacing out of line | a `supersede` event |

Which revision is *current* is then a computation over that history rather than a field somebody
sets (`SPEC.md` §7.1) — and it has three outcomes, including "in conflict", because two people
depositing from the same parent is a real state and resolving it by timestamp would be a guess.

## The index is derived, and committed anyway

`registry.toml`'s `[projects]` and `[records]` can be rebuilt by walking the tree. They are
committed regardless, because a reader resolving one UUID should not have to walk anything, and a
registry should be able to say what it holds without a tool.

Being derivable is what makes that cheap: a validator checks it against the tree, and a writer
that meets a conflict in it — it is the one file every deposit touches — regenerates it instead of
merging by hand. [`reindex!`](@ref) is that operation, and it is why two deposits can collide
without anybody having to resolve TOML.

## The site is derived, so the copy can carry what the original cannot

`build` rewrites `_site` from scratch every run, and it is never committed. That is not only
hygiene. Because the site is a copy, it can hold what a frozen revision may not: a report
published before this package had a dark mode gets a derived dark layer and a colour-scheme
control **in the site's copy**, while the revision stays byte-identical under its own checksums.
(Unless its stylesheet draws with a colour Archeion does not recognise: half a conversion is worse
than none, so that report keeps its light one and `build` reports how many there are.)

The general rule — anything a reader should get but a revision must not promise belongs in the
derived layer.

## Writers refuse; they do not repair

[`deposit`](@ref) and [`sync!`](@ref) demand a registry with no uncommitted content of its own,
because a half-written state is what the next deposit would build on. [`migrate!`](@ref) is
stricter — any uncommitted change at all — because its undo is `git checkout`. Beyond that:

  * [`deposit`](@ref) stages under `_incoming/` and writes `SHA256SUMS` last, so the presence of
    that file means the revision is complete; if the result does not validate, the revision is
    taken back out
  * [`migrate!`](@ref) settles everything knowable — identifiers, slugs, collisions among them,
    whether every project file and `record.toml` parses — before the first rename, and undoes the
    rest with git if the converted tree does not validate

The limit is worth knowing rather than discovering: the undo covers the checks, not git itself. A
`deposit` into a registry that is not a git repository fails at `git add`, *after* the revision
has been moved into place.

## Two faces, one document

A deposit takes a **gallery** — what a person reads — and an **agent** view, what a program reads,
both rendered from the same Pinax document. Neither is derived from the other and neither is the
authority: they are two renderings of one source, so a machine reader never has to parse HTML and
a human reader never has to read JSON.

## Only the standard library

Archeion depends on `Dates`, `Random`, `SHA`, `TOML` and `UUIDs`, and nothing else. Pinax and
DataVault are reached through package extensions, so `validate` and `build` run on a machine that
has neither — which is what makes a registry's CI cheap, and what keeps the library usable from a
server that will never render a figure.

[`publish`](@ref) exists only when both are loaded. That is the seam: the parts needing a plotting
stack are the parts that are optional.

## Where the reasoning lives

This page is a summary. The argument for any particular decision is in the source, beside the code
it constrains — the comments in `src/` run to some four hundred lines, written to be read.
