// Transport-agnostic request handler (schema v3): (method, path, query, opts) -> {status,type,body,headers?}.
// opts = { headers: {origin, host, referer, user}, body: URLSearchParams }. Read routes + write-back.
import {
  openDb, recents, byProject, archivedByProject, archivedRecords, byTag, projects, tags as allTags, getRecord, recordFigures,
  recordRuns, recordTags, recordComments, figuresGallery, search, searchProjects, parseFields, recentActivity,
  getProject, setProjectPara, setProjectDescription,
  projectMeta, addProjectTag, removeProjectTag, addTodo, toggleTodo, removeTodo,
  ensureUser, setRecordImportance, setFigureImportance, setArchived, toggleBookmark,
  bookmarkedSet, userBookmarks, addComment, addTag, removeTag,
  notesForDisplay, allNotesForDisplay, noteForDisplay, getNote, addNote, updateNote, removeNote, setPinned, setNoteArchived, setNoteTags, noteComments, addNoteComment,
  addNoteAnnotation, noteAnnotations, getNoteAnnotation, removeNoteAnnotation, relatedNotes, graphData,
  parseMentions, resolveMentions, parseEmbeds, resolveEmbeds,
  projectContext, contextMarkdown, setTodoDone,
  getAccount, getAccountById, getByInviteToken, countAccounts, listAccounts, createAccount, inviteAccount, revokePassword, setPassword, verifyLogin, verifyPassword, deleteAccount, ensureTrustedAdmin,
} from "./db.js";
import * as V from "./render.js";
import { SESSION_COOKIE, sessionSecret, makeToken, verifyToken, parseCookies, setSessionCookie, clearSessionCookie } from "./auth.js";

