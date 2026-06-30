// The note layer (Zettelkasten + structure notes): the /notes workspace, the /compose composer, the
// advisor /show page (presentLayout), and the /note open view + comments. Split out of pages.js and
// re-exported via render.js, so app.js (`import * as V`) is unaffected. body_md → HTML via util.md;
// ![[embeds]] / [[mentions]] are resolved in the db layer, rendered here.
import { esc, rid, stars, md, figUrl, figMedia, figHref } from "./util.js";
import { impSelect } from "./components.js";
import { layout, presentLayout, composeShell } from "./layout.js";

// ---- notes (Zettelkasten) + structure notes ----
// an ![[embed]] → a viewer block. figure = inline image (consecutive ones flow into columns), opens
// the page CENTERED on that figure (#arxfig). section = a foldable <details> that reveals the section
// (a deep-linked iframe), title opens centered (#arxsec). page = a card that opens a POPUP (a CSS
// :target modal with the page in an iframe).
function embedHtml(e, i) {
  if (e.kind === "figure") {
    const f = e.figure;
    const suffix = e.target.slice(e.target.indexOf(":") + 1); // = string(f.id) = the page's <img alt>/<iframe title>
    return `<a class="embed-figl" href="${figHref(e.record, suffix)}" target="_blank" rel="noopener" title="open centered on this figure">` +
      `<figure class="embed-fig">${figMedia(f.thumbnail || f.path, f.caption)}` +
      `<figcaption>${esc(f.caption)} <span class="embed-open">↗</span></figcaption></figure></a>`;
  }
  if (e.kind === "section") {
    const open = `/r/${rid(e.record.id)}#arxsec=${encodeURIComponent(e.label)}`; // full page, centred
    const only = `${open}&only=1`; // the fold iframe shows ONLY this section's block
    return `<details class="embed-secfold"><summary><span class="embed-ico">▦</span> <span class="embed-t">${esc(e.label)}</span> ` +
      `<a class="embed-src" href="${open}" target="_blank" rel="noopener" title="open centered on this section">${esc(e.record.title)} ↗</a></summary>` +
      `<iframe class="embed-frame" loading="lazy" src="${only}"></iframe></details>`;
  }
  if (e.kind === "record") {
    const r = e.record;
    const nf = (r.figures || []).length, nr = r.runs || 0;
    const meta = [`<span class="imp" title="importance">${stars(r.importance || 0)}</span>`, esc(r.project || ""), esc((r.date || "").slice(0, 10)),
      `${nf} fig${nf === 1 ? "" : "s"} · ${nr} run${nr === 1 ? "" : "s"}`].join(" · ");
    const tags = (r.tags || []).map((t) => ` <a class="tag" href="/?tag=${encodeURIComponent(t)}">#${esc(t)}</a>`).join("");
    const toc = (e.headings || []).map((h) => `<li class="toc-l${h.level}">${esc(h.text)}</li>`).join("");
    return `<div class="embed-page">` +
      `<a class="embed-page-t" href="#pm-${i}"><span class="embed-ico">▤</span> <span class="embed-t">${esc(r.title)}</span> <span class="embed-src">open ▸</span></a>` +
      `<div class="embed-page-meta">${meta || "—"}${tags}</div>` +
      (toc ? `<details class="embed-page-toc"><summary>contents (${e.headings.length})</summary><ul>${toc}</ul></details>` : "") +
      `</div>` +
      `<div class="embed-modal" id="pm-${i}"><a class="embed-modal-bg" href="#_" aria-label="close"></a>` +
      `<div class="embed-modal-box"><div class="embed-modal-bar"><span>${esc(r.title)}</span><a href="/r/${rid(r.id)}" target="_blank" rel="noopener">open in tab ↗</a><a class="embed-modal-x" href="#_">✕</a></div>` +
      `<iframe class="embed-modal-frame" loading="lazy" src="/r/${rid(r.id)}"></iframe></div></div>`;
  }
  return `<span class="embed-bad">![[${esc(e.target)}]]</span>`;
}
// render a note body: ![[embed]] (protected through md as a token, then swapped for HTML) + [[mention]]
// → a markdown link. Figures use an INLINE token so consecutive ones land in one paragraph and flow
// into columns (inline-block); sections/pages use a block token.
function noteBodyHtml(n) {
  let t = String(n.body_md || "");
  const embeds = n.embeds || [];
  embeds.forEach((e, i) => {
    const tok = e.kind === "figure" ? `EMBED${i}END` : `\n\nEMBED${i}END\n\n`;
    t = t.split(`![[${e.target}]]`).join(tok);
  });
  for (const m of n.mentions || []) if (m.ref) t = t.split(`[[${m.target}]]`).join(`[${m.target}](${m.ref})`);
  let html = md.render(t);
  embeds.forEach((e, i) => { const h = embedHtml(e, i); html = html.replace(`<p>EMBED${i}END</p>`, h).split(`EMBED${i}END`).join(h); });
  return html;
}
function noteCard(n, showScope) {
  const scope = showScope && n.scope ? ` <a class="note-scope" href="/p/${rid(n.scope)}">${esc(n.scope)}</a>` : "";
  const open = ` <a class="note-open" href="/note/${n.id}" title="open — read &amp; comment / annotate">open ↗</a>`;
  const preview = n.pinned ? ` <a class="note-show" href="/show/${n.id}" title="advisor view (clean page)">preview ↗</a>` : "";
  const imp = n.importance ? ` <span class="imp" title="importance">${stars(n.importance)}</span>` : "";
  const tags = (n.tags || []).map((t) => ` <a class="tag" href="/?tag=${encodeURIComponent(t)}">#${esc(t)}</a>`).join("");
  const title = n.title ? `<span class="note-title">${esc(n.title)}</span>` : `<span class="note-title muted">(untitled)</span>`;
  // top-right tools, left→right: (date) · edit · archive · pin
  const tools = `<span class="note-tools">` +
    `<span class="note-when muted" title="last edited">${esc((n.updated_at || "").slice(0, 10))}</span>` +
    `<span class="admin-only">` + // edit / archive / pin — managers only (members just read + open ↗)
    `<a class="note-edit-link" href="/compose?id=${n.id}" title="edit in the composer">✎ edit</a>` +
    `<form method="post" action="/notearchive" class="note-arch"><input type="hidden" name="id" value="${n.id}"><input type="hidden" name="archived" value="${n.archived ? 0 : 1}"><button title="${n.archived ? "restore to active notes" : "archive — hide from active (kept in search)"}">${n.archived ? "🗄 unarchive" : "🗄 archive"}</button></form>` +
    `<form method="post" action="/notepin" class="note-pin"><input type="hidden" name="id" value="${n.id}"><input type="hidden" name="pinned" value="${n.pinned ? 0 : 1}"><button title="${n.pinned ? "unpin" : "pin as a structure note (advisor page)"}">${n.pinned ? "📌 unpin" : "📌 pin"}</button></form>` +
    `</span></span>`;
  return `<div class="note${n.pinned ? " pinned" : ""}${n.archived ? " archived" : ""}" data-note="${n.id}">
    <div class="note-head"><span class="note-headl">${n.pinned ? '<span class="pin-on" title="structure note">📌</span> ' : ""}${title}${imp}${tags}${scope}${open}${preview}</span>${tools}</div>
    ${(n.description || "").trim() ? `<div class="note-desc muted">${esc(n.description)}</div>` : ""}
    <div class="md note-body">${noteBodyHtml(n)}</div>
    <div class="note-foot admin-only">
      <form method="post" action="/notedel" class="note-del"><input type="hidden" name="id" value="${n.id}"><button title="delete note">×</button></form>
    </div></div>`;
}
export function notesBlock(scope, notes, { showScope = false } = {}) {
  const items = notes.map((n) => noteCard(n, showScope)).join("") || `<p class="empty">No notes yet.</p>`;
  const add = `<form method="post" action="/noteadd" class="note-add admin-only"><input type="hidden" name="scope" value="${esc(scope)}">
    <input name="title" placeholder="title (optional)" autocomplete="off">
    <textarea name="body" rows="3" placeholder="note (markdown; [[project]]/[[record-id]] to link, ![[figure-id]] to embed)…" required></textarea>
    <div class="note-actions"><button>add note</button></div></form>`;
  return `<div class="notes">${items}${add}</div>`;
}

