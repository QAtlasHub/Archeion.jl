# Registry format, version 1 (draft)

This file is the format. Archeion.jl is one implementation of it and may be replaced; a registry is
valid when it satisfies this document, whatever wrote it.

Status: **draft**. Sections 1-9 are normative for `spec = "registry/1"`. Section 10 lists what is
not decided yet; nothing there may be relied on.

## 1. Names and paths

- **R1** Path segments under `projects/` and `records/` use only ASCII `[A-Za-z0-9_.-]`: no
  non-ASCII (NFC/NFD normalisation differs between macOS and Linux) and no spaces. No two entries
  of one directory are equal once lower-cased (a case-insensitive filesystem would merge them).
  Identifiers and slugs are lower case (R5, R6); upper case appears only in the fixed names of this
  document (`README.md`, `SHA256SUMS`) and in the `T` and `Z` of R2 times.
- **R2** No `:` anywhere in a path. A time in a path is `YYYYMMDDTHHMMSSZ`, UTC, without separators.
  (Windows cannot check out a file whose name contains `:`.)
- **R3** A path segment is at most 64 characters; a path relative to the repository root is at most
  180 characters.
- **R4** No segment is a Windows reserved name (`con`, `prn`, `aux`, `nul`, `com1`-`com9`,
  `lpt1`-`lpt9`, with or without an extension), and no segment ends in `.`.
- **R5** An identifier is a type prefix and eight characters of lower-case Crockford base32
  (`0-9`, `a-z` without `i`, `l`, `o`, `u`): `p_` for a project, `r_` for a record.
- **R6** A directory name may carry a human-readable slug, but identity is carried by the identifier
  alone. A slug is frozen when the directory is created and is never renamed.
- **R7** Times inside files are RFC 3339 in UTC with a `Z` suffix. Paths use R2, files use R7.

## 2. Objects and layout

| Object | What it is | Mutable? |
|---|---|---|
| Project | a line of research, with a display name | display name only |
| Record | one question, answered by a series of revisions | never |
| Revision | one frozen answer: a rendered report and what it was made from | never |
| Event | a fact added later about a record or revision (comment, correction, yank, ...) | never |

"Latest", indexes, search and dashboards are **derived** from these and are not committed (§9).

```text
projects/<project-id>.toml
records/<YYYY>/<YYYY-MM-DD>-<slug>-<record-id>/
    record.toml
    revisions/<YYYYMMDDTHHMMSSZ>-<tag>/
        entry.toml
        README.md
        SHA256SUMS
        gallery/            the human face (HTML, figures)
        agent/              the machine face (agent.json, agent.md, figure data)
        repro/              whatever was captured to rebuild it (optional)
    events/<YYYYMMDDTHHMMSSZ>-<origin>-<key>.toml
```

- `<YYYY>` and `<YYYY-MM-DD>` are the record's creation date in UTC. A record's project is a field,
  not a path segment: a record can be reassigned without moving it.
- `<tag>` is four characters of the R5 alphabet, so two revisions frozen in the same second differ.
- `_incoming/` (a deposit in progress) and `_site/` (a build) are never committed.

## 3. `projects/<project-id>.toml`

| Field | Required | Meaning |
|---|---|---|
| `spec` | yes | `"registry/1"` |
| `id` | yes | the project identifier; equals the file name without `.toml` |
| `name` | yes | display name; may change |
| `created` | yes | R7 time |

## 4. `record.toml`

| Field | Required | Meaning |
|---|---|---|
| `spec` | yes | `"registry/1"` |
| `id` | yes | the record identifier; equals the directory name's suffix |
| `kind` | yes | `"report"` (for now the only kind; see §10) |
| `project` | yes | a project identifier that exists in `projects/` |
| `created` | yes | R7 time; its UTC date equals the directory's date |

A record file is written once. Anything that changes later is an event.

## 5. Revisions

### 5.1 `entry.toml`

The only structured file in a revision. It is written by the tool that holds the document model at
render time; it is never reconstructed by parsing the rendered output.

| Field | Required | Meaning |
|---|---|---|
| `spec` | yes | `"registry/1"` |
| `id.project`, `id.record`, `id.rev`, `id.kind` | yes | must agree with `record.toml` and the directory name |
| `parents` | yes | revision ids of this record this revision revises; `[]` for the first |
| `time.frozen` | yes | when the revision was frozen; equals the directory's time to the second |
| `time.rendered` | no | when the report was rendered |
| `doc.title` | yes | the report's title |
| `doc.status` | yes | `"trial"` or `"final"`: how far the author vouches for it (§5.4) |
| `doc.question`, `doc.claim` | no | one sentence each: what was asked, what can be said |
| `doc.tags` | no | list of strings |
| `anchors.stable` | yes | ids that keep their meaning across revisions and may be commented on |
| `anchors.local` | yes | ids valid inside this revision only (auto-numbered) |
| `source` | no | where the code came from (§5.3) |
| `preservation.level` | yes | `"read"`; higher levels are established by events (§6) |
| `preservation.external` | no | URLs the revision needs to display fully |
| `migrated` | no | set when the revision was converted from an older format |

