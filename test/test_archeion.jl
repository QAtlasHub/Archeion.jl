# Behavioral tests for the Archeion MVP core. These pin the public contract of
# capture_repro / Record / build_index / add_search, so internal refactors (e.g. the
# _git -> LibGit2 swap) and later changes are guarded against regressions.
using Archeion
using Test
using TOML

@testset "Record <-> record.toml round-trip (full)" begin
    d = mktempdir()
    rec = Archeion.Record(;
        id="r1",
        project="p",
        title="T",
        gallery="g/index.html",
        summary="s",
        tags=["a", "b"],
        bookmark=true,
        thumbnail="t.png",
        git_commit="abc123",
        data_keys=["k1", "k2"],
    )
    @test isfile(Archeion.write_record(rec, d))
    r = Archeion.read_record(d)
    @test (r.id, r.project, r.title, r.gallery) == ("r1", "p", "T", "g/index.html")
    @test r.tags == ["a", "b"] && r.tags isa Vector{String}
    @test r.data_keys == ["k1", "k2"] && r.data_keys isa Vector{String}
    @test r.bookmark
    @test r.thumbnail == "t.png"
    @test r.git_commit == "abc123"
end

@testset "Record round-trip with defaults (thumbnail omitted)" begin
    d = mktempdir()
    Archeion.write_record(
        Archeion.Record(; id="r2", project="p", title="T", gallery="g/index.html"), d
    )
    raw = TOML.parsefile(joinpath(d, "record.toml"))
    @test !haskey(raw, "thumbnail")              # `nothing` is omitted, not serialised
    r = Archeion.read_record(d)
    @test r.thumbnail === nothing
    @test r.tags == String[] && r.tags isa Vector{String}
    @test r.bookmark == false
end

@testset "read_record errors clearly on a missing required field" begin
    dir = mktempdir()
    write(joinpath(dir, "record.toml"), "project = \"p\"\ntitle = \"t\"\ngallery = \"g\"\n")  # no id
    @test_throws ErrorException Archeion.read_record(dir)
end

@testset "build_index renders cards + bookmark + short commit" begin
    site = mktempdir()
    recs = [
        Archeion.Record(;
            id="a",
            project="p",
            title="Alpha",
            gallery="a/index.html",
            tags=["x"],
            bookmark=true,
            git_commit="0123456789abcdef",
        ),
        Archeion.Record(; id="b", project="p", title="Beta", gallery="b/index.html"),
    ]
    p = Archeion.build_index(recs; out=site, title="Reg")
    @test isfile(p)
    html = read(p, String)
    @test occursin("Alpha", html) && occursin("Beta", html)
    @test occursin("Reg", html)
    @test occursin("★", html)                    # bookmark marker
    @test occursin("0123456", html)              # short commit in the meta line
end

@testset "add_search returns false (no throw) when npx is unavailable" begin
    site = mktempdir()
    write(joinpath(site, "index.html"), "<html><body>hi</body></html>")
    withenv("PATH" => "") do
        @test Archeion.add_search(site) === false
    end
end

@testset "capture_repro on a non-git directory" begin
    src = mktempdir()
    write(joinpath(src, "Project.toml"), "name = \"X\"\n")
    write(joinpath(src, "Manifest.toml"), "# manifest\n")
    dest = mktempdir()
    b = Archeion.capture_repro(src, dest)
    @test b.git_commit == "unknown"
    @test b.git_dirty == false
    @test b.has_manifest == true
    @test isfile(joinpath(dest, "repro", "Project.toml"))
    @test isfile(joinpath(dest, "repro", "Manifest.toml"))
    rs = read(joinpath(dest, "repro", "reproduce.sh"), String)
    @test !occursin("git checkout unknown", rs)  # must not emit a broken checkout line
    @test occursin("not a git repository", rs)   # explains why instead
end

@testset "capture_repro warns and reports has_manifest=false without a Manifest" begin
    src = mktempdir()
    write(joinpath(src, "Project.toml"), "name = \"X\"\n")
    dest = mktempdir()
    b = @test_logs (:warn,) match_mode = :any Archeion.capture_repro(src, dest)
    @test b.has_manifest == false
end

@testset "capture_repro config handling (capture / missing-warn / collision-error)" begin
    src = mktempdir()
    write(joinpath(src, "Project.toml"), "name = \"X\"\n")
    write(joinpath(src, "Manifest.toml"), "# manifest\n")

    # present config -> captured + referenced in reproduce.sh
    cfgdir = mktempdir()
    cfg = joinpath(cfgdir, "sweep.toml")
    write(cfg, "x = 1\n")
    dest = mktempdir()
    Archeion.capture_repro(src, dest; config=cfg)
    @test isfile(joinpath(dest, "repro", "sweep.toml"))
    @test occursin(
        "# config used: sweep.toml", read(joinpath(dest, "repro", "reproduce.sh"), String)
    )

    # missing config path -> warns, not captured, no reproduce.sh comment
    dest2 = mktempdir()
    b = @test_logs (:warn,) match_mode = :any Archeion.capture_repro(
        src, dest2; config=joinpath(cfgdir, "nope.toml")
    )
    @test b isa Archeion.ReproBundle
    @test !occursin("# config used", read(joinpath(dest2, "repro", "reproduce.sh"), String))

    # config filename collides with the env snapshot -> error (no silent overwrite)
    bad = joinpath(mktempdir(), "Project.toml")
    write(bad, "name = \"bad\"\n")
    @test_throws ErrorException Archeion.capture_repro(src, mktempdir(); config=bad)
end

# git-backed paths: skipped where the `git` CLI is unavailable (used only to build the
# fixture repos). They pin the "dirty includes untracked" semantics LibGit2 must preserve.
if Sys.which("git") !== nothing
    function _init_repo(d)
        run(`git -C $d init -q`)
        run(`git -C $d config user.email t@example.com`)
        run(`git -C $d config user.name tester`)
        write(joinpath(d, "Project.toml"), "name = \"X\"\n")
        write(joinpath(d, "Manifest.toml"), "# manifest\n")
        run(`git -C $d add -A`)
        run(`git -C $d commit -q -m init`)
        return d
    end

    @testset "capture_repro on a clean git repo" begin
        dest = mktempdir()
        b = Archeion.capture_repro(_init_repo(mktempdir()), dest)
        @test occursin(r"^[0-9a-f]{40}$", b.git_commit)
        @test b.git_dirty == false
        rs = read(joinpath(dest, "repro", "reproduce.sh"), String)
        @test occursin("git checkout " * b.git_commit, rs)
    end

    @testset "capture_repro on a dirty git repo warns and sets git_dirty" begin
        src = _init_repo(mktempdir())
        write(joinpath(src, "untracked.txt"), "x")
        b = @test_logs (:warn,) match_mode = :any Archeion.capture_repro(src, mktempdir())
        @test b.git_dirty == true
    end

    @testset "capture_repro strict=true on a dirty repo raises" begin
        src = _init_repo(mktempdir())
        write(joinpath(src, "untracked.txt"), "x")
        @test_throws ErrorException Archeion.capture_repro(src, mktempdir(); strict=true)
    end
else
    @info "git CLI not found — skipping git-backed capture_repro tests"
end
