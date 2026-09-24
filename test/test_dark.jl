# dark: the site is derived, so the site's copy of a frozen revision may be darkened. The
# revision may not, and this is mostly about proving that it is not.

layer_of(css) = Archeion.darkened(css).layer

@testset "dark: a light stylesheet gains a layer, and keeps the one it had" begin
    r = Archeion.darkened(LIGHT_SHEET)
    @test r.why === :ok
    # The layer is the stylesheet again — same rules, same selectors, no query wrapped round it.
    # *When* it applies is the linking page's `media` (appearance.jl), because an attribute can be
    # rewritten by the control and a query baked in here could not.
    @test !occursin("@media (prefers-color-scheme: dark)", r.layer)
    @test occursin("background:#0d1117", r.layer) && occursin("color:#e6edf3", r.layer)
    @test occursin("color:#4493f8", r.layer)                # the link
    @test occursin("#30363d", r.layer)                      # the hairline
    @test !occursin("#fafafa", r.layer) && !occursin("#0366d6", r.layer)

    # a document is a white page and does not follow the theme into the dark
    @test occursin("iframe.pinax-pdf{background:#fff}", r.layer)

    # a sheet that brought its own dark mode keeps it, untouched, and says which case it was
    kept = Archeion.darkened(
        LIGHT_SHEET * "\n@media (prefers-color-scheme: dark){a{color:red}}"
    )
    @test kept.why === :already && isempty(kept.layer)
    # and one drawing with a colour this does not know is left alone, and names the colour
    miss = Archeion.darkened(LIGHT_SHEET * "\n.x{color:#123456}")
    @test miss.why === :unknown && isempty(miss.layer) && miss.unknown == ["#123456"]
    # nothing to darken is its own answer, not a layer with nothing in it
    @test Archeion.darkened("").why === :colourless
    @test Archeion.darkened("body{margin:0}\n").why === :colourless
    @test isempty(Archeion.darkened("body{margin:0}\n").layer)
end

@testset "dark: only a colour is exchanged, and a colour is only ever a value" begin
    # A `#` in a stylesheet names a colour in exactly one place. Everywhere else it names
    # something, and rewriting it breaks the thing it names.
    for (what, css, must_keep) in (
        ("an id selector", "#eee{color:#444}", "#eee{"),
        ("an id in a group", "#abcdef .x{color:#444}", "#abcdef .x{"),
        ("a fragment in an attribute", "a[href=\"#fff\"]{color:#444}", "[href=\"#fff\"]"),
        ("a string somebody reads", ".a::before{content:\"#fff\";color:#444}", "\"#fff\""),
        ("a colour named in a comment", "/* was #fafafa */\n.a{color:#444}", "#fafafa"),
    )
        l = layer_of(css)
        @test occursin(must_keep, l)                        # what it names is left alone
        @test occursin("#9198a1", l)                        # and the declaration still went dark
    end
    # a reference into an SVG is a name; a sheet whose only `#` is one has nothing to darken
    @test Archeion.darkened(".a{fill:url(#eee)}").why === :colourless
    # #rrggbbaa carries an alpha this does not know how to keep, so it is left as it stands
    @test occursin("#12ab34ff", layer_of(".x{color:#12ab34ff}\nbody{color:#444}"))
end

@testset "dark: the white a document is drawn on belongs to the rule, not to the line" begin
    # Minified CSS is one line. If the exception were scoped to the line, the whole file would
    # keep its whites the moment a pdf rule appeared anywhere in it.
    mixed =
        "figure iframe.pinax-pdf{background:#fff}section.section{background:#fff;" *
        "border:1px solid #e2e5e9}"
    l = layer_of(mixed)
    @test occursin("iframe.pinax-pdf{background:#fff}", l)  # the document stays white
    @test occursin("section.section{background:#161b22", l) # the card beside it does not
end

