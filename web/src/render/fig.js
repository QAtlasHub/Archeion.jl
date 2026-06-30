// Shared figure/link helpers — the SINGLE source of truth for how a figure is previewed and where its
// link goes. Imported by BOTH the server renderer (render/util.js → components/notes/pages) AND the
// CodeMirror editor (editor/main.js), so the composer's inline embeds, the live preview, and /show all
// agree (no drift). Pure string helpers, NO heavy deps (markdown-it/katex) so the editor bundle stays lean.

export const esc = (s) =>
  String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// record/figure ids contain "/" and ":" — keep "/" literal (Apache routes it), encode the rest.
export const rid = (id) => encodeURIComponent(id).replace(/%2F/gi, "/");

export const figUrl = (p) => (/^https?:|^\//.test(p) ? p : "/" + p); // content-store-relative → /figures/…

export const isPdf = (p) => /\.pdf($|[?#])/i.test(p || "");

// A figure preview. PDF can't render in <img> (the file is there but the browser shows a broken image),
// so embed it in a NON-interactive <iframe> = the browser's PDF viewer shows the figure; raster
// (svg/png/gif) stays an <img>. `pointer-events:none` (CSS) lets a wrapping <a> take the click.
export const figMedia = (p, alt = "", cls = "") =>
  isPdf(p)
    ? `<iframe loading="lazy" class="pdfthumb ${cls}" src="${esc(figUrl(p))}#toolbar=0&navpanes=0&view=FitH" title="${esc(alt)}"></iframe>`
    : `<img loading="lazy" class="${cls}" src="${esc(figUrl(p))}" alt="${esc(alt)}">`;

// A figure's link target. In a MULTI-PAGE Pinax doc the figure lives on a SUB-PAGE (not the record's
// index/cards page), so /r/<record> would land on the cards and never show the figure. The section
// figure id is "<page>_s_fig<n>" → the sub-page file is "<page>.html"; link straight there, centred via
// #arxfig (annot.js focuses it). Single-page docs (no "_s_fig" id) fall back to /r/<record>.
// `figSuffix` is the part after "record:" (the Pinax figure id).
export const figHref = (recordId, figSuffix) => {
  const m = /^(.+)_s_fig\d+$/.exec(figSuffix || "");
  if (m) {
    const safe = String(recordId).replace(/[^A-Za-z0-9_-]/g, "_");
    return `/pages/${safe}/${m[1]}.html#arxfig=${encodeURIComponent(figSuffix)}`;
  }
  return `/r/${rid(recordId)}#arxfig=${encodeURIComponent(figSuffix)}`;
};
