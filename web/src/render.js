// HTML rendering. body_md (the source-of-truth) → HTML via markdown-it; everything else is
// escaped. No framework — small string templates, served by any transport (daemon or CGI).
import MarkdownIt from "markdown-it";

const md = new MarkdownIt({ html: false, linkify: true, breaks: false });

const esc = (s) =>
  String(s ?? "").replace(
    /[&<>"]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c],
  );

// FTS snippet: \x02/\x03 mark matches. Escape first, then turn the markers into <mark>.
const snipHtml = (s) =>
  esc(s).replaceAll("\u0002", "<mark>").replaceAll("\u0003", "</mark>");

function tagsHtml(tagsJson) {
  let tags = [];
  try {
    tags = JSON.parse(tagsJson || "[]");
  } catch {
    /* ignore */
  }
  return tags
    .map(
      (t) =>
        `<a class="tag" href="/?tag=${encodeURIComponent(t)}">#${esc(t)}</a>`,
    )
    .join(" ");
}

const metaLine = (r) =>
  `<div class="meta">${r.pinned ? '<span class="pin">★</span> ' : ""}` +
  `<span class="status status-${esc(r.status)}">${esc(r.status || "")}</span> ` +
  `<span class="date">${esc((r.date || "").slice(0, 10))}</span> ${tagsHtml(r.tags)}</div>`;

const card = (r) =>
  `<a class="card" href="/r/${encodeURIComponent(r.id)}">
     <div class="title">${esc(r.title)}</div>${metaLine(r)}
   </a>`;

function layout(title, body, q = "") {
  return `<!doctype html><html lang="ja"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><link rel="stylesheet" href="/style.css">
</head><body>
<header><a href="/" class="brand">Archeion</a>
<form action="/search" method="get" class="search">
<input name="q" placeholder="search…" value="${esc(q)}" autocomplete="off"></form></header>
<main>${body}</main></body></html>`;
}

export function renderLanding({ pinned, recents, facets, activeTag, activeStatus }) {
  const chip = (label, key, val, active) =>
    `<a class="chip${active ? " on" : ""}" href="/?${key}=${encodeURIComponent(val)}">${esc(label)}</a>`;
  const filters =
    `<div class="filters">` +
    (activeTag || activeStatus ? `<a class="chip clear" href="/">✕ clear</a>` : "") +
    facets.statuses.map((s) => chip(s, "status", s, s === activeStatus)).join("") +
    facets.tags.map((t) => chip("#" + t, "tag", t, t === activeTag)).join("") +
    `</div>`;
  const filtering = Boolean(activeTag || activeStatus);
  const pinnedSec =
    !filtering && pinned.length
      ? `<section><h2>★ Pinned</h2><div class="cards">${pinned.map(card).join("")}</div></section>`
      : "";
  const heading = filtering ? "Filtered" : "Current changes";
  const recentsSec =
    `<section><h2>${esc(heading)}</h2><div class="cards">` +
    (recents.map(card).join("") ||
      `<p class="empty">No records yet — run <code>Archeion.ingest</code>.</p>`) +
    `</div></section>`;
  return layout("Archeion", filters + pinnedSec + recentsSec);
}

export function renderRecord(r) {
  if (!r) return layout("Not found", `<p class="empty">Record not found.</p>`);
  return layout(
    r.title,
    `<article><h1>${esc(r.title)}</h1>${metaLine(r)}
     <div class="md">${md.render(r.body_md || "")}</div></article>`,
  );
}

export function renderSearch(q, results) {
  const items = results
    .map(
      (r) =>
        `<a class="result" href="/r/${encodeURIComponent(r.id)}">
           <div class="title">${esc(r.title)}</div>
           <div class="snip">${snipHtml(r.snip)}</div></a>`,
    )
    .join("");
  return layout(
    `search: ${q}`,
    `<h2>Search${q ? `: ${esc(q)}` : ""}</h2>` +
      (items || `<p class="empty">No matches.</p>`),
    q,
  );
}
