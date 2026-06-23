// Read-only access to the registry SQLite DB (the one Archeion.jl ingests).
// The web app only reads here in P1; write-back (comments/tags/status) comes later.
import Database from "better-sqlite3";

export function openDb(path) {
  const db = new Database(path, { readonly: true, fileMustExist: true });
  db.pragma("foreign_keys = ON");
  return db;
}

const CARD_COLS =
  "id, project, run, title, date, status, tags, pinned, updated_at";

// "Current changes": most recent by completion date, falling back to ingest time.
export function recents(db, limit = 60) {
  return db
    .prepare(
      `SELECT ${CARD_COLS} FROM records
       ORDER BY COALESCE(NULLIF(date,''), updated_at) DESC LIMIT ?`,
    )
    .all(limit);
}

export function pinned(db) {
  return db
    .prepare(
      `SELECT ${CARD_COLS} FROM records WHERE pinned = 1
       ORDER BY COALESCE(NULLIF(date,''), updated_at) DESC`,
    )
    .all();
}

export function filterRecords(db, { status, tag } = {}, limit = 200) {
  let sql = `SELECT ${CARD_COLS} FROM records WHERE 1=1`;
  const args = [];
  if (status) {
    sql += " AND status = ?";
    args.push(status);
  }
  if (tag) {
    sql += " AND tags LIKE ?";
    args.push(`%"${tag}"%`); // tags is a JSON array string
  }
  sql += " ORDER BY COALESCE(NULLIF(date,''), updated_at) DESC LIMIT ?";
  args.push(limit);
  return db.prepare(sql).all(...args);
}

export function getRecord(db, id) {
  return db.prepare("SELECT * FROM records WHERE id = ?").get(id);
}

// FTS5 search over title/tags/body_md. Each whitespace token is quoted (implicit AND),
// so user input can't inject FTS operators; matches are wrapped with \x02..\x03 for the
// renderer to turn into <mark> after HTML-escaping.
export function search(db, q, limit = 60) {
  const terms = q
    .split(/\s+/)
    .filter(Boolean)
    .map((t) => `"${t.replace(/"/g, '""')}"`)
    .join(" ");
  if (!terms) return [];
  try {
    return db
      .prepare(
        `SELECT r.id, r.project, r.run, r.title, r.date, r.status, r.tags,
                snippet(records_fts, 2, char(2), char(3), '…', 14) AS snip
         FROM records_fts JOIN records r ON r.rowid = records_fts.rowid
         WHERE records_fts MATCH ? ORDER BY rank LIMIT ?`,
      )
      .all(terms, limit);
  } catch {
    return [];
  }
}

export function facets(db) {
  const statuses = db
    .prepare(
      "SELECT DISTINCT status FROM records WHERE status IS NOT NULL AND status <> '' ORDER BY status",
    )
    .all()
    .map((r) => r.status);
  const tagSet = new Set();
  for (const r of db.prepare("SELECT tags FROM records").all()) {
    try {
      for (const t of JSON.parse(r.tags || "[]")) tagSet.add(t);
    } catch {
      /* ignore malformed tags */
    }
  }
  return { statuses, tags: [...tagSet].sort() };
}
