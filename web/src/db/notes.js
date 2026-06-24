// Notes = free-form Zettelkasten layer (app-owned). A note is scoped to a project (scope = slug) or
// global (scope = ""). A PINNED note is a "structure note" — a curated, advisor-facing page shown
// clean at /show/:id. body_md carries two link forms:
//   [[target]]   = a mention/link to a project or record (resolveMentions classifies it)
//   ![[target]]  = an EMBED (transclusion): a figure inline, or a record's figures (resolveEmbeds)
// so the human can compose one presentation page without teaching anyone to navigate the app.
import { cleanTag } from "./util.js";

// [[x]] but NOT ![[x]] (those are embeds) — deduped, trimmed
export const parseMentions = (body) => {
  const out = []; const re = /(?<!!)\[\[([^\]]+)\]\]/g; let m;
  while ((m = re.exec(String(body || "")))) out.push(m[1].trim());
  return [...new Set(out.filter(Boolean))];
};
// ![[x]] embeds
export const parseEmbeds = (body) => {
  const out = []; const re = /!\[\[([^\]]+)\]\]/g; let m;
  while ((m = re.exec(String(body || "")))) out.push(m[1].trim());
  return [...new Set(out.filter(Boolean))];
};

// classify each mention target against the live registry: a record id, a project name, or unresolved
export function resolveMentions(db, targets) {
  return (targets || []).map((t) => {
    if (db.prepare("SELECT 1 FROM records WHERE id = ?").get(t)) return { target: t, kind: "record", ref: `/r/${t}` };
    if (db.prepare("SELECT 1 FROM projects WHERE name = ?").get(t)) return { target: t, kind: "project", ref: `/p/${t}` };
    return { target: t, kind: "unresolved", ref: null };
  });
}
// resolve an embed target to a figure / a section / a record (+ its figures). Every kind also carries
// the source record id so the rendered block can link to its Pinax page.
export function resolveEmbeds(db, targets) {
  return (targets || []).map((t) => {
    const hash = t.indexOf("#");
    if (hash >= 0) { // "<record>#<section title>" — a section block
      const record = t.slice(0, hash), label = t.slice(hash + 1);
      const r = db.prepare("SELECT id, title FROM records WHERE id = ?").get(record);
      return { target: t, kind: "section", label, record: r || { id: record, title: record } };
    }
    const figure = db.prepare("SELECT id, path, thumbnail, caption FROM figures WHERE id = ?").get(t);
    if (figure) return { target: t, kind: "figure", figure, record: t.slice(0, t.indexOf(":")) };
    const rec = db.prepare("SELECT id, title, project, date, importance, body_md FROM records WHERE id = ?").get(t);
    if (rec) {
      const figures = db.prepare("SELECT id, path, thumbnail, caption FROM figures WHERE record_id = ? ORDER BY ord").all(t);
      const tags = db.prepare("SELECT t.name FROM tags t JOIN record_tags rt ON rt.tag_id = t.id WHERE rt.record_id = ? ORDER BY t.name").all(t).map((r) => r.name);
      const runs = db.prepare("SELECT COUNT(*) AS n FROM record_runs WHERE record_id = ?").get(t).n;
      // contents = the ## / ### headings of the record's body_md (= page / section titles)
      const headings = String(rec.body_md || "").split("\n")
        .filter((l) => /^#{2,3}\s/.test(l)).map((l) => ({ level: l.startsWith("### ") ? 3 : 2, text: l.replace(/^#{2,3}\s+/, "").trim() }));
      return { target: t, kind: "record", record: { id: rec.id, title: rec.title, project: rec.project, date: rec.date, importance: rec.importance, tags, figures, runs }, headings };
    }
    return { target: t, kind: "unresolved" };
  });
}

const withLinks = (db, n) => ({
  ...n,
  tags: noteTags(db, n.id),
  mentions: resolveMentions(db, parseMentions(n.body_md)),
  embeds: resolveEmbeds(db, parseEmbeds(n.body_md)),
});

const NOTECOLS = "id, scope, title, body_md, pinned, importance, description, archived, created_at, updated_at";
// project page = active (non-archived) notes only; the global /notes page gets everything and splits.
export function listNotes(db, scope) {
  return db
    .prepare(`SELECT ${NOTECOLS} FROM notes WHERE scope = ? AND archived = 0 ORDER BY importance DESC, updated_at DESC`)
    .all(String(scope ?? ""));
}
export function allNotes(db, { limit = 500 } = {}) {
  return db
    .prepare(`SELECT ${NOTECOLS} FROM notes ORDER BY pinned DESC, importance DESC, updated_at DESC LIMIT ?`)
    .all(limit);
}
// notes with mentions + embeds attached — for rendering and the present view
export function notesForDisplay(db, scope) { return listNotes(db, scope).map((n) => withLinks(db, n)); }
export function allNotesForDisplay(db) { return allNotes(db).map((n) => withLinks(db, n)); }
export function noteForDisplay(db, id) { const n = getNote(db, id); return n ? withLinks(db, n) : null; }
export function pinnedNotes(db) { return allNotes(db).filter((n) => n.pinned).map((n) => withLinks(db, n)); }

export function getNote(db, id) {
  return db.prepare("SELECT * FROM notes WHERE id = ?").get(id);
}
const clampImp = (v) => Math.max(0, Math.min(3, parseInt(v, 10) || 0));
export function addNote(db, scope, title, body, { importance = 0, pinned = 0, description = "" } = {}) {
  body = String(body || "").trim();
  if (!body) return null;
  return db
    .prepare("INSERT INTO notes (scope, title, body_md, importance, pinned, description) VALUES (?,?,?,?,?,?)")
    .run(String(scope || ""), String(title || "").trim(), body, clampImp(importance), pinned ? 1 : 0, String(description || "")).lastInsertRowid;
}
// update title/body always; importance/description only when provided (the inline note-card edit omits them)
export function updateNote(db, id, title, body, opts = {}) {
  const sets = ["title = ?", "body_md = ?", "updated_at = datetime('now')"];
  const args = [String(title || "").trim(), String(body || "")];
  if (opts.importance !== undefined) { sets.push("importance = ?"); args.push(clampImp(opts.importance)); }
  if (opts.description !== undefined) { sets.push("description = ?"); args.push(String(opts.description || "")); }
  args.push(id);
  return db.prepare(`UPDATE notes SET ${sets.join(", ")} WHERE id = ?`).run(...args).changes;
}
export function removeNote(db, id) {
  return db.prepare("DELETE FROM notes WHERE id = ?").run(id).changes;
}
// note tags (reuse the shared `tags` vocabulary); setNoteTags replaces the whole set (composer saves all at once)
export function noteTags(db, id) {
  return db.prepare("SELECT t.name FROM tags t JOIN note_tags nt ON nt.tag_id = t.id WHERE nt.note_id = ? ORDER BY t.name").all(id).map((r) => r.name);
}
export function setNoteTags(db, id, names) {
  db.prepare("DELETE FROM note_tags WHERE note_id = ?").run(id);
  for (const raw of names || []) {
    const name = cleanTag(raw); if (!name) continue;
    db.prepare("INSERT OR IGNORE INTO tags (name) VALUES (?)").run(name);
    const tid = db.prepare("SELECT id FROM tags WHERE name = ?").get(name).id;
    db.prepare("INSERT OR IGNORE INTO note_tags (note_id, tag_id) VALUES (?,?)").run(id, tid);
  }
}
// pin/unpin = mark a note as a structure note (advisor-facing page)
export function setPinned(db, id, on) {
  const n = db.prepare("SELECT 1 FROM notes WHERE id = ?").get(id);
  if (!n) return false;
  db.prepare("UPDATE notes SET pinned = ?, updated_at = datetime('now') WHERE id = ?").run(on ? 1 : 0, id);
  return true;
}
// comments / annotations on a note (shown on the "open" view /note/:id)
export function addNoteComment(db, noteId, userId, bodyMd) {
  bodyMd = String(bodyMd || "").trim();
  if (!bodyMd) return null;
  const id = db.prepare("INSERT INTO note_comments (note_id, user_id, body_md) VALUES (?,?,?)").run(noteId, userId ?? null, bodyMd).lastInsertRowid;
  db.prepare("UPDATE notes SET updated_at = datetime('now') WHERE id = ?").run(noteId);
  return id;
}
export function noteComments(db, noteId) {
  return db
    .prepare("SELECT c.id, c.body_md, c.created_at, COALESCE(u.name,'anon') AS author FROM note_comments c LEFT JOIN users u ON u.id = c.user_id WHERE c.note_id = ? ORDER BY c.id")
    .all(noteId);
}
// archive/unarchive = move a note out of the active list (still in search / the archived section)
export function setNoteArchived(db, id, on) {
  const n = db.prepare("SELECT 1 FROM notes WHERE id = ?").get(id);
  if (!n) return false;
  db.prepare("UPDATE notes SET archived = ?, updated_at = datetime('now') WHERE id = ?").run(on ? 1 : 0, id);
  return true;
}

// backlinks: notes that mention a given target (project name or record id)
export function notesMentioning(db, target, { limit = 100 } = {}) {
  return db
    .prepare("SELECT id, scope, title, body_md, updated_at FROM notes WHERE body_md LIKE ? ORDER BY updated_at DESC LIMIT ?")
    .all(`%[[${target}]]%`, limit);
}
