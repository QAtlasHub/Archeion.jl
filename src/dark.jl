# dark.jl — the catalogue and the reports in it, read in the dark.
#
# A revision is frozen: its `gallery/style.css` is covered by the `SHA256SUMS` beside it, so it
# cannot be given a dark mode. Most of them were rendered before one existed, and always will have
# been. A catalogue that goes dark in front of them would be the seam this package spent its
# stylesheet avoiding.
#
# The site, though, is not the registry. `build` copies each revision into `_site` and rewrites
# that copy on every run (§2 — the site is derived and never committed), so the copy may carry
# what the original cannot. What is derived here is a dark layer: the same stylesheet again, its
# colours exchanged for their dark counterparts, inside `@media (prefers-color-scheme: dark)`.
# Same selectors, same specificity, later in the file — so it wins exactly when the reader's
# system asks for it, and the registry's own bytes are never touched.

# Every colour Pinax has drawn with, by what it is for rather than what it is. Six frozen
# stylesheets across the two registries spell 44 distinct colours; all of them are here, because a
# colour with no role would be left light on a dark page, which is worse than no dark mode.
const ROLE = Dict(
    # the page, and what is read on it
    "#fafafa" => "bg",
    "#24292f" => "fg",
    "#57606a" => "mut",
    "#444" => "mut",
    "#555" => "mut",
    "#666" => "mut",
    "#6a737d" => "mut",
    "#3d4451" => "mut",
    "#8b949e" => "faint",
    "#8a949e" => "faint",
    "#888" => "faint",
    # every hairline it has ever drawn
    "#e2e5e9" => "line",
    "#eee" => "line",
    "#eaecef" => "line",
    "#eef0f2" => "line",
    "#ccd" => "line",
    "#d0d7de" => "line",
    "#cbd5e1" => "line",
    "#b6bec7" => "line",
    "#e1e4e8" => "line",
    "#e5e7eb" => "line",
    # surfaces
    "#fff" => "card",
    "#fdfdfe" => "card",
    "#f6f8fa" => "soft",
    "#f4f6f8" => "soft",
    "#f3f4f6" => "soft",
    "#fafbfc" => "soft",
    "#fbfbfd" => "soft",
    "#eef1f4" => "soft",
    # a link
    "#0366d6" => "acc",
    "#0969da" => "acc",
    "#1f6feb" => "acc",
    # it passed, it did not, look at this
    "#1a7f37" => "ok",
    "#2da44e" => "ok",
    "#e6ffec" => "ok-bg",
    "#a40e26" => "bad",
    "#cf222e" => "bad",
    "#d33" => "bad",
    "#ffebe9" => "bad-bg",
    "#9a6700" => "warn",
    "#eac54f" => "warn",
    "#e3b341" => "warn",
    "#fff8c5" => "warn-bg",
    "#fff8e1" => "warn-bg",
)

# What each role is after dark. GitHub's dark canvas, because the light side is GitHub's light one
# and a reader who knows one knows the other.
const DARK = Dict(
    "bg" => "#0d1117",
    "fg" => "#e6edf3",
    "mut" => "#9198a1",
    "faint" => "#6e7681",
    "line" => "#30363d",
    "card" => "#161b22",
    "acc" => "#4493f8",
    "soft" => "#1c2128",
    "ok" => "#3fb950",
    "ok-bg" => "#12261e",
    "bad" => "#f85149",
    "bad-bg" => "#25171c",
    "warn" => "#d29922",
    "warn-bg" => "#272115",
    # the contribution graph's five steps, empty to busiest
    "l0" => "#161b22",
    "l1" => "#0e4429",
    "l2" => "#006d32",
    "l3" => "#26a641",
    "l4" => "#39d353",
)

# A document is a white page. It is not a surface of the theme and does not follow it into the
# dark — the same exception the light stylesheet makes, for the same reason.
const DRAWN_ON_WHITE = ("pinax-pdf", "card-thumb-pdf", "thumb-pdf")

dark_of(hex) = get(DARK, get(ROLE, lowercase(hex), ""), nothing)

"""
    darkened(css) -> String

`css` again, every colour exchanged for its dark counterpart, wrapped in a
`prefers-color-scheme: dark` query. Returns `""` when there is nothing to say: a stylesheet that
already answers the query brought its own dark mode and keeps it, and one whose colours are not
all known is left alone rather than half-converted.
"""
function darkened(css)
    occursin("prefers-color-scheme", css) && return ""
    unknown = String[]
    out = IOBuffer()
    for line in split(css, '\n')
        keep = any(w -> occursin(w, line), DRAWN_ON_WHITE)
        println(
            out,
            replace(
                line,
                r"#[0-9a-fA-F]{3,8}\b" => function (hex)
                    length(hex) == 9 && return hex          # #rrggbbaa: an alpha, left as it is
                    keep && lowercase(hex) in ("#fff", "#ffffff") && return hex
                    d = dark_of(hex)
                    d === nothing && (push!(unknown, hex); return hex)
                    return d
                end,
            ),
        )
    end
    isempty(unknown) || return ""
    return "\n@media (prefers-color-scheme: dark){\n" * String(take!(out)) * "}\n"
end

# The stylesheet a face of a revision is read through. `assets/` is where vendored files live
# (KaTeX brings its own, and rewriting someone else's library is not ours to do).
function is_own_stylesheet(rel)
    return endswith(rel, ".css") && !occursin("assets/", replace(rel, '\\' => '/'))
end

"""
    darken_site_copy!(dir) -> Int

Give every stylesheet under `dir` — a copy of a revision inside `_site`, never the revision — a
dark layer, and say how many got one. A stylesheet that already has one, or that draws with a
colour this does not know, is left exactly as it was.
"""
function darken_site_copy!(dir)
    n = 0
    for (d, _, files) in walkdir(dir), f in files
        rel = relpath(joinpath(d, f), dir)
        is_own_stylesheet(rel) || continue
        path = joinpath(d, f)
        layer = darkened(read(path, String))
        isempty(layer) && continue
        open(io -> print(io, layer), path, "a")
        n += 1
    end
    return n
end
