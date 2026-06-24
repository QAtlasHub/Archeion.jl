// Shared vocabulary used by BOTH the data layer (db/*) and the views (render/*) — one source of
// truth so the two never drift. PARA = the filing buckets; SEARCH_FIELDS = the toggleable search
// scopes (value + UI label); parseFields validates a request's ?fields= list (empty ⇒ ALL).
export const PARA = ["Projects", "Areas", "Resources", "Archives"];

export const SEARCH_FIELDS = [
  ["title", "Title"], ["description", "description"], ["figtitle", "fig title"], ["figcaption", "fig caption"],
  ["tag", "tag"], ["date", "date"], ["comment", "comment"], ["todo", "todo"],
];
export const FIELD_VALUES = SEARCH_FIELDS.map(([v]) => v);
export const parseFields = (arr) => {
  const f = (Array.isArray(arr) ? arr : []).filter((x) => FIELD_VALUES.includes(x));
  return f.length ? f : FIELD_VALUES; // nothing selected ⇒ ALL
};
