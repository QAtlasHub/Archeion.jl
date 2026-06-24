// The page shell: <head> (asset links), the sticky header (hamburger + brand + scoped search form
// with the field selector), the PARA/tags sidebar, and the <main> slot. Every page calls layout().
import { esc, rid, ASSET_V } from "./util.js";
import { PARA } from "../constants.js";
import { fieldSelector } from "./components.js";

// the app sidebar (core nav + PARA-grouped projects + tags) — shared by the home layout AND the
// standalone present page, so /show navigates with the SAME menu the hamburger toggles.
export function sideNav({ projects = [], tags = [] } = {}) {
  const groups = {};
  for (const p of projects) (groups[p.para] ||= []).push(p);
  const projLink = (p) => `<a href="/p/${rid(p.project)}">${esc(p.project)} <span class="n">${p.n}</span></a>`;
  const paraSections =
    PARA.filter((b) => (groups[b] || []).length)
      .map((b) => `<h3>${b}</h3><div class="projects">${groups[b].map(projLink).join("")}</div>`)
      .join("") || `<span class="empty">no projects</span>`;
  const tagLinks = tags.map((t) => `<a href="/?tag=${encodeURIComponent(t)}">#${esc(t)}</a>`).join(" ");
  return `<nav class="side">
  <a class="navitem" href="/gallery">🖼 Figures</a>
  <a class="navitem" href="/notes">📝 Notes</a>
  <a class="navitem" href="/bookmarks">★ Bookmarks</a>
  <a class="navitem" href="/archived">🗄 Archived</a>
  ${paraSections}
  <h3>Tags</h3><div class="tags">${tagLinks || "<span class=empty>—</span>"}</div>
</nav>`;
}

export function layout(title, main, { q = "", user = "", projects = [], tags = [], scope = "", fields = [] } = {}) {
  return `<!doctype html><html lang="ja"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><link rel="stylesheet" href="/style.css?v=${ASSET_V}"><link rel="stylesheet" href="/katex/katex.min.css"><script src="/app.js?v=${ASSET_V}" defer></script></head><body>
<header><button class="hamburger" type="button" aria-label="toggle sidebar" title="menu">☰</button><a href="/" class="brand">Archeion</a>
<form action="/search" method="get" class="search">${scope ? `<input type="hidden" name="project" value="${esc(scope)}">` : ""}${fieldSelector(fields)}<input name="q" value="${esc(q)}" placeholder="${scope ? `search in ${esc(scope)} (figures &amp; Pinax)…` : "search projects…"}" autocomplete="off"></form>
<span class="who">${esc(user)}</span></header>
<div class="wrap">${sideNav({ projects, tags })}<main>${main}</main></div></body></html>`;
}

// the structure-note composer shell: a full-bleed two-pane workspace (no app sidebar), but WITH the
// client (/app.js) for the picker / live preview / pane toggle.
export function composeShell(title, main, headerExtra = "") {
  return `<!doctype html><html lang="ja"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><link rel="stylesheet" href="/style.css?v=${ASSET_V}"><link rel="stylesheet" href="/katex/katex.min.css"><script src="/app.js?v=${ASSET_V}" defer></script><script src="/compose-editor.js?v=${ASSET_V}" defer></script></head>
<body class="cmp-body"><header class="cmp-top"><a href="/notes" class="brand">← Notes</a><span class="cmp-h">${esc(title)}</span>${headerExtra}</header>${main}</body></html>`;
}

// the advisor-facing shell: a curated, readable page. The header + sidebar mirror the HOME page (same
// brand / search-pill / hamburger / nav menu) so a standalone /show is a real, navigable Archeion page;
// the note keeps its narrow reading column (.present-wrap) inside <main>. The back-links (crumb, Notes,
// edit) sit on the right. `chrome:false` drops header/sidebar/footer + the script entirely — used by the
// composer's inline preview, whose own header already covers it (no duplicate, stays clean).
export function presentLayout(title, main, { scope = "", id = "", chrome = true, projects = [], tags = [] } = {}) {
  const headLinks = `<link rel="stylesheet" href="/style.css?v=${ASSET_V}"><link rel="stylesheet" href="/katex/katex.min.css">`;
  if (!chrome) {
    return `<!doctype html><html lang="ja"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>${headLinks}</head>
<body class="present-body present-bare"><div class="present-wrap">${main}</div></body></html>`;
  }
  return `<!doctype html><html lang="ja"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>${headLinks}<script src="/app.js?v=${ASSET_V}" defer></script></head>
<body class="present-body">
<header class="present-head"><button class="hamburger" type="button" aria-label="toggle sidebar" title="menu">☰</button><a class="brand" href="/">Archeion</a>
<form action="/search" method="get" class="search"><input name="q" placeholder="search projects…" autocomplete="off"></form>
<nav class="present-nav">${scope ? `<a class="present-crumb" href="/p/${rid(scope)}">${esc(scope)}</a>` : ""}<a href="/notes">📝 Notes</a>${id ? `<a class="present-edit" href="/compose?id=${id}">edit ✎</a>` : ""}</nav></header>
<div class="wrap">${sideNav({ projects, tags })}<main><div class="present-wrap">${main}
<footer class="present-foot">${scope ? `${esc(scope)} · ` : ""}Archeion</footer></div></main></div></body></html>`;
}
