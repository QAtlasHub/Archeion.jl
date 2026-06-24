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
  parseMentions, resolveMentions, parseEmbeds, resolveEmbeds,
  projectContext, contextMarkdown, setTodoDone,
} from "./db.js";
import * as V from "./render.js";

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
  return function handle(method, path, query, opts = {}) {
    const h = opts.headers || {};
    const body = opts.body || new URLSearchParams();
    const uid = () => ensureUser(db, h.user || "");
    // fetch() writes send X-Requested-With: fetch and want 204 (no redirect → no re-render → no
    // stale read-back on Lolipop NFS). Plain form posts (no header) still get the 303 redirect.
    const xrw = (h.xrw || "") === "fetch";
    const ok = (loc) => (xrw ? { status: 204, type: "text/plain; charset=utf-8", body: "" } : redirect(loc));

    if (method === "POST") {
      if (!sameOrigin(h)) return { status: 403, type: "text/plain", body: "CSRF: bad origin" };
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
      user: h.user || "",
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
    if (path.startsWith("/show/")) {
      // the advisor-facing view of a pinned structure note: home-style header + sidebar/hamburger menu
      const note = noteForDisplay(db, decodeURIComponent(path.slice(6)));
      return html(V.renderShow(note, side()), note ? 200 : 404);
    }
    if (path.startsWith("/note/")) {
      // "open" a note: the working view — rendered note + comments / annotations (a normal app page)
      const id = decodeURIComponent(path.slice(6));
      const note = noteForDisplay(db, id);
      return html(V.renderNoteView(note, note ? noteComments(db, id) : [], side()), note ? 200 : 404);
    }
    if (path === "/compose") {
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
    {
      // JSON for inject.js (the overlay on a Pinax page): record meta + tags + runs + bookmark + comments
      const m = path.match(/^\/api\/record\/(.+)$/);
      if (m) {
        const id = decodeURIComponent(m[1]);
        const rec = getRecord(db, id);
        if (!rec) return { status: 404, type: "application/json; charset=utf-8", body: "{}" };
        const data = {
          id: rec.id, title: rec.title, project: rec.project, date: rec.date,
          importance: rec.importance, archived: !!rec.archived,
          tags: recordTags(db, id), runs: recordRuns(db, id),
          bookmarked: bookmarkedSet(db, uid()).has("record:" + id),
          comments: recordComments(db, id).map((c) => ({
            author: c.author, created_at: c.created_at, body_html: V.mdHtml(c.body_md),
          })),
        };
        return { status: 200, type: "application/json; charset=utf-8", body: JSON.stringify(data) };
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
        }),
        rec ? 200 : 404,
      );
    }
    return html(V.renderRecord(null, side()), 404);
  };
}
