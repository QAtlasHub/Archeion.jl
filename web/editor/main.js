// The /compose editor — CodeMirror 6 (Obsidian's engine). It edits RAW markdown (so [[…]] / ![[…]]
// are never serialized/escaped — zero corruption), and a live-preview ViewPlugin renders, INLINE,
// the elements that matter when the cursor isn't on them: $…$ math (KaTeX), ![[id]] figure embeds,
// [[id]] links. Click an element → cursor lands on it → it reveals the raw source (Obsidian feel).
// Bundled to /compose-editor.js (esbuild IIFE). Figure data comes from a CSP-safe JSON island.
import { EditorView, keymap, Decoration, WidgetType, ViewPlugin } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { syntaxHighlighting, defaultHighlightStyle } from "@codemirror/language";
import katex from "katex";

const readJSON = (elid) => { try { return JSON.parse(document.getElementById(elid)?.textContent || "{}"); } catch (_) { return {}; } };
const FIGS = readJSON("arx-figs"); // figure-id → {url, caption}
const RECS = readJSON("arx-recs"); // record-id → {title, thumb, importance, figs, tags, …}
const stars = (n) => "★".repeat(n) + "☆".repeat(Math.max(0, 3 - n));

// an embed target is one of: "<record>:<figid>" (figure), "<record>#<section>" (section), "<record>" (page)
function parseEmbed(raw) {
  const hash = raw.indexOf("#");
  if (hash >= 0) return { kind: "section", record: raw.slice(0, hash), label: raw.slice(hash + 1) };
  const colon = raw.indexOf(":");
  if (colon >= 0) return { kind: "figure", record: raw.slice(0, colon), figid: raw };
  return { kind: "record", record: raw };
}

class MathWidget extends WidgetType {
  constructor(tex) { super(); this.tex = tex; }
  eq(o) { return o.tex === this.tex; }
  toDOM() {
    const el = document.createElement("span");
    el.className = "cm-math";
    try { katex.render(this.tex, el, { throwOnError: false }); } catch (_) { el.textContent = "$" + this.tex + "$"; }
    return el;
  }
}
// an embed renders as a BLOCK that opens its source Pinax page on click (figure = image, section /
// page = a labelled card). It's an <a>; ignoreEvent + an explicit handler open it in a new tab
// (contenteditable would otherwise just place the caret).
class EmbedWidget extends WidgetType {
  constructor(id) { super(); this.id = id; }
  eq(o) { return o.id === this.id; }
  ignoreEvent() { return true; }
  toDOM() {
    const p = parseEmbed(this.id);
    const a = document.createElement("a");
    a.className = "cm-embed cm-embed-" + p.kind;
    let href = "/r/" + p.record; // open centered on the figure / section (the page's inject reads the #frag)
    if (p.kind === "figure") href += "#arxfig=" + encodeURIComponent(p.figid.slice(p.figid.indexOf(":") + 1));
    else if (p.kind === "section") href += "#arxsec=" + encodeURIComponent(p.label);
    a.href = href; a.title = "open " + p.record;
    a.addEventListener("mousedown", (e) => { e.preventDefault(); window.open(a.href, "_blank", "noopener"); });
    const span = (cls, txt) => { const s = document.createElement("span"); s.className = cls; s.textContent = txt; return s; };
    if (p.kind === "figure") {
      const f = FIGS[this.id];
      if (f) { const img = document.createElement("img"); img.src = f.url; img.alt = f.caption || ""; img.loading = "lazy"; a.appendChild(img); if (f.caption) a.appendChild(span("cm-embed-cap", f.caption)); }
      else { a.classList.add("cm-embed-missing"); a.textContent = "![[" + this.id + "]]"; }
    } else if (p.kind === "section") {
      a.append(span("cm-embed-ico", "▦"), span("cm-embed-t", p.label), span("cm-embed-src", ((RECS[p.record] || {}).title || p.record) + " ↗"));
    } else {
      const rec = RECS[p.record] || {};
      if (rec.thumb) { const img = document.createElement("img"); img.src = rec.thumb; img.loading = "lazy"; a.appendChild(img); }
      a.appendChild(span("cm-embed-t", rec.title || p.record));
      const q = [stars(rec.importance || 0)];
      if (typeof rec.figs === "number") q.push(rec.figs + " fig" + (rec.figs === 1 ? "" : "s"));
      a.appendChild(span("cm-embed-src", q.join(" · ")));
    }
    return a;
  }
}
class LinkWidget extends WidgetType {
  constructor(id) { super(); this.id = id; }
  eq(o) { return o.id === this.id; }
  toDOM() { const a = document.createElement("span"); a.className = "cm-wikilink"; a.textContent = this.id; return a; }
}

