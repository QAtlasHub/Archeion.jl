# CLAUDE.md — Archeion.jl

**The last layer of the infra stack** (ParamIO → DataVault → SweepRunner → Pinax → **Archeion**):
rendered reports, accumulated across projects in a git repository, readable without any tool.

## Role / public API

- The **format** is `SPEC.md` (`spec = "registry/2"`). The package implements it; it is not the
  format. A change to what a registry may contain is a change to `SPEC.md` first.
- `Archeion.validate(root) -> (report, summary)` · `Archeion.build(root[, out])` ·
  `new_binding(path; registry, project, slug, kind)` · `deposit(binding; gallery, agent, doc, source_repo)`
  · `Archeion.doc_fields(::Pinax.Document)` (extension) · `julia -m Archeion validate|build`.
- `Archeion.publish(vault, recipe; binding, title, out, status, source_repo, remote)` (extension,
  needs Pinax **and** DataVault) is render → deposit → push/PR in one call: the path every study
  was copying. `status` is required — a revision's `trial`/`final` is the author's statement, and
  Pinax's page default would otherwise make it silently `final`.

## Versioning

- **This is a `0.x` package: an addition is a PATCH bump; only a breaking change is a minor one.**
  Pkg reads `0.x.y` as compatible with `>= 0.x.y, < 0.(x+1)`, so a minor bump makes every
  downstream `compat = "0.x"` wrong and has to be chased through the repositories that pin it.
  A new function, command, flag or section of the built site breaks nobody: bump the patch.
  Removing or renaming one, changing what an argument means, or changing what a valid registry may
  contain: bump the minor, and say which in the release notes.
- Got this wrong on 2026-09-23 — 0.5.0 through 0.9.0 in a day for what was almost all additions,
  costing a `compat` edit downstream that was never needed. The tags were renumbered the same day
  onto the line they should have had (0.4.3 … 0.5.2, with 0.5.0 the one breaking release, the
  `pages` flags); the releases say so, and the commits did not move.

## Contracts that trip callers

- **A record is created once** (`new_binding`, committed in the repo that renders it) and every
  `deposit` through that binding adds a revision. `deposit` never creates a record by itself. The
  binding also fixes the record's `kind` (`"report"` or `"note"`); a binding without one means
  `"report"`, and an existing record keeps the kind it was created with.
- **The entry is written from the document model**, never parsed back from the output: pass
  `doc_fields(Pinax.current_document())`, not something read out of `agent.json`.
- **Revisions are immutable.** Corrections, withdrawals and comments are events (SPEC §7);
  "current" is computed from parents and events, never chosen by time.
- **Times inside files are UTC with `Z`.** Julia's TOML rejects any other offset and reads a
  zone-less time as the same value, so the validator checks this on the text.

## Where to look

- `test/fixture/` — a complete registry with one record; `test/helpers.jl` breaks copies of it.
- [QAtlasHub/archeion-demo](https://github.com/QAtlasHub/archeion-demo) — a registry built with
  this package, including the script that renders and deposits its record.

## Invariants when changing this package

- **The core depends on the standard library only.** Anything that needs another package (Pinax,
  DataVault) is an extension. The reader must run wherever Julia does.
- **Readers keep reading every `registry/N` ever written.** `registry/2` never gains a required
  field; that is `registry/3`.
- **Every new check comes with a test that breaks the fixture and requires the check to name it.**
  A check that passes a good registry proves nothing on its own.
