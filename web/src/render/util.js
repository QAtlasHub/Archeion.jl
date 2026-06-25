// Low-level view helpers: HTML escaping, id/url encoding, the markdown renderer, and the asset
// version. No DOM, no DB — pure string → string. Shared by every component / page / the layout.
import MarkdownIt from "markdown-it";
import mk from "@vscode/markdown-it-katex";

const md = new MarkdownIt({ html: false, linkify: true });
md.use(mk.default || mk); // server-side KaTeX: $…$ / $$…$$ → KaTeX HTML (parsed before markdown, so x_1 is safe;
//                            the page just needs /katex/katex.min.css + its self-hosted fonts to display).
export { md };
export const mdHtml = (s) => md.render(s || ""); // for the JSON API (inject.js discussion)

// bump on any /app.js or /style.css change → ?v= busts the browser cache (dashboard pages are
// no-store, so a normal reload picks up the new version — no hard refresh needed).
export const ASSET_V = "43";

export const esc = (s) =>
  String(s ?? "").replace(
    /[&<>"]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c],
  );
// record/figure ids contain "/" and ":" — keep "/" literal (Apache routes it), encode the rest.
export const rid = (id) => encodeURIComponent(id).replace(/%2F/gi, "/");
export const snipHtml = (s) =>
  esc(s).replaceAll("", "<mark>").replaceAll("", "</mark>");
export const stars = (n) => "★".repeat(n) + "☆".repeat(Math.max(0, 3 - n));
export const isBk = (set, kind, id) => set && set.has(kind + ":" + id);
export const figUrl = (p) => (/^https?:|^\//.test(p) ? p : "/" + p); // content-store-relative → /figures/…
