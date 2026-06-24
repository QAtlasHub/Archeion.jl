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

test("notes: add a project note; [[mention]] linkifies; shows on project + global pages", () => {
  const app = setup();
  assert.equal(post(app, "/noteadd", { scope: "proj", title: "βc grid", body: "refine [[p/r1]] near βc; cf [[proj]]" }).status, 303);
  const proj = get(app, "/p/proj").body;
  assert.match(proj, /Notes \(1\)/);
  assert.match(proj, /βc grid/);
  assert.match(proj, /href="\/r\/p\/r1"/); // record mention resolved to a link
  assert.match(proj, /href="\/p\/proj"/); // project mention resolved
  const all = get(app, "/notes").body;
  assert.match(all, /βc grid/);
  assert.match(all, /note-scope/); // global page tags each note with its scope
});

test("context: /api/project/:n/context is an atomic JSON pack; ?format=md is an ingestible brief", () => {
  const app = setup();
  post(app, "/noteadd", { scope: "proj", body: "a human note" });
  const r = get(app, "/api/project/proj/context");
  assert.equal(r.status, 200);
  const ctx = JSON.parse(r.body);
  assert.equal(ctx.schema, "archeion/project-context@1");
  assert.equal(ctx.notes.length, 1);
  assert.equal(ctx.records.length, 1);
  assert.ok(Array.isArray(ctx.records[0].runs)); // compute seam (datavault_ref) present per record
  assert.match(ctx.records[0].body_md, /magnetization/); // RAG text carried through
  const md = get(app, "/api/project/proj/context", { format: "md" });
  assert.match(md.type, /text\/markdown/);
  assert.match(md.body, /# proj — project context/);
  assert.match(md.body, /## Notes/);
  assert.match(md.body, /## Records/);
});

test("context: unknown project → 404", () => {
  const app = setup();
  assert.equal(get(app, "/api/project/nope/context").status, 404);
});

test("context.related: surfaces past experiments elsewhere by shared tag", () => {
  const app = setup();
  const db = new DatabaseSync(dbPath); // add a second project + record sharing #mps
  db.exec("INSERT INTO projects (name) VALUES ('proj2')");
  db.exec("INSERT INTO records (id,project,title,body_md,date) VALUES ('p2/r1','proj2','Run two','# Run two','2026-06-21')");
  db.exec("INSERT INTO tags (name) VALUES ('mps')");
  db.exec("INSERT INTO record_tags (record_id,tag_id) SELECT 'p/r1', id FROM tags WHERE name='mps'");
  db.exec("INSERT INTO record_tags (record_id,tag_id) SELECT 'p2/r1', id FROM tags WHERE name='mps'");
  db.close();
  const ctx = JSON.parse(get(app, "/api/project/proj/context").body);
  const hit = ctx.related.find((r) => r.id === "p2/r1");
  assert.ok(hit, "related includes the other project's record");
  assert.ok(hit.why.some((w) => w.includes("tag:mps")), "carries the reason (shared tag)");
});

test("structure note: pin → /show page with an inline ![[figure]] embed + the home nav menu", () => {
  const app = setup();
  post(app, "/noteadd", { scope: "proj", title: "For the advisor", body: "Converged near Tc: ![[p/r1:mag]]" });
  const id = JSON.parse(get(app, "/api/project/proj/context").body).notes[0].id;
  assert.equal(post(app, "/notepin", { id: String(id), pinned: "1" }).status, 303);
  const show = get(app, "/show/" + id);
  assert.equal(show.status, 200);
  assert.match(show.body, /For the advisor/);
  assert.match(show.body, /\/figures\/mag\.svg/); // the figure is transcluded inline
  assert.match(show.body, /class="hamburger"/); // hamburger toggles the menu (same as home)
  assert.match(show.body, /class="side"/); // …revealing the home nav menu (Figures/Notes/projects/tags)
  assert.match(show.body, /class="present-wrap"/); // note still in its narrow reading column
});

test("structure note: pinning shows on the project page (unpin + show link)", () => {
  const app = setup();
  post(app, "/noteadd", { scope: "proj", body: "draft" });
  const id = JSON.parse(get(app, "/api/project/proj/context").body).notes[0].id;
  post(app, "/notepin", { id: String(id), pinned: "1" });
  const proj = get(app, "/p/proj").body;
  assert.match(proj, /📌 unpin/);
  assert.match(proj, new RegExp(`/show/${id}`));
});

test("composer: /compose has the CM6 editor + a live-Archeion refs iframe + figure-data island", () => {
  const app = setup();
  const r = get(app, "/compose");
  assert.equal(r.status, 200);
  assert.match(r.body, /id="cmp-body"/); // source textarea (CM6 mounts over it; JS-off fallback)
  assert.match(r.body, /id="cmp-editor"/); // the CodeMirror mount point
  assert.match(r.body, /class="cmp-frame cmp-refs-frame" src="\//); // refs = a live-Archeion iframe
  assert.match(r.body, /class="cmp-refs"/); // refs toggle
  assert.match(r.body, /id="arx-figs"/); // figure-data island for inline ![[id]] rendering
  assert.match(r.body, /p\/r1:mag/); // …and it carries the project's figure(s)
  assert.match(r.body, /compose-editor\.js/); // the editor bundle is loaded
  // preview works WITHOUT saving (even on a brand-new note): button + hidden POST form + named iframe
  assert.match(r.body, /class="cmp-preview-btn"/);
  assert.match(r.body, /id="cmp-preview-form"[^>]*action="\/api\/note\/preview"[^>]*target="cmp-preview-frame"/);
  assert.match(r.body, /class="cmp-frame cmp-preview-frame" name="cmp-preview-frame"/);
  assert.doesNotMatch(r.body, /data-src=/); // no longer points at a saved /show
});

test("framing: dashboard pages allow same-origin embedding (composer iframes Archeion)", () => {
  const app = setup();
  // the handler doesn't set XFO (server.js/index.php do at the transport layer), so just assert the
  // page renders — the SAMEORIGIN header is asserted by deploy config; here we guard the iframe src.
  assert.match(get(app, "/compose").body, /<iframe class="cmp-frame cmp-refs-frame" src="\/"/);
});

test("math: $…$ renders as KaTeX server-side (safe with x_1) in the preview", () => {
  const app = setup();
  const r = app("POST", "/api/note/preview", new URLSearchParams(), {
    headers: { origin: "http://localhost", host: "localhost", user: "alice" },
    body: new URLSearchParams({ body: "energy $E=mc^2$ and a subscript $x_1$" }),
  });
  assert.equal(r.status, 200);
  assert.match(r.body, /class="katex"/); // rendered to KaTeX HTML (needs /katex/katex.min.css to display)
});

test("composer: /api/note/preview renders ![[figure]] embeds + [[mention]] links", () => {
  const app = setup();
  const r = app("POST", "/api/note/preview", new URLSearchParams(), {
    headers: { origin: "http://localhost", host: "localhost", user: "alice" },
    body: new URLSearchParams({ body: "result ![[p/r1:mag]] see [[p/r1]]" }),
  });
  assert.equal(r.status, 200);
  assert.match(r.body, /\/figures\/mag\.svg/); // embed transcluded
  assert.match(r.body, /href="\/r\/p\/r1"/); // mention linked
});

test("composer preview: a full page of the CURRENT edits, chrome-free (no header → no duplicate)", () => {
  const app = setup();
  const r = app("POST", "/api/note/preview", new URLSearchParams(), {
    headers: { origin: "http://localhost", host: "localhost", user: "alice" },
    body: new URLSearchParams({ title: "Draft", importance: "3", tags: "#mps draft", description: "wip", body: "unsaved body" }),
  });
  assert.equal(r.status, 200);
  assert.match(r.body, /<!doctype html>/i); // a full page (loads in the iframe), not a fragment
  assert.match(r.body, /present-bare/); // chrome-free body class
  assert.doesNotMatch(r.body, /present-head/); // NO header (the composer's own header covers it)
  assert.doesNotMatch(r.body, /present-foot/); // …and no footer
  assert.match(r.body, /Draft/); // title from the live edits (never saved)
  assert.match(r.body, /present-meta/); // importance/tags rendered
  assert.match(r.body, /#mps/);
  assert.match(r.body, /present-desc/); // description rendered
});

test("standalone /show uses the HOME-style header (brand + search), matching the rest of Archeion", () => {
  const app = setup();
  post(app, "/noteadd", { scope: "proj", title: "Pinned", body: "x", pinned: "1", from: "compose" });
  const id = JSON.parse(get(app, "/api/project/proj/context").body).notes[0].id;
  const show = get(app, "/show/" + id).body;
  assert.match(show, /class="present-head"/); // present-head IS shown on the standalone page
  assert.match(show, /class="hamburger"[^>]*>☰/); // …with the home hamburger to toggle the menu
  assert.match(show, /<a class="brand" href="\/">Archeion<\/a>/); // home brand
  assert.match(show, /<form action="\/search" method="get" class="search">/); // home-style search pill
  assert.match(show, /class="present-nav"/); // back-links (crumb / Notes / edit) on the right
});

test("composer: save makes a pinned structure note (importance kept) + returns into the composer", () => {
  const app = setup();
  const r = post(app, "/noteadd", { scope: "proj", title: "SN", body: "x ![[p/r1:mag]]", pinned: "1", importance: "2", from: "compose" });
  assert.equal(r.status, 303);
  assert.match(r.headers.Location, /^\/compose\?id=\d+$/);
  const id = r.headers.Location.match(/id=(\d+)/)[1];
  assert.equal(get(app, "/show/" + id).status, 200); // advisor page exists (pinned)
  assert.match(get(app, "/notes").body, /📌 pinned/); // shows under the "pinned" section
});

test("notes page: pinned / all notes (+ filter) buckets; per-card date·edit·pin tools in order", () => {
  const app = setup();
  post(app, "/noteadd", { title: "Loose one", body: "alpha body" });
  const body = get(app, "/notes").body;
  assert.match(body, /📌 pinned/); // the pinned bucket
  assert.match(body, /🗂 all notes/); // the "all notes" bucket
  assert.match(body, /class="note-filter"/); // …with a client-side filter input
  assert.doesNotMatch(body, /Structure notes — advisor pages/); // old heading gone
  assert.doesNotMatch(body, />global</); // the confusing "global" label is gone (unscoped → no chip)
  // per-card top-right tools, in source order: (date) edit · archive · pin
  assert.match(body, /class="note-tools">[\s\S]*?class="note-when[\s\S]*?class="note-edit-link" href="\/compose\?id=\d+"[\s\S]*?class="note-arch"[\s\S]*?class="note-pin"/);
});

test("notes page: quick-add has a description field; markdown is signposted; composer button", () => {
  const app = setup();
  const body = get(app, "/notes").body;
  assert.match(body, /class="note-add"[\s\S]*?name="description"/); // quick-add can set a description
  assert.match(body, /Notes are <strong>markdown<\/strong>/); // markdown is made explicit
  assert.match(body, /class="make-sn" href="\/compose"[^>]*>✎ new in composer/); // the rich-composer entry
});

test("notes: quick-add saves a description (round-trips to the open view + composer)", () => {
  const app = setup();
  assert.equal(post(app, "/noteadd", { title: "WithDesc", description: "a quick summary", body: "x" }).status, 303);
  const id = get(app, "/notes").body.match(/data-note="(\d+)"/)[1];
  assert.match(get(app, "/note/" + id).body, /a quick summary/); // shown on the open view
  assert.match(get(app, "/compose", { id }).body, /a quick summary<\/textarea>/); // prefilled in the composer
});

test("notes: each card has an 'open ↗' link → the working note view (/note/:id)", () => {
  const app = setup();
  post(app, "/noteadd", { title: "Openable", body: "hello" });
  const all = get(app, "/notes").body;
  const id = all.match(/data-note="(\d+)"/)[1];
  assert.match(all, new RegExp(`class="note-open" href="/note/${id}"`));
  const view = get(app, "/note/" + id);
  assert.equal(view.status, 200);
  assert.match(view.body, /Openable/); // the note is rendered…
  assert.match(view.body, /Comments &amp; annotations/); // …with a comments/annotations thread
  assert.match(view.body, /action="\/note\/\d+\/comment"/); // and a comment form
  assert.equal(get(app, "/note/999999").status, 404); // unknown note → 404
});

test("notes: comment on a note via POST /note/:id/comment → shows on the open view", () => {
  const app = setup();
  post(app, "/noteadd", { title: "Discussable", body: "body" });
  const id = get(app, "/notes").body.match(/data-note="(\d+)"/)[1];
  const r = post(app, "/note/" + id + "/comment", { body_md: "needs more runs near βc" });
  assert.equal(r.status, 303);
  assert.match(r.headers.Location, new RegExp(`/note/${id}`));
  assert.match(get(app, "/note/" + id).body, /needs more runs near βc/); // the comment is rendered
});

test("notes: archive moves a note into the archived bucket; unarchive restores it", () => {
  const app = setup();
  post(app, "/noteadd", { title: "ToArchive", body: "gamma" });
  const id = get(app, "/notes").body.match(/data-note="(\d+)"/)[1];
  assert.equal(post(app, "/notearchive", { id, archived: "1" }).status, 303);
  const body = get(app, "/notes").body;
  assert.match(body, /class="archived-sec"/); // the archived <details> section…
  assert.match(body, /🗄 archived \(1\)/); // …with the one archived note
  assert.equal(post(app, "/notearchive", { id, archived: "0" }).status, 303);
  assert.doesNotMatch(get(app, "/notes").body, /archived-sec/); // restored → section gone
});

test("structure note: importance / tags / description are saved, shown on /show, prefilled in /compose", () => {
  const app = setup();
  const r = post(app, "/noteadd", { title: "SN", body: "x", pinned: "1", importance: "2", tags: "#mps review", description: "a short summary", from: "compose" });
  assert.equal(r.status, 303);
  const id = r.headers.Location.match(/id=(\d+)/)[1];
  const show = get(app, "/show/" + id).body;
  assert.match(show, /present-meta/); // importance + tags shown
  assert.match(show, /#mps/);
  assert.match(show, /present-desc/); // description shown
  assert.match(show, /a short summary/);
  const comp = get(app, "/compose", { id }).body;
  assert.match(comp, /class="cmp-tags" value="[^"]*#mps/); // tags prefilled
  assert.match(comp, /a short summary<\/textarea>/); // description prefilled
});

test("LLM channel: check a todo via /api/project/:n/todo (no Origin = server-to-server)", () => {
  const app = setup();
  post(app, "/todoadd", { name: "proj", body: "verify N=64" });
  let ctx = JSON.parse(get(app, "/api/project/proj/context").body);
  const id = ctx.todos[0].id;
  assert.equal(ctx.todos[0].done, 0);
  const r = app("POST", "/api/project/proj/todo", new URLSearchParams(), {
    headers: { host: "localhost", user: "alice" }, body: new URLSearchParams({ id: String(id), done: "1" }),
  });
  assert.equal(r.status, 200);
  ctx = JSON.parse(get(app, "/api/project/proj/context").body);
  assert.equal(ctx.todos[0].done, 1); // the LLM's check is reflected
});

test.after(() => {
  for (const s of ["", "-wal", "-shm"]) rmSync(dbPath + s, { force: true });
});
