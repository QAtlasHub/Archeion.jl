// Archeion — progressive enhancement. Intercept the write-forms and apply the change to the DOM
// IMMEDIATELY, then persist in the background (fetch). The UI never waits on the network, so it
// feels instant (desktop-app feel); if the write fails we undo the change and warn. We also stop
// re-reading the DB after a write — on Lolipop's NFS a fresh request can read a stale snapshot, so
// the optimistic update (we know what we wrote) is the source of truth. JS-off → plain forms work.
"use strict";
(() => {
  const WRITE = /\/(tagadd|tagdel|bookmark|importance|figimportance|archive|projectpara|ptagadd|ptagdel|todoadd|todotoggle|tododel)$|\/comment$/;
  const dataOf = (f) => Object.fromEntries(new FormData(f));
  // "#mps tpq, foo" → ["mps","tpq","foo"] — same forgiving split the server uses (app.js parseTags)
  const splitTags = (s) => (s || "").split(/[,\s]+/).map((t) => t.replace(/^#/, "").trim()).filter(Boolean);

  // fire-and-forget persist; runs undo() if it didn't land
  function save(action, data, undo) {
    fetch(action, {
      method: "POST",
      headers: { "X-Requested-With": "fetch" },
      body: new URLSearchParams(data),
    })
      .then((r) => { if (!r.ok && r.status !== 204) throw new Error("HTTP " + r.status); })
      .catch((err) => { if (undo) undo(); alert("保存に失敗しました: " + err.message); });
  }

  // a #tag chip identical to render.js tagEditor()
  function makeChip(recId, name) {
    const span = document.createElement("span");
    span.className = "chip";
    const a = document.createElement("a");
    a.href = "/?tag=" + encodeURIComponent(name);
    a.textContent = "#" + name;
    const form = document.createElement("form");
    form.method = "post";
    form.action = "/tagdel";
    form.innerHTML = '<input type="hidden" name="id"><input type="hidden" name="tag"><button title="remove">×</button>';
    form.querySelector('[name="id"]').value = recId;
    form.querySelector('[name="tag"]').value = name;
    span.append(a, form);
    return span;
  }
  const flash = (el) => { el.classList.add("saved"); setTimeout(() => el.classList.remove("saved"), 700); };

  // in-place navigation (used for search): fetch the page, swap ONLY <main> — no full-screen refresh.
  // Falls back to a real navigation on any error. The header/sidebar stay; event delegation keeps
  // the swapped-in forms working. History is pushed so back/forward re-fetch + swap.
  async function navSwap(url, push) {
    console.log("[archeion] navSwap →", url);
    let res, text;
    try { res = await fetch(url, { headers: { "X-Requested-With": "fetch" } }); text = await res.text(); }
    catch (e) { console.warn("[archeion] navSwap fetch failed → full nav", e); location.href = url; return; }
    const doc = new DOMParser().parseFromString(text, "text/html");
    const m = doc.querySelector("main"), cur = document.querySelector("main");
    if (!m || !cur) { console.warn("[archeion] navSwap no <main> → full nav", { fetched: !!m, current: !!cur }); location.href = url; return; }
    cur.replaceWith(m);
    const t = doc.querySelector("title"); if (t) document.title = t.textContent;
    window.scrollTo(0, 0);
    if (push) {
      // push ONE entry when you START searching (so Back returns to the page you were on), then
      // REPLACE on each refinement — searches don't pile up in the back-stack.
      const target = res.url || url;
      if (history.state && history.state.arxSearch) history.replaceState({ arxSearch: true }, "", target);
      else history.pushState({ arxSearch: true }, "", target);
    }
    console.log("[archeion] navSwap done");
  }

  // project-meta widgets (project tag chip + todo item) matching render.js renderProject()
  function makePChip(project, name) {
    const span = document.createElement("span");
    span.className = "ptag-chip";
    const a = document.createElement("a");
    a.href = "/?tag=" + encodeURIComponent(name);
    a.textContent = "#" + name;
    const form = document.createElement("form");
    form.method = "post"; form.action = "/ptagdel";
    form.innerHTML = '<input type="hidden" name="name"><input type="hidden" name="tag"><button title="remove">×</button>';
    form.querySelector('[name="name"]').value = project;
    form.querySelector('[name="tag"]').value = name;
    span.append(a, form);
    return span;
  }
  function makeTodo(body, id) {
    const div = document.createElement("div");
    div.className = "ptodo"; div.dataset.todo = id || "";
    div.innerHTML =
      '<form method="post" action="/todotoggle"><input type="hidden" name="id"><button class="tg" title="toggle">☐</button></form>' +
      '<span class="ptodo-body"></span>' +
      '<form method="post" action="/tododel"><input type="hidden" name="id"><button class="x" title="delete">×</button></form>';
    div.querySelectorAll('[name="id"]').forEach((i) => (i.value = id || ""));
    div.querySelector(".ptodo-body").textContent = body;
    return div;
  }

  document.addEventListener("submit", (e) => {
    const f = e.target;
    const action = f.getAttribute("action") || "";
    if (action === "/search") { // in-place search — fetch + swap <main>, no full-page refresh
      e.preventDefault();
      console.log("[archeion] search submit intercepted");
      navSwap("/search?" + new URLSearchParams(new FormData(f)).toString(), true);
      return;
    }
    if (!WRITE.test(action)) return; // leave anything else unknown to the browser
    e.preventDefault();

    if (action === "/tagadd") {
      const input = f.querySelector('[name="tag"]');
      const id = f.querySelector('[name="id"]').value;
      const names = splitTags(input.value);
      if (!names.length) return;
      const row = f.parentElement;
      const have = new Set([...row.querySelectorAll(".chip a")].map((a) => a.textContent));
      const added = [];
      for (const n of names) if (!have.has("#" + n)) { const c = makeChip(id, n); row.insertBefore(c, f); added.push(c); }
      input.value = ""; input.focus();
      save("/tagadd", { id, tag: names.join(" ") }, () => added.forEach((c) => c.remove()));
    } else if (action === "/tagdel") {
      const chip = f.closest(".chip"); const data = dataOf(f);
      const anchor = chip.nextSibling, parent = chip.parentElement;
      chip.remove();
      save("/tagdel", data, () => parent.insertBefore(chip, anchor));
    } else if (action === "/bookmark") {
      const b = f.querySelector("button"); const data = dataOf(f);
      const set = (on) => { b.classList.toggle("on", on); b.textContent = on ? "★" : "☆"; };
      const now = !b.classList.contains("on"); set(now);
      save("/bookmark", data, () => set(!now));
    } else if (action === "/archive") {
      const hidden = f.querySelector('[name="archived"]'), btn = f.querySelector("button");
      const h1 = document.querySelector("article h1"), data = dataOf(f); // capture before toggling
      const set = (archived) => {
        hidden.value = archived ? "0" : "1"; // value = what the NEXT click will request
        btn.textContent = archived ? "unarchive" : "archive";
        const badge = h1?.querySelector(".badge");
        if (archived && h1 && !badge) h1.insertAdjacentHTML("beforeend", ' <span class="badge">archived</span>');
        if (!archived && badge) badge.remove();
      };
      const willArchive = data.archived === "1";
      set(willArchive);
      save("/archive", data, () => set(!willArchive));
    } else if (action.endsWith("/comment")) {
      const ta = f.querySelector('[name="body_md"]'); const body = (ta.value || "").trim();
      if (!body) return;
      const data = dataOf(f);
      f.closest(".discussion")?.querySelector(".empty")?.remove();
      const div = document.createElement("div");
      div.className = "comment";
      div.innerHTML = '<div class="cmeta">you · now</div><div class="md"></div>';
      div.querySelector(".md").textContent = body; // canonical markdown copy appears on next load
      f.parentElement.insertBefore(div, f); ta.value = "";
      save(action, data, () => div.remove());
    } else if (action === "/ptagadd") {
      const input = f.querySelector('[name="tag"]'); const project = f.querySelector('[name="name"]').value;
      const names = splitTags(input.value);
      if (!names.length) return;
      const row = f.parentElement;
      const have = new Set([...row.querySelectorAll(".ptag-chip a")].map((a) => a.textContent));
      const added = [];
      for (const n of names) if (!have.has("#" + n)) { const c = makePChip(project, n); row.insertBefore(c, f); added.push(c); }
      input.value = ""; input.focus();
      save("/ptagadd", { name: project, tag: names.join(" ") }, () => added.forEach((c) => c.remove()));
    } else if (action === "/ptagdel") {
      const chip = f.closest(".ptag-chip"); const data = dataOf(f);
      const anchor = chip.nextSibling, parent = chip.parentElement;
      chip.remove();
      save("/ptagdel", data, () => parent.insertBefore(chip, anchor));
    } else if (action === "/todoadd") {
      const input = f.querySelector('[name="body"]'); const project = f.querySelector('[name="name"]').value;
      const bodyv = (input.value || "").trim(); if (!bodyv) return;
      const item = makeTodo(bodyv, ""); // server assigns the id; fill it in from the response
      f.parentElement.insertBefore(item, f); input.value = ""; input.focus();
      fetch("/todoadd", { method: "POST", headers: { "X-Requested-With": "fetch" }, body: new URLSearchParams({ name: project, body: bodyv }) })
        .then((r) => (r.ok ? r.json() : Promise.reject(new Error("HTTP " + r.status))))
        .then((d) => { if (d && d.id != null) { item.dataset.todo = d.id; item.querySelectorAll('[name="id"]').forEach((i) => (i.value = d.id)); } })
        .catch((err) => { item.remove(); alert("保存に失敗しました: " + err.message); });
    } else if (action === "/todotoggle") {
      const item = f.closest(".ptodo"); const data = dataOf(f); const btn = f.querySelector("button");
      const done = item.classList.toggle("done"); btn.textContent = done ? "☑" : "☐";
      save("/todotoggle", data, () => { const d = item.classList.toggle("done"); btn.textContent = d ? "☑" : "☐"; });
    } else if (action === "/tododel") {
      const item = f.closest(".ptodo"); const data = dataOf(f);
      const anchor = item.nextSibling, parent = item.parentElement;
      item.remove();
      save("/tododel", data, () => parent.insertBefore(item, anchor));
    } else {
      // importance / figimportance / projectpara: select already shows the new value; just persist
      flash(f);
      save(action, dataOf(f));
    }
  });

  // Desktop feel: importance / PARA selects save the instant you change them (no "set" click).
  // search-field selection persists across pages (server renders all-on; we restore the saved subset).
  const FIELDS_KEY = "arx-fields";
  const saveFields = (form) => {
    const all = [...form.querySelectorAll('input[name="fields"]')];
    const on = all.filter((c) => c.checked).map((c) => c.value);
    try {
      if (!on.length || on.length === all.length) localStorage.removeItem(FIELDS_KEY); // empty/full ⇒ default ALL
      else localStorage.setItem(FIELDS_KEY, JSON.stringify(on));
    } catch (_) { /* ignore */ }
  };
  const restoreFields = () => {
    let saved; try { saved = JSON.parse(localStorage.getItem(FIELDS_KEY) || "null"); } catch (_) { /* ignore */ }
    if (!Array.isArray(saved) || !saved.length) return; // nothing saved ⇒ leave server default (ALL)
    document.querySelectorAll('form[action="/search"] input[name="fields"]')
      .forEach((c) => { c.checked = saved.includes(c.value); });
  };
  restoreFields(); // defer ⇒ DOM ready; programmatic .checked fires no change, so no stray search

  document.addEventListener("change", (e) => {
    const el = e.target;
    // toggling a search-field checkbox: remember the selection, then re-run the search in place
    if (el.name === "fields" && el.form?.getAttribute("action") === "/search") { saveFields(el.form); el.form.requestSubmit(); return; }
    const action = el.tagName === "SELECT" ? el.form?.getAttribute("action") || "" : "";
    if (/\/(importance|figimportance|projectpara)$/.test(action)) el.form.requestSubmit();
  });

  // hamburger (top-left) → collapse/expand the sidebar, persisted across pages
  const applySidebar = () => document.body.classList.toggle("sidebar-collapsed", localStorage.getItem("arx-sidebar") === "collapsed");
  applySidebar();
  document.addEventListener("click", (e) => {
    if (!e.target.closest(".hamburger")) return;
    const c = document.body.classList.toggle("sidebar-collapsed");
    localStorage.setItem("arx-sidebar", c ? "collapsed" : "open");
  });

  // "Show 10 more" reveals the next batch of (server-sent, hidden) figures in place — no reload
  document.addEventListener("click", (e) => {
    const btn = e.target.closest(".showmore");
    if (!btn) return;
    e.preventDefault();
    const step = parseInt(btn.dataset.step || "10", 10) || 10;
    document.querySelectorAll(".figgrid .fig-hidden").forEach((el, i) => {
      if (i < step) { el.classList.remove("fig-hidden"); el.classList.add("fig-in"); }
    });
    if (!document.querySelector(".figgrid .fig-hidden")) btn.remove(); // nothing left → drop the button
  });

  // /notes "all notes" filter — hide non-matching cards in that section as you type (instant, no reload)
  document.addEventListener("input", (e) => {
    const inp = e.target.closest(".note-filter");
    if (!inp) return;
    const q = inp.value.trim().toLowerCase();
    const sec = inp.closest("section") || document;
    sec.querySelectorAll(".note").forEach((card) => {
      card.classList.toggle("note-hidden", !!q && !card.textContent.toLowerCase().includes(q));
    });
  });

  // a figure's embed code (![[id]]): inside the composer's refs iframe → add it to the open note;
  // otherwise (normal browsing) → copy to clipboard.
  const inComposerFrame = window.top !== window.self;
  document.addEventListener("click", (e) => {
    const b = e.target.closest(".embed-copy");
    if (!b) return;
    e.preventDefault();
    const code = "![[" + (b.dataset.embed || "") + "]]";
    if (inComposerFrame) {
      try { window.parent.postMessage({ type: "arx-embed", code }, location.origin); flash(b); } catch (_) { /* ignore */ }
    } else if (navigator.clipboard) {
      navigator.clipboard.writeText(code).then(() => flash(b)).catch(() => {});
    }
  });

  // copy an invite link (admin user list): the absolute URL (origin + the /invite/<token> path)
  document.addEventListener("click", (e) => {
    const b = e.target.closest(".copy-link");
    if (!b) return;
    e.preventDefault();
    const url = location.origin + (b.dataset.path || "");
    if (navigator.clipboard) navigator.clipboard.writeText(url).then(() => { const t = b.textContent; b.textContent = "✓ copied"; setTimeout(() => { b.textContent = t; }, 1000); }).catch(() => {});
  });

  // --- structure-note composer (only present on /compose) ---
  const cmp = document.querySelector(".cmp");
  if (cmp) {
    // the right pane shows EITHER refs (live-Archeion iframe; its ⧉/add buttons postMessage embeds)
    // OR preview (the CURRENT edits, no save). The header buttons (outside .cmp) switch it. Preview
    // POSTs the live form fields into the named iframe via a hidden form → reflects unsaved edits.
    const pForm = document.getElementById("cmp-preview-form");
    const mForm = document.getElementById("cmp-form");
    document.querySelector(".cmp-refs")?.addEventListener("click", () => { cmp.classList.add("refs-open", "show-refs"); cmp.classList.remove("show-preview"); });
    document.querySelector(".cmp-preview-btn")?.addEventListener("click", () => {
      cmp.classList.add("refs-open", "show-preview"); cmp.classList.remove("show-refs");
      if (pForm && mForm) { // copy live edits (title/body/meta) into the hidden form, then render
        for (const n of ["title", "body", "importance", "tags", "description"]) {
          const dst = pForm.querySelector(`[name="${n}"]`), src = mForm.querySelector(`[name="${n}"]`);
          if (dst && src) dst.value = src.value;
        }
        pForm.submit(); // → POST /api/note/preview into iframe[name=cmp-preview-frame]
      }
    });
    cmp.querySelector(".cmp-refs-close")?.addEventListener("click", () => cmp.classList.remove("refs-open"));
    // drag the splitter to resize refs ↔ editor. The splitter tracks the mouse exactly (--refs-w =
    // distance from the right edge to the cursor); rAF-throttled for smoothness; while dragging the
    // iframe's pointer-events are off (CSS) so it can't swallow mousemove (was the "one-way" feel).
    const splitter = cmp.querySelector(".cmp-splitter");
    if (splitter) {
      let dragging = false, raf = 0, x = 0;
      const apply = () => { raf = 0; const r = cmp.getBoundingClientRect(); cmp.style.setProperty("--refs-w", Math.min(Math.max(r.right - x, 280), r.width - 320) + "px"); };
      window.addEventListener("mousemove", (e) => { if (!dragging) return; x = e.clientX; if (!raf) raf = requestAnimationFrame(apply); });
      splitter.addEventListener("mousedown", (e) => { dragging = true; cmp.classList.add("dragging"); e.preventDefault(); });
      window.addEventListener("mouseup", () => { if (dragging) { dragging = false; cmp.classList.remove("dragging"); } });
    }
  }

  window.addEventListener("popstate", () => navSwap(location.href, false)); // back/forward → re-swap
  document.documentElement.classList.add("js"); // CSS then hides the now-redundant "set" buttons
  // /note/:id live: merge new comments (by data-cid) without clobbering the draft textarea
  (() => {
    const disc = document.querySelector(".nv-disc");
    if (!disc || !location.pathname.startsWith("/note/")) return;
    const id = location.pathname.slice("/note/".length);
    const list = disc.querySelector(".nv-comments");
    let busy = false;
    async function pollNote() {
      if (busy || document.hidden) return; busy = true;
      try {
        const d = await (await fetch("/api/note/" + encodeURIComponent(id), { headers: { "X-Requested-With": "fetch" } })).json();
        const have = new Set([...list.querySelectorAll("[data-cid]")].map((n) => n.dataset.cid));
        for (const c of (d.comments || [])) {
          if (have.has(String(c.id))) continue;
          list.querySelector(".empty")?.remove();
          const node = document.createElement("div"); node.className = "nv-comment"; node.dataset.cid = String(c.id);
          const m = document.createElement("div"); m.className = "nv-cmeta muted"; m.textContent = `${c.author || "anon"} · ${(c.created_at || "").slice(0, 16)}`;
          const b = document.createElement("div"); b.className = "md nv-cbody"; b.innerHTML = c.body_html || "";
          node.append(m, b); list.appendChild(node);
        }
      } catch { /* transient */ } finally { busy = false; }
    }
    setInterval(pollNote, 4000);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) pollNote(); });
  })();

  // ---- structure-note annotator (/show, pinned): select a passage → margin note; text-quote anchored ----
  (() => {
    const noteId = document.body.dataset.note;
    const article = document.querySelector(".present");
    if (!noteId || !article) return;
    const api = "/api/note/" + encodeURIComponent(noteId) + "/annotations";
    const seen = new Set();
    const panel = document.createElement("section");
    panel.className = "anno-list";
    panel.innerHTML = `<h2>Annotations <span class="muted anno-count">(0)</span></h2><div class="anno-items"></div>`;
    article.after(panel);
    const itemsEl = panel.querySelector(".anno-items");
    const recount = () => { panel.querySelector(".anno-count").textContent = `(${itemsEl.querySelectorAll(".anno-item").length})`; };

    // text-quote highlight: concat the article's text nodes, locate exact (disambiguated by prefix/suffix), wrap segments
    const buildIndex = () => {
      const nodes = []; let text = "";
      const w = document.createTreeWalker(article, NodeFilter.SHOW_TEXT);
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
      for (let i = segs.length - 1; i >= 0; i--) { // reverse so earlier nodes' offsets stay valid
        const { node, s, e } = segs[i];
        const r = document.createRange(); r.setStart(node, s); r.setEnd(node, e);
        const m = document.createElement("mark"); m.className = "anno"; m.dataset.aid = String(aid);
        try { r.surroundContents(m); } catch { /* crosses a boundary — skip */ }
      }
    };
    const highlight = (a) => { const idx = buildIndex(); const r = locate(idx, a.anchor || {}); if (r) wrap(idx, r[0], r[1], a.id); return !!r; };

    const addItem = (a, anchored) => {
      const d = document.createElement("div"); d.className = "anno-item"; d.dataset.aid = String(a.id);
      const meta = document.createElement("div"); meta.className = "anno-meta muted";
      meta.textContent = `${a.author || "anon"} · ${(a.created_at || "").slice(0, 16)}${anchored ? "" : " · (text moved)"}`;
      const quote = document.createElement("div"); quote.className = "anno-quote"; quote.textContent = "“" + (((a.anchor || {}).exact) || "").slice(0, 80) + "”";
      const body = document.createElement("div"); body.className = "md anno-body"; body.innerHTML = a.body_html || "";
      d.append(meta, quote, body);
      if (a.can_delete) {
        const del = document.createElement("button"); del.type = "button"; del.className = "anno-del"; del.textContent = "×"; del.title = "delete";
        del.onclick = () => { save(api + "/del", { aid: a.id }); d.remove(); document.querySelectorAll(`mark.anno[data-aid="${a.id}"]`).forEach((m) => m.replaceWith(document.createTextNode(m.textContent))); recount(); };
        d.append(del);
      }
      d.onclick = (e) => { if (e.target.classList.contains("anno-del")) return; const m = document.querySelector(`mark.anno[data-aid="${a.id}"]`); if (m) { m.scrollIntoView({ behavior: "smooth", block: "center" }); m.classList.add("anno-flash"); setTimeout(() => m.classList.remove("anno-flash"), 1500); } };
      itemsEl.appendChild(d); recount();
    };
    const render = (a) => { if (seen.has(String(a.id))) return; seen.add(String(a.id)); addItem(a, highlight(a)); };

    let btn = null, form = null;
    const clearUI = () => { btn?.remove(); btn = null; form?.remove(); form = null; };
    document.addEventListener("mousedown", (e) => { if (form && !form.contains(e.target) && e.target !== btn) clearUI(); });
    article.addEventListener("mouseup", () => {
      const sel = getSelection();
      if (!sel || sel.isCollapsed) return;
      const exact = sel.toString();
      if (!exact.trim() || exact.length > 600) return;
      const range = sel.getRangeAt(0);
      if (!article.contains(range.startContainer)) return;
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
          try {
            const res = await fetch(api, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", "X-Requested-With": "fetch" }, body: new URLSearchParams({ exact, prefix, suffix, body_md: bodyMd }) });
            if (res.ok) render(await res.json());
          } catch { /* ignore */ }
          clearUI(); getSelection().removeAllRanges();
        };
      };
      document.body.appendChild(btn);
    });

    async function load() {
      try { const d = await (await fetch(api, { headers: { "X-Requested-With": "fetch" } })).json(); for (const a of (d.annotations || [])) render(a); }
      catch { /* transient */ }
    }
    load();
    setInterval(() => { if (!document.hidden && !form) load(); }, 5000); // live-merge, but never while a draft form is open
  })();

  console.log("[archeion] app.js loaded (v41 — structure-note annotator on /show)");
})();
