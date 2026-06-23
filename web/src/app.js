// Transport-agnostic request handler: (method, path, query) -> { status, type, body }.
// The same handler is driven by the daemon (server.js) now, and a CGI shim later — so the
// app is portable between panza (daemon) and Lolipop (node-as-CGI).
import {
  openDb,
  recents,
  pinned,
  getRecord,
  search,
  facets,
  filterRecords,
} from "./db.js";
import { renderLanding, renderRecord, renderSearch } from "./render.js";

const html = (body, status = 200) => ({
  status,
  type: "text/html; charset=utf-8",
  body,
});

export function createApp(dbPath) {
  const db = openDb(dbPath);
  return function handle(method, path, query) {
    if (method !== "GET" && method !== "HEAD") {
      return { status: 405, type: "text/plain", body: "Method Not Allowed" };
    }
    if (path === "/") {
      const tag = query.get("tag");
      const status = query.get("status");
      const recs =
        tag || status ? filterRecords(db, { tag, status }) : recents(db);
      return html(
        renderLanding({
          pinned: pinned(db),
          recents: recs,
          facets: facets(db),
          activeTag: tag,
          activeStatus: status,
        }),
      );
    }
    if (path === "/search") {
      const q = (query.get("q") || "").trim();
      return html(renderSearch(q, q ? search(db, q) : []));
    }
    if (path.startsWith("/r/")) {
      const id = decodeURIComponent(path.slice(3));
      const rec = getRecord(db, id);
      return html(renderRecord(rec), rec ? 200 : 404);
    }
    return html(renderRecord(null), 404);
  };
}
