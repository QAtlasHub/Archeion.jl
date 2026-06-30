// Archeion page annotation layer — injected into every page file of a record's Pinax render. ALL
// comments are server-side (no localStorage "unsaved"), and every one carries its LOCATION so the panel
// below doubles as a traceable comment list:
//   • passage — select descriptive prose → ✎ → inline highlight + a panel entry (text-quote anchored)
//   • figure  — a ✎ on each figure (PDFs can't be selected) → a comment on that figure (its stable id)
//   • section — a ✎ on each section heading → a comment on that section
// Posts to /api/record/<id>/annotations (kind/page/target_id/anchor); the panel entry links back to its
// target. Mirrors the structure-note annotator but unified over the three location kinds.
"use strict";
(function () {
  const rid = window.ARCHEION_RECORD;
  if (!rid) return;
  if (window.top !== window.self) return;          // not the compose / section-fold iframe
  if (/[#&]only=/.test(location.hash || "")) return; // not section-only mode

  const page = window.ARCHEION_PAGE || "";
  const ridPath = encodeURIComponent(rid).replace(/%2F/gi, "/");
  const api = "/api/record/" + ridPath + "/annotations";

  const st = document.createElement("style");
  st.textContent = `
  mark.anno{background:#fff3a8;border-radius:2px;cursor:pointer}
  mark.anno.anno-flash{outline:2px solid #f0a500}
  .anno-flash{outline:2px solid #f0a500;outline-offset:2px;border-radius:3px}
  .anno-cmt{display:inline-flex;align-items:center;gap:3px;margin-left:8px;padding:2px 8px;border:1px solid #cfd8dc;background:#eceff1;color:#37474f;border-radius:6px;cursor:pointer;font:12px system-ui}
  .anno-cmt:hover{background:#cfd8dc}
  .arx-caret{border:none;background:none;cursor:pointer;font:13px system-ui;color:#7a8a99;margin-right:6px;padding:0;vertical-align:middle}
  section.section.arx-collapsed > *:not(h2){display:none}
  .anno-list{max-width:1180px;margin:28px auto;padding:0 16px;font:14px/1.55 system-ui,-apple-system,sans-serif}
  .anno-list h2{font-size:15px;border-top:1px solid #e3e3e3;padding-top:14px;color:#333}
  .anno-list .anno-count{color:#999;font-weight:400}
  .anno-item{border:1px solid #e6e6e6;border-radius:8px;padding:8px 10px;margin:8px 0;background:#fff;position:relative;cursor:pointer}
  .anno-loc{display:inline-block;font-size:11px;font-weight:600;color:#0a6;background:#e6f6ef;border-radius:4px;padding:1px 6px;margin-bottom:4px}
  .anno-loc.loc-figure{color:#0277bd;background:#e3f2fd}
  .anno-loc.loc-section{color:#6a1b9a;background:#f3e5f5}
  .anno-loc.loc-passage{color:#0a6;background:#e6f6ef}
  .anno-meta{color:#8a8a8a;font-size:12px}
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

  const SKIP = (el) =>
    el && el.closest && el.closest("nav,script,style,#pinax-bar,.arx-header,.arx-top,.arx-disc,.anno-list,.anno-form,.anno-add-btn,.anno-cmt,mark.anno,h1");
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const post = (data) =>
    fetch(api, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", "X-Requested-With": "fetch" }, body: new URLSearchParams(data) });

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

    // ── passage text-quote machinery (highlight in place) ──
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
      for (let i = segs.length - 1; i >= 0; i--) {
        const { node, s, e } = segs[i];
        const r = document.createRange(); r.setStart(node, s); r.setEnd(node, e);
        const m = document.createElement("mark"); m.className = "anno"; m.dataset.aid = String(aid);
        try { r.surroundContents(m); } catch { /* crosses a boundary */ }
      }
    };
    const highlightPassage = (a) => { if (!a.anchor || !a.anchor.exact) return false; const idx = buildIndex(); const r = locate(idx, a.anchor); if (r) wrap(idx, r[0], r[1], a.id); return !!r; };

    // ── target lookup (for scroll-to + matching) ──
    const figFor = (figid) => [...document.querySelectorAll("figure")].find((f) => { const l = f.querySelector("img[alt], iframe[title]"); return l && (l.getAttribute("alt") || l.getAttribute("title")) === figid; });
    const secFor = (anchor) => document.getElementById(anchor) || [...document.querySelectorAll("section.section")].find((s) => s.id === anchor);
    const flash = (el) => { if (!el) return; el.scrollIntoView({ behavior: "smooth", block: "center" }); el.classList.add("anno-flash"); setTimeout(() => el.classList.remove("anno-flash"), 1500); };
    const scrollToTarget = (a) => {
      if (a.target_kind === "figure") { const f = figFor(a.target_id); flash(f ? (f.querySelector("img,iframe") || f) : null); }
      else if (a.target_kind === "section") flash(secFor(a.target_id));
      else { const m = document.querySelector(`mark.anno[data-aid="${a.id}"]`); flash(m); }
    };
    const locLabel = (a) =>
      a.target_kind === "figure" ? "Figure · " + (a.target_id || "?")
      : a.target_kind === "section" ? "Section · " + (a.target_id || "?")
      : a.target_kind === "passage" ? "“" + ((a.anchor && a.anchor.exact) || "").slice(0, 60) + "”"
      : "Discussion";

    // ── one panel entry = one comment + its location (the traceable list) ──
    const addItem = (a) => {
      ensurePanel();
      const anchored = a.target_kind !== "passage" || highlightPassage(a);
      const d = document.createElement("div"); d.className = "anno-item"; d.dataset.aid = String(a.id);
      const loc = document.createElement("div"); loc.className = "anno-loc loc-" + a.target_kind; loc.textContent = locLabel(a);
      const meta = document.createElement("div"); meta.className = "anno-meta";
      meta.textContent = `${a.author || "anon"} · ${(a.created_at || "").slice(0, 16)}${a.target_kind === "passage" && !anchored ? " · (text moved)" : ""}`;
      const bdy = document.createElement("div"); bdy.className = "anno-body"; bdy.innerHTML = a.body_html || "";
      d.append(loc, meta, bdy);
      if (a.can_delete) {
        const del = document.createElement("button"); del.type = "button"; del.className = "anno-del"; del.textContent = "×"; del.title = "delete";
        del.onclick = (e) => {
          e.stopPropagation();
          fetch(api + "/del", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", "X-Requested-With": "fetch" }, body: new URLSearchParams({ aid: a.id }) }).catch(() => {});
          d.remove();
          document.querySelectorAll(`mark.anno[data-aid="${a.id}"]`).forEach((m) => m.replaceWith(document.createTextNode(m.textContent)));
          recount();
        };
        d.append(del);
      }
      d.onclick = (e) => { if (!e.target.classList.contains("anno-del")) scrollToTarget(a); };
      itemsEl.appendChild(d); recount();
    };
    const render = (a) => { if (seen.has(String(a.id))) return; seen.add(String(a.id)); addItem(a); };

    // ── a floating comment form anchored at a screen rect; onSave(text) ──
    let btn = null, form = null;
    const clearUI = () => { btn?.remove(); btn = null; form?.remove(); form = null; };
    document.addEventListener("mousedown", (e) => { if (form && !form.contains(e.target) && e.target !== btn) clearUI(); });
    const openForm = (rect, onSave) => {
      clearUI();
      form = document.createElement("div"); form.className = "anno-form";
      form.style.left = Math.min(rect.left, innerWidth - 320) + "px"; form.style.top = (rect.bottom + 6) + "px";
      form.innerHTML = `<textarea rows="3" placeholder="comment (markdown)…"></textarea><div class="anno-form-acts"><button type="button" class="anno-save">save</button><button type="button" class="anno-cancel">cancel</button></div>`;
      document.body.appendChild(form);
      form.querySelector("textarea").focus();
      form.querySelector(".anno-cancel").onclick = clearUI;
      form.querySelector(".anno-save").onclick = async () => {
        const txt = form.querySelector("textarea").value.trim(); if (!txt) return;
        await onSave(txt);
        clearUI();
      };
    };
    const submit = async (data) => { try { const r = await post(data); if (r.ok) render(await r.json()); } catch { /* ignore */ } };

    // passage: select prose → ✎ annotate
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
      btn.onclick = () => openForm(rect, (txt) => { getSelection().removeAllRanges(); return submit({ kind: "passage", page, exact, prefix, suffix, body_md: txt }); });
      document.body.appendChild(btn);
    });

    // figure: a ✎ on each figure card (figures are PDFs → no text selection)
    document.querySelectorAll("figure").forEach((fig) => {
      const lab = fig.querySelector("img[alt], iframe[title]");
      const figid = lab && (lab.getAttribute("alt") || lab.getAttribute("title"));
      if (!figid) return;
      const dest = fig.querySelector("figcaption") || fig;
      const b = document.createElement("button"); b.type = "button"; b.className = "anno-cmt"; b.textContent = "✎ comment";
      b.onclick = () => openForm(b.getBoundingClientRect(), (txt) => submit({ kind: "figure", page, target_id: figid, body_md: txt }));
      dest.appendChild(b);
    });

    // section: a PERSISTENT fold caret + a ✎ comment on each heading, keyed by the section's stable
    // anchor id so both the fold state (localStorage) and the comment survive navigation / re-renders.
    const foldKey = (anchor) => "arxfold:" + rid + ":" + page + ":" + anchor;
    document.querySelectorAll("section.section").forEach((sec) => {
      const h = sec.querySelector(":scope > h2");
      if (!h || h.querySelector(".arx-caret")) return; // need an h2; idempotent
      const anchor = sec.id || h.textContent.trim();
      let collapsed = false;
      try { collapsed = localStorage.getItem(foldKey(anchor)) === "1"; } catch { /* ignore */ }
      if (collapsed) sec.classList.add("arx-collapsed");           // restore folded-state on load
      const caret = document.createElement("button");
      caret.type = "button"; caret.className = "arx-caret"; caret.title = "fold section";
      caret.textContent = collapsed ? "▸" : "▾";
      caret.onclick = () => {
        const c = sec.classList.toggle("arx-collapsed");
        caret.textContent = c ? "▸" : "▾";
        try { c ? localStorage.setItem(foldKey(anchor), "1") : localStorage.removeItem(foldKey(anchor)); } catch { /* ignore */ }
      };
      h.insertBefore(caret, h.firstChild);
      const b = document.createElement("button"); b.type = "button"; b.className = "anno-cmt"; b.textContent = "✎";
      b.title = "comment on this section";
      b.onclick = () => openForm(b.getBoundingClientRect(), (txt) => submit({ kind: "section", page, target_id: anchor, body_md: txt }));
      h.appendChild(b);
    });

    async function load() {
      try {
        const d = await (await fetch(api + "?page=" + encodeURIComponent(page), { headers: { "X-Requested-With": "fetch" } })).json();
        for (const a of (d.annotations || [])) render(a);
      } catch { /* transient */ }
    }
    load();
    setInterval(() => { if (!document.hidden && !form) load(); }, 5000);

    // deep-link: /pages/<rec>/<page>.html#arxfig=<figid> (or #arxsec=<title>) → centre+flash the target,
    // so a figure link from the project gallery / a note lands ON the figure (not just the page top).
    const focusTarget = () => {
      const h = location.hash || "", mf = h.match(/arxfig=([^&]+)/), ms = h.match(/arxsec=([^&]+)/);
      let el = null;
      if (mf) { const fid = decodeURIComponent(mf[1]); el = figFor(fid); el = el ? (el.querySelector("img,iframe") || el) : null; }
      else if (ms) {
        const t = decodeURIComponent(ms[1]);
        let s = secFor(t) || [...document.querySelectorAll("section.section")].find((x) => { const hh = x.querySelector(":scope > h2"); return hh && hh.textContent.replace(/^[▾▸✎\s]*/, "").trim().startsWith(t); });
        el = s ? (s.querySelector(":scope > h2") || s) : null;
      }
      if (el) { el.scrollIntoView({ behavior: "smooth", block: "center" }); el.classList.add("anno-flash"); setTimeout(() => el.classList.remove("anno-flash"), 1800); }
    };
    focusTarget();
    window.addEventListener("hashchange", focusTarget);
    console.log("[archeion] annotation layer ready:", rid, page);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", run);
  else run();
})();
