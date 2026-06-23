# Archeion.jl/web — the registry web app

Web app for the **Archeion** experiment registry — a private, searchable, annotatable view
over the experiments produced on **panza**. It lives **in this repo** (`Archeion.jl/web/`,
not a separate repository — consolidated to avoid repo overhead).

## Two halves, one data contract

| | role | stack | where |
| --- | --- | --- | --- |
| `Archeion.jl` (the parent, `..`) | render figures (Pinax) + provenance + **ingest → DB/figures** | Julia | panza (build time) |
| `Archeion.jl/web` (here) | **serve** the registry + write-back (memos/discussion/tags/status) | Node | panza daemon *or* Lolipop CGI |

They meet at: the SQLite DB (`db/schema.sql`) + the figures under `data/figures/`. Julia
writes; Node reads.

## Layout (role-separated)

```
src/        application source (transport-agnostic handler + daemon/CGI adapters, routes, views)
db/         database management — schema.sql, migrations (NOT the data; the .db lives in data/)
deploy/     deployment + the SELECTABLE deploy modes (see deploy/README.md)
public/     static frontend assets (css/js)
data/       (gitignored) ingested runtime data: archeion.db + figures/
bin/        (gitignored) auxiliary binaries (e.g. the vendored node for Lolipop CGI)
```

## Data model (RAG-portable)

`records.body_md` is clean, atomic, per-record Markdown — the **source of truth**, also
directly **embeddable for RAG later** (no restructuring; "port the DB as-is"). HTML is a
derived view. Tables: `records` (+ FTS5) / `links` (network/Zettelkasten) / `comments`
(memos/discussion). See `db/schema.sql`.

## Hosting: decided late, app is portable

The core handler (`src/app.js`) is transport-agnostic, so the *same* app runs as **P** (panza
daemon, via Cloudflare Tunnel + Access — data stays on panza, highest confidentiality) or
**L** (Lolipop node-as-CGI — always-up, ~99 ms cold start measured; data on Lolipop; needs an
unofficial glibc-2.17 Node 20 build). Pick at deploy time. See `deploy/README.md`.

## Status

P1 scaffolding: data contract (`db/schema.sql`) ✓, layout ✓. Next: `src/` read app (landing +
record page + FTS5 search) and the `Archeion.jl` ingest target (→ `data/`), then write-back,
then the selectable deploy.
