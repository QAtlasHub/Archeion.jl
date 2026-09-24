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
# colours exchanged for their dark counterparts, written beside it as `style.dark.css` and linked
# by the page after its own sheet. Same selectors, same specificity, later in the cascade — so it
# wins exactly when it is asked for, and the registry's own bytes are never touched.
#
# *When* it is asked for is the linking page's `media` attribute, and that is why the layer is a
# file rather than bytes appended inside an `@media` block: an attribute can be rewritten by the
# control (appearance.jl), a query baked into the copy cannot. Without JavaScript the attribute
# stays as written — the system's answer — which is what this did before there was a control.

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
# and a reader who knows one knows the other. `build.jl`'s own dark block is built from this, so
# the catalogue and the reports cannot drift apart.
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
# dark — the same exception the light stylesheet makes, for the same reason. Matched against the
# rule's selector, not the line it happens to be printed on.
const DRAWN_ON_WHITE = ("pinax-pdf", "card-thumb-pdf")

function dark_of(hex)
    role = get(ROLE, lowercase(hex), nothing)
    role === nothing && return nothing
    return get(DARK, role, nothing)
end

# A hex run starting at `i`, or nothing. CSS allows 3, 4, 6 or 8 digits; anything else spelled
# with a `#` is not a colour.
function hex_at(css, i)
    j = nextind(css, i)
    n = 0
    while j <= lastindex(css) && isxdigit(css[j]) && n < 8
        j = nextind(css, j)
        n += 1
    end
    n in (3, 4, 6, 8) || return nothing
    # `#abcdefg` is an identifier that merely starts like a colour
    j <= lastindex(css) &&
        (isletter(css[j]) || isdigit(css[j]) || css[j] == '_') &&
        return nothing
    return css[i:prevind(css, j)], j
end

"""
    recoloured(css, unknown) -> String

`css` with every colour exchanged for its dark counterpart — and **only** the colours. A `#` in a
stylesheet is a colour just once: in the value of a declaration. Everywhere else it names
something, and rewriting it breaks the thing it names —

    #eee{…}                 an id selector, not a shade
    fill:url(#eee)          a reference to a gradient defined elsewhere
    content:"#eee"          three characters somebody reads

so this walks the sheet as blocks and declarations rather than as lines of text, and leaves
comments, strings, selectors and `url(…)` exactly as they are. Colours it does not know are
collected in `unknown` and left alone; the caller decides what that means.
"""
function recoloured(css::AbstractString, unknown::Set{String})
    out = IOBuffer()
    prelude = IOBuffer()          # the text since the last brace: a selector, or an at-rule
    stack = String[]              # the preludes of the blocks we are inside
    in_value = false              # past the `:` of a declaration, where a colour may stand
    i, n = firstindex(css), lastindex(css)
    while i <= n
        c = css[i]
        if c == '/' && i < n && css[nextind(css, i)] == '*'          # a comment
            j = findnext("*/", css, i)
            stop = j === nothing ? n : last(j)
            print(out, css[i:stop])
            i = nextind(css, stop)
        elseif c == '"' || c == '\''                                  # text, not a colour
            j = findnext(isequal(c), css, nextind(css, i))
            stop = j === nothing ? n : j
            print(out, css[i:stop])
            i = nextind(css, stop)
        elseif c == '{'
            push!(stack, strip(String(take!(prelude))))
            in_value = false
            print(out, c)
            i = nextind(css, i)
        elseif c == '}'
            isempty(stack) || pop!(stack)
            take!(prelude)
            in_value = false
            print(out, c)
            i = nextind(css, i)
        elseif isempty(stack)                                         # a selector or an at-rule
            print(prelude, c)
            print(out, c)
            i = nextind(css, i)
        elseif c == ':'
            in_value = true
            print(out, c)
            i = nextind(css, i)
        elseif c == ';'
            in_value = false
            print(out, c)
            i = nextind(css, i)
        elseif in_value && lowercase(css[i:min(n, i + 3)]) == "url("  # a name, not a colour
            j = findnext(isequal(')'), css, i)
            stop = j === nothing ? n : j
            print(out, css[i:stop])
            i = nextind(css, stop)
        elseif in_value && c == '#' && hex_at(css, i) !== nothing
            hex, j = hex_at(css, i)
            white = lowercase(hex) in ("#fff", "#ffffff")
            on_white = any(w -> any(s -> occursin(w, s), stack), DRAWN_ON_WHITE)
            d = dark_of(hex)
            if length(hex) == 9                                       # #rrggbbaa: an alpha
                print(out, hex)
            elseif white && on_white
                print(out, hex)
            elseif d === nothing
                push!(unknown, lowercase(hex))
                print(out, hex)
            else
                print(out, d)
            end
            i = j
        else
            print(out, c)
            i = nextind(css, i)
        end
    end
    return String(take!(out))
end

"""
    darkened(css) -> NamedTuple

The dark layer for `css`: `layer`, the same stylesheet with its colours exchanged, and `why`,
which says what happened —

- `:ok` — a layer was derived, and `layer` is it
- `:already` — the stylesheet answers the query itself and keeps its own dark mode
- `:colourless` — there is nothing to darken
- `:unknown` — it draws with colours not in `ROLE`, listed in `unknown`

A stylesheet is never half-converted: an unknown colour means no layer at all, because a page
half in the dark is worse than a page that stayed light.
"""
function darkened(css)
    occursin("prefers-color-scheme", css) &&
        return (; layer="", why=:already, unknown=String[])
    unknown = Set{String}()
    body = recoloured(css, unknown)
    isempty(unknown) || return (; layer="", why=:unknown, unknown=sort!(collect(unknown)))
    body == css && return (; layer="", why=:colourless, unknown=String[])
    return (; layer=body, why=:ok, unknown=String[])
