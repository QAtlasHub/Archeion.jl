// Per-user write-back: users, bookmarks (record OR figure), and discussion comments. These are the
// app-owned annotation tables; re-ingest never touches them.
import { REC, FIG } from "./util.js";

export function ensureUser(db, name) {
  const n = name && name.trim() ? name.trim() : "anon";
  db.prepare("INSERT OR IGNORE INTO users (name) VALUES (?)").run(n);
  return db.prepare("SELECT id FROM users WHERE name = ?").get(n).id;
}

// per-user bookmark of a record OR figure (toggle); returns the new state (true=bookmarked)
export function toggleBookmark(db, userId, kind, targetId) {
  const ex = db
    .prepare("SELECT 1 FROM bookmarks WHERE user_id=? AND target_kind=? AND target_id=?")
    .get(userId, kind, targetId);
  if (ex) {
    db.prepare("DELETE FROM bookmarks WHERE user_id=? AND target_kind=? AND target_id=?").run(
      userId, kind, targetId,
    );
    return false;
  }
  db.prepare("INSERT INTO bookmarks (user_id, target_kind, target_id) VALUES (?,?,?)").run(
    userId, kind, targetId,
  );
  return true;
}
export function bookmarkedSet(db, userId) {
  const s = new Set();
  for (const b of db
    .prepare("SELECT target_kind, target_id FROM bookmarks WHERE user_id=?")
    .all(userId)) {
    s.add(b.target_kind + ":" + b.target_id);
  }
  return s;
}
export function userBookmarks(db, userId) {
  const records = db
    .prepare(
      `SELECT ${REC} FROM bookmarks b JOIN records r ON r.id = b.target_id
       WHERE b.user_id=? AND b.target_kind='record' ORDER BY b.added_at DESC`,
    )
    .all(userId);
  const figures = db
    .prepare(
      `SELECT ${FIG} FROM bookmarks b JOIN figures f ON f.id = b.target_id
       JOIN records r ON r.id = f.record_id
       WHERE b.user_id=? AND b.target_kind='figure' ORDER BY b.added_at DESC`,
    )
    .all(userId);
  return { records, figures };
}

// ── unified comments + annotations: every one carries its LOCATION ──────────────────────────────────
// One table (`annotations`) holds the record discussion + figure/section/passage notes; the location is
// (target_kind, page, target_id, anchor). All server-side (no localStorage "unsaved"); searchable; the
// comment list + where each points is traceable from this one table.
const _safeParse = (s) => { try { return JSON.parse(s || "{}"); } catch { return {}; } };

export function addAnnotation(db, recordId, { kind = "record", page = "", targetId = "", anchor = null } = {}, userId, bodyMd) {
  bodyMd = String(bodyMd || "").trim();
  if (!bodyMd) return null;
  if (kind === "passage" && !(anchor && anchor.exact)) return null; // a passage must carry a text anchor
  const anchorJson = anchor
    ? JSON.stringify({ exact: String(anchor.exact || ""), prefix: String(anchor.prefix || ""), suffix: String(anchor.suffix || "") })
    : "";
  const id = db
    .prepare("INSERT INTO annotations (record_id, target_kind, page, target_id, anchor, user_id, body_md) VALUES (?,?,?,?,?,?,?)")
    .run(recordId, kind, String(page || ""), String(targetId || ""), anchorJson, userId ?? null, bodyMd).lastInsertRowid;
  db.prepare("INSERT INTO search_fts (text, kind, id, record_id) VALUES (?,?,?,?)").run(bodyMd, "comment", String(id), recordId);
  db.prepare("UPDATE records SET updated_at = datetime('now') WHERE id = ?").run(recordId);
  return id;
}

// list a record's annotations, optionally filtered by kind and/or page; anchor parsed back to an object
export function recordAnnotations(db, recordId, { kind = null, page = null } = {}) {
  let sql =
    "SELECT a.id, a.target_kind, a.page, a.target_id, a.anchor, a.user_id, a.body_md, a.created_at, " +
    "COALESCE(u.name,'anon') AS author FROM annotations a LEFT JOIN users u ON u.id = a.user_id WHERE a.record_id = ?";
  const args = [recordId];
  if (kind !== null) { sql += " AND a.target_kind = ?"; args.push(kind); }
  if (page !== null) { sql += " AND a.page = ?"; args.push(String(page)); }
  sql += " ORDER BY a.id";
  return db.prepare(sql).all(...args).map((a) => ({ ...a, anchor: a.anchor ? _safeParse(a.anchor) : null }));
}
export function getAnnotation(db, id) {
  return db.prepare("SELECT id, record_id, target_kind, user_id FROM annotations WHERE id = ?").get(id);
}
export function removeAnnotation(db, id) {
  db.prepare("DELETE FROM search_fts WHERE kind='comment' AND id = ?").run(String(id));
  return db.prepare("DELETE FROM annotations WHERE id = ?").run(id).changes;
}

// compat wrappers for the record-level Discussion (callers unchanged; now backed by `annotations`)
export function addComment(db, recordId, userId, bodyMd) {
  return addAnnotation(db, recordId, { kind: "record" }, userId, bodyMd);
}
export function recordComments(db, recordId) {
  return recordAnnotations(db, recordId, { kind: "record" });
}
