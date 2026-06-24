// Tags = the shared #tag vocabulary on records. The sidebar shows only tags actually in use.
import { cleanTag } from "./util.js";

export function tags(db) {
  // only tags actually in use (an orphan tag, removed from its last record, drops out of the sidebar)
  return db
    .prepare("SELECT DISTINCT t.name FROM tags t JOIN record_tags rt ON rt.tag_id = t.id ORDER BY t.name")
    .all()
    .map((r) => r.name);
}

export function addTag(db, recordId, name) {
  name = cleanTag(name);
  if (!name) return;
  db.prepare("INSERT OR IGNORE INTO tags (name) VALUES (?)").run(name);
  const tid = db.prepare("SELECT id FROM tags WHERE name = ?").get(name).id;
  db.prepare("INSERT OR IGNORE INTO record_tags (record_id, tag_id) VALUES (?,?)").run(recordId, tid);
  db.prepare("UPDATE records SET updated_at = datetime('now') WHERE id = ?").run(recordId);
}

export function removeTag(db, recordId, name) {
  name = cleanTag(name);
  if (!name) return;
  db.prepare(
    "DELETE FROM record_tags WHERE record_id = ? AND tag_id = (SELECT id FROM tags WHERE name = ?)",
  ).run(recordId, name);
  db.prepare("UPDATE records SET updated_at = datetime('now') WHERE id = ?").run(recordId);
}
