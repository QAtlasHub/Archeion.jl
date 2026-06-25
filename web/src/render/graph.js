// The graph view: notes (primary) + the projects/records they connect to, as a force-directed map.
// The page is just a <canvas> + legend + the client (/graph.js, vanilla, no deps); the edges come
// from /api/graph (db.graphData), which reads the same [[mention]]/![[embed]] data as the per-note
// Related panel. Self-hosted under CSP default-src 'self' — nothing vendored.
import { layout } from "./layout.js";
import { ASSET_V } from "./util.js";

export function renderGraph({ projects = [], tags = [], user = "" } = {}) {
  const legend = `<div class="graph-legend">` +
    `<span class="gl gl-note">●</span> notes` +
    `<span class="gl gl-project">●</span> projects` +
    `<span class="gl gl-record">●</span> records` +
    `<span class="graph-hint">drag to pan · scroll to zoom · drag a node to move · click to open</span></div>`;
  const main = `<div class="graph-wrap"><canvas id="graph"></canvas>${legend}</div>` +
    `<script src="/graph.js?v=${ASSET_V}" defer></script>`;
  return layout("Graph", main, { projects, tags, user });
}
