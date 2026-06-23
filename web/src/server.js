// Daemon adapter (panza): a plain node:http server over the transport-agnostic app.
// Env: ARCHEION_DB (db path), HOST, PORT. Serves /style.css statically; everything else
// goes through the app handler.
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { readFile } from "node:fs/promises";
import { createApp } from "./app.js";

const here = dirname(fileURLToPath(import.meta.url));
const DB = process.env.ARCHEION_DB || join(here, "..", "data", "archeion.db");
const PUBLIC = join(here, "..", "public");
const HOST = process.env.HOST || "127.0.0.1";
const PORT = Number(process.env.PORT || 8090);

const app = createApp(DB);

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
    if (url.pathname === "/style.css") {
      const css = await readFile(join(PUBLIC, "style.css"));
      res.writeHead(200, { "content-type": "text/css; charset=utf-8" });
      return res.end(css);
    }
    const r = app(req.method, url.pathname, url.searchParams);
    res.writeHead(r.status, { "content-type": r.type });
    res.end(req.method === "HEAD" ? undefined : r.body);
  } catch (err) {
    res.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
    res.end("Internal error: " + err.message);
  }
});

server.listen(PORT, HOST, () =>
  console.log(`archeion-web → http://${HOST}:${PORT}  (db: ${DB})`),
);