@testset "dark: the site's copy is darkened; the revisions it came from are not" begin
    with_fixture() do root, rec, rev
        second = second_revision!(rec, rev; parent=true)
        sheets = Dict(
            r => with_stylesheet!(r, LIGHT_SHEET * "\n/* $(basename(r)) */\n") for
            r in (rev, second)
        )
        before = Dict(r => read(s, String) for (r, s) in sheets)
        @test isempty(Archeion.validate(root).errors)

        res = Archeion.build(root)
        @test res.dark.dark == 2 && res.dark.unknown == 0

        @test res.dark.controls == 2                            # both pages came away switchable

        for (r, sheet) in sheets
            gallery = joinpath(root, "_site", REC_REL, "revisions", basename(r), "gallery")
            copied = joinpath(gallery, "style.css")
            # the copy of the sheet is the sheet; the dark layer is a file beside it
            @test read(copied, String) == before[r]
            layer = read(joinpath(gallery, "style.dark.css"), String)
            @test occursin("#0d1117", layer) && !occursin("#fafafa", layer)
            # …which the page links, gated by a media the control can rewrite
            html = read(joinpath(gallery, "index.html"), String)
            @test occursin(
                """<link rel="stylesheet" href="style.dark.css" media="(prefers-color-scheme: dark)" data-appearance-dark>""",
                html,
            )
            @test occursin("pinax-appearance", html)
            # what the registry holds is what it held: byte for byte, digest included
            @test read(sheet, String) == before[r]
            @test sums_verify(r)
        end
        @test isempty(Archeion.validate(root).errors)
    end
end

@testset "dark: a vendored stylesheet is not ours to rewrite" begin
    with_fixture() do root, rec, rev
        with_stylesheet!(rev)                                # one of ours, beside theirs
        assets = joinpath(rev, "gallery", "assets", "katex")
        mkpath(assets)
        write(joinpath(assets, "katex.min.css"), ".katex{color:#24292f}\n")

        n = Archeion.darken_site_copy!(joinpath(rev, "gallery"))
        @test n.dark == 1                                    # ours, and only ours
        @test isfile(joinpath(rev, "gallery", "style.dark.css"))
        @test !isfile(joinpath(assets, "katex.min.dark.css"))
    end
    # `assets` is a directory, not a substring: a stylesheet of ours is not theirs for spelling
    @test Archeion.is_own_stylesheet(joinpath("gallery", "style.css"))
    @test Archeion.is_own_stylesheet(joinpath("gallery", "dataassets", "ours.css"))
    @test !Archeion.is_own_stylesheet(
        joinpath("gallery", "assets", "katex", "katex.min.css")
    )
end

@testset "dark: a report left light is reported, not left quiet" begin
    with_fixture() do root, rec, rev
        with_stylesheet!(rev, "body{color:#123456}\n")       # a colour with no role
        res = @test_logs (:warn, r"no dark mode for this stylesheet") match_mode = :any Archeion.build(
            root
        )
        @test res.dark.unknown == 1 && res.dark.dark == 0
    end
end

# Relative luminance and contrast, as WCAG 2.1 defines them.
_lin(c) = c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)^2.4
function _lum(hex)
    h = lstrip(hex, '#')
    length(h) == 3 && (h = join(c^2 for c in h))
    r, g, b = (parse(Int, h[i:(i + 1)]; base=16) / 255 for i in (1, 3, 5))
    return 0.2126_lin(r) + 0.7152_lin(g) + 0.0722_lin(b)
end
function contrast(a, b)
    lo, hi = extrema((_lum(a) + 0.05, _lum(b) + 0.05))
    return hi / lo
end

@testset "dark: whatever the palette puts together can be read" begin
    # Exchanging colours by role is mechanical, and mechanical is how a palette ends up with grey
    # on grey. Rather than measure the pairs the stylesheets happen to draw today — which would
    # say nothing about the one they draw tomorrow — every role that carries text is measured on
    # every role that is a surface.
    D = Archeion.DARK
    surfaces = ("bg", "card", "soft")
    for text in ("fg", "mut", "acc", "ok", "bad", "warn"), on in surfaces
        r = contrast(D[text], D[on])
        r >= 4.5 || @info "contrast too low" text = D[text] on = D[on] ratio = r
        @test r >= 4.5
    end
    # `faint` is the small print — counts, sources, timestamps — and is held to the threshold
    # that exists for text one is not expected to read word by word.
    for on in surfaces
        @test contrast(D["faint"], D[on]) >= 3.0
    end
    # a status says what it is by colour, so it is measured against the ground it says it on
    for (fg, bg) in (("ok", "ok-bg"), ("bad", "bad-bg"), ("warn", "warn-bg"))
        @test contrast(D[fg], D[bg]) >= 4.5
    end
    @test contrast(D["line"], D["bg"]) >= 1.5              # a line, not a letter
end

@testset "dark: every colour the frozen reports use has a role, and every role an answer" begin
    for hex in keys(Archeion.ROLE)
        @test Archeion.dark_of(hex) !== nothing
    end
    @test Archeion.dark_of("#123456") === nothing
    # the catalogue's own dark block is built from the same table, so it cannot drift from it
    for (name, value) in Archeion.DARK
        name in ("faint", "ok-bg", "bad-bg", "warn-bg") && continue   # the reports' only
        @test occursin("--$name:$value", Archeion.CSS)
    end
end
