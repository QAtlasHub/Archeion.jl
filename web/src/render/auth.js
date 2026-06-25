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
  const rows = accounts.map((a) => `<tr>
    <td>${esc(a.name)}${a.id === me.id ? ' <span class="muted">(you)</span>' : ""}</td>
    <td>${esc(a.role)}</td>
    <td>${a.must_change ? '<span class="muted">temp pw — must change</span>' : ""}</td>
    <td class="admin-acts">
      <form method="post" action="/admin/userreset" class="inline"><input type="hidden" name="id" value="${a.id}"><input name="password" type="password" placeholder="new temp pw (≥8)" minlength="8" required><button>reset</button></form>
      ${a.id === me.id ? "" : `<form method="post" action="/admin/userdel" class="inline" onsubmit="return confirm('Delete ${esc(a.name)}?')"><input type="hidden" name="id" value="${a.id}"><button class="danger">delete</button></form>`}
    </td></tr>`).join("");
  const main = `<h2>Users <span class="muted">(${accounts.length})</span></h2>
    <p class="muted">Add collaborators with a temporary password; they set their own on first sign-in. The shared Basic-auth gate is separate (one password for the whole site).</p>
    <table class="admin-users"><thead><tr><th>user</th><th>role</th><th>status</th><th></th></tr></thead><tbody>${rows}</tbody></table>
    <h3>Add user</h3>
    <form method="post" action="/admin/useradd" class="auth-form">
      <label>Username <input name="name" required></label>
      <label>Temporary password <input name="password" type="password" required minlength="8" placeholder="≥ 8 characters"></label>
      <label>Role <select name="role"><option value="member">member</option><option value="admin">admin</option></select></label>
      <button>Add user</button>
    </form>`;
  return layout("Users", main, { user: me.display_name || me.name, projects, tags });
}
