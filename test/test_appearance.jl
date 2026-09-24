# appearance: `dark.jl` derives the layer, `appearance.jl` decides when it applies. What is checked
# here is the *when* — the markup, the link's `media`, and the three refusals. The cycle the control
# performs was measured in jsdom against a site built from the real registry; the cascade it drives
# is a browser's business and is not asserted here.

const FRAGMENT = "<div>a report page this is not</div>"

whole_page(head="", body="") = """
<!doctype html><html lang="en"><head><meta charset="utf-8">$head</head>
<body>$body</body></html>
"""

@testset "appearance: a page gets the control, or a reason it does not" begin
    got = Archeion.inject_appearance(whole_page(), "system", ["style.dark.css"])
    @test got !== nothing
    @test occursin("""href="style.dark.css" media="(prefers-color-scheme: dark)\"""", got)
    @test occursin("data-appearance-dark", got)
    @test occursin("pinax-appearance", got)
    # the script sets the attribute before anything can paint with it
    @test findfirst("data-theme", got)[1] < findfirst("</head>", got)[1]
    # …and the button is in the body, not the head
    @test findfirst("<button class=\"pinax-appearance\"", got)[1] >
        findfirst("</head>", got)[1]

    # Three refusals, each for its own reason.
    @test Archeion.inject_appearance(whole_page(), "system", String[]) === nothing
    @test Archeion.inject_appearance(FRAGMENT, "system", ["x.dark.css"]) === nothing
    brought_its_own = whole_page("", """<button class="pinax-appearance"></button>""")
    @test Archeion.inject_appearance(brought_its_own, "system", ["x.dark.css"]) === nothing
end

@testset "appearance: nothing to switch, so nothing to switch it with" begin
    # A button that sets `data-theme` on a page where no rule answers to it is worse than no
    # button: it looks like the site is broken rather than like the site never offered.
    @test Archeion.inject_appearance(whole_page(), "dark", String[]) === nothing
end

@testset "appearance: the page's own stylesheets, and only those" begin
    html = """
    <link rel="stylesheet" href="style.css">
    <link rel="stylesheet" href="assets/katex/katex.min.css">
    <link rel="stylesheet" href="https://cdn.example/katex.min.css">
    <link rel="stylesheet" href="/site-wide.css">
    <link rel="icon" href="favicon.css">
    """
    @test Archeion.linked_stylesheets(html) == ["style.css", "assets/katex/katex.min.css"]
end

@testset "appearance: the default is the registry's, and a typo does not darken a site" begin
    @test Archeion.appearance_of(Dict{String,Any}()) == "system"
    @test Archeion.appearance_of(Dict{String,Any}("appearance" => "dark")) == "dark"
    @test Archeion.appearance_of(Dict{String,Any}("appearance" => "LIGHT")) == "light"
    # a misspelling in a config file is not a reason to hold a whole site in the dark
    @test (@test_logs (:warn, r"appearance is not one of") Archeion.appearance_of(
        Dict{String,Any}("appearance" => "darkk")
    )) == "system"
end

@testset "appearance: the catalogue and the reports are told the same default" begin
    with_fixture() do root, rec, rev
        with_stylesheet!(rev)
        reg = joinpath(root, "registry.toml")
        write(
            reg,
            replace(
                read(reg, String),
                "\n[projects]" => "\n[site]\nappearance = \"dark\"\n\n[projects]",
            ),
        )
        @test isempty(Archeion.validate(root).errors)

        res = Archeion.build(root)
        @test res.dark.controls == 1

        catalogue = read(joinpath(root, "_site", "index.html"), String)
        report = read(
            joinpath(
                root, "_site", REC_REL, "revisions", basename(rev), "gallery", "index.html"
            ),
            String,
        )
        for page in (catalogue, report)
            @test occursin("var d=\"dark\"", page)          # one site, one default
            @test occursin("pinax-appearance", page)
        end
        # and the registry itself is where it was
        @test sums_verify(rev)
        @test isempty(Archeion.validate(root).errors)
    end
end
