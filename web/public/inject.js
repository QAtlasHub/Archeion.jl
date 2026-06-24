// Archeion overlay, injected into a run's real Pinax page (NOT an iframe — the Pinax page IS the
// document). Two phases so there's no flash: (1) STRUCTURAL changes (sticky header with Home + Pinax's
// toolbar, per-figure download, foldable sections) run synchronously on DOMContentLoaded, before the
// first paint; (2) the DATA panel (project / importance / tags / runs / bookmark) + Discussion fill in
// after the /api fetch. Writes reuse Archeion's 204 endpoints. Record id from window.ARCHEION_RECORD.
"use strict";
async function archeionOverlay() {
  const id = window.ARCHEION_RECORD;
  if (!id || document.querySelector(".arx-header")) return; // no id, or already injected (idempotent)
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

  // per-figure download, theme-independent (any <figure> the theme didn't already give one)
  document.querySelectorAll("figure").forEach((fig) => {
    if (fig.querySelector("a[download]")) return;
    const src = fig.querySelector("img[src], iframe[src]")?.getAttribute("src");
    if (!src) return;
    const a = document.createElement("a");
    a.className = "arx-dl"; a.href = src; a.setAttribute("download", ""); a.textContent = "⤓ download";
    (fig.querySelector("figcaption") || fig).appendChild(a);
  });

  // section folding via a dedicated caret (so Pinax's own section comment/star don't fold)
  document.querySelectorAll("section.section > h2").forEach((h) => {
    const caret = document.createElement("button");
    caret.type = "button"; caret.className = "arx-caret"; caret.title = "fold section"; caret.textContent = "▾";
    caret.addEventListener("click", () => { caret.textContent = h.parentElement.classList.toggle("arx-collapsed") ? "▸" : "▾"; });
    h.insertBefore(caret, h.firstChild);
  });

  // ===== PHASE 2: data (/api) — metaproperty panel (after the title) + Discussion =====
  let rec;
  try { rec = await (await fetch("/api/record/" + ridPath)).json(); } catch { return; }

  const top = document.createElement("div");
  top.className = "arx-top";
  const star = (n, on) => `<button class="arx-star${on ? " on" : ""}" data-imp="${n}" title="importance ${n}">★</button>`;
  top.innerHTML =
    `<div class="arx-props">` +
    `<div class="arx-row"><span class="arx-k">project</span><span class="arx-v"><a href="/p/${encodeURIComponent(rec.project)}">${esc(rec.project)}</a></span></div>` +
    `<div class="arx-row"><span class="arx-k">date</span><span class="arx-v">${esc((rec.date || "").slice(0, 10))}</span></div>` +
    `<div class="arx-row"><span class="arx-k">importance</span><span class="arx-v arx-imp">${[1, 2, 3].map((n) => star(n, n <= rec.importance)).join("")}</span></div>` +
    `<div class="arx-row"><span class="arx-k">tags</span><span class="arx-v arx-tags"></span></div>` +
    (rec.runs && rec.runs.length ? `<div class="arx-row"><span class="arx-k">runs</span><span class="arx-v arx-runs">${rec.runs.map((r) => `<code>${esc(r.project)}/${esc(r.run)}</code>`).join(" ")}</span></div>` : "") +
    `<div class="arx-row"><span class="arx-k"></span><span class="arx-v"><button class="arx-bk${rec.bookmarked ? " on" : ""}">${rec.bookmarked ? "★ bookmarked" : "☆ bookmark"}</button> <button class="arx-arch">${rec.archived ? "unarchive" : "archive"}</button></span></div>` +
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
  (rec.tags || []).forEach((t) => tagsWrap.appendChild(chip(t)));
  tagsWrap.appendChild(addForm);

  const bk = top.querySelector(".arx-bk");
  bk.onclick = () => {
    const on = !bk.classList.contains("on");
    bk.classList.toggle("on", on); bk.textContent = on ? "★ bookmarked" : "☆ bookmark";
    save("/bookmark", { kind: "record", id });
  };
  const arch = top.querySelector(".arx-arch");
  arch.onclick = () => { rec.archived = !rec.archived; arch.textContent = rec.archived ? "unarchive" : "archive"; syncArch(); save("/archive", { id, archived: rec.archived ? 1 : 0 }); };

  const disc = document.createElement("section");
  disc.className = "arx-disc";
  const cList = (rec.comments || []).map((c) => `<div class="arx-comment"><div class="arx-cmeta">${esc(c.author)} · ${esc((c.created_at || "").slice(0, 16))}</div><div class="arx-cbody">${c.body_html || esc(c.body_md || "")}</div></div>`).join("");
  disc.innerHTML = `<h2>Discussion</h2><div class="arx-comments">${cList || '<p class="arx-empty">No comments yet.</p>'}</div>` +
    `<form class="arx-cform"><textarea required placeholder="comment (markdown)…" rows="3"></textarea><button>comment</button></form>`;
  document.body.appendChild(disc);
  const cform = disc.querySelector(".arx-cform");
  cform.onsubmit = (e) => {
    e.preventDefault();
    const ta = cform.querySelector("textarea"); const body = (ta.value || "").trim(); if (!body) return;
    disc.querySelector(".arx-empty")?.remove();
    const d = document.createElement("div"); d.className = "arx-comment";
    d.innerHTML = `<div class="arx-cmeta">you · now</div><div class="arx-cbody"></div>`;
    d.querySelector(".arx-cbody").textContent = body;
    disc.querySelector(".arx-comments").appendChild(d); ta.value = "";
    save("/r/" + ridPath + "/comment", { body_md: body }, () => d.remove());
  };
  console.log("[archeion] overlay ready:", id);
}
// Run on DOMContentLoaded — Pinax's app.js (registered earlier) builds #pinax-bar first; we then move
// it + apply the structural overlay synchronously, before paint (no flash). Idempotency guard above.
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", archeionOverlay);
else archeionOverlay();
