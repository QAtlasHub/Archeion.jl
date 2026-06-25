// Archeion graph view — a tiny force-directed layout on <canvas>, zero deps (CSP default-src 'self').
// Reads /api/graph ({nodes,edges}); nodes are typed note|project|record. Interactions: drag the
// background to pan, scroll to zoom (around the cursor), drag a node to reposition it, click a node
// to open its page. Physics is a lightweight repulsion + edge-spring + center-gravity sim that cools
// to rest; any interaction reheats it. O(n^2) per tick — fine for the few-hundred-node scale here.
(() => {
  const canvas = document.getElementById("graph");
  if (!canvas) return;
  const ctx = canvas.getContext("2d");
  const COLOR = { note: "#7048e8", project: "#0369a1", record: "#2b8a3e", unresolved: "#adb5bd" };
  const PINNED = "#e8590c"; // pinned (structure) notes pop
  const DPR = Math.min(2, window.devicePixelRatio || 1);

  let nodes = [], edges = [], byId = new Map();
  let W = 0, H = 0;
  let tx = 0, ty = 0, scale = 1;       // world→screen: sx = x*scale + tx
  let alpha = 1;                        // simulation temperature
  let drag = null, panning = null, moved = 0, hover = null;

  const colorOf = (n) => (n.type === "note" && n.pinned ? PINNED : (COLOR[n.type] || COLOR.unresolved));
  const radiusOf = (n) => (n.type === "project" ? 9 : n.type === "record" ? 6.5 : (n.pinned ? 7 : 5));
  const toWorld = (sx, sy) => ({ x: (sx - tx) / scale, y: (sy - ty) / scale });

  function resize() {
    W = canvas.clientWidth; H = canvas.clientHeight;
    canvas.width = Math.round(W * DPR); canvas.height = Math.round(H * DPR);
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
  }

  function reheat(a = 0.6) { if (alpha < a) alpha = a; }

  function tick() {
    if (alpha < 0.01) return;
    const grav = 0.025;
    for (let i = 0; i < nodes.length; i++) {
      const a = nodes[i];
      a.vx *= 0.9; a.vy *= 0.9;
      for (let j = i + 1; j < nodes.length; j++) {
        const b = nodes[j];
        let dx = a.x - b.x, dy = a.y - b.y, d2 = dx * dx + dy * dy || 0.01;
        const d = Math.sqrt(d2), f = (2400 * alpha) / d2, ux = dx / d, uy = dy / d;
        a.vx += ux * f; a.vy += uy * f; b.vx -= ux * f; b.vy -= uy * f;
      }
      a.vx += -a.x * grav * alpha; a.vy += -a.y * grav * alpha; // pull toward origin (0,0)
    }
    for (const e of edges) {
      const a = byId.get(e.source), b = byId.get(e.target);
      if (!a || !b) continue;
      let dx = b.x - a.x, dy = b.y - a.y, d = Math.sqrt(dx * dx + dy * dy) || 0.01;
      const rest = e.kind === "scope" || e.kind === "in" ? 70 : 95;
      const f = (d - rest) * 0.02 * alpha, ux = dx / d, uy = dy / d;
      a.vx += ux * f; a.vy += uy * f; b.vx -= ux * f; b.vy -= uy * f;
    }
    for (const n of nodes) { if (n === drag) continue; n.x += n.vx; n.y += n.vy; }
    alpha *= 0.985;
  }

  function draw() {
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    ctx.fillStyle = "#ffffff"; ctx.fillRect(0, 0, W, H);
    if (!nodes.length) {
      ctx.fillStyle = "#868e96"; ctx.font = "14px system-ui, sans-serif"; ctx.textAlign = "center";
      ctx.fillText("No links yet — add [[mentions]] / ![[embeds]] in your notes.", W / 2, H / 2);
      return;
    }
    // edges
    ctx.lineWidth = 1; ctx.strokeStyle = "rgba(120,120,130,0.28)";
    ctx.beginPath();
    for (const e of edges) {
      const a = byId.get(e.source), b = byId.get(e.target);
      if (!a || !b) continue;
      ctx.moveTo(a.x * scale + tx, a.y * scale + ty);
      ctx.lineTo(b.x * scale + tx, b.y * scale + ty);
    }
    ctx.stroke();
    // nodes
    const showLabels = scale >= 0.5;
    for (const n of nodes) {
      const sx = n.x * scale + tx, sy = n.y * scale + ty, r = radiusOf(n);
      ctx.beginPath(); ctx.arc(sx, sy, r, 0, Math.PI * 2);
      ctx.fillStyle = colorOf(n); ctx.fill();
      if (n === hover) { ctx.lineWidth = 2; ctx.strokeStyle = "#212529"; ctx.stroke(); }
    }
    // labels (over the dots so they read; halo for contrast over edges)
    if (showLabels || hover) {
      ctx.font = "11px system-ui, sans-serif"; ctx.textAlign = "left"; ctx.textBaseline = "middle";
      for (const n of nodes) {
        if (!showLabels && n !== hover && n.type !== "project") continue;
        const sx = n.x * scale + tx, sy = n.y * scale + ty, r = radiusOf(n);
        const label = n.label.length > 28 ? n.label.slice(0, 27) + "…" : n.label;
        const lx = sx + r + 4;
        ctx.lineWidth = 3; ctx.strokeStyle = "rgba(255,255,255,0.9)"; ctx.strokeText(label, lx, sy);
        ctx.fillStyle = n === hover ? "#212529" : "#495057"; ctx.fillText(label, lx, sy);
      }
    }
  }

  function frame() { tick(); draw(); requestAnimationFrame(frame); }

  function nodeAt(sx, sy) {
    for (let i = nodes.length - 1; i >= 0; i--) {
      const n = nodes[i], dx = sx - (n.x * scale + tx), dy = sy - (n.y * scale + ty);
      if (dx * dx + dy * dy <= (radiusOf(n) + 4) ** 2) return n;
    }
    return null;
  }
  const evpos = (e) => { const r = canvas.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };

  canvas.addEventListener("mousedown", (e) => {
    const p = evpos(e); moved = 0;
    const n = nodeAt(p.x, p.y);
    if (n) { drag = n; reheat(); } else { panning = { x: p.x, y: p.y, tx, ty }; }
  });
  window.addEventListener("mousemove", (e) => {
    const p = evpos(e);
    if (drag) { const w = toWorld(p.x, p.y); drag.x = w.x; drag.y = w.y; drag.vx = drag.vy = 0; moved += 1; reheat(0.3); }
    else if (panning) { tx = panning.tx + (p.x - panning.x); ty = panning.ty + (p.y - panning.y); moved += 1; }
    else { const h = nodeAt(p.x, p.y); if (h !== hover) { hover = h; canvas.style.cursor = h ? "pointer" : "grab"; } }
  });
  window.addEventListener("mouseup", () => {
    if (drag && moved < 4 && drag.ref) location.href = drag.ref; // a click (not a drag) → open the page
    drag = null; panning = null;
  });
  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    const p = evpos(e), f = e.deltaY < 0 ? 1.12 : 1 / 1.12, ns = Math.max(0.25, Math.min(4, scale * f));
    const k = ns / scale; tx = p.x - (p.x - tx) * k; ty = p.y - (p.y - ty) * k; scale = ns;
  }, { passive: false });
  window.addEventListener("resize", resize);

  fetch("/api/graph", { headers: { "X-Requested-With": "fetch" } })
    .then((r) => r.json())
    .then((g) => {
      nodes = (g.nodes || []).map((n, i) => {
        const ang = i * 2.399963, rad = 12 * Math.sqrt(i + 1); // phyllotaxis seed → no overlap, deterministic
        return { ...n, x: Math.cos(ang) * rad, y: Math.sin(ang) * rad, vx: 0, vy: 0 };
      });
      edges = g.edges || [];
      byId = new Map(nodes.map((n) => [n.id, n]));
      resize(); tx = W / 2; ty = H / 2; alpha = 1;
      canvas.style.cursor = "grab";
      requestAnimationFrame(frame);
    })
    .catch(() => { resize(); draw(); });
})();
