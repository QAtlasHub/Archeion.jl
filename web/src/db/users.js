// App-level accounts (login identity) — layered ABOVE the shared Basic-auth gate, which keeps the whole
// site private. These give per-person attribution (comments / bookmarks) + self-service password change.
// Passwords are scrypt-hashed (node builtin, no deps). App-owned; ingest never touches them.
import { randomBytes, scryptSync, timingSafeEqual } from "node:crypto";

const N = 16384, R = 8, P = 1, KEYLEN = 32; // scrypt cost (~16 MB, ~50–100 ms per hash)

export function hashPassword(pass) {
  const salt = randomBytes(16);
  const dk = scryptSync(String(pass), salt, KEYLEN, { N, r: R, p: P });
  return `scrypt$${N}$${R}$${P}$${salt.toString("hex")}$${dk.toString("hex")}`;
}
export function verifyPassword(pass, stored) {
  if (!stored || typeof stored !== "string" || !stored.startsWith("scrypt$")) return false;
  const [, n, r, p, saltHex, hashHex] = stored.split("$");
  let dk;
  try {
    const want = Buffer.from(hashHex, "hex");
    dk = scryptSync(String(pass), Buffer.from(saltHex, "hex"), want.length, { N: +n, r: +r, p: +p });
    return dk.length === want.length && timingSafeEqual(dk, want);
  } catch {
    return false;
  }
}

const norm = (s) => String(s || "").trim();
export function getAccount(db, name) {
  return db.prepare("SELECT id, name, display_name, pw_hash, role, must_change FROM users WHERE name = ?").get(norm(name));
}
export function getAccountById(db, id) {
  return db.prepare("SELECT id, name, display_name, pw_hash, role, must_change FROM users WHERE id = ?").get(id);
}
// real accounts = rows WITH a password (excludes any legacy/trusted name-only rows)
export function countAccounts(db) {
  return db.prepare("SELECT COUNT(*) c FROM users WHERE pw_hash IS NOT NULL").get().c;
}
export function listAccounts(db) {
  return db.prepare("SELECT id, name, display_name, role, must_change, created_at FROM users WHERE pw_hash IS NOT NULL ORDER BY role, name").all();
}
// create (or claim a legacy name-only row). Returns the id, or null if a real account already owns the name.
export function createAccount(db, name, pass, { role = "member", mustChange = false, displayName = null } = {}) {
  name = norm(name);
  if (!name || !pass) return null;
  const r = role === "admin" ? "admin" : "member";
  const ex = getAccount(db, name);
  if (ex && ex.pw_hash) return null; // name taken by a real account
  if (ex) { // legacy / trusted row without a password → claim it
    db.prepare("UPDATE users SET pw_hash=?, role=?, must_change=?, display_name=COALESCE(?,display_name) WHERE id=?")
      .run(hashPassword(pass), r, mustChange ? 1 : 0, displayName, ex.id);
    return ex.id;
  }
  return db.prepare("INSERT INTO users (name, display_name, pw_hash, role, must_change) VALUES (?,?,?,?,?)")
    .run(name, displayName, hashPassword(pass), r, mustChange ? 1 : 0).lastInsertRowid;
}
export function setPassword(db, id, pass, { mustChange = false } = {}) {
  if (!pass) return false;
  db.prepare("UPDATE users SET pw_hash=?, must_change=? WHERE id=?").run(hashPassword(pass), mustChange ? 1 : 0, id);
  return true;
}
export function verifyLogin(db, name, pass) {
  const a = getAccount(db, name);
  return a && a.pw_hash && verifyPassword(pass, a.pw_hash) ? a : null;
}
export function deleteAccount(db, id) {
  return db.prepare("DELETE FROM users WHERE id = ?").run(id).changes;
}
// daemon/tests trusted bypass: get-or-create a name as an admin (no password — never used for login)
export function ensureTrustedAdmin(db, name) {
  name = norm(name) || "you";
  db.prepare("INSERT OR IGNORE INTO users (name, role) VALUES (?, 'admin')").run(name);
  const a = getAccount(db, name);
  return { ...a, role: "admin" };
}