// the global notes page, in three buckets: 📌 pinned (advisor pages) · 🗂 all notes (with a
// client-side filter for when they grow) · 🗄 archived (folded away, still searchable).
export function renderNotes(notes, { projects, tags, user }) {
  const active = notes.filter((n) => !n.archived);
  const pinned = active.filter((n) => n.pinned);
  const loose = active.filter((n) => !n.pinned);
  const archived = notes.filter((n) => n.archived);
  const cards = (list) => `<div class="notes">${list.map((n) => noteCard(n, true)).join("")}</div>`;

  const pinnedBlock = `<section class="pinned-sec"><h3>📌 pinned <span class="muted">(${pinned.length})</span></h3>${
    pinned.length ? cards(pinned) : `<p class="empty">No pinned notes — pin one (📌) to make a curated advisor page at <code>/show/:id</code>.</p>`
  }</section>`;

  // quick-add: a fast markdown jot (title + description + body). The rich path (embed figures/sections,
  // live preview, pin as an advisor page) is the composer — "✎ new in composer" in the heading.
  const addForm = `<form method="post" action="/noteadd" class="note-add admin-only"><input type="hidden" name="scope" value="">
    <div class="note-add-head">quick note <span class="muted">— a fast markdown jot; ✎ edit opens it in the full composer later</span></div>
    <input name="title" placeholder="title (optional)" autocomplete="off">
    <input name="description" placeholder="description (optional) — short one-line summary, markdown" autocomplete="off">
    <textarea name="body" rows="3" placeholder="body — markdown ($E=mc^2$, [[project]]/[[record-id]] links, ![[figure-id]] embeds)…" required></textarea>
    <div class="note-actions"><button>add note</button></div></form>`;
  const allBlock = `<section class="allnotes-sec">
    <div class="allnotes-head"><h3>🗂 all notes <span class="muted">(${loose.length})</span></h3>
      <input type="search" class="note-filter" placeholder="🔍 filter notes — title / project / text…" autocomplete="off" aria-label="filter notes"></div>
    ${loose.length ? cards(loose) : `<p class="empty">No notes yet.</p>`}
    ${addForm}</section>`;

  const archivedBlock = archived.length
    ? `<details class="archived-sec"><summary>🗄 archived (${archived.length})</summary>${cards(archived)}</details>`
    : "";

  const main = `<h2>📝 Notes <a class="make-sn admin-only" href="/compose" title="rich composer — embed figures/sections, live preview, then pin as an advisor page">✎ new in composer</a></h2>
    <p class="muted">Notes are <strong>markdown</strong> (<code>[[project]]</code>/<code>[[record-id]]</code> links, <code>![[figure-id]]</code> embeds, <code>$math$</code>). Two ways to write: the <strong>composer</strong> (rich — embeds + live preview; the way to build a <strong>pinned</strong> advisor page at <code>/show/:id</code>) or a <strong>quick note</strong> below. <strong>open ↗</strong> any note to read &amp; comment.</p>
    ${pinnedBlock}
    ${allBlock}
    ${archivedBlock}`;
  return layout("Notes", main, { user, projects, tags });
}

