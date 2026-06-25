// Stateless signed-cookie sessions — fits node-as-CGI (one process per request, no server-side store).
// A cookie carries `userId.expiry.HMAC(userId.expiry, secret)`; we re-verify the HMAC + expiry each
// request. The secret lives in <dataDir>/session.secret (created once; kept off the web by the
// .htaccess `data/` block). No DB, no sessions table.
import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";

export const SESSION_COOKIE = "arx_session";
const TTL = 30 * 24 * 3600; // 30 days

export function sessionSecret(dbPath) {
  const dir = dirname(dbPath);
  const f = join(dir, "session.secret");
  try { if (existsSync(f)) { const s = readFileSync(f, "utf8").trim(); if (s) return s; } } catch { /* fall through */ }
  const s = randomBytes(32).toString("hex");
  try { mkdirSync(dir, { recursive: true }); writeFileSync(f, s, { mode: 0o600 }); } catch { /* ephemeral if unwritable */ }
  return s;
}

const sign = (payload, secret) => createHmac("sha256", secret).update(payload).digest("hex");
const now = () => Math.floor(Date.now() / 1000);

export function makeToken(userId, secret, ttl = TTL) {
  const payload = `${userId}.${now() + ttl}`;
  return `${payload}.${sign(payload, secret)}`;
}
export function verifyToken(token, secret) {
  if (!token) return null;
  const i = token.lastIndexOf(".");
  if (i < 1) return null;
  const payload = token.slice(0, i), sig = token.slice(i + 1);
  const want = sign(payload, secret);
  const a = Buffer.from(sig), b = Buffer.from(want);
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
  const dot = payload.indexOf(".");
  const id = +payload.slice(0, dot), exp = +payload.slice(dot + 1);
  if (!id || !exp || exp < now()) return null;
  return id;
}

export function parseCookies(header) {
  const out = {};
  for (const part of String(header || "").split(";")) {
    const eq = part.indexOf("=");
    if (eq > 0) out[part.slice(0, eq).trim()] = decodeURIComponent(part.slice(eq + 1).trim());
  }
  return out;
}
// Secure: the site is HTTPS-enforced. SameSite=Lax: sent on top-level navigation (our login flow).
export const setSessionCookie = (token, maxAge = TTL) =>
  `${SESSION_COOKIE}=${encodeURIComponent(token)}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}`;
export const clearSessionCookie = () =>
  `${SESSION_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`;
