# The registry's machine face, and the dashboard rendered from it. What these pin is that the
# digest reports STATE, not just size: a record that cannot be reproduced, or that carries no
# machine face, has to be visible without opening it.

using Archeion
using Test

# A record directory as a study leaves it: a gallery, and optionally a Pinax agent.json.
function _record(root, id; title="T", agent=nothing, date="2026-09-15", kwargs...)
    dir = joinpath(root, id)
    mkpath(joinpath(dir, "assets"))
    write(joinpath(dir, "index.html"), "<h1>$(title)</h1>")
    write(joinpath(dir, "assets", "fig1.svg"), "<svg/>")
    if agent !== nothing
        mkpath(joinpath(dir, "agent"))
        write(joinpath(dir, "agent", "agent.json"), agent)
    end
    Archeion.write_record(
        Archeion.Record(;
            id=id,
            project=first(split(id, "/")),
            title=title,
            gallery=joinpath(id, "index.html"),
            date=date,
            kwargs...,
        ),
        dir,
    )
    return dir
end

# the shape Pinax's :agent backend emits, cut down to what the digest reads
function _agent_json(;
    status="final", sections=["One", "Two"], figs=2, with_data=2, asset="assets/fig1.svg"
)
    return """
           {"title":"","parts":[],"pages":[{"id":"p","title":"P","status":"$(status)","figures":[],
            "tables":[{"header":["a"],"rows":[[1]]}],
            "sections":[$(join([
               "{\"id\":\"s$(i)\",\"title\":\"$(s)\",\"figures\":[" *
               join([ "{\"id\":\"f\",\"assets\":[\"$(asset)\"]" * (j <= with_data ? ",\"table\":{\"header\":[\"x\"],\"rows\":[[1]]}" : "") * "}"
                      for j in 1:(i == 1 ? figs : 0) ], ",") *
               "],\"tables\":[]}"
               for (i, s) in enumerate(sections)], ","))]}]}
           """
end

@testset "digest over an empty and a plain root" begin
    dg = Archeion.digest(joinpath(mktempdir(), "nope"))
    @test dg["totals"]["records"] == 0
    @test dg["totals"]["figures"] == 0
    @test isempty(dg["records"])
    @test dg["totals"]["first"] == ""
end

@testset "a record with no machine face is counted as having none" begin
    root = mktempdir()
    _record(root, "p/s"; title="No agent")
    dg = Archeion.digest(root)
    @test dg["totals"]["records"] == 1
    @test dg["totals"]["without_agent"] == 1
    @test dg["records"][1]["agent"] === nothing
    @test !haskey(dg["records"][1], "figures")        # nothing to read, so nothing claimed
    @test dg["totals"]["unknown_commit"] == 1         # no srcdir was given, so no commit
    @test dg["totals"]["reproducible"] == 0
end

@testset "agent.json supplies status, sections, figures and a thumbnail" begin
    root = mktempdir()
    _record(root, "p/s"; title="With agent", agent=_agent_json(), git_commit="a"^40)
    dg = Archeion.digest(root)
    e = dg["records"][1]
    @test e["status"] == "final"
    @test e["sections"] == ["One", "Two"]
    @test e["figures"] == 2
    @test e["figures_with_data"] == 2
    @test e["tables"] == 1
    @test e["agent"] == joinpath("p/s", "agent", "agent.json")
    @test e["thumbnail"] == joinpath("p/s", "assets", "fig1.svg")
    @test dg["totals"]["reproducible"] == 1
    @test dg["totals"]["without_agent"] == 0
end

@testset "one trial page makes the record trial" begin
    root = mktempdir()
    _record(root, "p/s"; agent=_agent_json(; status="trial"))
    @test Archeion.digest(root)["records"][1]["status"] == "trial"
end

@testset "a thumbnail that is not on disk is not offered" begin
    root = mktempdir()
    _record(root, "p/s"; agent=_agent_json(; asset="assets/missing.svg"))
    @test !haskey(Archeion.digest(root)["records"][1], "thumbnail")
end

@testset "dirty and unknown are counted apart, because they fail differently" begin
    root = mktempdir()
    _record(root, "p/clean"; git_commit="a"^40)
    _record(root, "p/dirty"; git_commit="b"^40, git_dirty=true)
    _record(root, "p/none")
    t = Archeion.digest(root)["totals"]
    @test (t["reproducible"], t["dirty"], t["unknown_commit"]) == (1, 1, 1)
    @test t["records"] == 3
    @test t["projects"] == 1
end

@testset "the dashboard shows the registry's state above its records" begin
    root = mktempdir()
    Archeion.create_registry(root; name="Lab", git=false)
    _record(root, "p/s"; title="A record", agent=_agent_json())
    _record(root, "p/t"; title="Unreproducible")
    html = read(Archeion.reindex(root), String)

    @test occursin("<title>Lab</title>", html)
    @test occursin("<div class=\"pinax-stats\">", html)
    @test occursin(">records<", html)
    @test occursin(">not reproducible<", html)
    @test occursin(">no machine face<", html)
    @test occursin("A record", html)
    @test occursin("One", html)                      # section titles ride on the card
    @test occursin("no agent.json", html)            # and the gap is said on the card that has it
    @test occursin("p  ·  2026-09-15", html)         # which project it belongs to leads the line

    # the machine face is written beside the human one, and says the same thing
    js = joinpath(root, "index.json")
    @test isfile(js)
    parsed = Archeion.JSON3.read(read(js, String))
    @test parsed["totals"]["records"] == 2
    @test parsed["totals"]["without_agent"] == 1
    @test length(parsed["records"]) == 2
end

@testset "the search box appears only once there is an index to search" begin
    root = mktempdir()
    Archeion.create_registry(root; name="R", git=false)
    _record(root, "p/s"; title="A record", agent=_agent_json())

    # asked not to build one: no box, and nothing on disk to mislead
    plain = read(Archeion.reindex(root; search=false), String)
    @test !occursin("pagefind/pagefind-ui.js", plain)
    @test !isdir(joinpath(root, "pagefind"))

    if Sys.which("npx") === nothing
        @info "npx not found — skipping the half of this that needs Pagefind"
    else
        html = read(Archeion.reindex(root), String)          # search = true by default
        @test isfile(joinpath(root, "pagefind", "pagefind-ui.js"))
        @test occursin("pagefind/pagefind-ui.js", html)
        @test occursin("id=\"pinax-search\"", html)
    end
end