// the note as a present <article> — title + meta (importance/tags) + description + body. Shared by the
// standalone /show page and the composer's inline preview (so both render identically).
function noteArticle(note) {
  const bits = [];
  if (note.importance) bits.push(`<span class="imp" title="importance">${stars(note.importance)}</span>`);
  if ((note.tags || []).length) bits.push(note.tags.map((t) => `<a class="tag" href="/?tag=${encodeURIComponent(t)}">#${esc(t)}</a>`).join(" "));
  const meta = bits.length ? `<div class="present-meta">${bits.join(" · ")}</div>` : "";
  const desc = (note.description || "").trim() ? `<div class="present-desc md">${md.render(note.description)}</div>` : "";
  return `<article class="present">${note.title ? `<h1>${esc(note.title)}</h1>` : ""}${meta}${desc}<div class="md">${noteBodyHtml(note)}</div></article>`;
}

// the advisor-facing PRESENT view: a pinned structure note rendered clean (the standalone /show page,
// WITH the home-style header + sidebar/hamburger so it's a fully navigable Archeion page).
export function renderShow(note, { projects = [], tags = [] } = {}) {
  if (!note) return presentLayout("Not found", `<article class="present"><p class="empty">Page not found.</p></article>`, { projects, tags });
  return presentLayout(note.title || "Archeion", noteArticle(note), { scope: note.scope, id: note.id, projects, tags, annot: note.pinned ? note.id : "" });
}

