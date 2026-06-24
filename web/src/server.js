// Daemon adapter (panza): a plain node:http server over the transport-agnostic app.
// Serves /style.css and /figures/* (content store) statically; parses form POSTs; forwards
// Origin/Host/Referer + the user; sets security headers. Env: ARCHEION_DB, ARCHEION_CONTENT,
// ARCHEION_USER, HOST, PORT.
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { dirname, join, normalize, extname } from "node:path";
import { readFile } from "node:fs/promises";
import { Buffer } from "node:buffer";
import { createApp } from "./app.js";

const here = dirname(fileURLToPath(import.meta.url));
const DB = process.env.ARCHEION_DB || join(here, "..", "data", "archeion.db");
const PUBLIC = join(here, "..", "public");
const CONTENT = process.env.ARCHEION_CONTENT || join(here, "..", "data");
const HOST = process.env.HOST || "127.0.0.1";
const PORT = Number(process.env.PORT || 8090);
const USER = process.env.ARCHEION_USER || "you";

const SECURITY_HEADERS = {
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Referrer-Policy": "same-origin",
  "Content-Security-Policy":
    "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; form-action 'self'; base-uri 'none'",
};
// Headers for the embedded Pinax pages (/pages/*): framable by our own dashboard, and WITHOUT the
// strict app CSP so the run's own page (KaTeX CDN, its inline styles) renders unbroken. It's our
// own trusted render output, served behind the same Basic auth.
const FRAME_HEADERS = {
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "SAMEORIGIN",
  "Referrer-Policy": "same-origin",
};
const MIME = {
  ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
  ".gif": "image/gif", ".webp": "image/webp", ".pdf": "application/pdf",
  ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8",
};

async function readForm(req) {
  if (req.method !== "POST") return undefined;
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > 1_000_000) throw new Error("request body too large");
    chunks.push(c);
  }
  return new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
}

async function serveStatic(res, base, rel, headers = SECURITY_HEADERS) {
  const p = normalize(join(base, rel));
  if (!p.startsWith(normalize(base))) {
    res.writeHead(403);
    return res.end();
  }
  try {
    const data = await readFile(p);
    res.writeHead(200, {
      "content-type": MIME[extname(p).toLowerCase()] || "application/octet-stream",
      ...headers,
    });
    res.end(data);
  } catch {
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("not found");
  }
}

const app = createApp(DB);

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
    if (req.method === "GET" && ["/style.css", "/app.js", "/inject.js", "/inject.css"].includes(url.pathname)) {
      return serveStatic(res, PUBLIC, url.pathname.slice(1));
    }
    if (req.method === "GET" && url.pathname.startsWith("/figures/")) {
      return serveStatic(res, CONTENT, url.pathname.replace(/^\/+/, ""));
    }
    if (req.method === "GET" && url.pathname.startsWith("/pages/")) {
      return serveStatic(res, CONTENT, url.pathname.replace(/^\/+/, ""), FRAME_HEADERS);
    }
    const body = await readForm(req);
    const r = app(req.method, url.pathname, url.searchParams, {
      headers: {
        origin: req.headers.origin,
        host: req.headers.host,
        referer: req.headers.referer,
        xrw: req.headers["x-requested-with"],
        user: USER,
      },
      body,
    });
    // no-store on dynamic responses (not static assets): a post-write 303 → record GET must not
    // be served from the browser/bfcache, or the write "doesn't reflect" until a hard refresh.
    res.writeHead(r.status, {
      "content-type": r.type, "cache-control": "no-store, max-age=0",
      ...SECURITY_HEADERS, ...(r.headers || {}),
    });
    res.end(req.method === "HEAD" ? undefined : r.body);
  } catch (err) {
    res.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
    res.end("Internal error: " + err.message);
  }
});

server.listen(PORT, HOST, () =>
  console.log(`archeion-web → http://${HOST}:${PORT}  (db: ${DB}, content: ${CONTENT})`),
);
