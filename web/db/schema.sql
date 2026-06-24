-- Archeion registry — schema v3 (Phase A). The shared data contract.
-- node:sqlite / SQLite. Layers: CONTENT (ingest-owned, by stable id) vs ANNOTATION (app-owned;
-- shared = importance/archived/tags, per-user = bookmarks/comments). Re-ingest UPSERTs content
-- by stable id and never touches annotations. Recall on two axes: record (experiment) + figure.

PRAGMA journal_mode = DELETE;  -- NOT WAL: node-as-CGI = per-request process + Lolipop NFS home (no -shm/mmap) ⇒ WAL writes invisible to the next reader. See web/src/db.js openDb.
PRAGMA foreign_keys = ON;

-- ===================== PROJECTS (the PARA root) =====================
-- PARA is the root grouping: each project is assigned to one bucket; records (Pinax) belong to a
-- project. `para` is app-owned (the user files projects); ingest only ensures the row exists.
-- `name` is the CANONICAL project key = slug(project) — the SAME normalization as records.id, so the
-- URL / FK / id all agree and a spelling drift ("Logistic" vs "logistic") can never split a project or
-- orphan its PARA filing. Ingest is the only normalizer; the viewer only ever sees slugs.
CREATE TABLE IF NOT EXISTS projects (
    name        TEXT PRIMARY KEY,                  -- canonical = slug(project) (matches records.id's project part)
    para        TEXT NOT NULL DEFAULT 'Projects',  -- Projects | Areas | Resources | Archives
    description TEXT NOT NULL DEFAULT '',
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_projects_para ON projects(para);

-- ===================== CONTENT (ingest-owned) =====================

-- record = one experiment = one Pinax generation-source (may span runs; see record_runs).
-- id MUST be stable & source-based (survives re-render and run-set changes) — annotations key off it.
CREATE TABLE IF NOT EXISTS records (
    id           TEXT PRIMARY KEY,
    project      TEXT NOT NULL REFERENCES projects(name),  -- = slug(project), the canonical project key
    title        TEXT NOT NULL,
    pinax_source TEXT,
    html_path    TEXT,
    pdf_path     TEXT,
    body_md      TEXT NOT NULL DEFAULT '',
    date         TEXT,
    git_commit   TEXT,
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at   TEXT NOT NULL DEFAULT (datetime('now')),
    importance   INTEGER NOT NULL DEFAULT 0,   -- shared "notable experiment" (0..3); app-owned
    archived     INTEGER NOT NULL DEFAULT 0    -- shared hide flag (failures kept but hidden); app-owned
);
CREATE INDEX IF NOT EXISTS idx_records_project    ON records(project);
CREATE INDEX IF NOT EXISTS idx_records_updated    ON records(updated_at);
CREATE INDEX IF NOT EXISTS idx_records_importance ON records(importance);

-- runs an experiment renders/compares (M:N)
CREATE TABLE IF NOT EXISTS record_runs (
    record_id     TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    project       TEXT NOT NULL,
    run           TEXT NOT NULL,
    datavault_ref TEXT,
    PRIMARY KEY (record_id, project, run)
);
CREATE INDEX IF NOT EXISTS idx_record_runs_pr ON record_runs(project, run);

-- content VERSION history (ingest-owned): one row per DISTINCT content state of a record. Ingest
-- appends a version when the content fingerprint (title + body_md + run-set + git) changes, so a
-- re-render is idempotent but a re-run / refinement / code change is recorded. Annotations live on
-- the stable records.id and survive across versions; this only tracks how the CONTENT evolved.
CREATE TABLE IF NOT EXISTS record_versions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    record_id    TEXT    NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    version      INTEGER NOT NULL,                       -- 1, 2, 3, … per record
    title        TEXT    NOT NULL DEFAULT '',            -- the record's title at this version (minimal snapshot)
    ingested_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    git_commit   TEXT,
    date         TEXT,
    content_hash TEXT    NOT NULL,                       -- SHA-256 fingerprint; a change is what appends a version
    UNIQUE (record_id, version)
);
CREATE INDEX IF NOT EXISTS idx_record_versions ON record_versions(record_id, version);

-- figures = first-class recall axis. id MUST be stable (Pinax param/explicit id, not positional).
CREATE TABLE IF NOT EXISTS figures (
    id         TEXT PRIMARY KEY,             -- "<record_id>:<pinax-figure-id>"
    record_id  TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    ord        INTEGER NOT NULL DEFAULT 0,
    path       TEXT NOT NULL,
    thumbnail  TEXT,
    caption    TEXT NOT NULL DEFAULT '',
    importance INTEGER NOT NULL DEFAULT 0    -- shared "key figure" (0..3); app-owned
);
CREATE INDEX IF NOT EXISTS idx_figures_record     ON figures(record_id);
CREATE INDEX IF NOT EXISTS idx_figures_importance ON figures(importance);

-- ===================== SHARED ANNOTATION (app-owned) =====================
CREATE TABLE IF NOT EXISTS tags (
    id   INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS record_tags (
    record_id TEXT    NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    tag_id    INTEGER NOT NULL REFERENCES tags(id)    ON DELETE CASCADE,
    PRIMARY KEY (record_id, tag_id)
);
CREATE INDEX IF NOT EXISTS idx_record_tags_tag ON record_tags(tag_id);

-- project-level meta (app-owned; the Node app self-creates these too, so a live DB migrates without a
-- re-ingest). project_tags reuses the shared `tags` vocabulary; project_todos = a per-project checklist.
CREATE TABLE IF NOT EXISTS project_tags (
    project TEXT    NOT NULL,
    tag_id  INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (project, tag_id)
);
CREATE TABLE IF NOT EXISTS project_todos (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project    TEXT    NOT NULL,
    body       TEXT    NOT NULL,
    done       INTEGER NOT NULL DEFAULT 0,
    ord        INTEGER NOT NULL DEFAULT 0,
    created_at TEXT    NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_project_todos ON project_todos(project);

-- free-form Zettelkasten notes (app-owned; Node self-creates this too → live DB migrates without a
-- re-ingest). scope = a project slug, or '' for a global note. body_md may contain [[project]] /
-- [[record-id]] mentions (resolved to links for humans, to a typed mentions[] for the LLM context).
-- This is the human-authored context the project-context harness output (/api/project/:n/context)
-- exposes to the LLM compute loop alongside the existing meta / discussion / records.
CREATE TABLE IF NOT EXISTS notes (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    scope      TEXT    NOT NULL DEFAULT '',      -- project slug, or '' = global
    title      TEXT    NOT NULL DEFAULT '',      -- optional short title
    body_md    TEXT    NOT NULL,
    pinned     INTEGER NOT NULL DEFAULT 0,       -- 1 = a "structure note" / advisor-facing page (shown clean at /show/:id)
    importance INTEGER NOT NULL DEFAULT 0,       -- 0..3, for managing structure notes by importance (+ date)
    description TEXT   NOT NULL DEFAULT '',      -- short summary / front-matter (markdown), separate from body_md
    archived   INTEGER NOT NULL DEFAULT 0,       -- 1 = hidden from the active list (kept in the archived section + search)
    created_at TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT    NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_notes_scope ON notes(scope);
-- a note's tags (reuses the shared `tags` vocabulary, like project_tags / record_tags)
CREATE TABLE IF NOT EXISTS note_tags (
    note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    tag_id  INTEGER NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
    PRIMARY KEY (note_id, tag_id)
);
-- comments / annotations on a note (app-owned; parallels the records `comments` table). Shown on the
-- note's "open" view (/note/:id) where the author reads + annotates their own working note.
CREATE TABLE IF NOT EXISTS note_comments (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id    INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    user_id    INTEGER REFERENCES users(id),
    body_md    TEXT    NOT NULL,
    created_at TEXT    NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_note_comments_note ON note_comments(note_id);

-- ===================== USERS + PER-USER (app-owned) =====================
CREATE TABLE IF NOT EXISTS users (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL UNIQUE,        -- Basic-auth username (auto-created on first access)
    display_name TEXT,
    created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

-- bookmark a record OR a figure (per-user). polymorphic target (app validates target_id).
CREATE TABLE IF NOT EXISTS bookmarks (
    user_id     INTEGER NOT NULL REFERENCES users(id),
    target_kind TEXT    NOT NULL,             -- 'record' | 'figure'
    target_id   TEXT    NOT NULL,
    added_at    TEXT    NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (user_id, target_kind, target_id)
);

-- discussion + memo (per-user, mutually visible) on a record
CREATE TABLE IF NOT EXISTS comments (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    record_id  TEXT    NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    body_md    TEXT    NOT NULL,
    created_at TEXT    NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_comments_record ON comments(record_id);

-- ===================== SEARCH (records + figures + comments) =====================
-- App/ingest-maintained unified FTS. One row per record (title+body_md), per figure (caption),
-- per comment (body). Search returns matches across all three → present as experiments AND figures.
CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
    text,
    kind      UNINDEXED,                      -- 'record' | 'figure' | 'comment'
    id        UNINDEXED,                      -- records.id or figures.id
    record_id UNINDEXED
);
