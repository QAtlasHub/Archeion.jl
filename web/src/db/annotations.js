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

export function addComment(db, recordId, userId, bodyMd) {
  const id = db
    .prepare("INSERT INTO comments (record_id, user_id, body_md) VALUES (?,?,?)")
    .run(recordId, userId, bodyMd).lastInsertRowid;
  db.prepare("INSERT INTO search_fts (text, kind, id, record_id) VALUES (?,?,?,?)").run(
    bodyMd, "comment", String(id), recordId,
  );
  db.prepare("UPDATE records SET updated_at = datetime('now') WHERE id = ?").run(recordId);
  return id;
}
