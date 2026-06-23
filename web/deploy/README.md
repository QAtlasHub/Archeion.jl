# deploy — selectable build/deploy modes

Build/deploy is **modal**: you select *what* to deploy and *where*. The web app and the
static registry can be deployed independently or together — so a normal "update the figures"
run stays cheap, and "ship the whole web app" is one opt-in flag.

## Axes

**What** (selectable, combinable):
- `:figures` — the static figure galleries + cross-run index (the current `Archeion.deploy` path).
- `:db`      — ingest records → `web/data/archeion.db` (+ figures to `web/data/figures/`).
- `:webapp`  — the Node app itself (`web/src`, `web/public`, `web/bin/node`, the CGI shim).

**Where**:
- `P` — **panza**: local; `:db` writes the local SQLite, then restart the systemd daemon.
  Nothing is uploaded (the app reads local `data/`). Served via Cloudflare Tunnel + Access.
- `L` — **Lolipop**: FTPS-upload `:webapp` + `:db` (the ingested `archeion.db` + figures) +
  `bin/node` + the CGI shim. Node runs per-request (node-as-CGI).

## Intended interface (Julia side, to implement)

A single `Archeion.publish` with a target selection, e.g.:

```julia
Archeion.publish(outdirs;
    targets = [:figures],          # default: just the static figures (cheap, current behavior)
    where   = :lolipop,            # :lolipop (L) | :panza (P)
    config  = "config/deploy.local.toml")

# ship the whole web app + a fresh DB ingest to Lolipop:
Archeion.publish(outdirs; targets = [:db, :webapp, :figures], where = :lolipop)

# panza daemon: ingest locally + reload (no upload):
Archeion.publish(outdirs; targets = [:db], where = :panza)
```

`:figures` reuses the existing render+deploy. `:db`/`:webapp` are added when the ingest and
the read app land (P1). `where=:panza` skips FTPS (local + service reload); `where=:lolipop`
FTPS-mirrors the selected pieces (delete=false to preserve the panel `.htaccess`/`.htpasswd`).

## Per-target deploy bits live here

- `deploy/lolipop/` — node-as-CGI shim (PHP/CGI entry, `.htaccess`), FTPS layout.
- `deploy/panza/`  — systemd unit + cloudflared (Tunnel) + Access config.
