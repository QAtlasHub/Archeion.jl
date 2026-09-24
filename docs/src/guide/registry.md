```@meta
CurrentModule = Archeion
```

# Create a registry

A registry is a directory tree. Making one does not involve git, GitHub, or a server — those come
in later, and only if you want them, depending on how the registry will be read.

## 1. The tree

```julia
using Archeion
Archeion.init("path/to/registry"; title = "The Registry", tagline = "one question per record")
```

That writes `registry.toml`, empty `projects/` and `records/`, a `.gitignore` for the parts that
are derived, and — unless you pass `pages = false` — the workflows in step 3.

`registry.toml` is the one file that is about you rather than about the format. Its `[site]` block
is what a reader meets first:

```toml
[site]
title = "The Registry"
tagline = "one question per record"
footer = ""

# appearance = "dark"              # "system" (default) | "light" | "dark"

# [[site.links]]
# text = "The lab"
# url = "https://example.org"
```

Edit it now rather than later. Everything else in the file is generated.

## 2. A project

Records belong to projects, and projects are written by hand — naming a line of work is a
decision, not a side effect. Create `projects/<slug>.toml`:

```toml
spec = "registry/2"
uuid = "247b870f-4313-4ae6-aa32-5d309fe806e1"
name = "Chaotic attractors"
created = 2026-09-24T12:40:00Z
```

The UUID is yours to generate:

```console
$ julia -e 'using UUIDs; println(uuid4())'
```

Then bring the index up to date and check the result:

```julia
Archeion.reindex!("path/to/registry")
Archeion.validate("path/to/registry")     # -> ok: 0 record(s)
```

[`validate`](@ref) reports everything that is wrong at once, and when the index has fallen behind
the tree it names the command that fixes it. You will use it constantly; it is cheap and it never
writes.

## 3. How will it be read?

This is the decision that determines whether you need anything beyond the directory. Three
answers, and the registry itself is identical in all three:

| | what it needs | when |
|---|---|---|
| **you, on this machine** | nothing further | while the work is still yours |
| **people you can reach over SSH** | a machine that rebuilds the site into a directory | a private registry, read through Tailscale or an SSH file browser |
| **anyone with the URL** | a GitHub repository and Pages | a public registry |

The rest of this page is the third one, because it needs the most setup. For the second, skip to
[the private variant](@ref A-registry-that-must-not-be-published). For the first, there is nothing
to do: [`build`](@ref) writes `_site/`, every link in it is relative, and a browser opens it from
`file://`.

## 4. The CI (if it lives on GitHub)

[`setup_pages`](@ref) writes the workflows. `init` has already called it unless you asked it not
to, and you can call it again to refresh them after upgrading Archeion:

```julia
Archeion.setup_pages("path/to/registry")   # -> (; written, skipped)
```

| workflow | when | what it does |
|---|---|---|
| `validate.yml` | every pull request and push | runs `validate` and `build`, so a broken registry cannot merge |
| `pages.yml` | push to the default branch | builds the site and publishes it to GitHub Pages |
| `site.yml` | in place of `pages.yml`, when you pass `site` | builds into a directory on your own runner, to be read from there over SSH |

The Archeion version is pinned into the workflows — to the version that wrote them — and that is
the version `registry.toml`'s `implementation` field should name. Re-run `setup_pages` after an
upgrade so the two agree; `written` and `skipped` tell you which files it touched.

### A registry that must not be published

On every plan but Enterprise Cloud, GitHub Pages serves a site to anyone with the URL whether or
not the repository is private. So for a registry that must not be readable, do not publish it:

```julia
Archeion.setup_pages("path/to/registry";
                     runner = "self-hosted",
                     site   = "/srv/registry-site")
```

That writes `site.yml` instead of `pages.yml`. The site is rebuilt into that directory on the
machine `runner` names, on every push, and read from there over SSH — through Tailscale, an SSH
file browser, or any other way you already reach that filesystem. Nothing is published and no URL
exists to leak.

It is also a real http origin rather than `file://`, which matters for anything in a report that
a browser treats as cross-origin.

## 5. Where git comes in

Depositing is the one thing that needs it. [`deposit`](@ref) commits each revision as it lands, so
**the registry must be a git repository by the time you publish a result into it** — and so must
the repository that renders the report, because a revision cites the commit that produced it.

Measured, on a registry with no `.git` at all:

| | |
|---|---|
| `init`, `reindex!`, `validate`, `build` | all work |
| `deposit` | fails, at `git add`, after the revision is already on disk |

So `git init` before your first deposit, not after:

```console
$ git init && git add -A && git commit -m "the registry"
```

And keep committing. Every writer refuses to run against a registry with uncommitted content of
its own, because a half-written state is what the next deposit would build on.

## Then

[Publish a result](@ref Publish-a-result) into it.