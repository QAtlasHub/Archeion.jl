# Tags after the fact. The claim is that `record.toml` stays the truth: the verb writes one line
# there, the dashboard follows, and doing it twice does nothing the first time did not.

using Archeion
using Test

function _reg(; git=false)
    root = mktempdir()
    Archeion.create_registry(root; name="R", git=git)
    d = mktempdir()
    write(joinpath(d, "index.html"), "<h1>x</h1>")
    Archeion.deposit(
        d;
        project="p",
        source="s",
        title="T",
        root=root,
        tags=["first"],
        search=false,
        commit=git,
    )
    return root
end

@testset "tag! adds, and adding what is already there writes nothing" begin
    root = _reg()
    r = Archeion.tag!("p/s", "second", "third"; root=root, search=false)
    @test r.tags == ["first", "second", "third"]
    @test Archeion.read_record(joinpath(root, "p", "s")).tags ==
        ["first", "second", "third"]

    before = mtime(joinpath(root, "p", "s", "record.toml"))
    again = Archeion.tag!("p/s", "second"; root=root, search=false)
    @test again.tags == ["first", "second", "third"]
    @test mtime(joinpath(root, "p", "s", "record.toml")) == before      # nothing rewritten
end

@testset "untag! removes, and removing what is absent writes nothing" begin
    root = _reg()
    Archeion.tag!("p/s", "second"; root=root, search=false)
    r = Archeion.untag!("p/s", "first"; root=root, search=false)
    @test r.tags == ["second"]

    before = mtime(joinpath(root, "p", "s", "record.toml"))
    @test Archeion.untag!("p/s", "never-there"; root=root, search=false).tags == ["second"]
    @test mtime(joinpath(root, "p", "s", "record.toml")) == before
end

@testset "the tag reaches both faces of the registry" begin
    root = _reg()
    Archeion.tag!("p/s", "for-the-paper"; root=root, search=false)
    html = read(joinpath(root, "index.html"), String)
    @test occursin("for-the-paper", html)
    @test occursin("data-tags=", html)                     # the filter can match on it
    parsed = Archeion.JSON3.read(read(joinpath(root, "index.json"), String))
    @test "for-the-paper" in parsed["records"][1]["tags"]
end

@testset "an unknown id names the ids that exist" begin
    root = _reg()
    err = try
        Archeion.tag!("p/nope", "x"; root=root, search=false)
    catch e
        sprint(showerror, e)
    end
    @test occursin("p/nope", err)
    @test occursin("p/s", err)                             # so a typo is visible, not silent
end

@testset "an empty tag is refused" begin
    root = _reg()
    @test_throws ErrorException Archeion.tag!("p/s", "  "; root=root, search=false)
end

if Sys.which("git") !== nothing
    @testset "in a git registry the judgement gets its own commit" begin
        withenv(
            "GIT_AUTHOR_NAME" => "tester",
            "GIT_AUTHOR_EMAIL" => "t@example.com",
            "GIT_COMMITTER_NAME" => "tester",
            "GIT_COMMITTER_EMAIL" => "t@example.com",
        ) do
            root = _reg(; git=true)
            Archeion.tag!("p/s", "for-the-paper"; root=root, search=false)
            log = read(`git -C $root log --oneline --format=%s`, String)
            @test occursin("tag p/s: first, for-the-paper", log)
            @test isempty(strip(read(`git -C $root status --porcelain`, String)))
        end
    end
end
