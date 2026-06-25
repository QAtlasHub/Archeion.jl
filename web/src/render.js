// HTML views (schema v3) — re-export surface. Server-rendered; body_md → HTML via markdown-it,
// everything else escaped. The implementation is split under render/*: util.js (helpers + the
// markdown renderer + ASSET_V), components.js (cards/forms/field selector), layout.js (the page
// shell), pages.js (record/figure/project views), notes.js (the Zettelkasten note layer). Consumers
// import from "./render.js" unchanged.
export { mdHtml } from "./render/util.js";
export * from "./render/pages.js";
export * from "./render/notes.js";
export * from "./render/graph.js";
export * from "./render/auth.js";
