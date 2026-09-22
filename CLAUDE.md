# CLAUDE.md — Archeion.jl

**The last layer of the infra stack** (ParamIO → DataVault → SweepRunner → Pinax → **Archeion**):
rendered reports, accumulated across projects in a git repository, readable without any tool.

## Role / public API

- The **format** is `SPEC.md` (`spec = "registry/1"`). The package implements it; it is not the
  format. A change to what a registry may contain is a change to `SPEC.md` first.
- `Archeion.validate(root) -> (report, summary)` · `Archeion.build(root[, out])` ·
  `new_binding(path; registry, project, slug)` · `deposit(binding; gallery, agent, doc, source_repo)`
  · `Archeion.doc_fields(::Pinax.Document)` (extension) · `julia -m Archeion validate|build`.

## Contracts that trip callers

- **A record is created once** (`new_binding`, committed in the repo that renders it) and every
  `deposit` through that binding adds a revision. `deposit` never creates a record by itself.
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
- **Readers keep reading every `registry/N` ever written.** `registry/1` never gains a required
  field; that is `registry/2`.
- **Every new check comes with a test that breaks the fixture and requires the check to name it.**
  A check that passes a good registry proves nothing on its own.
