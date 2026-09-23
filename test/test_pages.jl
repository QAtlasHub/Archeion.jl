# pages: the workflows that make a registry readable without running anything, generated rather
# than copied, so the version they install is the one that generated them.

# Lines of the YAML block sequence under `steps:`: an item at six spaces, its keys at eight. A
# generated workflow that gets this wrong is one GitHub refuses, and nothing else here would
# notice — the indentation IS the structure.
function steps_of(yml)
    lines = split(yml, '\n')
    i = findfirst(l -> strip(l) == "steps:", lines)
    i === nothing && return String[]
    out = String[]
    for l in lines[(i + 1):end]
        isempty(strip(l)) && continue
        startswith(l, "      ") || break
        push!(out, String(l))
    end
    return out
end

@testset "setup_pages: both workflows, pinned to the version that wrote them" begin
    root = mktempdir()
    written = Archeion.setup_pages(root; version="9.9.9")
    @test written == [
        joinpath(".github", "workflows", "pages.yml"),
        joinpath(".github", "workflows", "validate.yml"),
    ]
    for w in written
        yml = read(joinpath(root, w), String)
        @test occursin("rev=\"v9.9.9\"", yml)
        @test occursin("-m Archeion", yml)
        steps = steps_of(yml)
        @test !isempty(steps)
        @test all(l -> startswith(l, "      - ") || startswith(l, "        "), steps)
        @test count(l -> startswith(l, "      - "), steps) >= 4
    end
    rm(root; recursive=true)
end

@testset "setup_pages: the branch it watches, and skipping the validate workflow" begin
    root = mktempdir()
    Archeion.setup_pages(root; version="1.2.3", branch="main", validate=false)
    dir = joinpath(root, ".github", "workflows")
    @test readdir(dir) == ["pages.yml"]
    @test occursin("branches: [main]", read(joinpath(dir, "pages.yml"), String))
    rm(root; recursive=true)
end

@testset "pages: the command says what is left to do, and what disagrees" begin
    root = mktempdir()
    write(joinpath(root, "registry.toml"), "spec = \"registry/1\"\nname = \"t\"\n")
    said = sprint() do io
        Archeion.pages_instructions(
            io, root, Archeion.setup_pages(root), Archeion._version()
        )
    end
    @test occursin("Settings -> Pages", said) && occursin("GitHub Actions", said)
    @test occursin("PUBLIC", said)                    # a private repo's site is not private
    @test !occursin("make the two agree", said)       # nothing claimed, nothing to disagree with

    write(
        joinpath(root, "registry.toml"),
        "spec = \"registry/1\"\nname = \"t\"\nimplementation = \"Archeion.jl v0.0.1\"\n",
    )
    said = sprint() do io
        Archeion.pages_instructions(
            io, root, Archeion.setup_pages(root), Archeion._version()
        )
    end
    @test occursin("make the two agree", said)
    rm(root; recursive=true)
end

@testset "pages: the CLI writes them where it is pointed" begin
    root = mktempdir()
    code = redirect_stdout(() -> Archeion.main(["pages", root, "--branch=trunk"]), devnull)
    @test code == 0
    yml = read(joinpath(root, ".github", "workflows", "pages.yml"), String)
    @test occursin("branches: [trunk]", yml)
    @test isfile(joinpath(root, ".github", "workflows", "validate.yml"))
    rm(root; recursive=true)
end

@testset "pages --site: the route for a registry that must not be published" begin
    root = mktempdir()
    written = Archeion.setup_pages(
        root; version="9.9.9", runner="[self-hosted, rosina]", site="/home/x/site/reg"
    )
    @test written == [
        joinpath(".github", "workflows", "site.yml"),
        joinpath(".github", "workflows", "validate.yml"),
    ]
    dir = joinpath(root, ".github", "workflows")
    @test !isfile(joinpath(dir, "pages.yml"))          # nothing is published
    yml = read(joinpath(dir, "site.yml"), String)
    @test occursin("runs-on: [self-hosted, rosina]", yml)
    @test occursin("rev=\"v9.9.9\"", yml)
    # built beside, then renamed into place: a reader never meets a half-written site
    @test occursin("/home/x/site/reg.new", yml) &&
        occursin("mv \"/home/x/site/reg.new\" \"/home/x/site/reg\"", yml)
    @test occursin("-m Archeion validate .", yml)      # and never publishes an invalid tree
    @test occursin(
        "runs-on: [self-hosted, rosina]", read(joinpath(dir, "validate.yml"), String)
    )

    said = sprint() do io
        Archeion.pages_instructions(io, root, written, "9.9.9"; site="/home/x/site/reg")
    end
    @test occursin("ssh-browser", said) && occursin("/home/x/site/reg/index.html", said)
    @test !occursin("Settings -> Pages", said)
    rm(root; recursive=true)
end

@testset "pages: the CLI takes its flags in any order" begin
    root = mktempdir()
    code = redirect_stdout(devnull) do
        Archeion.main(["pages", "--site=/tmp/s", root, "--branch=main"])
    end
    @test code == 0
    yml = read(joinpath(root, ".github", "workflows", "site.yml"), String)
    @test occursin("branches: [main]", yml) && occursin("/tmp/s", yml)
    rm(root; recursive=true)
end
