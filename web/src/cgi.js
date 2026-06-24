// node-as-CGI entry for Lolipop. The PHP front controller (deploy/lolipop/index.php) gathers
// the request and invokes `node --experimental-sqlite cgi.js`, passing method/path/query/
// origin/host via ARCHEION_* env and the POST body via stdin. We run the same transport-
// agnostic app handler and write back: one JSON meta line, then the body. PHP parses that.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createApp } from "./app.js";

const here = dirname(fileURLToPath(import.meta.url));
const DB = process.env.ARCHEION_DB || join(here, "data", "archeion.db");

const method = process.env.ARCHEION_METHOD || "GET";
const path = process.env.ARCHEION_PATH || "/";
const query = new URLSearchParams(process.env.ARCHEION_QUERY || "");
const headers = {
  origin: process.env.ARCHEION_ORIGIN || "",
  host: process.env.ARCHEION_HOST || "",
  xrw: process.env.ARCHEION_XRW || "", // X-Requested-With: fetch → write routes reply 204
};

let body;
if (method === "POST") {
  let raw = "";
  try {
    raw = readFileSync(0, "utf8"); // stdin
  } catch {
    raw = "";
  }
  body = new URLSearchParams(raw);
}

let r;
try {
  r = createApp(DB)(method, path, query, { headers, body });
} catch (err) {
  r = { status: 500, type: "text/plain; charset=utf-8", body: "Internal error: " + err.message };
}

process.stdout.write(
  JSON.stringify({ status: r.status, type: r.type, headers: r.headers || {} }) + "\n",
);
if (method !== "HEAD") process.stdout.write(r.body || "");
