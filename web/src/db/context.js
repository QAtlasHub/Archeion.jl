// The project-context harness output — the human↔LLM↔compute seam. Given a project, aggregate the
// HUMAN-authored context (status / description / tags / todos / notes / discussion) + the records
// (Pinax artifacts) with their compute pointers (record_runs.datavault_ref) and RAG text (body_md),
// in an ATOMIC form (every note / todo / comment / record carries a stable id) that an agent can drop
// straight into context. projectContext → JSON; contextMarkdown → a single ingestible md pack.
// Aligns in spirit with Pinax's agent.json (data, not pixels; status-aware).
import { projectMeta } from "./projects.js";
import { recordTags, recordRuns, recordComments } from "./records.js";
import { notesForDisplay, parseMentions, resolveMentions } from "./notes.js";

// Related PAST experiments elsewhere in the registry — the LLM's "have we done something like this?"
// memory. Deterministic relatedness (RAG dropped): shared tags, explicit note [[mentions]], and a
// shared DataVault run (same computed data). Each hit carries a `why` so the LLM knows the link.
export function relatedRecords(db, project, { limit = 20 } = {}) {
  const why = {};
  const add = (id, reason) => { if (id) (why[id] ||= new Set()).add(reason); };
  // (a) shared tags: this project's record tags + project tags → records in OTHER projects
  const myTags = new Set([
    ...db.prepare("SELECT DISTINCT t.name FROM record_tags rt JOIN tags t ON t.id = rt.tag_id JOIN records r ON r.id = rt.record_id WHERE r.project = ?").all(project).map((r) => r.name),
    ...db.prepare("SELECT t.name FROM project_tags pt JOIN tags t ON t.id = pt.tag_id WHERE pt.project = ?").all(project).map((r) => r.name),
  ]);
  for (const tag of myTags)
    for (const r of db.prepare("SELECT r.id FROM records r JOIN record_tags rt ON rt.record_id = r.id JOIN tags t ON t.id = rt.tag_id WHERE t.name = ? AND r.project <> ?").all(tag, project))
      add(r.id, `tag:${tag}`);
  // (b) explicit mentions in this project's notes
  for (const n of db.prepare("SELECT body_md FROM notes WHERE scope = ?").all(project))
    for (const m of resolveMentions(db, parseMentions(n.body_md))) {
      if (m.kind === "record") add(m.target, "note-mention");
      else if (m.kind === "project")
        for (const r of db.prepare("SELECT id FROM records WHERE project = ?").all(m.target)) add(r.id, "note-mention");
    }
  // (c) shared DataVault run lineage (literally the same computed data)
  for (const { p, run } of db.prepare("SELECT DISTINCT rr.project AS p, rr.run AS run FROM record_runs rr JOIN records r ON r.id = rr.record_id WHERE r.project = ?").all(project))
    for (const r of db.prepare("SELECT r.id FROM record_runs rr JOIN records r ON r.id = rr.record_id WHERE rr.project = ? AND rr.run = ? AND r.project <> ?").all(p, run, project))
      add(r.id, `run:${p}/${run}`);
  const out = Object.keys(why)
    .map((id) => { const r = db.prepare("SELECT id, project, title, importance FROM records WHERE id = ?").get(id); return r ? { ...r, why: [...why[id]] } : null; })
    .filter((r) => r && r.project !== project); // a same-project mention isn't "elsewhere"
  out.sort((a, b) => b.why.length - a.why.length || (b.importance || 0) - (a.importance || 0));
  return out.slice(0, limit);
}

export function projectContext(db, name, { recordLimit = 200 } = {}) {
  const meta = projectMeta(db, name);
  if (!meta) return null;
  const notes = notesForDisplay(db, name).map((n) => ({
    id: n.id, title: n.title, body_md: n.body_md, updated: n.updated_at, mentions: n.mentions,
  }));
  const recs = db
    .prepare(
      `SELECT id, title, importance, archived, date, body_md FROM records WHERE project = ?
       ORDER BY importance DESC, COALESCE(NULLIF(date,''), updated_at) DESC LIMIT ?`,
    )
    .all(name, recordLimit);
  const records = recs.map((r) => ({
    id: r.id, title: r.title, importance: r.importance, archived: !!r.archived, date: r.date,
    tags: recordTags(db, r.id),
    runs: recordRuns(db, r.id), // {project, run, datavault_ref} — the DataVault compute seam
    comments: recordComments(db, r.id).map((c) => ({ author: c.author, created_at: c.created_at, body_md: c.body_md })),
    body_md: r.body_md, // RAG text (title + page/section descriptions + captions)
  }));
  return {
    schema: "archeion/project-context@1",
    project: meta.name,
    status: meta.para, // PARA bucket
    description_md: meta.description,
    tags: meta.tags,
    todos: meta.todos,
    created: meta.created,
    updated: meta.updated_at,
    notes,
    records,
    related: relatedRecords(db, name), // past experiments elsewhere (shared tags / mentions / runs)
  };
}

// the same context as one ingestible markdown pack (for a human to copy, or an agent that wants text)
export function contextMarkdown(ctx) {
  if (!ctx) return "";
  const L = [`# ${ctx.project} — project context`,
    `*status:* ${ctx.status} · *tags:* ${ctx.tags.join(", ") || "—"} · *updated:* ${(ctx.updated || "").slice(0, 10)}`];
  if ((ctx.description_md || "").trim()) L.push("", "## Description", ctx.description_md.trim());
  if (ctx.todos.length) { L.push("", "## Todos"); for (const t of ctx.todos) L.push(`- [${t.done ? "x" : " "}] ${t.body}`); }
  if (ctx.notes.length) {
    L.push("", "## Notes");
    for (const n of ctx.notes) { L.push("", `### note ${n.id}${n.title ? ` — ${n.title}` : ""}`); L.push(n.body_md.trim()); }
  }
  if (ctx.records.length) {
    L.push("", "## Records (experiments)");
    for (const r of ctx.records) {
      L.push("", `### ${r.title}  \`${r.id}\``);
      const bits = [`importance ${r.importance}`];
      if (r.tags.length) bits.push(`tags: ${r.tags.join(", ")}`);
      if (r.archived) bits.push("archived");
      L.push(`*${bits.join(" · ")}*`);
      if (r.runs.length) L.push(`runs: ${r.runs.map((x) => `${x.project}/${x.run}${x.datavault_ref ? ` [${x.datavault_ref}]` : ""}`).join(", ")}`);
      if ((r.body_md || "").trim()) L.push("", r.body_md.trim());
      for (const c of r.comments) L.push(`> **${c.author}:** ${c.body_md}`);
    }
  }
  if (ctx.related?.length) {
    L.push("", "## Related (past experiments elsewhere)");
    for (const r of ctx.related) L.push(`- ${r.title} \`${r.id}\` (${r.project}) — ${r.why.join(", ")}`);
  }
  return L.join("\n");
}