const html = (b, s = 200) => ({ status: s, type: "text/html; charset=utf-8", body: b });
const json = (o, s = 200) => ({ status: s, type: "application/json; charset=utf-8", body: JSON.stringify(o, null, 2) });
const redirect = (loc) => ({ status: 303, type: "text/html; charset=utf-8", body: "", headers: { Location: loc } });
const rid = (id) => encodeURIComponent(id).replace(/%2F/gi, "/");
const parseTags = (s) => (s || "").split(/[,\s]+/).map((t) => t.replace(/^#/, "").trim()).filter(Boolean);

function sameOrigin(h) {
  if (!h.origin) return true;
  try {
    return new URL(h.origin).host === h.host;
  } catch {
    return false;
  }
}
function back(h, fallback) {
  if (h.referer) {
    try {
      const u = new URL(h.referer);
      if (u.host === h.host) return u.pathname + u.search;
    } catch {
      /* ignore */
    }
  }
  return fallback;
}

export function createApp(dbPath) {
  const db = openDb(dbPath);
  const SECRET = sessionSecret(dbPath);
  return function handle(method, path, query, opts = {}) {
    const h = opts.headers || {};
    const body = opts.body || new URLSearchParams();
    // fetch() writes send X-Requested-With: fetch and want 204 (no redirect → no re-render → no
    // stale read-back on Lolipop NFS). Plain form posts (no header) still get the 303 redirect.
    const xrw = (h.xrw || "") === "fetch";
    const ok = (loc) => (xrw ? { status: 204, type: "text/plain; charset=utf-8", body: "" } : redirect(loc));
    const isPost = method === "POST";
    const cookie = (loc, value) => ({ status: 303, type: "text/html; charset=utf-8", body: "", headers: { Location: loc, "Set-Cookie": value } });

    // ===== identity (layer 2: app accounts; layer 1 = the shared Basic-auth gate, in front) =====
    // Trusted bypass: the panza daemon + the test harness pass headers.trustedUser → treated as an
    // admin without a login (the live CGI never sets it, so the live site requires a real login).
    let me = null;
    if (h.trustedUser) me = ensureTrustedAdmin(db, h.trustedUser);
    else {
      const id = verifyToken(parseCookies(h.cookie || "")[SESSION_COOKIE], SECRET);
      if (id) me = getAccountById(db, id);
    }
    const uid = () => (me ? me.id : 0);
    const needSetup = countAccounts(db) === 0;
    const sb = () => ({ projects: projects(db), tags: allTags(db) }); // sidebar data for the logged-in auth pages
    const role = me ? (me.role === "admin" ? "admin" : "member") : "";
    const r = (() => {

    // ----- public auth routes (reachable without a session) -----
    if (path === "/setup") {
      if (!needSetup) return redirect(me ? "/" : "/login");
      if (isPost) {
        if (!sameOrigin(h)) return { status: 403, type: "text/plain", body: "CSRF: bad origin" };
        const name = (body.get("name") || "").trim(), pass = body.get("password") || "";
        if (!name || pass.length < 8) return html(V.renderSetup("Username required and password must be ≥ 8 characters."), 400);
        const id = createAccount(db, name, pass, { role: "admin" });
        if (!id) return html(V.renderSetup("Could not create the account (name taken?)."), 400);
        return cookie("/", setSessionCookie(makeToken(id, SECRET)));
      }
      return html(V.renderSetup());
    }
    if (path === "/login") {
      if (needSetup) return redirect("/setup");
      if (me) return redirect("/");
      if (isPost) {
        if (!sameOrigin(h)) return { status: 403, type: "text/plain", body: "CSRF: bad origin" };
        const name = (body.get("name") || "").trim();
        const acc = getAccount(db, name);
        if (acc && !acc.pw_hash) return html(V.renderActivate(acc.name)); // invited (pending) → set own password
        const u = verifyLogin(db, name, body.get("password") || "");
        if (!u) return html(V.renderLogin("Wrong username or password."), 401);
        return cookie("/", setSessionCookie(makeToken(u.id, SECRET)));
      }
      return html(V.renderLogin());
    }
    // invite link: /invite/<token> → set your own password (no username needed), then signed in
    if (path.startsWith("/invite/")) {
      if (me) return redirect("/");
      const tok = decodeURIComponent(path.slice(8));
      const acc = getByInviteToken(db, tok);
      if (!acc || acc.pw_hash) return html(V.renderLogin("That invite link is invalid or already used."), 410);
      if (isPost) {
        if (!sameOrigin(h)) return { status: 403, type: "text/plain", body: "CSRF: bad origin" };
        const pass = body.get("password") || "";
        if (pass.length < 8) return html(V.renderActivate(acc.name, { err: "Password must be ≥ 8 characters.", action: `/invite/${encodeURIComponent(tok)}`, token: tok }), 400);
        setPassword(db, acc.id, pass, { mustChange: false }); // activates + consumes the token
        return cookie("/", setSessionCookie(makeToken(acc.id, SECRET)));
      }
      return html(V.renderActivate(acc.name, { action: `/invite/${encodeURIComponent(tok)}`, token: tok }));
    }
    // first sign-in of an invited account via username (alternative to the link)
    if (path === "/activate") {
      if (me) return redirect("/");
      const name = (body.get("name") || query.get("name") || "").trim();
      const acc = getAccount(db, name);
      if (!acc || acc.pw_hash) return redirect("/login"); // unknown or already activated
      if (isPost) {
        if (!sameOrigin(h)) return { status: 403, type: "text/plain", body: "CSRF: bad origin" };
        const pass = body.get("password") || "";
        if (pass.length < 8) return html(V.renderActivate(acc.name, { err: "Password must be ≥ 8 characters." }), 400);
        setPassword(db, acc.id, pass, { mustChange: false });
        return cookie("/", setSessionCookie(makeToken(acc.id, SECRET)));
      }
      return html(V.renderActivate(acc.name));
    }
    if (path === "/logout") return cookie("/login", clearSessionCookie());

    // ----- gate: everything below requires a session -----
    if (!me) {
      if (needSetup) return redirect("/setup");
      return method === "GET" ? redirect("/login") : { status: 401, type: "text/plain", body: "login required" };
    }
    // an admin-issued temporary password must be changed before anything else
    if (me.must_change && path !== "/account") {
      return method === "GET" ? redirect("/account") : { status: 403, type: "text/plain", body: "change your password first" };
    }

    // ----- self-service account (password change) -----
    if (path === "/account") {
      if (isPost) {
        if (!sameOrigin(h)) return { status: 403, type: "text/plain", body: "CSRF: bad origin" };
        const cur = body.get("current") || "", next = body.get("password") || "";
        if (next.length < 8) return html(V.renderAccount(me, "New password must be ≥ 8 characters.", null, sb()), 400);
        if (!verifyPassword(cur, getAccountById(db, me.id).pw_hash)) return html(V.renderAccount(me, "Current password is wrong.", null, sb()), 401);
        setPassword(db, me.id, next, { mustChange: false });
        return html(V.renderAccount({ ...me, must_change: 0 }, null, "Password changed.", sb()));
      }
      return html(V.renderAccount(me, null, null, sb()));
    }
    // ----- admin: user management -----
    if (path.startsWith("/admin/")) {
      if (me.role !== "admin") return { status: 403, type: "text/plain", body: "admins only" };
      if (isPost) {
        if (!sameOrigin(h)) return { status: 403, type: "text/plain", body: "CSRF: bad origin" };
        if (path === "/admin/useradd") {
          // invite by name only — the user sets their own password on first sign-in
          const name = (body.get("name") || "").trim();
          if (name) inviteAccount(db, name, body.get("role") === "admin" ? "admin" : "member");
          return redirect("/admin/users");
        }
        if (path === "/admin/userreset") {
          const id = +body.get("id"); // revoke the password → back to pending; the user re-sets it
          if (id && id !== me.id) revokePassword(db, id);
          return redirect("/admin/users");
        }
        if (path === "/admin/userdel") {
          const id = +body.get("id");
          if (id && id !== me.id) deleteAccount(db, id); // never delete yourself
          return redirect("/admin/users");
        }
        return redirect("/admin/users");
      }
      return html(V.renderAdminUsers(listAccounts(db), me, sb()));
    }

    if (method === "POST") {
      if (!sameOrigin(h)) return { status: 403, type: "text/plain", body: "CSRF: bad origin" };
      // members may only bookmark (personal) + comment (discussion); all management/destructive writes
      // (notes, archive, importance, tags, projects, …) are admin-only. The UI also hides these.
      if (me.role !== "admin" && !(path === "/bookmark" || path.endsWith("/comment") || path.includes("/annotations")))
        return { status: 403, type: "text/plain", body: "admins only" };
      const am = path.match(/^\/api\/note\/(.+)\/annotations(\/del)?$/);
      if (am) {
        const nid = decodeURIComponent(am[1]);
        const note = getNote(db, nid);
        if (!note) return { status: 404, type: "text/plain", body: "no note" };
        if (am[2]) { // /annotations/del — own annotation, or admin
          const a = getNoteAnnotation(db, +body.get("aid"));
          if (a && a.note_id === note.id && (a.user_id === me.id || me.role === "admin")) removeNoteAnnotation(db, a.id);
          return { status: 204, type: "text/plain", body: "" };
        }
        if (!note.pinned) return { status: 403, type: "text/plain", body: "annotations are for structure notes only" };
        const aid = addNoteAnnotation(db, note.id, uid(), { exact: body.get("exact"), prefix: body.get("prefix"), suffix: body.get("suffix") }, body.get("body_md"));
        if (!aid) return { status: 400, type: "text/plain", body: "bad annotation" };
        const a = noteAnnotations(db, note.id).find((x) => x.id === aid);
        return { status: 200, type: "application/json; charset=utf-8", body: JSON.stringify({ ...a, body_html: V.mdHtml(a.body_md), can_delete: true }) };
      }
      if (path === "/bookmark") {
        toggleBookmark(db, uid(), body.get("kind") === "figure" ? "figure" : "record", body.get("id") || "");
        return ok(back(h, "/"));
      }
      if (path === "/importance") {
        const id = body.get("id") || "";
        setRecordImportance(db, id, body.get("value"));
        return ok(`/r/${rid(id)}`);
      }
      if (path === "/figimportance") {
        setFigureImportance(db, body.get("id") || "", body.get("value"));
        return ok(back(h, "/"));
      }
      if (path === "/archive") {
        const id = body.get("id") || "";
        setArchived(db, id, body.get("archived") === "1");
        return ok(`/r/${rid(id)}`);
      }
      if (path === "/tagadd") {
        const id = body.get("id") || "";
        for (const t of parseTags(body.get("tag"))) addTag(db, id, t); // forgiving: "mps tpq" adds both
        return ok(`/r/${rid(id)}`);
      }
      if (path === "/tagdel") {
        const id = body.get("id") || "";
        removeTag(db, id, body.get("tag") || "");
        return ok(`/r/${rid(id)}`);
      }
      if (path === "/projectpara") {
        const name = body.get("name") || "";
        setProjectPara(db, name, body.get("para") || "");
        return ok(`/p/${rid(name)}`);
      }
      if (path === "/projectdesc") {
        const name = body.get("name") || "";
        setProjectDescription(db, name, body.get("description") || "");
        return ok(`/p/${rid(name)}`);
      }
      if (path === "/ptagadd") {
        const name = body.get("name") || "";
        for (const t of parseTags(body.get("tag"))) addProjectTag(db, name, t);
        return ok(`/p/${rid(name)}`);
      }
      if (path === "/ptagdel") {
        const name = body.get("name") || "";
        removeProjectTag(db, name, body.get("tag") || "");
        return ok(`/p/${rid(name)}`);
      }
      if (path === "/todoadd") {
        const name = body.get("name") || "";
        const tid = addTodo(db, name, body.get("body") || "");
        if (xrw) return { status: 200, type: "application/json; charset=utf-8", body: JSON.stringify({ id: tid }) };
        return redirect(`/p/${rid(name)}`);
      }
      if (path === "/todotoggle") {
        toggleTodo(db, body.get("id"));
        return ok(back(h, "/"));
      }
      if (path === "/tododel") {
        removeTodo(db, body.get("id"));
        return ok(back(h, "/"));
      }
      // notes use plain forms (they carry markdown + [[mentions]] that only the server renders), so
      // they redirect back and the page re-renders — no optimistic path.
      if (path === "/noteadd") {
        const scope = body.get("scope") || "";
        const nid = addNote(db, scope, body.get("title") || "", body.get("body") || "",
          { importance: body.get("importance") || 0, pinned: body.get("pinned") === "1", description: body.get("description") || "" });
        if (nid && body.get("tags") !== null) setNoteTags(db, nid, parseTags(body.get("tags")));
        if (body.get("from") === "compose") return redirect(nid ? `/compose?id=${nid}` : "/compose");
        return redirect(scope ? `/p/${rid(scope)}` : "/notes");
      }
      if (path === "/noteedit") {
        const n = getNote(db, body.get("id"));
        const opts = {}; // importance/description absent on the inline note-card edit → leave them
        if (body.get("importance") !== null) opts.importance = body.get("importance");
        if (body.get("description") !== null) opts.description = body.get("description");
        if (n) updateNote(db, n.id, body.get("title") || "", body.get("body") || "", opts);
        if (n && body.get("tags") !== null) setNoteTags(db, n.id, parseTags(body.get("tags")));
        if (body.get("from") === "compose") return redirect(n ? `/compose?id=${n.id}` : "/notes");
        return redirect(n && n.scope ? `/p/${rid(n.scope)}` : "/notes");
      }
      if (path === "/notedel") {
        const n = getNote(db, body.get("id"));
        if (n) removeNote(db, n.id);
        return redirect(n && n.scope ? `/p/${rid(n.scope)}` : "/notes");
      }
      if (path === "/notepin") {
        const n = getNote(db, body.get("id"));
        if (n) setPinned(db, n.id, body.get("pinned") === "1");
        return redirect(n && n.scope ? `/p/${rid(n.scope)}` : "/notes");
      }
      if (path === "/notearchive") {
        const n = getNote(db, body.get("id"));
        if (n) setNoteArchived(db, n.id, body.get("archived") === "1");
        return redirect(back(h, "/notes"));
      }
      // LLM channel: check/uncheck a todo (idempotent). Server-to-server (no Origin) passes the CSRF
      // gate; a cross-origin browser POST is still rejected. The advisor browses pages, not /api.
      {
        const tm = path.match(/^\/api\/project\/(.+)\/todo$/);
        if (tm) {
          const d = String(body.get("done") ?? "1");
          const ok = setTodoDone(db, body.get("id"), d === "1" || d === "true" || d === "done");
          return json({ ok }, ok ? 200 : 404);
        }
      }
      if (path === "/api/note/preview") {
        // inline preview of the composer's CURRENT edits (no save) — a full chrome-free present page,
        // loaded into the composer's preview iframe. Markdown + [[mentions]] + ![[embeds]] resolved here.
        const b = body.get("body") || "";
        const noteLike = {
          id: body.get("id") || "", scope: body.get("scope") || "",
          title: body.get("title") || "", importance: +(body.get("importance") || 0),
          tags: parseTags(body.get("tags")), description: body.get("description") || "",
          body_md: b, mentions: resolveMentions(db, parseMentions(b)), embeds: resolveEmbeds(db, parseEmbeds(b)),
        };
        return html(V.renderNotePreview(noteLike));
      }
      const m = path.match(/^\/r\/(.+)\/comment$/);
      if (m) {
        const id = decodeURIComponent(m[1]);
        if (getRecord(db, id)) {
          const t = (body.get("body_md") || "").trim();
          t && addComment(db, id, uid(), t);
        }
        return ok(`/r/${rid(id)}`);
      }
      const cm = path.match(/^\/note\/(.+)\/comment$/);
      if (cm) {
        const id = decodeURIComponent(cm[1]);
        if (getNote(db, id)) {
          const t = (body.get("body_md") || "").trim();
          t && addNoteComment(db, id, uid(), t);
        }
        return redirect(`/note/${rid(id)}`);
      }
      return { status: 404, type: "text/plain", body: "Not found" };
    }

    if (method !== "GET" && method !== "HEAD")
      return { status: 405, type: "text/plain", body: "Method Not Allowed" };

    const side = () => ({
      projects: projects(db),
      tags: allTags(db),
      bset: bookmarkedSet(db, uid()),
      user: me ? me.display_name || me.name : "",
      admin: !!me && me.role === "admin", // → <body data-role> → CSS hides .admin-only for members
    });

    if (path === "/") {
      const tag = query.get("tag");
      if (tag) return html(V.renderList(`tag: #${tag}`, byTag(db, tag), side()));
      return html(
        V.renderLanding({ recents: recents(db), activity: recentActivity(db), ...side() }),
      );
    }
    if (path === "/search") {
      const q = (query.get("q") || "").trim();
      const project = query.get("project") || "";
      // empty query → fall back to the original full screen (overview / the project page), not a blank result
      if (!q) return redirect(project ? `/p/${rid(project)}` : "/");
      const fields = parseFields(query.getAll("fields"));
      if (project) {
        // scoped: figure + Pinax search within one project (over the selected fields)
        return html(V.renderSearch(q, search(db, q, { project, fields }), { project, fields, ...side() }));
      }
      // from HOME: project search (over the selected fields)
      return html(V.renderProjectSearch(q, searchProjects(db, q, { fields }), { fields, ...side() }));
    }
    if (path === "/gallery") {
      // NOT "/figures": that path is the static figure-file directory on Lolipop (Apache would 403
      // the dir before our router sees it). The gallery page lives at /gallery; files at /figures/*.
      const project = query.get("project");
      const sort = query.get("sort") || "importance";
      return html(V.renderFigures(figuresGallery(db, { project, sort }), { project, sort, ...side() }));
    }
    if (path === "/bookmarks") {
      return html(V.renderBookmarks(userBookmarks(db, uid()), side()));
    }
    if (path === "/archived") {
      return html(V.renderList("🗄 Archived", archivedRecords(db), side()));
    }
    if (path === "/notes") {
      return html(V.renderNotes(allNotesForDisplay(db), side()));
    }
    if (path === "/graph") {
      // the link graph: notes (primary) + the projects/records they reference, drawn from the same
      // [[mention]]/![[embed]] data as the per-note Related panel. Read-only; both roles may view.
      return html(V.renderGraph(side()));
    }
    if (path.startsWith("/show/")) {
      // the advisor-facing view of a pinned structure note: home-style header + sidebar/hamburger menu
      const note = noteForDisplay(db, decodeURIComponent(path.slice(6)));
      return html(V.renderShow(note, side()), note ? 200 : 404);
    }
    if (path.startsWith("/note/")) {
      // "open" a note: the working view — rendered note + related (links/backlinks) + comments
      const id = decodeURIComponent(path.slice(6));
      const note = noteForDisplay(db, id);
      return html(V.renderNoteView(note, note ? noteComments(db, id) : [], note ? relatedNotes(db, id) : [], side()), note ? 200 : 404);
    }
    if (path === "/compose") {
      if (me.role !== "admin") return redirect("/notes"); // composing/editing notes is admin-only
      // the two-pane structure-note composer (pick figures/records to embed + markdown + live preview)
      const nid = query.get("id");
      const note = nid ? noteForDisplay(db, nid) : { scope: query.get("scope") || "", body_md: "", mentions: [], embeds: [] };
      const picker = projects(db).map((p) => ({
        project: p.project,
        records: byProject(db, p.project, { includeArchived: true }).map((r) => ({
          id: r.id, title: r.title, date: r.date, importance: r.importance, tags: recordTags(db, r.id), figures: recordFigures(db, r.id),
        })),
      }));
      return html(V.renderCompose(note, picker));
    }
    if (path.startsWith("/p/")) {
      const project = decodeURIComponent(path.slice(3));
      const sort = query.get("sort") || "date"; // experiments sort
      const fsort = query.get("fsort") || "importance"; // figures sort (independent of experiments)
      return html(
        V.renderProject(project, {
          records: byProject(db, project, { sort }),
          archived: archivedByProject(db, project),
          figures: figuresGallery(db, { project, limit: 60, sort: fsort }),
          meta: projectMeta(db, project),
          notes: notesForDisplay(db, project),
          sort,
          fsort,
          ...side(),
        }),
      );
    }
    {
      // the project-context harness output (human↔LLM↔compute seam): ?format=md → an ingestible pack,
      // else atomic JSON (meta / notes / discussion / records + their datavault_ref + body_md).
      const m = path.match(/^\/api\/project\/(.+)\/context$/);
      if (m) {
        const ctx = projectContext(db, decodeURIComponent(m[1]));
        if (!ctx) return { status: 404, type: "application/json; charset=utf-8", body: "{}" };
        if (query.get("format") === "md")
          return { status: 200, type: "text/markdown; charset=utf-8", body: contextMarkdown(ctx) };
        return json(ctx);
      }
    }
    if (path === "/api/graph") return json(graphData(db)); // {nodes,edges} for the /graph canvas
    {
      // JSON for inject.js (the overlay on a Pinax page): record meta + tags + runs + bookmark + comments
      const m = path.match(/^\/api\/record\/(.+)$/);
      if (m) {
        const id = decodeURIComponent(m[1]);
        const rec = getRecord(db, id);
        if (!rec) return { status: 404, type: "application/json; charset=utf-8", body: "{}" };
        const data = {
          id: rec.id, title: rec.title, project: rec.project, date: rec.date,
          importance: rec.importance, archived: !!rec.archived, admin: me.role === "admin",
          tags: recordTags(db, id), runs: recordRuns(db, id),
          bookmarked: bookmarkedSet(db, uid()).has("record:" + id),
          updated_at: rec.updated_at, // figure-freshness token for the live poll (cache-bust on change)
          comments: recordComments(db, id).map((c) => ({
            id: c.id, author: c.author, created_at: c.created_at, body_html: V.mdHtml(c.body_md),
          })),
        };
        return { status: 200, type: "application/json; charset=utf-8", body: JSON.stringify(data) };
      }
    }
    {
      // structure-note annotations (passage highlights) — for the /show annotator's load + live poll
      const am = path.match(/^\/api\/note\/(.+)\/annotations$/);
      if (am) {
        const id = decodeURIComponent(am[1]);
        if (!getNote(db, id)) return { status: 404, type: "application/json; charset=utf-8", body: "{}" };
        const list = noteAnnotations(db, id).map((a) => ({
          id: a.id, author: a.author, created_at: a.created_at, anchor: a.anchor,
          body_html: V.mdHtml(a.body_md), can_delete: a.user_id === me.id || me.role === "admin",
        }));
        return { status: 200, type: "application/json; charset=utf-8", body: JSON.stringify({ annotations: list }) };
      }
    }
    {
      // JSON for the note "open" view live-poll: merge new comments without losing the draft
      const m = path.match(/^\/api\/note\/([^/]+)$/); // [^/] so it doesn't swallow /…/annotations
      if (m) {
        const id = decodeURIComponent(m[1]);
        const note = getNote(db, id);
        if (!note) return { status: 404, type: "application/json; charset=utf-8", body: "{}" };
        return { status: 200, type: "application/json; charset=utf-8", body: JSON.stringify({
          updated_at: note.updated_at,
          comments: noteComments(db, id).map((c) => ({ id: c.id, author: c.author, created_at: c.created_at, body_html: V.mdHtml(c.body_md) })),
        }) };
      }
    }
    if (path.startsWith("/r/")) {
      const id = decodeURIComponent(path.slice(3));
      const rec = getRecord(db, id);
      // canonical view = the run's own Pinax page (Archeion overlay injected by inject.js) — go there
      if (rec && rec.html_path) return redirect("/" + String(rec.html_path).replace(/^\/+/, ""));
      // fallback for records with no stored Pinax page (legacy / synthetic seed)
      const s = side();
      return html(
        V.renderRecord(rec, {
          figures: rec ? recordFigures(db, id) : [],
          runs: rec ? recordRuns(db, id) : [],
          comments: rec ? recordComments(db, id) : [],
          tags: rec ? recordTags(db, id) : [],
          allTags: s.tags,
          bset: s.bset,
          user: s.user,
          projects: s.projects,
          admin: s.admin,
        }),
        rec ? 200 : 404,
      );
    }
    return html(V.renderRecord(null, side()), 404);
    })();
    // tag <body> with the role so CSS can hide .admin-only controls for members. The server-side gate
    // above is the real enforcement; this is just UX (don't show guests buttons that would 403).
    if (role && r && typeof r.body === "string" && (r.type || "").includes("html") && r.body.includes("<body"))
      r.body = r.body.replace("<body", `<body data-role="${role}"`);
    return r;
  };
}
