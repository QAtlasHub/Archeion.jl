```@meta
CurrentModule = Archeion
```

# Everything else

The rest of what Archeion does, in roughly the order you are likely to need it.

## From the shell, without writing Julia

Every routine operation has a command. This is what the CI workflows use, and usually what you
want from a terminal:

```console
$ julia --project=archeion-env -m Archeion validate .
$ julia --project=archeion-env -m Archeion build .
```

| command | what it does |
|---|---|
| `init [root]` | starts a registry — its directories, `registry.toml`, its workflows |
| `validate [root]` | prints the records and every warning and error |
| `build [root] [out]` | writes the site, by default to `<root>/_site` |
| `pages [root]` | writes the workflows that publish it, pinned to this version |
| `reindex [root]` | rewrites `registry.toml`'s index from the tree |
| `migrate [root]` | converts a `registry/1` tree, printing which identifier became which UUID |

The exit code is `0`, `1` for a registry with errors, and `2` for a usage problem — which is what
makes `validate` a CI gate with no wrapper around it.

## Checking a registry

```julia
r = Archeion.validate("path/to/registry")
r.errors      # a registry with any of these is not valid
r.warnings    # legal, but probably not what was meant
r.summary     # one line per record: revisions, events, which one is current
```

It never writes, so run it whenever you are unsure. If the index has fallen behind the tree —
after editing a project file by hand, say — it says so and names the fix:

```julia
Archeion.reindex!("path/to/registry")
```

[`reindex!`](@ref) regenerates `registry.toml`'s `[projects]` and `[records]` from the tree and
leaves the rest of the file alone. It is also how you settle a merge conflict in the index: take
either side, run it, and the answer is the tree's rather than a hand-merged guess.

## Working with a shared registry

Three things happen around a deposit once more than one person is depositing.

[`sync!`](@ref) brings your clone to its remote *before* anything is validated or written. A
deposit checks the state it is about to add to, so that state has to be the shared one. It refuses
a registry with uncommitted content of its own rather than fast-forwarding over your work.

[`check_source_published`](@ref) asks whether the commit that rendered the report is reachable
from its remote's default branch. If it is not, the revision will cite code nobody else can see.
That is a warning rather than a refusal: there are legitimate reasons to deposit before pushing.

[`rebase_onto_remote!`](@ref) handles the one file every deposit touches. Two deposits made at the
same time both write `registry.toml`, so they conflict there and nowhere else; this puts yours on
top of what arrived meanwhile and regenerates the index instead of asking you to merge it.

[`publish`](@ref) calls all three for you. You need them by name only when driving `deposit`
directly.

## Converting an old registry

```julia
Archeion.migrate!("path/to/registry")   # -> (; projects, records, summary, ids, at)
```

For `registry/1` trees. Commit first: the conversion is all-or-nothing, and the way it puts your
tree back is git's, so it needs a clean working tree to start from. A tree not under git is told
it has no undo rather than being left half converted.

`ids` is the part you cannot reconstruct afterwards — which old identifier became which UUID.
Bindings live in *other* repositories, so nothing here can update them for you, and you need that
table to do it yourself.

## Provenance

With DataVault loaded, a deposit can record where each point of data came from, not only which
code produced the report. [`write_provenance!`](@ref) and [`provenance_from`](@ref) are that path,
and [`publish`](@ref) uses them when it is given a vault.

`provenance.toml` is served with the site. The evidence behind it — the point tables, the source
snapshots under `repro/` — stays in the repository and is deliberately not copied into `_site`: a
table of 80,000 points is megabytes per revision, and a site that carried them would carry them
once for every revision ever deposited.

## The site's appearance

The catalogue and the reports in it are read as one thing, so they share a palette and one
colour-scheme control. `registry.toml` sets what a reader gets before choosing:

```toml
[site]
appearance = "dark"       # "system" (default) | "light" | "dark"
```

A reader's own choice is remembered in their browser and outranks it. Reports frozen before any of
this existed get a dark layer and the control in the *site's copy* — the revision itself is never
touched.

## Where the details are

Everything above has a docstring saying what each argument means, what comes back, and what it
refuses to do. [The API](@ref API) lists them grouped by when you need them.