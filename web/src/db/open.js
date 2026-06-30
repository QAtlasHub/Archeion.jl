// Open the registry DB. node:sqlite (Node 22+ builtin) — same code on panza (daemon) and Lolipop
// (node-as-CGI); needs --experimental-sqlite.
import { DatabaseSync } from "node:sqlite";

export function openDb(path) {
  const db = new DatabaseSync(path);
  // Rollback journal, NOT WAL. node-as-CGI spawns a fresh process per request, and Lolipop's
  // home dirs are on a network filesystem where WAL's shared-memory (-shm/mmap) doesn't work —
  // so a writer's commit sits invisibly in -wal and the redirect's reader process can't see it
  // ("nothing reflected"). DELETE writes straight to the main DB file, visible to the next
  // process immediately. Converts an existing WAL file on open (harmless if already DELETE).
  db.exec("PRAGMA journal_mode = DELETE");
  db.exec("PRAGMA foreign_keys = ON");
  db.exec("PRAGMA busy_timeout = 4000"); // per-request writers wait for the lock (low concurrency)
  // app-owned project-meta tables (created here so the live DB migrates without a re-ingest; also
  // declared in schema.sql for fresh DBs). project_tags reuses the shared `tags` vocabulary.
  db.exec("CREATE TABLE IF NOT EXISTS project_tags (project TEXT NOT NULL, tag_id INTEGER NOT NULL, PRIMARY KEY (project, tag_id))");
  db.exec(
    "CREATE TABLE IF NOT EXISTS project_todos (id INTEGER PRIMARY KEY AUTOINCREMENT, project TEXT NOT NULL, " +
      "body TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, ord INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT (datetime('now')))",
  );
  db.exec(
    "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL DEFAULT '', " +
      "title TEXT NOT NULL DEFAULT '', body_md TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, " +
      "importance INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT (datetime('now')), " +
      "updated_at TEXT NOT NULL DEFAULT (datetime('now')))",
  );
  // add-column migrations for older `notes` tables (each ALTER throws if the column already exists)
  for (const col of ["pinned INTEGER NOT NULL DEFAULT 0", "importance INTEGER NOT NULL DEFAULT 0", "description TEXT NOT NULL DEFAULT ''", "archived INTEGER NOT NULL DEFAULT 0"])
    try { db.exec(`ALTER TABLE notes ADD COLUMN ${col}`); } catch (_) { /* already there */ }
  db.exec("CREATE TABLE IF NOT EXISTS note_tags (note_id INTEGER NOT NULL, tag_id INTEGER NOT NULL, PRIMARY KEY (note_id, tag_id))");
  // comments / annotations on a note (app-owned; parallels the records `comments` table)
  db.exec(
    "CREATE TABLE IF NOT EXISTS note_comments (id INTEGER PRIMARY KEY AUTOINCREMENT, " +
      "note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE, user_id INTEGER, " +
      "body_md TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')))",
  );
  db.exec("CREATE INDEX IF NOT EXISTS idx_note_comments_note ON note_comments(note_id)");
  // inline annotations on a structure note (passage highlight + margin note; text-quote anchor)
  db.exec(
    "CREATE TABLE IF NOT EXISTS note_annotations (id INTEGER PRIMARY KEY AUTOINCREMENT, " +
      "note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE, user_id INTEGER, " +
      "anchor TEXT NOT NULL, body_md TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')))",
  );
  db.exec("CREATE INDEX IF NOT EXISTS idx_note_annotations_note ON note_annotations(note_id)");
  // UNIFIED comments+annotations on a record, each carrying its LOCATION (target_kind/page/target_id/
  // anchor) — record discussion + figure/section/passage notes in one table, all server-side. Supersedes
  // `comments` + `record_annotations`. Self-migrated so the live DB gains it with no re-ingest.
  db.exec(
    "CREATE TABLE IF NOT EXISTS annotations (id INTEGER PRIMARY KEY AUTOINCREMENT, " +
      "record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE, " +
      "target_kind TEXT NOT NULL DEFAULT 'record', page TEXT NOT NULL DEFAULT '', " +
      "target_id TEXT NOT NULL DEFAULT '', anchor TEXT NOT NULL DEFAULT '', " +
      "user_id INTEGER, body_md TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')))",
  );
  db.exec("CREATE INDEX IF NOT EXISTS idx_annotations_loc ON annotations(record_id, target_kind, page, target_id)");
  // app-level accounts (login identity, layered above the shared Basic-auth gate). Created here too so
  // a node-only / freshly-initialized DB has it; declared in schema.sql for ingest-built DBs.
  db.exec(
    "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, " +
      "display_name TEXT, pw_hash TEXT, role TEXT NOT NULL DEFAULT 'member', " +
      "must_change INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT (datetime('now')))",
  );
  // add-column migrations for older `users` tables (each ALTER throws if the column already exists)
  for (const col of ["pw_hash TEXT", "role TEXT NOT NULL DEFAULT 'member'", "must_change INTEGER NOT NULL DEFAULT 0", "invite_token TEXT"])
    try { db.exec(`ALTER TABLE users ADD COLUMN ${col}`); } catch (_) { /* already there */ }
  return db;
}