Unknown fields are ignored by readers. A later `registry/1` never adds a required field; that needs
`registry/2`, and readers keep reading `registry/1`.

A field whose value is not known is **omitted**. An empty list means "known to be empty", never
"unknown". A byte count is a positive integer. A commit is 40 hexadecimal characters. A digest is
`"sha256:"` followed by 64 hexadecimal characters.

### 5.2 `SHA256SUMS` and `README.md`

- `SHA256SUMS` lists every file of the revision except itself, one per line, in the format of
  `sha256sum`: 64 hex, two spaces, the path relative to the revision directory. It is written last;
  a revision without it is incomplete. `sha256sum -c SHA256SUMS` checks a revision without any tool
  from this repository.
- `README.md` is a plain-text rendering of `entry.toml`, written once with it, so that a revision
  can be read with nothing but a text viewer.

### 5.3 Where the code came from

`source` records the repositories whose code produced the revision:

```toml
[source]
captured = "publish"      # when the state was read: "run-start", "completion" or "publish"

[[source.repo]]
role = "render"           # "compute", "analysis" or "render"
commit = "<40 hex>"
dirty = false
```

`captured` says when the repository's working tree was observed, and nothing more. None of its
values says which code a process had loaded: a process can run code it loaded before the
observation, or code that is not on disk at all (a function defined in a REPL, a closure sent from
another process). `"run-start"`, `"completion"` and `"publish"` are three moments of observation,
not a scale of strength, and `source` never claims that the observed commit produced the result.
That claim, and the provenance of individual parameter points (which point was computed by which
code, and which bytes the report read), is part of §10 until the upstream packages can supply it.

### 5.4 `doc.status`

`"final"` means the author presents this revision's claims, at the time of freezing, as correct to a
third party. `"trial"` means everything else. Withdrawal is not a status; it is an event.

## 6. Preservation

A revision is `read` when its `gallery/` opens in a browser from the repository alone, apart from
the URLs listed in `preservation.external`. `render` (rebuilt from what the revision holds) and
`compute` (recomputed from preserved data) are claims that must be earned: an event of kind
`capability.verified` records when, where and how the rebuild succeeded. Until then a revision is
`read`, whatever files it carries.

## 7. Events

- An event file is named `<YYYYMMDDTHHMMSSZ>-<origin>-<key>.toml`. `origin` is `loc` for an event
  written here, with `key` four random characters of the R5 alphabet, or the name of an external
  source, with `key` derived from that source's own identifier so that importing the same thing
  twice produces the same file name.
- Required fields: `spec`, `kind`, `at` (R7), `subject.record` (the containing record).
  `subject.rev` and `subject.anchor` narrow the subject.
- Kinds in `registry/1`: `comment`, `yank`, `supersede`, `capability.verified`. A reader counts and
  shows events of a kind it does not know; it does not drop them.
- An event is never edited. An edit elsewhere becomes a new event.

### 7.1 Which revision is current

```text
live   = revisions not named by a yank event
heads  = live revisions that are not a parent of another live revision
         and are not the target of a supersede event from a live revision
|heads| = 1  → that revision is current
|heads| = 0  → the record is withdrawn
|heads| > 1  → the record is in conflict; nothing is chosen by time
```

## 8. What a revision must not say

A revision states what it used. It does not state what has been computed: that is the data store's
current state, not a property of a frozen answer. `entry.toml` contains no key named `completed`,
`available`, `missing`, `done` or `exists`.

## 9. Committed and derived

Committed: every object of §2, and files derived from exactly one revision and frozen with it
(`README.md`, `SHA256SUMS`). Derived and never committed: anything computed from several objects —
the catalogue, search indexes, the current revision of a record, counts.

## 10. Not decided (not normative)

- **Experiments and notes.** Whether a lab notebook is a separate object or a record of another kind.
- **Identifier length.** Eight characters (40 bits) is readable; a validator rejects collisions. A
  full UUID is the alternative.
- **Per-point provenance.** A table, kept outside `entry.toml`, from each parameter point to the
  digest of the result bytes the report read and to an observation of the source the computing
  process could see. The observation and its **binding** to the code that ran are separate claims:
  the binding is `unverified` unless loaded sources were checked against the observation, or the
  process was started from it. Needs DataVault, SweepRunner and Pinax to record these.
- **Source capture for a dirty tree.** A git commit object built from a temporary index, or a
  content-addressed tar of declared source roots.
- **Data references and replicas.** Content digests of the data a revision used, and events that
  record where copies are and when they were last verified.
- **Comments from GitHub.** Import by a full, idempotent scan; the key of an imported event.
- **Public copies.** A public revision generated afresh from a public profile, with the private
  correspondence recorded on the private side only.
