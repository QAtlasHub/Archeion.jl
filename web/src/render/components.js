// Reusable view fragments: the record/figure cards, the inline forms (bookmark, tag editor, sort,
// importance select), and the search-field selector. Each returns an HTML string. Data is escaped;
// only markdown bodies (rendered elsewhere) carry HTML.
import { esc, rid, stars, figUrl, isBk } from "./util.js";
import { SEARCH_FIELDS } from "../constants.js";

// importance picker (0..3 stars) — shared by the record control + per-figure annotation
export const impSelect = (name, current) =>
  `<select name="${name}">${[0, 1, 2, 3].map((n) => `<option value="${n}"${n === current ? " selected" : ""}>${stars(n)}</option>`).join("")}</select>`;

// sort toggle (date | importance) — `base` ends with "?" or "&"; the active option is highlighted
export function sortControl(base, current, param = "sort") {
  const cur = current === "importance" ? "importance" : "date";
  const opt = (k, label) => `<a class="sortopt${cur === k ? " on" : ""}" href="${base}${param}=${k}">${label}</a>`;
  return `<span class="sortctl">sort: ${opt("date", "date")} · ${opt("importance", "importance")}</span>`;
}

export function bookmarkForm(kind, id, bset) {
  const on = isBk(bset, kind, id);
  return `<form method="post" action="/bookmark" class="bk"><input type="hidden" name="kind" value="${kind}">
    <input type="hidden" name="id" value="${esc(id)}"><button class="${on ? "on" : ""}" title="bookmark">${on ? "★" : "☆"}</button></form>`;
}

// Obsidian-style tag chips: each #tag is a light-blue pill (a filter link) with an × remove form;
// a trailing "+ tag" input adds one (or several, space/comma-separated). No JS — plain forms.
export function tagEditor(recId, tags) {
  const chips = (tags || [])
    .map(
      (t) => `<span class="chip"><a href="/?tag=${encodeURIComponent(t)}">#${esc(t)}</a>` +
        `<form method="post" action="/tagdel"><input type="hidden" name="id" value="${esc(recId)}">` +
        `<input type="hidden" name="tag" value="${esc(t)}"><button title="remove">×</button></form></span>`,
    )
    .join("");
  return `<div class="tagrow">${chips}` +
    `<form method="post" action="/tagadd" class="chip-add"><input type="hidden" name="id" value="${esc(recId)}">` +
    `<input name="tag" placeholder="+ tag" autocomplete="off"><button title="add">+</button></form></div>`;
}

export function recordCard(r, bset) {
  const tags = (r.tags || []).map((t) => `<a class="tag" href="/?tag=${encodeURIComponent(t)}">#${esc(t)}</a>`).join(" ");
  const thumb = r.thumb
    ? `<a class="cardthumb" href="/r/${rid(r.id)}"><img loading="lazy" src="${esc(figUrl(r.thumb))}" alt=""></a>`
    : "";
  return `<div class="card${r.archived ? " arch" : ""}">
    ${thumb}
    <a class="title" href="/r/${rid(r.id)}">${esc(r.title)}</a>
    <div class="meta"><a class="proj" href="/p/${rid(r.project)}">${esc(r.project)}</a>
      <span class="imp" title="importance">${stars(r.importance || 0)}</span>
      <span class="date">${esc((r.date || "").slice(0, 10))}</span> ${tags}${r.archived ? ' <span class="badge arch-badge">🗄 archived</span>' : ""}</div>
    ${bookmarkForm("record", r.id, bset)}</div>`;
}

export function figureCard(f, bset, extraCls = "") {
  return `<figure class="figcard${extraCls ? " " + extraCls : ""}">
    <a href="/r/${rid(f.record_id)}"><img loading="lazy" src="${esc(figUrl(f.thumbnail || f.path))}" alt="${esc(f.caption)}"></a>
    <figcaption>${esc(f.caption)}
      <span class="imp">${stars(f.importance || 0)}</span>
      <a class="rt" href="/r/${rid(f.record_id)}">${esc(f.record_title || f.record_id)}</a>
      <a class="dl" href="${esc(figUrl(f.path))}" download title="download">⤓</a>
      ${bookmarkForm("figure", f.id, bset)}</figcaption></figure>`;
}

// the search-field selector (chips) shown inside the header search form; default = all checked
export function fieldSelector(fields) {
  const fset = new Set(fields && fields.length ? fields : SEARCH_FIELDS.map((f) => f[0]));
  const checks = SEARCH_FIELDS
    .map(([v, l]) => `<label class="fchip"><input type="checkbox" name="fields" value="${v}"${fset.has(v) ? " checked" : ""}><span>${l}</span></label>`)
    .join("");
  return `<details class="fieldsel"><summary title="search fields">fields</summary><div class="fieldopts">${checks}</div></details>`;
}
