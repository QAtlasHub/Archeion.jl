// The page shell: <head> (asset links), the sticky header (hamburger + brand + scoped search form
// with the field selector), the PARA/tags sidebar, and the <main> slot. Every page calls layout().
import { esc, rid, ASSET_V } from "./util.js";
import { PARA } from "../constants.js";
import { fieldSelector } from "./components.js";

export function layout(title, main, { q = "", user = "", projects = [], tags = [], scope = "", fields = [] } = {}) {
  const groups = {};
  for (const p of projects) (groups[p.para] ||= []).push(p);
  const projLink = (p) => `<a href="/p/${rid(p.project)}">${esc(p.project)} <span class="n">${p.n}</span></a>`;
  const paraSections =
    PARA.filter((b) => (groups[b] || []).length)
      .map((b) => `<h3>${b}</h3><div class="projects">${groups[b].map(projLink).join("")}</div>`)
      .join("") || `<span class="empty">no projects</span>`;
  const tagLinks = tags.map((t) => `<a href="/?tag=${encodeURIComponent(t)}">#${esc(t)}</a>`).join(" ");
  return `<!doctype html><html lang="ja"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><link rel="stylesheet" href="/style.css?v=${ASSET_V}"><script src="/app.js?v=${ASSET_V}" defer></script></head><body>
<header><button class="hamburger" type="button" aria-label="toggle sidebar" title="menu">☰</button><a href="/" class="brand">Archeion</a>
<form action="/search" method="get" class="search">${scope ? `<input type="hidden" name="project" value="${esc(scope)}">` : ""}${fieldSelector(fields)}<input name="q" value="${esc(q)}" placeholder="${scope ? `search in ${esc(scope)} (figures &amp; Pinax)…` : "search projects…"}" autocomplete="off"></form>
<span class="who">${esc(user)}</span></header>
<div class="wrap"><nav class="side">
  <a class="navitem" href="/gallery">🖼 Figures</a>
  <a class="navitem" href="/bookmarks">★ Bookmarks</a>
  <a class="navitem" href="/archived">🗄 Archived</a>
  ${paraSections}
  <h3>Tags</h3><div class="tags">${tagLinks || "<span class=empty>—</span>"}</div>
</nav><main>${main}</main></div></body></html>`;
}
