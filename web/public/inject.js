// Archeion overlay, injected into a run's real Pinax page (NOT an iframe — the Pinax page IS the
// document). Two phases so there's no flash: (1) STRUCTURAL changes (sticky header with Home + Pinax's
// toolbar, per-figure download, foldable sections) run synchronously on DOMContentLoaded, before the
// first paint; (2) the DATA panel (project / importance / tags / runs / bookmark) + Discussion fill in
// after the /api fetch. Writes reuse Archeion's 204 endpoints. Record id from window.ARCHEION_RECORD.
"use strict";
async function archeionOverlay() {
  const id = window.ARCHEION_RECORD;
  if (!id || document.querySelector(".arx-header")) return; // no id, or already injected (idempotent)
  // section-only mode: the /show section-fold iframe loads "#…&only=1" → render JUST that section's
  // block (hide all siblings + chrome), so an embedded section shows only itself, not the whole page.
  if (/[#&]only=/.test(location.hash || "")) {
    const h = location.hash, ms = h.match(/arxsec=([^&]+)/), mf = h.match(/arxfig=([^&]+)/);
    let el = null;
    if (ms) { const t = decodeURIComponent(ms[1]); el = [...document.querySelectorAll("section.section")].find((s) => { const x = s.querySelector(":scope > h2"); return x && x.textContent.replace(/^[▾▸]\s*/, "").trim() === t; }); }
    else if (mf) { const fid = decodeURIComponent(mf[1]); el = [...document.querySelectorAll("figure")].find((f) => { const l = f.querySelector("img[alt], iframe[title]"); return l && (l.getAttribute("alt") || l.getAttribute("title")) === fid; }); }
    if (el) { document.body.classList.add("arx-only"); let node = el; while (node && node !== document.body) { for (const sib of node.parentElement.children) if (sib !== node && !sib.contains(el)) sib.style.display = "none"; node = node.parentElement; } }
    return;
  }
  const ridPath = encodeURIComponent(id).replace(/%2F/gi, "/"); // keep "/" literal in URLs
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  async function post(action, data) {
    const r = await fetch(action, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", "X-Requested-With": "fetch" },
      body: new URLSearchParams(data),
    });
    if (!r.ok && r.status !== 204) throw new Error("HTTP " + r.status);
  }
  const save = (action, data, undo) => post(action, data).catch((e) => { if (undo) undo(); alert("保存に失敗: " + e.message); });

  // ===== PHASE 1: structural (no network) — applied before the first paint, so no flash =====
  // sticky header: Pinax's own toolbar (#pinax-bar: ★only / export / clear) with Home lined up in it
  const header = document.createElement("div");
  header.className = "arx-header";
  document.body.insertBefore(header, document.body.firstChild);
  const pbar = document.getElementById("pinax-bar");
  if (pbar) header.appendChild(pbar);
  const home = document.createElement("a");
  home.className = "arx-home"; home.href = "/"; home.title = "Home";
  home.innerHTML = `<svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true"><path fill="currentColor" d="M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z"/></svg><span>Home</span>`;
  const hostbar = pbar || header;
  hostbar.insertBefore(home, hostbar.firstChild); // Home in line with ★only / export / clear

  // add-buttons appear ONLY when this page is iframed inside the composer (/compose) — NOT in the
  // /show section-fold iframe (same-origin, so we can read the parent's path).
  const embed = window.top !== window.self && (() => {
    try { return window.parent.location.pathname.startsWith("/compose"); } catch (_) { return false; }
  })();
  const emit = (code, btn, label) => {
    try { window.parent.postMessage({ type: "arx-embed", code }, location.origin); } catch (_) { /* ignore */ }
    if (btn) { btn.textContent = "✓ added"; setTimeout(() => { btn.textContent = label; }, 900); }
  };
  if (embed) {
    const add = document.createElement("button");
    add.type = "button"; add.className = "arx-addnote"; add.textContent = "➕ add page";
    add.addEventListener("click", () => emit("![[" + id + "]]", add, "➕ add page"));
    hostbar.insertBefore(add, hostbar.firstChild);
  }

  // per-figure: a theme-independent download + (compose mode) an "add figure" button. The figure id
  // is its <img alt> / <iframe title> — Pinax emits string(f.id) there, = the DB figure-id suffix.
  document.querySelectorAll("figure").forEach((fig) => {
    const dest = fig.querySelector("figcaption") || fig;
    const src = fig.querySelector("img[src], iframe[src]")?.getAttribute("src");
    if (src && !fig.querySelector("a[download]")) {
      const a = document.createElement("a");
      a.className = "arx-dl"; a.href = src; a.setAttribute("download", ""); a.textContent = "⤓ download";
      dest.appendChild(a);
    }
    if (embed) {
      const lab = fig.querySelector("img[alt], iframe[title]");
      const figid = lab && (lab.getAttribute("alt") || lab.getAttribute("title"));
      if (figid) {
        const b = document.createElement("button");
        b.type = "button"; b.className = "arx-addfig"; b.textContent = "➕ add figure";
        b.addEventListener("click", () => emit("![[" + id + ":" + figid + "]]", b, "➕ add figure"));
        dest.appendChild(b);
      }
    }
  });

  // each section: a fold caret + (compose mode) an "add section" button = its title + its figures
  document.querySelectorAll("section.section").forEach((sec) => {
    const h = sec.querySelector(":scope > h2");
    if (!h) return;
    const title = h.textContent.trim(); // capture before injecting caret/buttons
    const caret = document.createElement("button");
    caret.type = "button"; caret.className = "arx-caret"; caret.title = "fold section"; caret.textContent = "▾";
    caret.addEventListener("click", () => { caret.textContent = sec.classList.toggle("arx-collapsed") ? "▸" : "▾"; });
    h.insertBefore(caret, h.firstChild);
    if (embed) {
      const b = document.createElement("button");
      b.type = "button"; b.className = "arx-addsec"; b.textContent = "➕ add section";
      b.addEventListener("click", () => {
        const t = title.replace(/[[\]#]/g, "").trim() || "section"; // sanitize for the ![[record#title]] syntax
        emit("![[" + id + "#" + t + "]]", b, "➕ add section");
      });
      h.appendChild(b);
    }
  });

  // ===== PHASE 2: data (/api) — metaproperty panel (after the title) + Discussion =====
  let rec;
  try { rec = await (await fetch("/api/record/" + ridPath)).json(); } catch { return; }
  const admin = !!rec.admin; // members see read-only meta + bookmark + discussion; admins get curation

  const top = document.createElement("div");
  top.className = "arx-top";
  const star = (n, on) => `<button class="arx-star${on ? " on" : ""}" data-imp="${n}" title="importance ${n}">★</button>`;
  top.innerHTML =
    `<div class="arx-props">` +
    `<div class="arx-row"><span class="arx-k">project</span><span class="arx-v"><a href="/p/${encodeURIComponent(rec.project)}">${esc(rec.project)}</a></span></div>` +
    `<div class="arx-row"><span class="arx-k">date</span><span class="arx-v">${esc((rec.date || "").slice(0, 10))}</span></div>` +
    `<div class="arx-row"><span class="arx-k">importance</span><span class="arx-v arx-imp">${admin ? [1, 2, 3].map((n) => star(n, n <= rec.importance)).join("") : [1, 2, 3].map((n) => (n <= rec.importance ? "★" : "☆")).join("")}</span></div>` +
    `<div class="arx-row"><span class="arx-k">tags</span><span class="arx-v arx-tags"></span></div>` +
    (rec.runs && rec.runs.length ? `<div class="arx-row"><span class="arx-k">runs</span><span class="arx-v arx-runs">${rec.runs.map((r) => `<code>${esc(r.project)}/${esc(r.run)}</code>`).join(" ")}</span></div>` : "") +
    `<div class="arx-row"><span class="arx-k"></span><span class="arx-v"><button class="arx-bk${rec.bookmarked ? " on" : ""}">${rec.bookmarked ? "★ bookmarked" : "☆ bookmark"}</button>${admin ? ` <button class="arx-arch">${rec.archived ? "unarchive" : "archive"}</button>` : ""}</span></div>` +
    `</div>`;
  const h1 = document.body.querySelector("h1"); // the run title
  if (h1) h1.insertAdjacentElement("afterend", top);
  else document.body.insertBefore(top, header.nextSibling);

  // archived banner — clear visualization that this run is archived (toggled with the button below)
  const banner = document.createElement("div");
  banner.className = "arx-archived-banner";
  banner.textContent = "🗄 This run is archived — hidden from active lists (still in search / tags / the project's Archived section)";
  header.insertAdjacentElement("afterend", banner);
  const syncArch = () => { banner.hidden = !rec.archived; document.body.classList.toggle("arx-is-archived", !!rec.archived); };
  syncArch();

  const impWrap = top.querySelector(".arx-imp");
  const paintImp = (v) => impWrap.querySelectorAll(".arx-star").forEach((b) => b.classList.toggle("on", +b.dataset.imp <= v));
  impWrap.addEventListener("click", (e) => {
    const b = e.target.closest(".arx-star"); if (!b) return;
    const n = +b.dataset.imp; const v = rec.importance === n ? 0 : n;
    const prev = rec.importance; rec.importance = v; paintImp(v);
    save("/importance", { id, value: v }, () => { rec.importance = prev; paintImp(prev); });
  });

  const tagsWrap = top.querySelector(".arx-tags");
  const chip = (t) => {
    const s = document.createElement("span"); s.className = "arx-chip";
    s.innerHTML = `<a href="/?tag=${encodeURIComponent(t)}">#${esc(t)}</a><button title="remove">×</button>`;
    s.querySelector("button").onclick = () => { s.remove(); save("/tagdel", { id, tag: t }, () => tagsWrap.insertBefore(s, addForm)); };
    return s;
  };
  const addForm = document.createElement("form"); addForm.className = "arx-tagadd";
  addForm.innerHTML = `<input name="tag" placeholder="+ tag" autocomplete="off">`;
  addForm.onsubmit = (e) => {
    e.preventDefault();
    const inp = addForm.querySelector("input");
    const names = (inp.value || "").split(/[,\s]+/).map((t) => t.replace(/^#/, "").trim()).filter(Boolean);
    for (const n of names) if (!(rec.tags || []).includes(n)) { rec.tags.push(n); tagsWrap.insertBefore(chip(n), addForm); }
    inp.value = "";
    if (names.length) save("/tagadd", { id, tag: names.join(" ") });
  };
  if (admin) {
    (rec.tags || []).forEach((t) => tagsWrap.appendChild(chip(t)));
    tagsWrap.appendChild(addForm);
  } else { // read-only chips for members (no remove ×, no add form)
    tagsWrap.innerHTML = (rec.tags || []).map((t) => `<a class="arx-chip" href="/?tag=${encodeURIComponent(t)}">#${esc(t)}</a>`).join("") || '<span class="arx-empty">—</span>';
  }

  const bk = top.querySelector(".arx-bk");
  bk.onclick = () => {
    const on = !bk.classList.contains("on");
    bk.classList.toggle("on", on); bk.textContent = on ? "★ bookmarked" : "☆ bookmark";
    save("/bookmark", { kind: "record", id });
  };
  const arch = top.querySelector(".arx-arch");
  if (arch) arch.onclick = () => { rec.archived = !rec.archived; arch.textContent = rec.archived ? "unarchive" : "archive"; syncArch(); save("/archive", { id, archived: rec.archived ? 1 : 0 }); };

  const disc = document.createElement("section");
  disc.className = "arx-disc";
  const cList = (rec.comments || []).map((c) => `<div class="arx-comment" data-cid="${c.id}"><div class="arx-cmeta">${esc(c.author)} · ${esc((c.created_at || "").slice(0, 16))}</div><div class="arx-cbody">${c.body_html || esc(c.body_md || "")}</div></div>`).join("");
  disc.innerHTML = `<h2>Discussion</h2><div class="arx-comments">${cList || '<p class="arx-empty">No comments yet.</p>'}</div>` +
    `<form class="arx-cform"><textarea required placeholder="comment (markdown)…" rows="3"></textarea><button>comment</button></form>`;
  document.body.appendChild(disc);
  const commentsEl = disc.querySelector(".arx-comments");
  // append a server comment (DOM-built: author via textContent; body_html is our own rendered markdown)
  const appendComment = (c) => {
    commentsEl.querySelector(".arx-empty")?.remove();
    const d = document.createElement("div"); d.className = "arx-comment"; d.dataset.cid = String(c.id);
    const m = document.createElement("div"); m.className = "arx-cmeta"; m.textContent = `${c.author || "anon"} · ${(c.created_at || "").slice(0, 16)}`;
    const b = document.createElement("div"); b.className = "arx-cbody"; b.innerHTML = c.body_html || "";
    d.append(m, b); commentsEl.appendChild(d);
  };
  // LIVE poll: merge NEW comments (by id) + cache-bust re-rendered figures, WITHOUT touching the open
  // textarea — a half-typed comment survives every refresh (consistency via stable data-cid + timestamp).
  let lastRev = rec.updated_at, polling = false;
  async function poll() {
    if (polling || document.hidden) return; polling = true;
    try {
      const d = await (await fetch("/api/record/" + ridPath, { headers: { "X-Requested-With": "fetch" } })).json();
      if (d.updated_at && d.updated_at !== lastRev) { // figures re-rendered → cache-bust the imgs/iframes
        lastRev = d.updated_at;
        document.querySelectorAll("figure img[src], figure iframe[src]").forEach((el) => {
          const base = (el.getAttribute("src") || "").split("?")[0];
          if (base && !base.startsWith("data:")) el.setAttribute("src", `${base}?v=${encodeURIComponent(d.updated_at)}`);
        });
      }
      const have = new Set([...commentsEl.querySelectorAll("[data-cid]")].map((n) => n.dataset.cid));
      for (const c of (d.comments || [])) if (!have.has(String(c.id))) appendComment(c);
    } catch { /* transient */ } finally { polling = false; }
  }
  setInterval(poll, 4000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) poll(); });
  const cform = disc.querySelector(".arx-cform");
  cform.onsubmit = (e) => {
    e.preventDefault();
    const ta = cform.querySelector("textarea"); const body = (ta.value || "").trim(); if (!body) return;
    ta.value = ""; // the poll renders the saved comment by id (no optimistic dup); restore on failure
    save("/r/" + ridPath + "/comment", { body_md: body }, () => { ta.value = body; });
    setTimeout(poll, 200); // pull the just-saved comment in promptly
  };
  // deep link: a #arxfig=<figid> / #arxsec=<title> in the URL → scroll that figure/section to centre
  // + flash it (so an embed's link "opens centred on" its target, not just at the top of the page).
  const focusTarget = () => {
    const h = location.hash || "", mf = h.match(/arxfig=([^&]+)/), ms = h.match(/arxsec=([^&]+)/);
    let el = null;
    if (mf) {
      const fid = decodeURIComponent(mf[1]);
      el = [...document.querySelectorAll("figure")].find((f) => { const l = f.querySelector("img[alt], iframe[title]"); return l && (l.getAttribute("alt") || l.getAttribute("title")) === fid; });
    } else if (ms) {
      const t = decodeURIComponent(ms[1]);
      el = [...document.querySelectorAll("section.section")].find((s) => { const hh = s.querySelector(":scope > h2"); return hh && hh.textContent.replace(/^[▾▸]\s*/, "").trim() === t; });
    }
    if (el) {
      el.scrollIntoView({ behavior: "smooth", block: "center" });
      document.querySelectorAll(".arx-target").forEach((x) => x.classList.remove("arx-target"));
      el.classList.add("arx-target"); setTimeout(() => el.classList.remove("arx-target"), 2400);
    }
  };
  focusTarget();
  window.addEventListener("hashchange", focusTarget);
  console.log("[archeion] overlay ready:", id);
}
// Run on DOMContentLoaded — Pinax's app.js (registered earlier) builds #pinax-bar first; we then move
// it + apply the structural overlay synchronously, before paint (no flash). Idempotency guard above.
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", archeionOverlay);
else archeionOverlay();
