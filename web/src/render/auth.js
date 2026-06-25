// Auth pages: first-run setup, login, self-service account (password change), and the admin user list.
// login/setup use a minimal centered shell (no sidebar — the user isn't in yet); account/admin use the
// normal app layout (they're logged-in pages). Re-exported via render.js.
import { esc, ASSET_V } from "./util.js";
import { layout } from "./layout.js";

function authShell(title, main) {
  return `<!doctype html><html lang="ja"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><link rel="stylesheet" href="/style.css?v=${ASSET_V}"></head>
<body class="auth-body"><main class="auth-card"><h1 class="auth-brand">Archeion</h1>${main}</main></body></html>`;
}
const errBox = (msg) => (msg ? `<p class="auth-err">${esc(msg)}</p>` : "");
const okBox = (msg) => (msg ? `<p class="auth-ok">${esc(msg)}</p>` : "");

export function renderSetup(err) {
  return authShell("Set up Archeion", `<h2>Create the admin account</h2>
    <p class="muted">First-run setup — this becomes the administrator (can add other users).</p>
    ${errBox(err)}
    <form method="post" action="/setup" class="auth-form">
      <label>Username <input name="name" autocomplete="username" required autofocus></label>
      <label>Password <input name="password" type="password" autocomplete="new-password" required minlength="8" placeholder="≥ 8 characters"></label>
      <button>Create admin &amp; sign in</button>
    </form>`);
}

export function renderLogin(err) {
  return authShell("Sign in · Archeion", `<h2>Sign in</h2>
    ${errBox(err)}
    <form method="post" action="/login" class="auth-form">
      <label>Username <input name="name" autocomplete="username" required autofocus></label>
      <label>Password <input name="password" type="password" autocomplete="current-password" required></label>
      <button>Sign in</button>
    </form>`);
}

// activation = a pending invite (admin set the name; no password yet) sets their OWN password.
// Reached by the invite link (/invite/<token>, token → no username needed) or by login with a
// pending username (→ action "/activate" + hidden name).
export function renderActivate(name, { err = null, action = "/activate", token = "" } = {}) {
  const hidden = token ? "" : `<input type="hidden" name="name" value="${esc(name)}">`;
  return authShell("Set your password · Archeion", `<h2>Welcome, ${esc(name)}</h2>
    <p class="muted">Choose your own password to activate your account.</p>
    ${errBox(err)}
    <form method="post" action="${esc(action)}" class="auth-form">
      ${hidden}
      <label>New password <input name="password" type="password" autocomplete="new-password" required minlength="8" placeholder="≥ 8 characters" autofocus></label>
      <button>Set password &amp; sign in</button>
    </form>`);
}

// account = self-service password change (+ admin gets a link to user management)
export function renderAccount(me, err, ok, { projects = [], tags = [] } = {}) {
  const adminLink = me.role === "admin" ? `<p><a href="/admin/users">Manage users →</a></p>` : "";
  const forced = me.must_change ? `<p class="auth-err">Set a new password to continue (an admin gave you a temporary one).</p>` : "";
  const main = `<h2>Account — ${esc(me.display_name || me.name)} <span class="muted">(${esc(me.role)})</span></h2>
    ${forced}${errBox(err)}${okBox(ok)}
    <form method="post" action="/account" class="auth-form acct-form">
      <label>Current password <input name="current" type="password" autocomplete="current-password" required></label>
      <label>New password <input name="password" type="password" autocomplete="new-password" required minlength="8" placeholder="≥ 8 characters"></label>
      <button>Change password</button>
    </form>
    ${adminLink}`;
  return layout("Account", main, { user: me.display_name || me.name, projects, tags });
}

export function renderAdminUsers(accounts, me, { projects = [], tags = [] } = {}) {
  const rows = accounts.map((a) => {
    const del = `<form method="post" action="/admin/userdel" class="inline" onsubmit="return confirm('Delete ${esc(a.name)}?')"><input type="hidden" name="id" value="${a.id}"><button class="danger">delete</button></form>`;
    const acts = a.id === me.id
      ? '<span class="muted">—</span>'
      : a.pending
        ? `<button type="button" class="copy-link" data-path="/invite/${esc(a.invite_token)}">copy invite link</button>${del}`
        : `<form method="post" action="/admin/userreset" class="inline" onsubmit="return confirm('Reset ${esc(a.name)}? They set a new password via a fresh invite link.')"><input type="hidden" name="id" value="${a.id}"><button>reset password</button></form>${del}`;
    return `<tr>
      <td>${esc(a.name)}${a.id === me.id ? ' <span class="muted">(you)</span>' : ""}</td>
      <td>${esc(a.role)}</td>
      <td><span class="muted">${a.pending ? "invited" : "active"}</span></td>
      <td class="admin-acts">${acts}</td></tr>`;
  }).join("");
  const main = `<h2>Users <span class="muted">(${accounts.length})</span></h2>
    <p class="muted">Invite a collaborator by <strong>username only</strong>, then send them the <strong>invite link</strong> (copy it from the row) — they open it and set their own password (you never see it). They'll also need the shared site password (Basic auth). "Reset" revokes the password and makes a fresh link.</p>
    <table class="admin-users"><thead><tr><th>user</th><th>role</th><th>status</th><th></th></tr></thead><tbody>${rows}</tbody></table>
    <h3>Invite user</h3>
    <form method="post" action="/admin/useradd" class="auth-form">
      <label>Username <input name="name" required autocomplete="off"></label>
      <label>Role <select name="role"><option value="member">member</option><option value="admin">admin</option></select></label>
      <button>Invite</button>
    </form>`;
  return layout("Users", main, { user: me.display_name || me.name, projects, tags });
}