const RE = /\$([^$\n]+?)\$|!\[\[([^\]\n]+?)\]\]|(?<!!)\[\[([^\]\n]+?)\]\]/g;
function buildDecos(view) {
  const widgets = [];
  const sel = view.state.selection.main;
  for (const { from, to } of view.visibleRanges) {
    const text = view.state.doc.sliceString(from, to);
    let m;
    RE.lastIndex = 0;
    while ((m = RE.exec(text))) {
      const s = from + m.index, e = s + m[0].length;
      if (sel.from <= e && sel.to >= s) continue; // cursor on it → show raw source (editable)
      let w;
      if (m[1] !== undefined) w = new MathWidget(m[1].trim());
      else if (m[2] !== undefined) w = new EmbedWidget(m[2].trim());
      else if (m[3] !== undefined) w = new LinkWidget(m[3].trim());
      if (w) widgets.push(Decoration.replace({ widget: w }).range(s, e));
    }
  }
  return Decoration.set(widgets, true);
}
const livePreview = ViewPlugin.fromClass(
  class {
    constructor(view) { this.decorations = buildDecos(view); }
    update(u) { if (u.docChanged || u.selectionSet || u.viewportChanged) this.decorations = buildDecos(u.view); }
  },
  { decorations: (v) => v.decorations },
);

function mount() {
  const host = document.getElementById("cmp-editor");
  const hidden = document.getElementById("cmp-body");
  if (!host || !hidden) return;
  const sync = (v) => { hidden.value = v.state.doc.toString(); };
  const view = new EditorView({
    doc: hidden.value,
    parent: host,
    extensions: [
      history(),
      keymap.of([...defaultKeymap, ...historyKeymap]),
      markdown(),
      syntaxHighlighting(defaultHighlightStyle),
      EditorView.lineWrapping,
      livePreview,
      EditorView.updateListener.of((u) => { if (u.docChanged) sync(u.view); }),
    ],
  });
  hidden.style.display = "none";
  hidden.form?.addEventListener("submit", () => sync(view)); // belt-and-braces before POST
  // refs "+" inserts raw markdown at the cursor (CM6 edits source, so ![[id]] stays intact)
  window.arxInsert = (text) => {
    const { from, to } = view.state.selection.main;
    const before = view.state.doc.sliceString(0, from);
    // figures insert INLINE (space-separated) so consecutive ones flow into columns; sections/pages
    // take their own line (they're block viewers).
    const isFig = /^!\[\[[^#\]]*:[^#\]]*\]\]$/.test(text);
    const ins = isFig
      ? (before && !/\s$/.test(before) ? " " : "") + text + " "
      : (before && !before.endsWith("\n") ? "\n" : "") + text + "\n";
    view.dispatch({ changes: { from, to, insert: ins }, selection: { anchor: from + ins.length } });
    sync(view); view.focus();
  };
  // the refs iframe (live Archeion) posts embed codes when you click ⧉ / "add to note"
  window.addEventListener("message", (e) => {
    if (e.origin !== location.origin) return;
    if (e.data && e.data.type === "arx-embed" && typeof e.data.code === "string") window.arxInsert(e.data.code);
  });
}
if (document.readyState !== "loading") mount();
else document.addEventListener("DOMContentLoaded", mount);
