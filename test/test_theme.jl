# theme: the catalogue and the reports it links to are read as one thing, so they are one palette.
# Archeion cannot depend on Pinax, so it names the same values; this checks they still agree, and
# fails when either side moves.

using Pinax

# What a CSS declaration gives a property, inside the first rule whose selector matches.
function css_value(css, selector, property)
    m = match(Regex("\\Q$selector\\E\\s*\\{([^}]*)\\}"), css)
    m === nothing && return nothing
    d = match(Regex("(?:^|;)\\s*\\Q$property\\E\\s*:\\s*([^;}]+)"), m[1])
    return d === nothing ? nothing : strip(d[1])
end

token(name) = css_value(Archeion.CSS, ":root", name)

@testset "theme: the palette is Pinax's, and the two still agree" begin
    gallery = Pinax._GALLERY_CSS               # internal: what is being tracked is internal too
    @test css_value(gallery, "body", "background") == token("--bg") == "#fafafa"
    @test css_value(gallery, "body", "color") == token("--fg") == "#24292f"
    @test css_value(gallery, "nav a", "color") == token("--acc") == "#0366d6"
    @test occursin(token("--line"), css_value(gallery, "section.section", "border"))
    @test occursin(token("--card"), css_value(gallery, "section.section", "background"))
    @test css_value(gallery, ".desc", "background") == token("--soft") == "#f6f8fa"
    # the same type, so a heading does not change face between the catalogue and the report
    @test occursin("system-ui", css_value(gallery, "body", "font-family"))
    @test occursin("system-ui", css_value(Archeion.CSS, "body", "font"))
end

@testset "theme: no dark mode, because the reports have none" begin
    # A catalogue that flips to dark in front of light reports is a worse seam than any shade.
    @test !occursin("prefers-color-scheme", Archeion.CSS)
    @test !occursin("prefers-color-scheme", Pinax._GALLERY_CSS)
end

@testset "theme: every colour the site draws with comes from a token" begin
    # Hard-coded colours are how a palette drifts. `#fff` behind a figure is the exception: a
    # figure is drawn on white whatever the page around it is.
    body = replace(Archeion.CSS, r":root\{[^}]*\}" => "")
    hard = [m.match for m in eachmatch(r"#[0-9a-fA-F]{3,6}", body)]
    @test all(==("#fff"), hard)
end
