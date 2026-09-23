# dark: the site is derived, so the site's copy of a frozen revision may be darkened. The
# revision may not, and this is mostly about proving that it is not.

const LIGHT_SHEET = """
body{background:#fafafa;color:#24292f}
a{color:#0366d6}
section.section{background:#fff;border:1px solid #e2e5e9}
figcaption{color:#444}
.pinax-verdict-fail{background:#ffebe9;border:1px solid #cf222e;color:#a40e26}
figure iframe.pinax-pdf{background:#fff}
"""

# Add a stylesheet to a copied fixture's revision and keep SHA256SUMS true, so the registry it
# lands in is one `validate` accepts.
function with_stylesheet!(rev, css=LIGHT_SHEET)
    rel = joinpath("gallery", "style.css")
    write(joinpath(rev, rel), css)
    open(joinpath(rev, "SHA256SUMS"), "a") do io
        return println(io, bytes2hex(open(sha256, joinpath(rev, rel))), "  ", rel)
    end
    return joinpath(rev, rel)
end

@testset "dark: a light stylesheet gains a layer, and keeps the one it had" begin
    layer = Archeion.darkened(LIGHT_SHEET)
    @test occursin("@media (prefers-color-scheme: dark)", layer)
    @test occursin("background:#0d1117", layer) && occursin("color:#e6edf3", layer)
    @test occursin("color:#4493f8", layer)                  # the link
    @test occursin("#30363d", layer)                        # the hairline
    @test !occursin("#fafafa", layer) && !occursin("#0366d6", layer)

    # a document is a white page and does not follow the theme into the dark
    pdf = only(l for l in split(layer, '\n') if occursin("pinax-pdf", l))
    @test occursin("#fff", pdf)

    # a sheet that brought its own dark mode keeps it, untouched
    @test Archeion.darkened(
        LIGHT_SHEET * "\n@media (prefers-color-scheme: dark){a{color:red}}"
    ) == ""
    # and one drawing with a colour this does not know is left alone, not half-converted
    @test Archeion.darkened(LIGHT_SHEET * "\n.x{color:#123456}") == ""
end

@testset "dark: the site's copy is darkened; the revision it came from is not" begin
    with_fixture() do root, rec, rev
        sheet = with_stylesheet!(rev)
        before = read(sheet, String)
        @test isempty(first(Archeion.validate(root)).errors)

        Archeion.build(root)
        copied = joinpath(
            root, "_site", REC_REL, "revisions", REV_NAME, "gallery", "style.css"
        )
        @test occursin("prefers-color-scheme: dark", read(copied, String))
        @test startswith(read(copied, String), before)      # the light half is still first

        # what the registry holds is what it held: byte for byte, and its digest still agrees
        @test read(sheet, String) == before
        @test sums_verify(rev)
        @test isempty(first(Archeion.validate(root)).errors)
    end
end

@testset "dark: a vendored stylesheet is not ours to rewrite" begin
    with_fixture() do root, rec, rev
        assets = joinpath(rev, "gallery", "assets", "katex")
        mkpath(assets)
        write(joinpath(assets, "katex.min.css"), ".katex{color:#24292f}\n")
        @test Archeion.darken_site_copy!(joinpath(rev, "gallery")) == 0
        @test !occursin(
            "prefers-color-scheme", read(joinpath(assets, "katex.min.css"), String)
        )
    end
end

@testset "dark: every colour the frozen reports use has a role" begin
    # The derived layer refuses to half-convert, so an unknown colour silently means "no dark
    # mode for that report". This is the list that keeps that from happening quietly.
    for hex in keys(Archeion.ROLE)
        @test Archeion.dark_of(hex) !== nothing
    end
    @test Archeion.dark_of("#123456") === nothing
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

@testset "dark: what the palette puts together can be read" begin
    # Exchanging colours by role is mechanical, and mechanical is how a palette ends up with grey
    # on grey. Every pair the stylesheets actually draw is measured, not eyeballed.
    D = Archeion.DARK
    for (what, fg, bg, need) in (
        ("body text", "fg", "bg", 4.5),
        ("text on a card", "fg", "card", 4.5),
        ("text in a panel", "fg", "soft", 4.5),
        ("muted text", "mut", "bg", 4.5),
        ("muted on a card", "mut", "card", 4.5),
        ("faint text", "faint", "bg", 3.0),          # small print: large-text threshold
        ("a link", "acc", "bg", 4.5),
        ("a link on a card", "acc", "card", 4.5),
        ("passed", "ok", "ok-bg", 4.5),
        ("failed", "bad", "bad-bg", 4.5),
        ("warning", "warn", "warn-bg", 4.5),
        ("a hairline", "line", "bg", 1.5),           # a line, not a letter
    )
        r = contrast(D[fg], D[bg])
        r >= need || @info "contrast too low" what fg = D[fg] bg = D[bg] ratio = r need
        @test r >= need
    end
end
