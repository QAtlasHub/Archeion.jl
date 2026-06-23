-- Archeion registry — SQLite schema (the source of truth for the web app).
--
-- RAG-portable by design: `records.body_md` is clean, atomic, per-record Markdown that can
-- be embedded later (semantic search / RAG) WITHOUT restructuring — "port the DB as-is".
-- The Julia side (Archeion.jl, on panza) ingests records + figures; this web app reads them
-- and adds interactive state (tags / status / PARA / links / comments / pins). Heavy raw
-- data stays on panza; figure assets live under data/figures/ (referenced, not stored here).

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- One experiment record = one (project, study, run) node (Zettelkasten-atomic).
CREATE TABLE IF NOT EXISTS records (
    id          TEXT PRIMARY KEY,          -- slug, e.g. "lorenz_rho_sweep/pilot"
    project     TEXT NOT NULL,
    study       TEXT,
    run         TEXT,
    title       TEXT NOT NULL,
    date        TEXT,                        -- ISO8601 (sorts chronologically as text)
    status      TEXT    DEFAULT 'active',    -- draft | active | done | archived
    para        TEXT,                        -- PARA: project | area | resource | archive
    tags        TEXT    DEFAULT '[]',        -- JSON array of strings
    pinned      INTEGER DEFAULT 0,           -- 1 = pinned (advisor view / landing)
    git_commit  TEXT,
    data_keys   TEXT    DEFAULT '[]',        -- JSON array of DataVault keys (references)
    figures     TEXT    DEFAULT '[]',        -- JSON array of figure paths under data/figures/
    body_md     TEXT    DEFAULT '',          -- Markdown source-of-truth (RAG-embeddable)
    created_at  TEXT    DEFAULT (datetime('now')),
    updated_at  TEXT    DEFAULT (datetime('now'))
);

-- Full-text search (search NOW; the same text embeds for RAG LATER).
CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(
    title, tags, body_md,
    content='records', content_rowid='rowid'
);
CREATE TRIGGER IF NOT EXISTS records_ai AFTER INSERT ON records BEGIN
    INSERT INTO records_fts(rowid, title, tags, body_md)
        VALUES (new.rowid, new.title, new.tags, new.body_md);
END;
CREATE TRIGGER IF NOT EXISTS records_ad AFTER DELETE ON records BEGIN
    INSERT INTO records_fts(records_fts, rowid, title, tags, body_md)
        VALUES ('delete', old.rowid, old.title, old.tags, old.body_md);
END;
CREATE TRIGGER IF NOT EXISTS records_au AFTER UPDATE ON records BEGIN
    INSERT INTO records_fts(records_fts, rowid, title, tags, body_md)
        VALUES ('delete', old.rowid, old.title, old.tags, old.body_md);
    INSERT INTO records_fts(rowid, title, tags, body_md)
        VALUES (new.rowid, new.title, new.tags, new.body_md);
END;

-- Network / Zettelkasten links between records.
CREATE TABLE IF NOT EXISTS links (
    from_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    to_id   TEXT NOT NULL,                    -- another record id
    kind    TEXT DEFAULT 'related',           -- builds-on | cites | supersedes | related
    PRIMARY KEY (from_id, to_id, kind)
);

-- Memos / discussion threads on a record.
CREATE TABLE IF NOT EXISTS comments (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    record_id  TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    author     TEXT,
    body_md    TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_comments_record ON comments(record_id);
CREATE INDEX IF NOT EXISTS idx_records_status  ON records(status);
CREATE INDEX IF NOT EXISTS idx_records_pinned  ON records(pinned);
CREATE INDEX IF NOT EXISTS idx_records_project ON records(project);
