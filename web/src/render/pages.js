// The pages: one exported render<X>() per view. Each builds a <main> body from components and wraps
// it in layout(). body_md → HTML via markdown-it (util.md); everything else is escaped.
import { esc, rid, snipHtml, figUrl, stars, md } from "./util.js";
import { recordCard, figureCard, bookmarkForm, tagEditor, sortControl, impSelect } from "./components.js";
import { PARA } from "../constants.js";
import { layout, presentLayout, composeShell } from "./layout.js";

// ---- notes (Zettelkasten) + structure notes ----
// an ![[embed]] → a viewer block. figure = inline image (consecutive ones flow into columns), opens
// the page CENTERED on that figure (#arxfig). section = a foldable <details> that reveals the section
// (a deep-linked iframe), title opens centered (#arxsec). page = a card that opens a POPUP (a CSS
// :target modal with the page in an iframe).
function embedHtml(e, i) {
  if (e.kind === "figure") {
    const f = e.figure;
    const suffix = e.target.slice(e.target.indexOf(":") + 1); // = string(f.id) = the page's <img alt>
    return `<a class="embed-figl" href="/r/${rid(e.record)}#arxfig=${encodeURIComponent(suffix)}" target="_blank" rel="noopener" title="open centered on this figure">` +
      `<figure class="embed-fig"><img loading="lazy" src="${esc(figUrl(f.thumbnail || f.path))}" alt="${esc(f.caption)}">` +
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
    `<a class="note-edit-link" href="/compose?id=${n.id}" title="edit in the composer">✎ edit</a>` +
    `<form method="post" action="/notearchive" class="note-arch"><input type="hidden" name="id" value="${n.id}"><input type="hidden" name="archived" value="${n.archived ? 0 : 1}"><button title="${n.archived ? "restore to active notes" : "archive — hide from active (kept in search)"}">${n.archived ? "🗄 unarchive" : "🗄 archive"}</button></form>` +
    `<form method="post" action="/notepin" class="note-pin"><input type="hidden" name="id" value="${n.id}"><input type="hidden" name="pinned" value="${n.pinned ? 0 : 1}"><button title="${n.pinned ? "unpin" : "pin as a structure note (advisor page)"}">${n.pinned ? "📌 unpin" : "📌 pin"}</button></form>` +
    `</span>`;
  return `<div class="note${n.pinned ? " pinned" : ""}${n.archived ? " archived" : ""}" data-note="${n.id}">
    <div class="note-head"><span class="note-headl">${n.pinned ? '<span class="pin-on" title="structure note">📌</span> ' : ""}${title}${imp}${tags}${scope}${open}${preview}</span>${tools}</div>
    ${(n.description || "").trim() ? `<div class="note-desc muted">${esc(n.description)}</div>` : ""}
    <div class="md note-body">${noteBodyHtml(n)}</div>
    <div class="note-foot">
      <form method="post" action="/notedel" class="note-del"><input type="hidden" name="id" value="${n.id}"><button title="delete note">×</button></form>
    </div></div>`;
}
function notesBlock(scope, notes, { showScope = false } = {}) {
  const items = notes.map((n) => noteCard(n, showScope)).join("") || `<p class="empty">No notes yet.</p>`;
  const add = `<form method="post" action="/noteadd" class="note-add"><input type="hidden" name="scope" value="${esc(scope)}">
    <input name="title" placeholder="title (optional)" autocomplete="off">
    <textarea name="body" rows="3" placeholder="note (markdown; [[project]]/[[record-id]] to link, ![[figure-id]] to embed)…" required></textarea>
    <div class="note-actions"><button>add note</button></div></form>`;
  return `<div class="notes">${items}${add}</div>`;
}

export function renderLanding({ recents, activity, projects, tags, bset, user }) {
  const cards = recents.map((r) => recordCard(r, bset)).join("") ||
    `<p class="empty">No records — run <code>Archeion.ingest(doc)</code>.</p>`;
  const act = activity.comments
    .slice(0, 12)
    .map(
      (c) => `<li><a href="/r/${rid(c.record_id)}">${esc(c.record_title)}</a>
        <span class="muted">${esc(c.author)}: ${esc((c.body_md || "").slice(0, 80))}</span></li>`,
    )
    .join("");
  const active = (projects || []).filter((p) => p.para === "Projects");
  const projCards =
    active
      .map((p) => `<a class="card projcard" href="/p/${rid(p.project)}">
        <div class="title">${esc(p.project)}</div><div class="meta">${p.n} records</div></a>`)
      .join("") || `<p class="empty">No active projects — file one under PARA on its project page.</p>`;
  const main = `<section><h2>Active Projects</h2><div class="cards">${projCards}</div></section>
    <section><h2>Current changes</h2><div class="cards">${cards}</div></section>
    ${act ? `<section><h2>Recent discussion</h2><ul class="activity">${act}</ul></section>` : ""}`;
  return layout("Archeion", main, { user, projects, tags });
}

// The FALLBACK record view. Records WITH a stored Pinax page are 303-redirected to it (Archeion
// overlays annotation chrome via inject.js), so only legacy / page-less records reach here — we
// reconstruct from body_md + a figure grid, with the same annotation controls.
export function renderRecord(rec, { figures, runs, comments, tags, bset, user, projects, allTags }) {
  if (!rec) return layout("Not found", `<p class="empty">Record not found.</p>`, { user, projects, tags: allTags });
  const runrows = runs.map((r) => `<li><code>${esc(r.project)}/${esc(r.run)}</code></li>`).join("");
  const figs = figures
    .map(
      (f) => `<figure class="figcard">
        <img loading="lazy" src="${esc(figUrl(f.thumbnail || f.path))}" alt="${esc(f.caption)}">
        <figcaption>${esc(f.caption)}
          <form method="post" action="/figimportance" class="imp-set"><input type="hidden" name="id" value="${esc(f.id)}">
            ${impSelect("value", f.importance)}<button>set</button></form>
          <a class="dl" href="${esc(figUrl(f.path))}" download title="download">⤓</a>
          ${bookmarkForm("figure", f.id, bset)}</figcaption></figure>`,
    )
    .join("");
  const cmts = comments
    .map((c) => `<div class="comment"><div class="cmeta">${esc(c.author)} · ${esc((c.created_at || "").slice(0, 16))}</div><div class="md">${md.render(c.body_md || "")}</div></div>`)
    .join("");
  const body = `${figs ? `<section class="figgrid">${figs}</section>` : ""}
      <section class="body"><div class="md">${md.render(rec.body_md || "")}</div></section>`;
  const main = `<article>
    <h1>${esc(rec.title)} ${rec.archived ? '<span class="badge">archived</span>' : ""}</h1>
    <div class="meta"><a class="proj" href="/p/${rid(rec.project)}">${esc(rec.project)}</a>
      <span class="date">${esc((rec.date || "").slice(0, 10))}</span>
      ${bookmarkForm("record", rec.id, bset)}</div>
    ${tagEditor(rec.id, tags)}
    <section class="controls">
      <form method="post" action="/importance" class="inline"><input type="hidden" name="id" value="${esc(rec.id)}">
        importance ${impSelect("value", rec.importance)}<button>set</button></form>
      <form method="post" action="/archive" class="inline"><input type="hidden" name="id" value="${esc(rec.id)}">
        <input type="hidden" name="archived" value="${rec.archived ? 0 : 1}"><button>${rec.archived ? "unarchive" : "archive"}</button></form>
    </section>
    ${runrows ? `<details class="runs"><summary>runs (${runs.length})</summary><ul>${runrows}</ul></details>` : ""}
    ${body}
    <section class="discussion"><h2>Discussion</h2>${cmts || '<p class="empty">No comments yet.</p>'}
      <form method="post" action="/r/${rid(rec.id)}/comment" class="comment-form">
        <textarea name="body_md" rows="3" placeholder="comment (markdown)…" required></textarea><button>comment</button></form>
    </section></article>`;
  return layout(rec.title, main, { user, projects, tags: allTags });
}

export function renderFigures(figures, { project, sort = "importance", projects, tags, bset, user }) {
  const grid = figures.map((f) => figureCard(f, bset)).join("") || `<p class="empty">No figures.</p>`;
  const head = project ? `Figures — ${esc(project)}` : "Figures";
  const base = project ? `/gallery?project=${encodeURIComponent(project)}&` : "/gallery?";
  return layout("Figures", `<section><h2>${head} ${sortControl(base, sort)}</h2><div class="figgrid">${grid}</div></section>`, {
    user, projects, tags,
  });
}

// scoped search (from a project): Pinax (records) + Figures within that project
export function renderSearch(q, { records, figures }, { project = "", fields = [], projects, tags, bset, user }) {
  const recs = records
    .map((r) => `<a class="result" href="/r/${rid(r.id)}"><div class="title">${esc(r.title)} <span class="muted">${esc(r.project)}</span>${r.archived ? ' <span class="badge arch-badge">🗄</span>' : ""}</div><div class="snip">${snipHtml(r.snip)}</div></a>`)
    .join("");
  const figs = figures.map((f) => figureCard(f, bset)).join("");
  const head = project ? `Search in ${esc(project)}` : "Search";
  const main = `<h2>${head}${q ? `: ${esc(q)}` : ""}</h2>
    <section><h3>Pinax (${records.length})</h3>${recs || '<p class="empty">none</p>'}</section>
    <section><h3>Figures (${figures.length})</h3><div class="figgrid">${figs || '<p class="empty">none</p>'}</div></section>`;
  return layout(`search: ${q}`, main, { q, user, projects, tags, scope: project, fields });
}

// project search (from HOME): matching projects as cards
export function renderProjectSearch(q, results, { fields = [], projects, tags, user }) {
  const cards = results
    .map((p) => `<a class="card projcard" href="/p/${rid(p.project)}"><div class="title">${esc(p.project)}</div>` +
      `<div class="meta"><span class="badge">${esc(p.para)}</span> <span class="muted">${p.n} records</span></div>` +
      ((p.description || "").trim() ? `<div class="muted psnip">${esc(p.description.slice(0, 140))}</div>` : "") + `</a>`)
    .join("") || '<p class="empty">No projects match.</p>';
  const main = `<h2>Projects${q ? `: ${esc(q)}` : ""}</h2><p class="muted">Search a project, then search inside it for figures &amp; Pinax.</p>
    <div class="cards">${cards}</div>`;
  return layout(`search: ${q}`, main, { q, user, projects, tags, fields });
}

export function renderProject(project, { records, archived = [], figures, meta = {}, notes = [], sort = "date", fsort = "importance", projects, tags, bset, user }) {
  const cards = records.map((r) => recordCard(r, bset)).join("") || `<p class="empty">No records.</p>`;
  const FIG_INIT = 12; // figures visible before "Show 10 more"
  const figCards = figures.map((f, i) => figureCard(f, bset, i >= FIG_INIT ? "fig-hidden" : "")).join("");
  const moreCount = Math.max(0, figures.length - FIG_INIT);
  const archCards = archived.map((r) => recordCard(r, bset)).join("");
  const id = esc(project);
  const para = meta.para || "Projects";
  const description = meta.description || "";
  const ptags = meta.tags || [];
  const todos = meta.todos || [];
  // --- the project meta property panel (Obsidian-style rows; project version of the record panel) ---
  const paraSel = `<form method="post" action="/projectpara" class="inline"><input type="hidden" name="name" value="${id}">
    <select name="para">${PARA.map((b) => `<option${b === para ? " selected" : ""}>${b}</option>`).join("")}</select><button>set</button></form>`;
  const tagChips = ptags
    .map((t) => `<span class="ptag-chip"><a href="/?tag=${encodeURIComponent(t)}">#${esc(t)}</a>` +
      `<form method="post" action="/ptagdel"><input type="hidden" name="name" value="${id}"><input type="hidden" name="tag" value="${esc(t)}"><button title="remove">×</button></form></span>`)
    .join("");
  const tagAdd = `<form method="post" action="/ptagadd" class="ptag-add"><input type="hidden" name="name" value="${id}"><input name="tag" placeholder="+ tag" autocomplete="off"></form>`;
  const todoItems = todos
    .map((t) => `<div class="ptodo${t.done ? " done" : ""}" data-todo="${t.id}">` +
      `<form method="post" action="/todotoggle"><input type="hidden" name="id" value="${t.id}"><button title="toggle" class="tg">${t.done ? "☑" : "☐"}</button></form>` +
      `<span class="ptodo-body">${esc(t.body)}</span>` +
      `<form method="post" action="/tododel"><input type="hidden" name="id" value="${t.id}"><button title="delete" class="x">×</button></form></div>`)
    .join("");
  const todoAdd = `<form method="post" action="/todoadd" class="ptodo-add"><input type="hidden" name="name" value="${id}"><input name="body" placeholder="+ todo" autocomplete="off"><button>add</button></form>`;
  const descHtml = description.trim() ? md.render(description) : '<span class="muted">—</span>';
  const descEdit = `<details class="pdesc-edit"><summary>edit</summary><form method="post" action="/projectdesc" class="pdesc-form"><input type="hidden" name="name" value="${id}"><textarea name="description" rows="4" placeholder="markdown…">${esc(description)}</textarea><button>save</button></form></details>`;
  const row = (k, v) => `<div class="prop-row"><span class="prop-k">${k}</span><span class="prop-v">${v}</span></div>`;
  const pmeta = `<div class="pmeta">
    ${row("status", paraSel)}
    ${row("tags", `<span class="ptags">${tagChips}${tagAdd}</span>`)}
    ${row("created", esc((meta.created || "").slice(0, 10)) || "—")}
    ${row("last edited", esc((meta.updated_at || "").slice(0, 10)) || "—")}
    ${row("todo", `<span class="ptodos">${todoItems}${todoAdd}</span>`)}
    ${row("description", `<div class="md">${descHtml}</div>${descEdit}`)}
  </div>`;
  const expBase = `/p/${rid(project)}?fsort=${fsort}&`; // keep figure sort when re-sorting experiments
  const figBase = `/p/${rid(project)}?sort=${sort}&`; //   keep experiment sort when re-sorting figures
  const figMore = `<div class="figmore">${moreCount ? `<button type="button" class="showmore" data-step="10">Show 10 more</button>` : ""}<a class="allfigs" href="/gallery?project=${encodeURIComponent(project)}&sort=${fsort}">All figures →</a></div>`;
  const ctxUrl = `/api/project/${encodeURIComponent(project)}/context`;
  const main = `<div class="phead"><h1>${esc(project)}</h1><span class="ctxlinks" title="human context, for the LLM compute loop">LLM context: <a href="${ctxUrl}">json</a> · <a href="${ctxUrl}?format=md">md</a></span></div>
    ${pmeta}
    <section class="notes-sec"><h3>Notes (${notes.length})</h3>${notesBlock(project, notes)}</section>
    <section><h3>Experiments (${records.length}) ${sortControl(expBase, sort)}</h3><div class="cards">${cards}</div></section>
    ${figures.length ? `<section><h3>Figures (${figures.length}) ${sortControl(figBase, fsort, "fsort")}</h3><div class="figgrid">${figCards}</div>${figMore}</section>` : ""}
    ${archived.length ? `<details class="archived-sec" open><summary>🗄 Archived (${archived.length})</summary><div class="cards">${archCards}</div></details>` : ""}`;
  return layout(project, main, { user, projects, tags, scope: project });
}

export function renderBookmarks({ records, figures }, { projects, tags, bset, user }) {
  const cards = records.map((r) => recordCard(r, bset)).join("");
  const figs = figures.map((f) => figureCard(f, bset)).join("");
  const main = `<h2>★ Bookmarks</h2>
    <section><h3>Experiments (${records.length})</h3><div class="cards">${cards || '<p class="empty">none</p>'}</div></section>
    <section><h3>Figures (${figures.length})</h3><div class="figgrid">${figs || '<p class="empty">none</p>'}</div></section>`;
  return layout("Bookmarks", main, { user, projects, tags });
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
  const addForm = `<form method="post" action="/noteadd" class="note-add"><input type="hidden" name="scope" value="">
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

  const main = `<h2>📝 Notes <a class="make-sn" href="/compose" title="rich composer — embed figures/sections, live preview, then pin as an advisor page">✎ new in composer</a></h2>
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
  return presentLayout(note.title || "Archeion", noteArticle(note), { scope: note.scope, id: note.id, projects, tags });
}

// inline composer preview (POST /api/note/preview): the SAME article, but CHROME-FREE — it renders
// inside the composer's split pane, whose own header already carries refs/preview/save, so a second
// header would just duplicate. Renders the CURRENT (POSTed) editor content → preview works UNSAVED.
export function renderNotePreview(note) {
  return presentLayout(note.title || "preview", noteArticle(note), { chrome: false });
}

// "open" a note → its WORKING view: the rendered note + a comments / annotations thread. A normal app
// page (home header + sidebar), unlike the clean advisor /show. Available for EVERY note (pinned or not).
export function renderNoteView(note, comments = [], { projects = [], tags = [], user = "" } = {}) {
  if (!note) return layout("Not found", `<p class="empty">Note not found.</p>`, { projects, tags, user });
  const actions = `<div class="nv-actions">` +
    `<a class="nv-btn" href="/compose?id=${note.id}" title="edit in the composer">✎ edit</a>` +
    (note.pinned ? `<a class="nv-btn" href="/show/${note.id}" title="clean advisor page">advisor view ↗</a>` : "") +
    `<a class="nv-btn" href="/notes">← all notes</a></div>`;
  const cItem = (c) => `<div class="nv-comment"><div class="nv-cmeta muted">${esc(c.author || "anon")} · ${esc((c.created_at || "").slice(0, 16))}</div><div class="md nv-cbody">${md.render(c.body_md || "")}</div></div>`;
  const disc = `<section class="nv-disc"><h2>Comments &amp; annotations <span class="muted">(${comments.length})</span></h2>` +
    `<div class="nv-comments">${comments.length ? comments.map(cItem).join("") : `<p class="empty">No comments yet — add one below.</p>`}</div>` +
    `<form method="post" action="/note/${note.id}/comment" class="nv-cform"><textarea name="body_md" rows="3" required placeholder="comment / annotation (markdown)…"></textarea><div class="note-actions"><button>add comment</button></div></form></section>`;
  return layout(note.title || "Note", `${actions}${noteArticle(note)}${disc}`, { projects, tags, user, scope: note.scope });
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

// generic record list (tag filter, etc.)
export function renderList(title, records, { projects, tags, bset, user }) {
  const cards = records.map((r) => recordCard(r, bset)).join("") || `<p class="empty">none</p>`;
  return layout(title, `<h2>${esc(title)}</h2><div class="cards">${cards}</div>`, {
    user, projects, tags,
  });
}
