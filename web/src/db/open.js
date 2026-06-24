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
  return db;
}
