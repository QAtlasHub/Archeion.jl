# site: what a reader meets before any record — the banner, its menu, the footer — and `init`,
# which writes the file those come from, so a registry has them from its first commit.

# The filter script is allowed to be JavaScript; the menu is not, because these pages are read
# from file:// too. Strip the one before looking at the other.
without_scripts(html) = replace(html, r"<script>.*?</script>"s => "")

@testset "site: the banner says what registry.toml says" begin
    with_fixture() do root, rec, rev
        reg = TOML.parsefile(joinpath(root, "registry.toml"))
        write(
            joinpath(root, "registry.toml"),
            """
            spec = "registry/2"
            name = "fallback-name"
            uuid = "$(reg["uuid"])"
            [site]
            title = "The Registry"
            tagline = "one question per record"
            footer = "built from the tree"
            [[site.links]]
            text = "Records"
            url = "index.html"
            [[site.links]]
            text = "The lab"
            url = "https://example.org"
            """,
        )
        Archeion.reindex!(root)                            # the head was rewritten; §2.1 stands
        Archeion.build(root)
        index = read(joinpath(root, "_site", "index.html"), String)
        page = read(joinpath(root, "_site", REC_REL, "index.html"), String)

        @test occursin("<header class=\"site\">", index)
        @test occursin(">The Registry</a>", index) && !occursin("fallback-name", index)
        @test occursin("one question per record", index)
        @test occursin("<footer class=\"site\">built from the tree</footer>", index)
        # a link out opens out; a link inside is relative to where the page sits
        @test occursin("href=\"https://example.org\" rel=\"noopener\"", index)
        @test occursin("href=\"./index.html\">Records</a>", index)
        @test occursin("href=\"../../../index.html\">Records</a>", page)
        @test occursin("<header class=\"site\">", page)        # the same banner, one level down
        # the menu opens with a checkbox, so it opens with scripting off
        @test occursin("class=\"burger\"", without_scripts(index))
        @test occursin("#m:checked~nav", Archeion.CSS)
    end
end

@testset "site: a registry that says nothing still has a name" begin
    with_fixture() do root, rec, rev
        write(joinpath(root, "registry.toml"), "spec = \"registry/2\"\n")
        Archeion.reindex!(root)
        Archeion.build(root)
        index = read(joinpath(root, "_site", "index.html"), String)
        @test occursin("<header class=\"site\">", index)
        @test occursin(basename(abspath(root)), index)         # its own directory name
        @test !occursin("<nav>", index)                        # no links, so no menu
        @test !occursin("<footer", index)
    end
end

@testset "init: valid and wearing its banner from the first commit" begin
    root = mktempdir()
    written = Archeion.init(
        root; name="lab-registry", title="Lab", tagline="what we measured"
    )
    @test "registry.toml" in written && ".gitignore" in written
    @test joinpath(".github", "workflows", "pages.yml") in written

    toml = TOML.parsefile(joinpath(root, "registry.toml"))
    @test toml["spec"] == "registry/2" && toml["name"] == "lab-registry"
    @test Archeion.is_uuid(toml["uuid"])                   # a registry names itself too
    @test toml["site"]["title"] == "Lab" && toml["site"]["tagline"] == "what we measured"
    @test occursin("_site/", read(joinpath(root, ".gitignore"), String))

    r = Archeion.validate(root)                                # empty, and valid
    @test isempty(r.errors) && isempty(r.summary)
    @test Archeion.build(root).records == 0                    # and it builds
    @test occursin(">Lab</a>", read(joinpath(root, "_site", "index.html"), String))

    e = attempt(() -> Archeion.init(root))                     # never over an existing registry
    @test e isa ErrorException && occursin("already holds", e.msg)
    rm(root; recursive=true)
end

@testset "init: what a tool leaves in a directory is not a record" begin
    root = mktempdir()
    Archeion.init(root; pages=false)
    write(joinpath(root, "records", ".DS_Store"), "")          # the classic
    r = Archeion.validate(root)
    @test isempty(r.errors)
    @test Archeion.build(root).records == 0
    rm(root; recursive=true)
end

@testset "init: the command, and what it tells you to do next" begin
    root = joinpath(mktempdir(), "lab-notes")     # a directory that does not exist yet
    out = IOBuffer()
    code = redirect_stdout(
        () -> Archeion.main(["init", root, "--title=Lab Notes", "--tagline=as we go"]),
        devnull,
    )
    @test code == 0
    toml = TOML.parsefile(joinpath(root, "registry.toml"))
    @test toml["name"] == "lab-notes"             # named after the directory unless told otherwise
    @test toml["site"]["title"] == "Lab Notes" && toml["site"]["tagline"] == "as we go"
    @test isempty(Archeion.validate(root).errors)

    said = sprint() do io
        Archeion.init_instructions(io, root, ["registry.toml"], "lab-notes")
    end
    @test occursin("registry.toml", said) && occursin("[site]", said)
    @test occursin("new_binding", said) && occursin("publish", said)
    rm(dirname(root); recursive=true)
end
