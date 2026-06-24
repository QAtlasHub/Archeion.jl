// Shared internals for the data-layer modules: the column lists every record/figure query selects,
// the record ORDER BY, and the small value-sanitisers. No DB handle, no side effects.
export const REC =
  "r.id, r.project, r.title, r.date, r.importance, r.archived, r.updated_at, " +
  "(SELECT path FROM figures WHERE record_id = r.id ORDER BY ord LIMIT 1) AS thumb"; // gallery preview
export const FIG =
  "f.id, f.record_id, f.path, f.thumbnail, f.caption, f.importance, r.project, r.title AS record_title";

const RECDATE = "COALESCE(NULLIF(r.date,''), r.updated_at) DESC"; // record list default order
export const recOrder = (sort) => (sort === "importance" ? `r.importance DESC, ${RECDATE}` : RECDATE);

export const clampImp = (v) => Math.max(0, Math.min(3, parseInt(v, 10) || 0)); // importance 0..3
export const cleanTag = (name) => String(name || "").replace(/^#/, "").trim();