// inline composer preview (POST /api/note/preview): the SAME article, but CHROME-FREE — it renders
// inside the composer's split pane, whose own header already carries refs/preview/save, so a second
// header would just duplicate. Renders the CURRENT (POSTed) editor content → preview works UNSAVED.
export function renderNotePreview(note) {
  return presentLayout(note.title || "preview", noteArticle(note), { chrome: false });
}

// "open" a note → its WORKING view: the rendered note + a comments / annotations thread. A normal app
// page (home header + sidebar), unlike the clean advisor /show. Available for EVERY note (pinned or not).
export function renderNoteView(note, comments = [], related = [], { projects = [], tags = [], user = "" } = {}) {
  if (!note) return layout("Not found", `<p class="empty">Note not found.</p>`, { projects, tags, user });
  const actions = `<div class="nv-actions">` +
    `<a class="nv-btn" href="/compose?id=${note.id}" title="edit in the composer">✎ edit</a>` +
    (note.pinned ? `<a class="nv-btn" href="/show/${note.id}" title="clean advisor page">advisor view ↗</a>` : "") +
    `<a class="nv-btn" href="/notes">← all notes</a></div>`;
  // related = the link graph around this note: what it references ([[project]]/[[record]]/[[note:…]])
  // + which notes reference it (backlinks). This is the edge data the future graph view reads.
  const out = (note.mentions || []).filter((m) => m.ref)
    .map((m) => `<a class="rel-chip rel-${m.kind}" href="${m.ref}">${esc(m.kind === "note" ? (m.title || m.target) : m.target)}</a>`).join(" ");
  const back = (related || []).map((r) => `<a class="rel-chip rel-note" href="/note/${r.id}">${esc(r.title || "(untitled)")}</a>`).join(" ");
  const rel = (out || back)
    ? `<section class="nv-rel">${out ? `<div class="rel-row"><span class="rel-k">links →</span> ${out}</div>` : ""}${back ? `<div class="rel-row"><span class="rel-k">← linked from</span> ${back}</div>` : ""}</section>`
    : "";
  const cItem = (c) => `<div class="nv-comment" data-cid="${c.id}"><div class="nv-cmeta muted">${esc(c.author || "anon")} · ${esc((c.created_at || "").slice(0, 16))}</div><div class="md nv-cbody">${md.render(c.body_md || "")}</div></div>`;
  const disc = `<section class="nv-disc"><h2>Comments &amp; annotations <span class="muted">(${comments.length})</span></h2>` +
    `<div class="nv-comments">${comments.length ? comments.map(cItem).join("") : `<p class="empty">No comments yet — add one below.</p>`}</div>` +
    `<form method="post" action="/note/${note.id}/comment" class="nv-cform"><textarea name="body_md" rows="3" required placeholder="comment / annotation (markdown)…"></textarea><div class="note-actions"><button>add comment</button></div></form></section>`;
  return layout(note.title || "Note", `${actions}${noteArticle(note)}${rel}${disc}`, { projects, tags, user, scope: note.scope });
}

