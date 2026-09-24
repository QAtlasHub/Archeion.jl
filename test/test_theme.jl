# theme: the catalogue and the reports it links to are read as one thing, so they are one palette.
# Archeion cannot depend on Pinax, so it names the same values; this checks they still agree, and
# fails when either side moves.

using Pinax

# What a CSS declaration gives a property, inside the first rule whose selector matches. Comments
# are dropped first: a palette worth reading is a palette worth annotating, and `/* … */` between
# two declarations would otherwise hide the second one from this.
uncommented(css) = replace(css, r"/\*.*?\*/"s => "")

function css_value(css, selector, property)
    css = uncommented(css)
    m = match(Regex("\\Q$selector\\E\\s*\\{([^}]*)\\}"), css)
    m === nothing && return nothing
    d = match(Regex("(?:^|;)\\s*\\Q$property\\E\\s*:\\s*([^;}]+)"), m[1])
    return d === nothing ? nothing : strip(d[1])
end

token(name) = css_value(Archeion.CSS, ":root", name)

# What a declaration comes out as, once the page's own tokens are substituted in. Either side may
# say `var(--x)` or the value itself, and what is being compared is the colour either way — so a
# side that tokenises its palette does not read as drift.
function resolved(css, selector, property)
    v = css_value(css, selector, property)
    v === nothing && return nothing
    for _ in 1:4                                   # tokens may name tokens; this palette is flat
        occursin("var(--", v) || break
        v = replace(
            v,
            r"var\((--[a-z0-9-]+)\)" =>
                m -> something(css_value(css, ":root", match(r"--[a-z0-9-]+", m).match), m),
        )
    end
    return strip(v)
end

@testset "theme: the palette is Pinax's, and the two still agree" begin
    gallery = Pinax._GALLERY_CSS               # internal: what is being tracked is internal too
    @test resolved(gallery, "body", "background") == token("--bg") == "#fafafa"
    @test resolved(gallery, "body", "color") == token("--fg") == "#24292f"
    @test resolved(gallery, "nav a", "color") == token("--acc") == "#0366d6"
    @test occursin(token("--line"), resolved(gallery, "section.section", "border"))
    @test occursin(token("--card"), resolved(gallery, "section.section", "background"))
    @test resolved(gallery, ".desc", "background") == token("--soft") == "#f6f8fa"
    # the same type, so a heading does not change face between the catalogue and the report
    @test occursin("system-ui", resolved(gallery, "body", "font-family"))
    @test occursin("system-ui", css_value(Archeion.CSS, "body", "font"))
end

@testset "theme: dark mode, because now the reports follow" begin
    # This used to assert that neither side had one. A catalogue that flips to dark in front of
    # light reports is a worse seam than any shade — so what changed is not the resolve, it is
    # that the reports can be brought along: the site's copy of a revision gets a derived dark
    # layer (dark.jl), including revisions frozen years before any of this.
    @test occursin("prefers-color-scheme: dark", Archeion.CSS)
    # Three states, not two: the system decides unless the reader has said otherwise, and the
    # query steps aside for an explicit light so one page can be held bright on a dark desktop.
    @test occursin(""":root:not([data-theme="light"]){""", Archeion.CSS)
    @test occursin(""":root[data-theme="dark"]{""", Archeion.CSS)
    # and the two dark blocks are one block printed twice, so they cannot drift apart
    darks = [
        m[1] for m in eachmatch(
            r":root(?::not\(\[data-theme=\"light\"\]\)|\[data-theme=\"dark\"\])\{(.*?)\}"s,
            Archeion.CSS,
        )
    ]
    @test length(darks) == 2 && darks[1] == darks[2]
    # every token the light palette defines is redefined after dark, and with a different value
    light = match(r":root\{(.*?)\}"s, Archeion.CSS)[1]
    dark = first(darks)
    names(block) = Set(m[1] for m in eachmatch(r"(--[a-z0-9-]+):", block))
    @test names(light) == names(dark)
    for n in names(light)
        @test css_value(Archeion.CSS, ":root", n) != nothing
        @test occursin(Regex("\\Q$n\\E:([^;}]+)"), dark)
    end
    l = Dict(m[1] => m[2] for m in eachmatch(r"(--[a-z0-9-]+):([^;}]+)", light))
    d = Dict(m[1] => m[2] for m in eachmatch(r"(--[a-z0-9-]+):([^;}]+)", dark))
    @test all(n -> l[n] != d[n], keys(l))          # none of them merely repeated
end

@testset "theme: every colour the site draws with comes from a token" begin
    # Hard-coded colours are how a palette drifts. `#fff` behind a figure is the exception: a
    # figure is drawn on white whatever the page around it is.
    # The control's own block is the other exception, and it earns it: the same rules are injected
    # into frozen reports whose palette predates the tokens, so every colour in it is the fallback
    # of a `var(--x, …)` — what a report that never heard of `--mut` draws the button with.
    body = replace(
        replace(Archeion.CSS, r":root[^{]*\{[^}]*\}" => ""), Archeion.APPEARANCE_CSS => ""
    )
    hard = [m.match for m in eachmatch(r"#[0-9a-fA-F]{3,6}", body)]
    @test all(==("#fff"), hard)
    for m in eachmatch(r"#[0-9a-fA-F]{3,6}", Archeion.APPEARANCE_CSS)
        @test occursin(
            Regex("var\\(--[a-z0-9-]+,\\s*\\Q$(m.match)\\E\\)"), Archeion.APPEARANCE_CSS
        )
    end
end

@testset "theme: one site, so one control and one memory" begin
    # A reader who turns the lights down on a record page has not asked to have them turned back
    # up when they follow the link into the report. The two packages cannot share code — a registry
    # has to build without a plotting stack — so they share the strings, and this is what notices
    # when one of them moves.
    @test Archeion.APPEARANCE_KEY == Pinax._APPEARANCE_KEY == "pinax-appearance"
    @test occursin("pinax-appearance", Archeion.APPEARANCE_BUTTON)
    @test occursin("pinax-appearance", Pinax._APPEARANCE_BUTTON)

    # the same three states in the same order, or the button means two things on one site
    cycle = "v===\"system\"?\"light\":v===\"light\"?\"dark\":\"system\""
    @test occursin(cycle, Archeion.appearance_foot("system"))
    @test occursin(cycle, Pinax._appearance_foot("system"))

    # and one dark palette. Pinax names fourteen; Archeion names those and the graph's five steps.
    pinax_dark = Dict(
        m[1] => m[2] for
        m in eachmatch(r"--([a-z0-9-]+):\s*(#[0-9a-fA-F]{3,6})", Pinax._DARK_TOKENS)
    )
    @test length(pinax_dark) == 14
    for (name, value) in pinax_dark
        @test Archeion.DARK[name] == value
    end
end
