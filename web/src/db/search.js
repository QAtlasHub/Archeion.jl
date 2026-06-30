// Field-aware search (per-field; default ALL). Query terms are AND'd: a record/project/figure
// matches when EVERY term appears in the concatenation of its SELECTED fields. Concatenated FTS is
// off so Title / description / fig title / caption (etc.) are independently selectable; results
// order by recency, the snippet is ours.
import { REC, FIG } from "./util.js";
import { FIELD_VALUES } from "../constants.js";

//  /  are private highlight sentinels around the matched term; render/snipHtml turns
// them into <mark>…</mark> after escaping (so the markup can't come from the data itself).
const MARK_A = "", MARK_B = "";
function _snippet(text, term) {
  text = String(text || "").replace(/\s+/g, " ").trim();
  const i = term ? text.toLowerCase().indexOf(term.toLowerCase()) : -1;
  if (i < 0) return text.slice(0, 120);
  const a = Math.max(0, i - 40);
  return (a ? "…" : "") + text.slice(a, i) + MARK_A + text.slice(i, i + term.length) + MARK_B +
    text.slice(i + term.length, i + term.length + 70) + (i + term.length + 70 < text.length ? "…" : "");
}

// figure "title" = its Pinax id/name (the label after the "<record-id>:" prefix in the figure id).
const figName = (id) => { const s = String(id || ""); return s.slice(s.lastIndexOf(":") + 1); };
// captions are their OWN search field now → strip them from a record's description haystack.
const _noCaptions = (body, caps) => { let t = String(body || ""); for (const c of caps || []) if (c) t = t.split(c).join(" "); return t; };

// scoped search (within one project): Pinax records (by record fields) + figures (by fig title / caption)
export function search(db, q, { limit = 80, project = null, fields = FIELD_VALUES } = {}) {
  const terms = String(q || "").toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return { records: [], figures: [] };
  const F = new Set(fields);
  const tagByRec = {}, cmtByRec = {}, capByRec = {};
  for (const r of db.prepare("SELECT rt.record_id AS id, t.name FROM record_tags rt JOIN tags t ON t.id = rt.tag_id").all())
    (tagByRec[r.id] ||= []).push(r.name);
  for (const c of db.prepare("SELECT record_id AS id, body_md FROM annotations").all())
    (cmtByRec[c.id] ||= []).push(c.body_md);
  for (const f of db.prepare("SELECT record_id AS id, caption FROM figures").all())
    (capByRec[f.id] ||= []).push(f.caption);
  const recs = db.prepare(`SELECT ${REC}, r.body_md FROM records r ${project ? "WHERE r.project = ?" : ""}`).all(...(project ? [project] : []));
  const records = [];
  for (const r of recs) {
    const parts = [];
    F.has("title") && parts.push(r.title);
    F.has("description") && parts.push(_noCaptions(r.body_md, capByRec[r.id])); // captions excluded — own field
    F.has("date") && parts.push(r.date);
    F.has("tag") && parts.push((tagByRec[r.id] || []).join(" "));
    F.has("comment") && parts.push((cmtByRec[r.id] || []).join(" "));
    const text = parts.join("  ·  ");
    if (terms.every((t) => text.toLowerCase().includes(t))) records.push({ ...r, snip: _snippet(text, terms[0]) });
    if (records.length >= limit) break;
  }
  // figures match on their OWN fields: fig title (the figure's name/id) and/or its caption
  const figs = db.prepare(`SELECT ${FIG} FROM figures f JOIN records r ON r.id = f.record_id${project ? " WHERE r.project = ?" : ""}`).all(...(project ? [project] : []));
  const figures = [];
  for (const f of figs) {
    const fp = [];
    F.has("figtitle") && fp.push(figName(f.id));
    F.has("figcaption") && fp.push(f.caption);
    if (!fp.length) continue; // neither figure field selected ⇒ figures don't match
    const h = fp.join("  ·  ").toLowerCase();
    if (terms.every((t) => h.includes(t))) figures.push({ ...f, snip: _snippet(f.caption || figName(f.id), terms[0]) });
    if (figures.length >= limit) break;
  }
  return { records, figures };
}

// project search (from HOME): a project matches when every term is in its SELECTED fields — 'title' =
// project name + record titles; description = project desc + record bodies (captions excluded);
// figtitle / figcaption = the project's figures; tag / todo / date / comment likewise.
export function searchProjects(db, q, { limit = 80, fields = FIELD_VALUES } = {}) {
  const terms = String(q || "").toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return [];
  const F = new Set(fields);
  const hay = {}; // project → concatenation of its SELECTED field text (each part gated as it's added)
  const add = (proj, v) => { if (proj && v) hay[proj] = (hay[proj] || "") + " " + v; };
  const cap = {};
  if (F.has("description")) // captions live inside body_md; strip them since they're their own field
    for (const f of db.prepare("SELECT record_id AS id, caption FROM figures").all()) (cap[f.id] ||= []).push(f.caption);
  if (F.has("title") || F.has("description") || F.has("date"))
    for (const r of db.prepare("SELECT id, project, title, body_md, date FROM records").all()) {
      F.has("title") && add(r.project, r.title);
      F.has("description") && add(r.project, _noCaptions(r.body_md, cap[r.id]));
      F.has("date") && add(r.project, r.date);
    }
  if (F.has("comment"))
    for (const c of db.prepare("SELECT r.project, c.body_md FROM annotations c JOIN records r ON r.id = c.record_id").all())
      add(c.project, c.body_md);
  if (F.has("tag"))
    for (const r of db.prepare("SELECT pt.project, t.name FROM project_tags pt JOIN tags t ON t.id = pt.tag_id").all())
      add(r.project, r.name);
  if (F.has("todo"))
    for (const r of db.prepare("SELECT project, body FROM project_todos").all()) add(r.project, r.body);
  if (F.has("figtitle") || F.has("figcaption"))
    for (const f of db.prepare("SELECT r.project, f.id, f.caption FROM figures f JOIN records r ON r.id = f.record_id").all()) {
      F.has("figtitle") && add(f.project, figName(f.id));
      F.has("figcaption") && add(f.project, f.caption);
    }
  const names = [];
  for (const p of db.prepare("SELECT name, description FROM projects").all()) {
    const parts = [hay[p.name] || ""];
    F.has("title") && parts.push(p.name); // a project's name IS its title (so 'title' off ⇒ no name match)
    F.has("description") && parts.push(p.description); // the project's own (hand-written) description
    const h = parts.join(" ").toLowerCase();
    if (terms.every((t) => h.includes(t))) names.push(p.name);
  }
  if (!names.length) return [];
  const ph = names.map(() => "?").join(",");
  return db.prepare(
    `SELECT p.name AS project, p.para, p.description, COUNT(r.id) AS n
       FROM projects p LEFT JOIN records r ON r.project = p.name AND r.archived = 0
       WHERE p.name IN (${ph}) GROUP BY p.name ORDER BY p.name LIMIT ?`,
  ).all(...names, limit);
}