// the structure-note composer: LEFT = click Pinax/figures to embed, RIGHT = markdown editor + live
// preview. Panes toggle on small screens. Saving makes/updates a pinned structure note.
export function renderCompose(note, picker) {
  const id = note?.id || "";
  const scope = note?.scope || "";
  const title = note?.title || "";
  const bodyMd = note?.body_md || "";
  const importance = note?.importance || 0;
  // figure id → {url, caption} for the editor's inline ![[id]] rendering (CSP-safe JSON island, not a script)
  const figMap = {};
  const recMap = {};
  for (const p of picker) for (const r of p.records) {
    recMap[r.id] = { title: r.title, thumb: r.figures[0] ? figUrl(r.figures[0].thumbnail || r.figures[0].path) : "",
      project: p.project, date: r.date, importance: r.importance || 0, tags: r.tags || [], figs: r.figures.length };
    for (const f of r.figures) figMap[f.id] = { url: figUrl(f.thumbnail || f.path), caption: f.caption };
  }
  const figJson = JSON.stringify(figMap).replace(/</g, "\\u003c");
  const recJson = JSON.stringify(recMap).replace(/</g, "\\u003c");
  // refs / show / save live in the top header (composeShell). save uses form="cmp-form" so it can
  // submit the form from outside it; show (preview) only exists once the note has an id.
  const headerExtra = `<div class="cmp-top-actions">` +
    `<button type="button" class="cmp-refs" title="open references to mention from">📎 refs</button>` +
    `<button type="button" class="cmp-preview-btn" title="preview the current edits inline (no save needed)">preview</button>` +
    `<button form="cmp-form" class="cmp-save">save</button></div>`;
  const main = `<div class="cmp">
    <section class="cmp-edit">
      <form id="cmp-form" method="post" action="${id ? "/noteedit" : "/noteadd"}">
        ${id ? `<input type="hidden" name="id" value="${id}">` : `<input type="hidden" name="scope" value="${esc(scope)}">`}
        <input type="hidden" name="pinned" value="1"><input type="hidden" name="from" value="compose">
        <input name="title" value="${esc(title)}" placeholder="structure note title" autocomplete="off" class="cmp-titlein">
        <div class="cmp-meta">
          <label class="cmp-imp">importance ${impSelect("importance", importance)}</label>
          <input name="tags" class="cmp-tags" value="${esc((note?.tags || []).map((t) => "#" + t).join(" "))}" placeholder="#tags (space/comma)" autocomplete="off">
          <textarea name="description" class="cmp-desc" rows="2" placeholder="description — short summary (markdown)">${esc(note?.description || "")}</textarea>
        </div>
        <textarea name="body" id="cmp-body" class="cmp-fallback" placeholder="markdown + math ($E=mc^2$)">${esc(bodyMd)}</textarea>
        <div id="cmp-editor" class="cmp-cm"></div>
      </form>
    </section>
    <div class="cmp-splitter" title="drag to resize"></div>
    <aside class="cmp-pick"><div class="cmp-pick-head"><span class="ph-refs">references — ⧉ figure / add buttons insert</span><span class="ph-preview">preview (current edits)</span><a class="ph-refs cmp-pick-open" href="/" target="_blank" rel="noopener">open ↗</a>${id ? `<a class="ph-preview cmp-pick-open" href="/show/${id}" target="_blank" rel="noopener">open ↗</a>` : ""}<button type="button" class="cmp-refs-close" title="close">✕</button></div><iframe class="cmp-frame cmp-refs-frame" src="/" title="Archeion references" loading="lazy"></iframe><iframe class="cmp-frame cmp-preview-frame" name="cmp-preview-frame" title="preview" loading="lazy"></iframe></aside>
    <form id="cmp-preview-form" method="post" action="/api/note/preview" target="cmp-preview-frame" hidden><input type="hidden" name="id" value="${id}"><input type="hidden" name="scope" value="${esc(scope)}"><input type="hidden" name="title"><input type="hidden" name="body"><input type="hidden" name="importance"><input type="hidden" name="tags"><input type="hidden" name="description"></form>
    <script type="application/json" id="arx-figs">${figJson}</script>
    <script type="application/json" id="arx-recs">${recJson}</script>
  </div>`;
  return composeShell(id ? `Edit · ${title || "structure note"}` : "Make structure note", main, headerExtra);
}
