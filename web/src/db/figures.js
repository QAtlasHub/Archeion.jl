// Figures = the figure recall axis: the gallery query + the shared figure-importance write-back.
import { FIG, clampImp } from "./util.js";

export function figuresGallery(db, { project = null, limit = 160, includeArchived = false, sort = "importance" } = {}) {
  let sql = `SELECT ${FIG} FROM figures f JOIN records r ON r.id = f.record_id WHERE 1=1`;
  const args = [];
  includeArchived || (sql += " AND r.archived = 0");
  if (project) {
    sql += " AND r.project = ?";
    args.push(project);
  }
  const order = sort === "date"
    ? "COALESCE(NULLIF(r.date,''), r.updated_at) DESC, f.importance DESC"
    : "f.importance DESC, r.updated_at DESC";
  sql += ` ORDER BY ${order} LIMIT ?`;
  args.push(limit);
  return db.prepare(sql).all(...args);
}

export function setFigureImportance(db, figId, value) {
  return db.prepare("UPDATE figures SET importance = ? WHERE id = ?").run(clampImp(value), figId)
    .changes;
}
