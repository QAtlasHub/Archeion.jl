#!/usr/bin/env bash
# Assemble the Lolipop upload tree into web/build/ (node-as-CGI layout), then deploy with:
#
#   cd infra/Archeion.jl
#   julia --project=. -e 'using Archeion; Archeion.deploy("web/build"; config="config/deploy.local.toml", delete=false)'
#
# delete=false is mandatory — the server keeps the Lolipop panel's Basic-auth .htaccess/.htpasswd
# (never staged here). Static assets sit at the docroot: /style.css and /figures/* (Apache serves
# them; the app links by those paths).
#
# Modes:
#   bash deploy/stage.sh                         # CODE/UI ONLY — index.php + cgi.js + style.css.
#                                                #   Does NOT touch the live DB (preserves live
#                                                #   importance/bookmarks/comments/tags/PARA). Fast.
#   ARCHEION_INCLUDE_DB=1 bash deploy/stage.sh   # + data/archeion.db + figures/  (OVERWRITES live
#                                                #   data — only for first deploy / full reset; an
#                                                #   incremental data update needs download→re-ingest
#                                                #   →upload to merge, not this raw overwrite).
#   ARCHEION_NODE_BIN=/path/to/node22 …          # + bin/node (first deploy / node upgrade only).
set -euo pipefail
cd "$(dirname "$0")/.."                       # -> web/

npm run bundle                                # src/*.js -> dist/cgi.js (self-contained)

rm -rf build && mkdir -p build/dist
cp deploy/lolipop/index.php build/index.php   # PHP front controller (spawns node per request)
cp dist/cgi.js              build/dist/cgi.js  # the bundled app
cp public/style.css         build/style.css   # served at /style.css
cp public/app.js            build/app.js      # progressive-enhancement client (served at /app.js)
cp public/compose-editor.js build/compose-editor.js  # CodeMirror 6 structure-note editor (served at /compose-editor.js)
cp public/inject.js         build/inject.js   # Archeion overlay injected into Pinax run pages
cp public/inject.css        build/inject.css
cp -r public/katex          build/katex       # self-hosted KaTeX css + woff2 fonts (served at /katex/*)

if [ "${ARCHEION_INCLUDE_DB:-}" = "1" ]; then
  mkdir -p build/data build/figures
  cp data/archeion.db   build/data/archeion.db
  cp data/figures/*.svg build/figures/ 2>/dev/null || true   # served at /figures/*
  echo "  + DB + figures (will OVERWRITE live data on deploy)"
fi

if [ -n "${ARCHEION_NODE_BIN:-}" ] && [ -f "${ARCHEION_NODE_BIN}" ]; then
  mkdir -p build/bin && cp "${ARCHEION_NODE_BIN}" build/bin/node && chmod +x build/bin/node
  echo "  + bundled node $("${ARCHEION_NODE_BIN}" --version 2>/dev/null) ($(du -h build/bin/node | cut -f1))"
fi

echo "staged -> web/build/ (deploy this dir; server keeps .htaccess/.htpasswd):"
find build -type f | sort
