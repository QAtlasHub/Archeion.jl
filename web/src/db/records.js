// Records = the experiment recall axis: list/queries + the per-record detail reads + the shared
// write-back (importance / archive). One record = one Pinax generation-source.
import { REC, recOrder, clampImp } from "./util.js";

// "Current changes": most recent (by experiment date, falling back to ingest/update time).
export function recents(db, { limit = 60, includeArchived = false } = {}) {
  const arch = includeArchived ? "" : "WHERE r.archived = 0";
  return db
    .prepare(
      `SELECT ${REC} FROM records r ${arch}
       ORDER BY COALESCE(NULLIF(r.date,''), r.updated_at) DESC LIMIT ?`,
    )
    .all(limit);
}

export function byProject(db, project, { limit = 500, includeArchived = false, sort = "date" } = {}) {
  const arch = includeArchived ? "" : " AND r.archived = 0";
  return db
    .prepare(`SELECT ${REC} FROM records r WHERE r.project = ?${arch} ORDER BY ${recOrder(sort)} LIMIT ?`)
    .all(project, limit);
}

// archived records of a project — the collapsible "🗄 Archived (N)" section on the project page
export function archivedByProject(db, project, { limit = 500 } = {}) {
  return db
    .prepare(
      `SELECT ${REC} FROM records r WHERE r.project = ? AND r.archived = 1
       ORDER BY COALESCE(NULLIF(r.date,''), r.updated_at) DESC LIMIT ?`,
    )
    .all(project, limit);
}

// all archived records across projects — the global "🗄 Archived" view
export function archivedRecords(db, { limit = 500 } = {}) {
  return db
    .prepare(`SELECT ${REC} FROM records r WHERE r.archived = 1 ORDER BY r.updated_at DESC LIMIT ?`)
    .all(limit);
}

// tag view INCLUDES archived (marked) — archiving declutters active views but never loses findability
export function byTag(db, tag, { limit = 500 } = {}) {
  return db
    .prepare(
      `SELECT ${REC} FROM records r
       JOIN record_tags rt ON rt.record_id = r.id JOIN tags t ON t.id = rt.tag_id
       WHERE t.name = ?
       ORDER BY COALESCE(NULLIF(r.date,''), r.updated_at) DESC LIMIT ?`,
    )
    .all(tag, limit);
}

export function getRecord(db, id) {
  return db.prepare("SELECT * FROM records WHERE id = ?").get(id);
}
export function recordFigures(db, recordId) {
  return db
    .prepare(
      "SELECT id, ord, path, thumbnail, caption, importance FROM figures WHERE record_id = ? ORDER BY ord",
    )
    .all(recordId);
}
export function recordRuns(db, recordId) {
  return db
    .prepare(
      "SELECT project, run, datavault_ref FROM record_runs WHERE record_id = ? ORDER BY project, run",
    )
    .all(recordId);
}
export function recordTags(db, recordId) {
  return db
    .prepare(
      "SELECT t.name FROM tags t JOIN record_tags rt ON rt.tag_id = t.id WHERE rt.record_id = ? ORDER BY t.name",
    )
    .all(recordId)
    .map((r) => r.name);
}
// (recordComments lives in db/annotations.js now — the record discussion is target_kind='record'
//  rows of the unified `annotations` table.)

// recent activity (replaces per-user unread/read-later): newest records + newest record-discussion notes
export function recentActivity(db, { limit = 30 } = {}) {
  const records = db
    .prepare(`SELECT ${REC} FROM records r WHERE r.archived = 0 ORDER BY r.updated_at DESC LIMIT ?`)
    .all(limit);
  const comments = db
    .prepare(
      `SELECT c.record_id, c.body_md, c.created_at, COALESCE(u.name,'anon') AS author,
              r.title AS record_title, r.project
       FROM annotations c JOIN records r ON r.id = c.record_id LEFT JOIN users u ON u.id = c.user_id
       WHERE c.target_kind = 'record' AND r.archived = 0 ORDER BY c.id DESC LIMIT ?`,
    )
    .all(limit);
  return { records, comments };
}

export function setRecordImportance(db, id, value) {
  return db
    .prepare("UPDATE records SET importance = ?, updated_at = datetime('now') WHERE id = ?")
    .run(clampImp(value), id).changes;
}
export function setArchived(db, id, on) {
  return db
    .prepare("UPDATE records SET archived = ?, updated_at = datetime('now') WHERE id = ?")
    .run(on ? 1 : 0, id).changes;
}
