// Smoke tests for the v3 app: build a tiny DB from the real schema, then drive the transport-
// agnostic handler. Covers both recall axes (record + figure), search, project view, and the
// write-back (bookmark / importance / comment / archive) + CSRF. Run with `npm test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createApp } from "../src/app.js";

const here = dirname(fileURLToPath(import.meta.url));
const dbPath = join(here, "_app_test.db");

function setup() {
  for (const s of ["", "-wal", "-shm"]) rmSync(dbPath + s, { force: true });
  const db = new DatabaseSync(dbPath);
  db.exec(readFileSync(join(here, "..", "db", "schema.sql"), "utf8"));
  db.exec("INSERT INTO projects (name) VALUES ('proj')"); // FK target for records.project
  db.exec(
    "INSERT INTO records (id,project,title,body_md,date) VALUES ('p/r1','proj','Run one','# Run one\nmagnetization data','2026-06-20')",
  );
  db.exec("INSERT INTO record_runs (record_id,project,run) VALUES ('p/r1','proj','r1')");
  db.exec(
    "INSERT INTO figures (id,record_id,ord,path,caption) VALUES ('p/r1:mag','p/r1',1,'figures/mag.svg','magnetization vs T')",
  );
  db.exec(
    "INSERT INTO search_fts (text,kind,id,record_id) VALUES ('Run one magnetization','record','p/r1','p/r1')",
  );
  db.exec(
    "INSERT INTO search_fts (text,kind,id,record_id) VALUES ('magnetization vs T','figure','p/r1:mag','p/r1')",
  );
  db.close();
  return createApp(dbPath);
}

const get = (app, path, q = {}) =>
  app("GET", path, new URLSearchParams(q), { headers: { host: "localhost", user: "alice" } });
const post = (app, path, form) =>
  app("POST", path, new URLSearchParams(), {
    headers: { origin: "http://localhost", host: "localhost", user: "alice" },
    body: new URLSearchParams(form),
  });

test("landing lists records + project sidebar", () => {
  const app = setup();
  const r = get(app, "/");
  assert.equal(r.status, 200);
  assert.match(r.body, /Run one/);
  assert.match(r.body, /proj/);
});

test("record page shows figures, runs, discussion", () => {
  const app = setup();
  const r = get(app, "/r/p/r1");
  assert.equal(r.status, 200);
  assert.match(r.body, /magnetization vs T/);
  assert.match(r.body, /\/figures\/mag\.svg/); // figure served from the content store
  assert.match(r.body, /runs \(1\)/);
  assert.match(r.body, /Discussion/);
});

test("figure gallery (figure recall axis) — at /gallery (/figures is the static file dir)", () => {
  const app = setup();
  const r = get(app, "/gallery");
  assert.match(r.body, /figcard/);
  assert.match(r.body, /magnetization vs T/);
});

test("search: HOME = project search; project-scoped = Pinax + figures", () => {
  const app = setup();
  // from HOME (no project) → project search (finds the project that owns a matching record)
  const home = get(app, "/search", { q: "magnetization" });
  assert.match(home.body, /Projects/);
  assert.match(home.body, /\/p\/proj/);
  // scoped to a project → Pinax (records) + Figures within it
  const scoped = get(app, "/search", { q: "magnetization", project: "proj" });
  assert.match(scoped.body, /Pinax \(1\)/);
  assert.match(scoped.body, /Figures \(1\)/);
});

test("search: empty query falls back to the full screen (not a blank result)", () => {
  const app = setup();
  const home = get(app, "/search", { q: "" });
  assert.equal(home.status, 303);
  assert.equal(home.headers.Location, "/");
  const proj = get(app, "/search", { q: "  ", project: "proj" });
  assert.equal(proj.status, 303);
  assert.equal(proj.headers.Location, "/p/proj");
});

test("project view filters by project", () => {
  const app = setup();
  assert.match(get(app, "/p/proj").body, /Run one/);
});

test("write-back: bookmark a record (per-user), shows in /bookmarks", () => {
  const app = setup();
  assert.equal(post(app, "/bookmark", { kind: "record", id: "p/r1" }).status, 303);
  assert.match(get(app, "/bookmarks").body, /Run one/);
});

test("write-back: shared importance persists", () => {
  const app = setup();
  assert.equal(post(app, "/importance", { id: "p/r1", value: "3" }).status, 303);
  assert.match(get(app, "/r/p/r1").body, /★★★/);
});

test("write-back: comment then it appears", () => {
  const app = setup();
  assert.equal(post(app, "/r/p/r1/comment", { body_md: "looks good" }).status, 303);
  assert.match(get(app, "/r/p/r1").body, /looks good/);
});

test("tags: add chips (forgiving multi-add) then remove one", () => {
  const app = setup();
  assert.equal(post(app, "/tagadd", { id: "p/r1", tag: "#mps tpq" }).status, 303);
  let body = get(app, "/r/p/r1").body;
  assert.match(body, /#mps/);
  assert.match(body, /#tpq/);
  assert.match(body, /action="\/tagdel"/); // each chip carries its own remove form
  assert.equal(post(app, "/tagdel", { id: "p/r1", tag: "mps" }).status, 303);
  body = get(app, "/r/p/r1").body;
  assert.doesNotMatch(body, /#mps/); // gone from chip row + sidebar (orphan tag drops out)
  assert.match(body, /#tpq/); // the other chip survives
});

test("write-back: archive hides from the landing", () => {
  const app = setup();
  post(app, "/archive", { id: "p/r1", archived: "1" });
  assert.doesNotMatch(get(app, "/").body, /Run one/);
});

test("PARA: project defaults to Active (Projects) and can be re-filed", () => {
  const app = setup();
  assert.match(get(app, "/").body, /Active Projects/);
  assert.match(get(app, "/p/proj").body, /selected>Projects/); // default bucket
  assert.equal(post(app, "/projectpara", { name: "proj", para: "Archives" }).status, 303);
  assert.match(get(app, "/p/proj").body, /selected>Archives/); // re-filed under PARA
});

test("CSRF: cross-origin POST is rejected", () => {
  const app = setup();
  const r = app("POST", "/bookmark", new URLSearchParams(), {
    headers: { origin: "http://evil.example", host: "localhost", user: "alice" },
    body: new URLSearchParams({ kind: "record", id: "p/r1" }),
  });
  assert.equal(r.status, 403);
});

test.after(() => {
  for (const s of ["", "-wal", "-shm"]) rmSync(dbPath + s, { force: true });
});
