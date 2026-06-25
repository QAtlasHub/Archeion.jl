// The pages: one exported render<X>() per view. Each builds a <main> body from components and wraps
// it in layout(). body_md → HTML via markdown-it (util.md); everything else is escaped.
import { esc, rid, snipHtml, figUrl, md } from "./util.js";
import { recordCard, figureCard, bookmarkForm, tagEditor, sortControl, impSelect } from "./components.js";
import { PARA } from "../constants.js";
import { layout } from "./layout.js";
import { notesBlock } from "./notes.js";

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

// generic record list (tag filter, etc.)
export function renderList(title, records, { projects, tags, bset, user }) {
  const cards = records.map((r) => recordCard(r, bset)).join("") || `<p class="empty">none</p>`;
  return layout(title, `<h2>${esc(title)}</h2><div class="cards">${cards}</div>`, {
    user, projects, tags,
  });
}
