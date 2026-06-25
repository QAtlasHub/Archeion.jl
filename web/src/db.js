// Registry data layer (schema v3) — re-export surface. The implementation is split by domain under
// db/* (one table-group per file); consumers import from "./db.js" unchanged. Two recall axes:
// records (experiments) and figures. Shared annotation = importance/archived/tags; per-user =
// bookmarks/comments. See db/util.js for the shared column lists and the project-meta migration in
// db/open.js.
export { openDb } from "./db/open.js";
export { PARA, parseFields } from "./constants.js";
export * from "./db/records.js";
export * from "./db/figures.js";
export * from "./db/projects.js";
export * from "./db/tags.js";
export * from "./db/search.js";
export * from "./db/annotations.js";
export * from "./db/users.js";
export * from "./db/notes.js";
export * from "./db/context.js";
