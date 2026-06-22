# Build the registry's cross-run index by delegating to `Pinax.contents` — one card per
# Record, linking to that run's pre-rendered gallery. Bookmark/tags/commit become the card
# meta line. This is the "map of contents one level up" that the Pinax design anticipates.

"""
    build_index(records; out, title="Archeion") -> path

Render the cross-run index over `records` (a vector of [`Record`](@ref)) to `out/index.html`
and return its path. Each card links to that record's `gallery`. This does not render or
copy the galleries themselves — they are expected to already exist under `out` (or at the
hrefs the records carry).
"""
function build_index(
    records::AbstractVector{Record}; out::AbstractString, title::AbstractString="Archeion"
)
    entries = map(records) do r
        meta = String[]
        r.bookmark && push!(meta, "★")
        isempty(r.tags) || push!(meta, join(r.tags, " · "))
        r.git_commit == "unknown" || push!(meta, "@" * first(r.git_commit, 7))
        return (;
            title=r.title,
            href=r.gallery,
            summary=isempty(r.summary) ? nothing : r.summary,
            thumbnail=r.thumbnail,
            meta=isempty(meta) ? r.date : join(meta, "  ·  "),
        )
    end
    return Pinax.contents(entries; out=out, title=title, level=:cards)
end
