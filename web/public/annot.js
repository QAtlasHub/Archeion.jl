// Archeion record-text annotator — injected into every page file of a record's Pinax render. Lets a
// reader select a passage of the DESCRIPTIVE TEXT (the "note" prose — section descriptions, intent/
// method/analysis — not just figures) and leave a margin note. The highlight is text-quote anchored
// ({exact,prefix,suffix}) so it survives re-renders; `page` scopes it to this file of a multi-page doc.
// Posts to /api/record/<id>/annotations?page=<file>. Mirrors the structure-note annotator (app.js /show).
"use strict";
(function () {
  const rid = window.ARCHEION_RECORD;
  if (!rid) return;
  if (window.top !== window.self) return;          // not in the compose / section-fold iframe
  if (/[#&]only=/.test(location.hash || "")) return; // not in section-only mode

  const page = window.ARCHEION_PAGE || "";
  const ridPath = encodeURIComponent(rid).replace(/%2F/gi, "/"); // keep "/" literal in the URL
  const api = "/api/record/" + ridPath + "/annotations";

  // the Pinax page doesn't load the app stylesheet → inject the annotator's own minimal CSS
  const st = document.createElement("style");
  st.textContent = `
  mark.anno{background:#fff3a8;border-radius:2px;cursor:pointer}
  mark.anno.anno-flash{outline:2px solid #f0a500}
  .anno-list{max-width:1180px;margin:28px auto;padding:0 16px;font:14px/1.55 system-ui,-apple-system,sans-serif}
  .anno-list h2{font-size:15px;border-top:1px solid #e3e3e3;padding-top:14px;color:#333}
  .anno-list .anno-count{color:#999;font-weight:400}
  .anno-item{border:1px solid #e6e6e6;border-radius:8px;padding:8px 10px;margin:8px 0;background:#fff;position:relative;cursor:pointer}
  .anno-meta{color:#8a8a8a;font-size:12px}
  .anno-quote{color:#555;font-style:italic;margin:3px 0}
  .anno-body{color:#111}
  .anno-body p{margin:.2em 0}
  .anno-del{position:absolute;top:5px;right:8px;border:none;background:none;color:#b00;cursor:pointer;font-size:16px;line-height:1}
  .anno-add-btn,.anno-form{position:fixed;z-index:99999}
  .anno-add-btn{padding:4px 10px;border:1px solid #0a7a5c;background:#0a7a5c;color:#fff;border-radius:6px;cursor:pointer;font:13px system-ui}
  .anno-form{background:#fff;border:1px solid #bbb;border-radius:8px;padding:8px;width:300px;box-shadow:0 6px 24px rgba(0,0,0,.18)}
  .anno-form textarea{width:100%;box-sizing:border-box;font:13px system-ui;resize:vertical}
  .anno-form-acts{display:flex;gap:6px;justify-content:flex-end;margin-top:6px}
  .anno-form-acts button{padding:3px 10px;border-radius:6px;border:1px solid #ccc;cursor:pointer}`;
  document.head.appendChild(st);

  // skip the overlay chrome / nav / our own UI when indexing/selecting text
  const SKIP = (el) =>
    el && el.closest && el.closest("nav,script,style,#pinax-bar,.arx-header,.arx-top,.arx-disc,.anno-list,.anno-form,.anno-add-btn,mark.anno,h1");

  const post = (url, data) =>
    fetch(url, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", "X-Requested-With": "fetch" },
      body: new URLSearchParams(data),
    });

  function run() {
    const root = document.body;
    const seen = new Set();
    let panel = null, itemsEl = null;
    const ensurePanel = () => {
      if (panel) return;
      panel = document.createElement("section");
      panel.className = "anno-list";
      panel.innerHTML = `<h2>Annotations <span class="anno-count">(0)</span></h2><div class="anno-items"></div>`;
      root.appendChild(panel);
      itemsEl = panel.querySelector(".anno-items");
    };
    const recount = () => { if (panel) panel.querySelector(".anno-count").textContent = `(${itemsEl.querySelectorAll(".anno-item").length})`; };

    // text-quote: concat the page's text nodes (minus chrome), locate exact disambiguated by prefix/suffix
    const buildIndex = () => {
      const nodes = []; let text = "";
      const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode: (n) => (n.nodeValue && n.nodeValue.trim() && !SKIP(n.parentElement)) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
      });
      let n; while ((n = w.nextNode())) { nodes.push({ node: n, start: text.length }); text += n.nodeValue; }
      return { text, nodes };
    };
    const locate = (idx, a) => {
      const t = idx.text; let from = 0, p;
      while ((p = t.indexOf(a.exact, from)) !== -1) {
        const pre = t.slice(Math.max(0, p - (a.prefix || "").length), p);
        const suf = t.slice(p + a.exact.length, p + a.exact.length + (a.suffix || "").length);
        if ((!a.prefix || pre.endsWith(a.prefix)) && (!a.suffix || suf.startsWith(a.suffix))) return [p, p + a.exact.length];
        from = p + 1;
      }
      const q = t.indexOf(a.exact); return q === -1 ? null : [q, q + a.exact.length];
    };
    const wrap = (idx, start, end, aid) => {
      const segs = [];
      for (const { node, start: ns } of idx.nodes) {
        const ne = ns + node.nodeValue.length;
        if (ne <= start || ns >= end) continue;
        segs.push({ node, s: Math.max(start, ns) - ns, e: Math.min(end, ne) - ns });
      }
      for (let i = segs.length - 1; i >= 0; i--) { // reverse so earlier offsets stay valid
        const { node, s, e } = segs[i];
        const r = document.createRange(); r.setStart(node, s); r.setEnd(node, e);
        const m = document.createElement("mark"); m.className = "anno"; m.dataset.aid = String(aid);
        try { r.surroundContents(m); } catch { /* crosses a boundary — skip */ }
      }
    };
    const highlight = (a) => { const idx = buildIndex(); const r = locate(idx, a.anchor || {}); if (r) wrap(idx, r[0], r[1], a.id); return !!r; };

    const addItem = (a, anchored) => {
      ensurePanel();
      const d = document.createElement("div"); d.className = "anno-item"; d.dataset.aid = String(a.id);
      const meta = document.createElement("div"); meta.className = "anno-meta";
      meta.textContent = `${a.author || "anon"} · ${(a.created_at || "").slice(0, 16)}${anchored ? "" : " · (text moved)"}`;
      const quote = document.createElement("div"); quote.className = "anno-quote"; quote.textContent = "“" + (((a.anchor || {}).exact) || "").slice(0, 80) + "”";
      const body = document.createElement("div"); body.className = "anno-body"; body.innerHTML = a.body_html || "";
      d.append(meta, quote, body);
      if (a.can_delete) {
        const del = document.createElement("button"); del.type = "button"; del.className = "anno-del"; del.textContent = "×"; del.title = "delete";
        del.onclick = (e) => {
          e.stopPropagation();
          post(api + "/del", { aid: a.id }).catch(() => {});
          d.remove();
          document.querySelectorAll(`mark.anno[data-aid="${a.id}"]`).forEach((m) => m.replaceWith(document.createTextNode(m.textContent)));
          recount();
        };
        d.append(del);
      }
      d.onclick = (e) => {
        if (e.target.classList.contains("anno-del")) return;
        const m = document.querySelector(`mark.anno[data-aid="${a.id}"]`);
        if (m) { m.scrollIntoView({ behavior: "smooth", block: "center" }); m.classList.add("anno-flash"); setTimeout(() => m.classList.remove("anno-flash"), 1500); }
      };
      itemsEl.appendChild(d); recount();
    };
    const render = (a) => { if (seen.has(String(a.id))) return; seen.add(String(a.id)); addItem(a, highlight(a)); };

    let btn = null, form = null;
    const clearUI = () => { btn?.remove(); btn = null; form?.remove(); form = null; };
    document.addEventListener("mousedown", (e) => { if (form && !form.contains(e.target) && e.target !== btn) clearUI(); });
    document.addEventListener("mouseup", () => {
      const sel = getSelection();
      if (!sel || sel.isCollapsed) return;
      const exact = sel.toString();
      if (!exact.trim() || exact.length > 600) return;
      const range = sel.getRangeAt(0);
      if (!root.contains(range.startContainer) || SKIP(range.startContainer.parentElement)) return;
      const idx = buildIndex();
      let g = -1; for (const { node, start } of idx.nodes) if (node === range.startContainer) { g = start + range.startOffset; break; }
      if (g < 0) return;
      const prefix = idx.text.slice(Math.max(0, g - 32), g), suffix = idx.text.slice(g + exact.length, g + exact.length + 32);
      const rect = range.getBoundingClientRect();
      clearUI();
      btn = document.createElement("button"); btn.type = "button"; btn.className = "anno-add-btn"; btn.textContent = "✎ annotate";
      btn.style.left = Math.min(rect.left, innerWidth - 130) + "px"; btn.style.top = (rect.bottom + 6) + "px";
      btn.onclick = () => {
        btn.remove(); btn = null;
        form = document.createElement("div"); form.className = "anno-form";
        form.style.left = Math.min(rect.left, innerWidth - 320) + "px"; form.style.top = (rect.bottom + 6) + "px";
        form.innerHTML = `<textarea rows="3" placeholder="annotation (markdown)…"></textarea><div class="anno-form-acts"><button type="button" class="anno-save">save</button><button type="button" class="anno-cancel">cancel</button></div>`;
        document.body.appendChild(form);
        form.querySelector("textarea").focus();
        form.querySelector(".anno-cancel").onclick = clearUI;
        form.querySelector(".anno-save").onclick = async () => {
          const bodyMd = form.querySelector("textarea").value.trim(); if (!bodyMd) return;
          try { const res = await post(api, { exact, prefix, suffix, page, body_md: bodyMd }); if (res.ok) render(await res.json()); } catch { /* ignore */ }
          clearUI(); getSelection().removeAllRanges();
        };
      };
      document.body.appendChild(btn);
    });

    async function load() {
      try {
        const d = await (await fetch(api + "?page=" + encodeURIComponent(page), { headers: { "X-Requested-With": "fetch" } })).json();
        for (const a of (d.annotations || [])) render(a);
      } catch { /* transient */ }
    }
    load();
    setInterval(() => { if (!document.hidden && !form) load(); }, 5000); // live-merge, never while a draft is open
    console.log("[archeion] annotator ready:", rid, page);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", run);
  else run();
})();
