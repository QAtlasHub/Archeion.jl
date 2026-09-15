# CLAUDE.md: Archeion.jl

**The experiment registry, the HUMAN confirmation loop** of the infra workflow (ParamIO →
DataVault → ParallelManager → Pinax → **Archeion**). Pinax renders two faces of a result; they
fan out to two loops: `agent.json` → an LLM reasons → the next sweep (steering); the **gallery →
Archeion → a human browses and confirms** (confirmation). Archeion is that human loop: rendered
results accumulate in it, each carrying the provenance needed to reproduce it.
See [`../CLAUDE.md`](../CLAUDE.md) for the whole workflow.

## The spine: the registry IS a directory tree

```
<root>/                            $ARCHEION_REGISTRY, or [archeion] root, or ~/registry
  index.html                       the catalogue, rebuilt from the tree
  pagefind/                        client-side full-text search (optional, no server)
  <project>/<source>/
    record.toml                    the ONLY file this package parses
    repro/                         commit, dirty flag, Project.toml, Manifest.toml, reproduce.sh
    index.html  assets/            the rendered result, exactly as it was built
    <anything else>                sidecars: notes, slides, an annotation store, a PDF
```

| verb | role |
| --- | --- |
| `deposit(dir; project, source, title/doc, srcdir, root)` | copy a built dir in + `capture_repro` + `write_record` + reindex |
| `read_records(root)` | every dir holding a `record.toml`, at any depth, newest first |
| `reindex(root; search)` | rebuild `index.html` (+ Pagefind) from the tree |
| `registry_root(; root, config)` | arg → `[archeion] root` → `ENV["ARCHEION_REGISTRY"]` → `~/registry` |
| `capture_repro(srcdir, dest; strict)` | env/code provenance (Pinax records *figure* provenance; this records *which commit*) |

Nothing on that path needs a server, which is the point: the catalogue is static HTML and the
search index is Pagefind, so the registry is readable straight off the machine that computed it.

## Optional layers, on top of the same tree

| layer | what it adds | entry point |
| --- | --- | --- |
| SQLite | FTS5 search, `body_md` (RAG-portable), record ↔ DataVault-run M:N, versions | `ingest(doc; db, …)` |
| `web/` (Node) | annotation write-back: memos, discussion, tags, status, a Zettelkasten note layer | `web/README.md` |
| deploy | push a built tree to a private host over FTPS; creds held by an in-memory agent | `deploy`, `publish`, `initialize` |

They read the same records. **None of them may become load-bearing for "can a human see this
result?"**: that path is `deposit` → the tree → a browser.

## Per-project config: the contract (this is how usage stays consistent)

**A project configures Archeion through the SAME `config.toml` that drives the compute stack, never
through anything in this (public) repo.** `[study] project_name` / `outdir` + `[datavault]` already
say *which* project and runs; an `[archeion]` section adds the registry bits:

```toml
[archeion]
root        = "/home/me/work/Vault/Registry"   # the registry tree (or set ARCHEION_REGISTRY)
category    = "Demonstration/Examples"         # PARA, used by the web app
tags        = ["chaos", "logistic"]
db          = "${ARCHEION_DB}"                 # optional: the SQLite layer
deploy      = "deploy.local.toml"              # optional: FTP target (gitignored)
```

```julia
Pinax.report(vault, recipe; title, out = "report")          # gallery + agent.json
Archeion.deposit("report"; project, source = "phase1", srcdir = ".",
                 doc = Pinax.current_document(), config = "config.toml")
```

- **This repo is config-free**: it ships the engine plus the `config/*.example.toml` templates. A
  project's `[archeion]` lives in the project (or gitignored locally); secrets go in env.
- **One registry root per machine, partitioned by `project`.** Do NOT split into per-project roots:
  that loses the cross-project "have we run this?" value. Same reasoning for `[archeion] db` when
  the SQLite layer is in use.

## Contracts that trip up callers (read this)

- **`Pinax.report` does NOT return the doc.** It returns `(; gallery, agent, n)`; the document comes
  from `Pinax.current_document()` after the render. A `doc=rep.doc` will `ErrorException`.
- **A deposit owns only what it wrote.** `.deposit.toml` lists the last deposit's files; a re-deposit
  prunes exactly the entries that this render no longer produces and touches nothing else. Never
  `rm -rf` a record directory: that is where the sidecars live.
- **An untitled record is refused.** `deposit` raises unless `title` (or `doc.meta.title`) is
  non-empty, because every card in the index is labelled by it and `Pinax.render` leaves it empty
  unless asked. This is a guard, not a nicety: an untitled record is indistinguishable in the
  catalogue, and `<title>Pinax gallery</title>` is what the browser tab shows.
- **A dirty tree is recorded, not hidden.** `git_dirty` reaches `record.toml` AND the index card
  (`@abc1234+dirty`), because a commit that does not describe the tree that ran is worse than no
  commit. `strict = true` refuses instead.
- **Heavy data is referenced, never copied.** `data_keys` holds DataVault keys; the raw arrays stay
  in the vault. A registry that copies data cannot be kept forever.
- **Content vs annotation split (SQLite layer).** Content (figures, provenance, `body_md`, runs) is
  ingest-owned and immutable; annotation (memos, comments, tags, status) is app-owned and mutable.
  **Re-ingest is idempotent and never touches annotations.**
- **`ingest` rewrites the pages it stores.** `_store_pages` clears its destination and injects
  `/inject.js` + `/annot.js` at absolute paths, so those pages only work under the Node app. That is
  why the SQLite layer has its own page store and does not write into the registry tree.
- **A `record` = one Pinax generation-source** (one rendered artifact), **M:N** to DataVault `runs`.
  It is NOT a DataVault run.

## Where to look for usage

- `README.md`: the tree, the quickstart, the optional layers.
- `test/test_registry.jl`: the deposit contract as executable claims (sidecar survival, pruning,
  refusals, provenance).
- `web/README.md`: the Node half, pages/routes, the note layer, deploy (daemon / CGI).
- `src/registry.jl` (tree) · `src/ingest.jl` (SQLite) · `web/db/schema.sql` (the Julia↔Node contract).

## Invariants when changing this package

- **The index is DERIVED from the tree.** `read_records` walks for `record.toml`; anything that
  needs a separate list of records has broken the property that another tool can drop a record in.
- **Only files a previous deposit wrote may be removed by a deposit.** If you add a path the deposit
  writes, it goes through the manifest, or a sidecar becomes collateral.
- **`record.toml` stays the only parsed file**, and stays readable by a human with `cat`. Fields are
  added with defaults so an older record still reads (see `read_record`).
- **The project key is the canonical `_slug(project)`**: the same slug the record id uses, because
  the viewer keys every project page off that string. A raw name would let a spelling drift split a
  project page and orphan its app-owned PARA filing.
- The SQLite schema is the **Julia↔Node contract**: evolve `web/db/schema.sql`, the Julia writer
  and the Node reader together. `body_md` stays clean and portable (RAG). Deploy stays portable
  (daemon ⇄ CGI); don't hardwire a host.