end

# The stylesheet a face of a revision is read through. A vendored file is someone else's to
# maintain (KaTeX brings its own), and `assets` is the directory they live in — as a path segment,
# so a directory merely spelled `dataassets` is still ours.
function is_own_stylesheet(rel)
    return endswith(rel, ".css") && !("assets" in splitpath(rel))
end

# The derived layer lives beside the sheet it came from rather than inside it: `style.css` gains a
# `style.dark.css`, and the page links it with a `media` the control can rewrite. Appended to the
# copy instead, the rules would be fixed to the system's answer forever, and a reader on a dark
# desktop could never ask one report to stay light.
dark_sheet_of(path) = chop(path; tail=length(".css")) * ".dark.css"

const DARK_SHEET_HEAD = """
/* Derived by Archeion from the stylesheet beside this one: the same rules and the same selectors,
   its colours exchanged for their dark counterparts (src/dark.jl). The revision this was copied
   from is frozen under its own SHA256SUMS and holds no such file; `_site` is derived and rewritten
   on every build. When it applies is the linking page's `media` attribute, which is how the
   reader's choice reaches these rules. */
"""

# The one rule this adds rather than recolours. A figure carries its own white inside the SVG,
# where no stylesheet reaches it — and it should: the axes and labels are dark ink, and taking the
# paper away would leave them unreadable on a dark page. So the page turns the lamp down instead.
# `brightness(.85)` makes the paper #d9d9d9, which still reads as paper and stops being a lamp.
#
# Measured at that value: inside the figure, ink/paper 14.9, axis/paper 7.2, a plotted line 4.4 —
# all still clear, a line being a graphical object that wants 3. Against the card it sits on, 12.3.
#
# It rides in this file rather than in the injected `<style>` because this file is already gated by
# the `media` the control rewrites, so it applies exactly when dark does and needs no guard of its
# own. Pinax says the same thing in its own stylesheet, for reports rendered from 0.1.8 on; this is
# for every report frozen before that, which is all of them.
const DARK_SHEET_TAIL = """

figure img, .card-thumb img, iframe.pinax-pdf, .card-thumb-pdf{filter:brightness(.85)}
"""

# A page's own stylesheets, as it spells them. A sheet somewhere else — a CDN, a site-absolute
# path — is not ours to darken and not ours to resolve.
function linked_stylesheets(html)
    out = String[]
    for m in eachmatch(r"<link\b[^>]*>"i, html)
        tag = m.match
        occursin(r"rel\s*=\s*[\"']stylesheet[\"']"i, tag) || continue
        h = match(r"href\s*=\s*\"([^\"]+)\""i, tag)
        h === nothing && continue
        href = h[1]
        (occursin("://", href) || startswith(href, "/")) && continue
        push!(out, href)
    end
    return out
end

"""
    darken_site_copy!(dir, appearance = "system") -> NamedTuple

Give every stylesheet under `dir` — a copy of a revision inside `_site`, never the revision — a
dark layer, and every page that links one the control to switch it. `appearance` is the scheme a
reader who has not chosen gets.

Returns what happened, counted: `dark`, `already`, `colourless`, `unknown`, `unknown_colours` —
the ones that stopped a stylesheet from being converted — and `controls`, the pages that came away
switchable. A report left light is the one failure this must not keep to itself.
"""
function darken_site_copy!(dir, appearance="system")
    dark = already = colourless = unknown = controls = 0
    colours = Set{String}()
    converted = Set{String}()                  # the sheets a page may now be offered a switch for
    for (d, _, files) in walkdir(dir), f in files
        rel = relpath(joinpath(d, f), dir)
        is_own_stylesheet(rel) || continue
        path = joinpath(d, f)
        r = darkened(read(path, String))
        if r.why === :ok
            write(dark_sheet_of(path), DARK_SHEET_HEAD * r.layer * DARK_SHEET_TAIL)
            push!(converted, rel)
            dark += 1
        elseif r.why === :already
            already += 1
        elseif r.why === :colourless
            colourless += 1
        else
            unknown += 1
            union!(colours, r.unknown)
            @warn "no dark mode for this stylesheet: it draws with colours Archeion does not \
                   know, and half a conversion is worse than none" path colours = r.unknown
        end
    end

    for (d, _, files) in walkdir(dir), f in files
        endswith(lowercase(f), ".html") || continue
        path = joinpath(d, f)
        here = dirname(relpath(path, dir))
        html = read(path, String)
        hrefs = [
            dark_sheet_of(h) for
            h in linked_stylesheets(html) if normpath(joinpath(here, h)) in converted
        ]
        out = inject_appearance(html, appearance, hrefs)
        out === nothing && continue
        write(path, out)
        controls += 1
    end

    return (;
        dark,
        already,
        colourless,
        unknown,
        unknown_colours=sort!(collect(colours)),
        controls,
    )
end
