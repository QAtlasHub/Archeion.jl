```@meta
CurrentModule = Archeion
```

# Create a registry

A registry is a git repository. This makes one, sets up the checks that keep it honest, and
publishes it as a site.

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

## 3. The CI

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

!!! warning "A private repository's Pages site is public"
    On every plan but Enterprise Cloud, GitHub Pages serves a site to anyone with the URL whether
    or not the repository is private. For a registry that must not be readable, do not publish it:

    ```julia
    Archeion.setup_pages("path/to/registry";
                         runner = "self-hosted",
                         site   = "/srv/registry-site")
    ```

    That writes `site.yml` instead of `pages.yml`. The site is rebuilt into that directory on the
    machine `runner` names, on every push, and read from there over SSH — through Tailscale, an
    SSH file browser, or any other way you already reach that filesystem. Nothing is published and
    no URL exists to leak.

    It is a real http origin rather than `file://`, which matters for anything in a report that a
    browser treats as cross-origin.

## 4. Commit

```console
$ git add -A && git commit -m "the registry"
```

This matters more than it looks. Every writer in Archeion refuses to run against a registry with
uncommitted content of its own, because a half-written state is what the next deposit would build
on. The habit costs nothing now and saves a confusing refusal later.

## Then

[Publish a result](@ref Publish-a-result) into it.