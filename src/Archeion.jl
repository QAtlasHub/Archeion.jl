module Archeion

# Archeion — a reproducible experiment registry that publishes Pinax galleries as a
# private, searchable static site. Conceptually a "Vault of DataVaults": DataVault
# formalizes a *per-project* directory layout but is intentionally unaware of any
# higher-level structure, so Archeion is the layer ABOVE — it discovers many DataVault
# output dirs across projects, aggregates their figures/data + provenance (生成元) into one
# unified, searchable view, and adds the env/code reproducibility Pinax/DataVault don't.

using TOML: TOML
using Dates: Dates
using Markdown: Markdown
using LibGit2: LibGit2
using Pinax: Pinax
using DataVault: DataVault
using SQLite: SQLite
using DBInterface: DBInterface
using SHA: sha256
using Sockets: Sockets, listen, connect, accept, gethostname
using Serialization: serialize, deserialize

include("repro.jl")      # git + environment snapshot (env/code provenance)
include("record.jl")     # Record metadata <-> record.toml
include("index.jl")      # records -> cross-run index, via Pinax.contents
include("search.jl")     # Pagefind full-text search over the assembled site
include("aggregate.jl")  # cross-project discovery over DataVault outdirs ("Vault of DataVaults")
include("ingest.jl")     # records -> web/db/archeion.db (SQLite; body_md = RAG-portable source)
include("read.jl")       # read the app-owned annotation layer back (comments/tags/status) -> LLM
include("deploy.jl")     # publish the built site privately over FTPS (Lolipop) + Basic auth
include("transport.jl")  # backend-neutral push/pull seam (FTPS / local; hostname dispatch)
include("secret.jl")     # encrypt the deploy config at rest; REPL-only lock/view (LLM can't decrypt)
include("agent.jl")      # ssh-agent-style daemon: holds creds in memory, serves deploy/pull over a socket
include("active.jl")     # `initialize` host default + no-config deploy/pull/publish (delegated to the agent)

export ReproBundle, capture_repro
export Record, write_record, read_record
export build_index, add_search
export master_ledger, records_from_outdirs, discover
export ingest
export record_comments,
    record_tags,
    record_annotations,
    record_annotation_list,
    project_annotations,
    feedback_md
export record_versions, status
export deploy, write_basic_auth, read_deploy_target
export RemoteTransport,
    FTPSTransport, LocalTransport, transport, pull, pull_file, push_dir, publish
export initialize, active, deinitialize, agent_up, lock_config, view_config

end # module Archeion
