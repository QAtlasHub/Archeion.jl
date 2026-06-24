// Projects = the PARA root + the project meta property panel (status / description / tags / todos /
// derived dates). All of this is app-owned annotation; ingest only ensures the project row exists.
import { PARA } from "../constants.js";
import { cleanTag } from "./util.js";

// projects (the PARA root) with their bucket + live record count
export function projects(db) {
  return db
    .prepare(
      `SELECT p.name AS project, p.para, COUNT(r.id) AS n
       FROM projects p LEFT JOIN records r ON r.project = p.name AND r.archived = 0
       GROUP BY p.name ORDER BY p.name`,
    )
    .all();
}
export function projectsByPara(db) {
  const groups = Object.fromEntries(PARA.map((b) => [b, []]));
  for (const p of projects(db)) (groups[p.para] || (groups[p.para] = [])).push(p);
  return groups;
}
export function activeProjects(db) {
  return projects(db).filter((p) => p.para === "Projects");
}
export function getProject(db, name) {
  return db.prepare("SELECT name, para, description FROM projects WHERE name = ?").get(name);
}
export function setProjectPara(db, name, para) {
  if (!PARA.includes(para)) return 0;
  db.prepare("INSERT OR IGNORE INTO projects (name) VALUES (?)").run(name);
  return db
    .prepare("UPDATE projects SET para = ?, updated_at = datetime('now') WHERE name = ?")
    .run(para, name).changes;
}
// project-level meta: the editable description (project "front matter"); markdown
export function setProjectDescription(db, name, description) {
  db.prepare("INSERT OR IGNORE INTO projects (name) VALUES (?)").run(name);
  return db
    .prepare("UPDATE projects SET description = ?, updated_at = datetime('now') WHERE name = ?")
    .run(String(description || ""), name).changes;
}

// ---- project meta property panel: derived dates + project tags + todos ----
const touchProject = (db, name) => {
  db.prepare("INSERT OR IGNORE INTO projects (name) VALUES (?)").run(name);
  db.prepare("UPDATE projects SET updated_at = datetime('now') WHERE name = ?").run(name);
};
export function projectMeta(db, name) {
  const p = db.prepare("SELECT name, para, description, updated_at FROM projects WHERE name = ?").get(name);
  if (!p) return null;
  const created = db.prepare("SELECT MIN(created_at) AS c FROM records WHERE project = ?").get(name)?.c || p.updated_at;
  const tags = db
    .prepare("SELECT t.name FROM tags t JOIN project_tags pt ON pt.tag_id = t.id WHERE pt.project = ? ORDER BY t.name")
    .all(name).map((r) => r.name);
  const todos = db.prepare("SELECT id, body, done FROM project_todos WHERE project = ? ORDER BY done, ord, id").all(name);
  return { ...p, created, tags, todos };
}
export function addProjectTag(db, project, name) {
  name = cleanTag(name); if (!name) return;
  db.prepare("INSERT OR IGNORE INTO tags (name) VALUES (?)").run(name);
  const tid = db.prepare("SELECT id FROM tags WHERE name = ?").get(name).id;
  db.prepare("INSERT OR IGNORE INTO project_tags (project, tag_id) VALUES (?,?)").run(project, tid);
  touchProject(db, project);
}
export function removeProjectTag(db, project, name) {
  name = cleanTag(name); if (!name) return;
  db.prepare("DELETE FROM project_tags WHERE project = ? AND tag_id = (SELECT id FROM tags WHERE name = ?)").run(project, name);
  touchProject(db, project);
}
export function addTodo(db, project, body) {
  body = String(body || "").trim(); if (!body) return null;
  const ord = db.prepare("SELECT COALESCE(MAX(ord),0)+1 AS n FROM project_todos WHERE project = ?").get(project).n;
  const info = db.prepare("INSERT INTO project_todos (project, body, ord) VALUES (?,?,?)").run(project, body, ord);
  touchProject(db, project);
  return info.lastInsertRowid;
}
export function toggleTodo(db, id) {
  const p = db.prepare("SELECT project FROM project_todos WHERE id = ?").get(id);
  db.prepare("UPDATE project_todos SET done = 1 - done WHERE id = ?").run(id);
  if (p) touchProject(db, p.project);
}
export function removeTodo(db, id) {
  const p = db.prepare("SELECT project FROM project_todos WHERE id = ?").get(id);
  db.prepare("DELETE FROM project_todos WHERE id = ?").run(id);
  if (p) touchProject(db, p.project);
}
