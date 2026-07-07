# CLAUDE.md — Archeion.jl

**The experiment registry — the HUMAN confirmation loop** of the infra workflow (ParamIO →
DataVault → ParallelManager → Pinax → **Archeion**). Pinax renders two faces of a result; they fan
out to two loops: `agent.json` → an LLM reasons → the next sweep (steering); the **gallery →
Archeion → deploy → a human browses and confirms** (confirmation). Archeion *is* that human loop:
it accumulates Pinax-rendered artifacts into one searchable, annotatable store and serves them.
See [`../CLAUDE.md`](../CLAUDE.md) for the whole workflow.

## Two halves, one data contract — the seam

| half | role | stack | where |
| --- | --- | --- | --- |
| `Archeion.jl` (Julia) | **`ingest`** Pinax artifacts (figures + provenance + `body_md`) → DB/figures; `build_index`; `deploy` | Julia | panza (build time) |
| `Archeion.jl/web` (Node) | **serve** the registry + **write-back** (memos / discussion / tags / status / favorite) + a **Zettelkasten note layer** (notes · structure-note composer · advisor `/show` pages) | Node | panza daemon *or* Lolipop CGI |

They meet at the **SQLite DB (`web/db/schema.sql`) + figures under `data/figures/`** — Julia writes,
Node reads. Julia public API: `ingest`, `build_index`, `add_search`, `deploy`, `Record` /
`write_record`, `capture_repro`, `discover` / `records_from_outdirs` / `master_ledger`.

## Per-project config — the contract (this is how usage stays consistent)

**A project configures Archeion through the SAME `config.toml` that drives the compute stack — never
through anything in this (public) repo.** `[study] project_name` / `outdir` + `[datavault]` already
say *which* project and runs; an `[archeion]` section adds the registry bits:

```toml
[study]
project_name = "logistic"                # → the Archeion `project` (records are keyed project/source)
outdir       = "out"

[archeion]
db          = "${ARCHEION_DB}"           # the ONE shared registry DB (same path for every project)
content_dir = "data"                     # where ingest stores pages/figures
category    = "Demonstration/Examples"   # PARA
tags        = ["chaos", "logistic"]
deploy      = "deploy.local.toml"        # FTP target (gitignored; secret via ARCHEION_FTP_PASSWORD)
```

Usage is then **config-driven and identical across projects** — no kwargs to hand-wire, nothing to
port between projects:

```julia
rep = Pinax.report(vault, recipe; out)                          # gallery + agent.json
Archeion.ingest("config.toml"; doc=rep.doc, source="phase1")    # project / db / paths from the config
Archeion.deploy("config.toml")                                  # reads [archeion].deploy
```

Rules that keep this consistent:
- **This repo is config-free** — it ships only the engine + the `deploy.example.toml` /
  `archeion.example.toml` templates. A project's `[archeion]` lives in the **project** (or gitignored
  locally); secrets go in env. Nothing project-specific is ever committed here.
- **`deploy`'s `config` auto-discovers when omitted** (`Archeion.deploy(site)`, no `config=`):
  explicit arg → `deploy.local.toml` in the CWD → `ENV["ARCHEION_DEPLOY"]` → the machine-global
  default `~/.archeion/deploy.toml` (`$ARCHEION_HOME/deploy.toml` if set) — see
  `_resolve_deploy_config` in `src/deploy.jl`. One 0600 file outside every repo can then drive
  deploy for **every** project on a machine: no per-project `deploy.local.toml`, no password
  prompt. A discovered machine-global config that isn't ~0600 gets a `@warn` (never a hard
  error) — perms, not encryption, are what keep it out of reach of anything but the owning user.
- **One shared registry, partitioned by `project`** (records are `project/source`). Do NOT split into
  per-project DB files — that fragments the registry and loses the cross-project "have we run this?"
  value (the LLM-loop memory). Point `[archeion] db` at the same shared DB everywhere (an `ARCHEION_DB`
  env var); use a separate db only when isolation is a hard requirement.
- The **config-driven `ingest(config; doc, …)` / `deploy(config)`** are thin wrappers over the existing
  kwarg `ingest(doc; db, project, source, …)` — they read `[study]`+`[archeion]` and fill the kwargs.
  (To add once the web-writeback `ingest` refactor settles, so they wrap the final signature.)

## The two faces again — inside the registry (human vs LLM)

The same human↔LLM duality runs through Archeion:
- **Human → the web app** (Node): browse, FTS5 search, pin / favorite / importance, memos &
  discussion, tags / status, PARA & Zettelkasten **notes** (markdown with `[[record]]` mentions +
  `![[figure]]` embeds; **pin** one → a curated advisor page at `/show/:id`). Where a human
  **confirms** a result; `deploy` closes the loop.
- **LLM → `body_md`** (RAG-portable, the source of truth): clean per-record Markdown, directly
  embeddable — so the registry doubles as the LLM loop's **memory** ("have we swept this before?"
  across all past runs).

## Contracts that trip up callers — read this

- **Content vs annotation split.** Content (figures, provenance, `body_md`, the runs it used) is
  **immutable, ingest-owned**; annotation (memos, comments, tags, status, favorite, **notes**) is
  **mutable, app-owned**. **Re-ingest is idempotent and never touches annotations** — that split is
  what makes re-running ingest safe.
- **A `record` = one Pinax generation-source** (the parent render → one rendered artifact), **M:N**
  to DataVault `runs` (a record may compare/render 1+ runs). It is NOT a DataVault run.
- **`body_md` is RAG-portable** — keep it clean per-record Markdown ("port the DB as-is"); the HTML
  is derived, the Markdown is the source of truth.
- Julia writes the DB + figures; Node only reads them (and writes its own annotation tables). Don't
  cross the contract.

## Where to look for usage

- `web/README.md` — the two-halves split, the data contract, **the pages/routes + the note layer**, deploy (panza daemon / Lolipop CGI).
- `notes/DB/DESIGN.md` (gitignored) — schema rationale (record/runs M:N, content/annotation, FTS).
- `src/ingest.jl` / `src/deploy.jl` — the ingest + deploy seams; `web/db/schema.sql` — the contract.

## Invariants when changing this package

- **One shared DB + one content folder** → cross-project search / aggregation; re-ingest must stay
  idempotent and **preserve all annotations**.
- **The project key is the canonical `slug(project)`** — ingest normalizes `records.project` /
  `projects.name` to the SAME slug as `records.id`, because the viewer keys every project page /
  sidebar / PARA filing off that string. Storing a raw name would let a spelling drift ("Logistic" vs
  "logistic") split a project page and **orphan its app-owned PARA filing**. Never store a raw project
  name; the viewer only ever sees slugs.
- The SQLite schema is the **Julia↔Node contract** — evolve `web/db/schema.sql`, the Julia writer,
  and the Node reader **together**.
- `body_md` stays clean and portable (RAG). Deploy stays portable (daemon ⇄ CGI); don't hardwire a host.
