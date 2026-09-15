# The registry as a directory tree. The claim these pin is narrow and load-bearing: a deposit
# owns what it wrote and NOTHING else, so a re-render can drop a stale figure but can never
# take a sidecar with it.

using Archeion
using Test

# A minimal "built directory": what deposit is handed is any tree with an index.html on top.
function _built(; title="a page", extra=Dict{String,String}())
    d = mktempdir()
    write(joinpath(d, "index.html"), "<!doctype html><h1>$(title)</h1>")
    mkpath(joinpath(d, "assets"))
    write(joinpath(d, "assets", "fig1.svg"), "<svg/>")
    for (k, v) in extra
        p = joinpath(d, k)
        mkpath(dirname(p))
        write(p, v)
    end
    return d
end

@testset "registry_root resolution order" begin
    cfg = joinpath(mktempdir(), "config.toml")
    write(cfg, "[archeion]\nroot = \"/from/config\"\n")
    withenv(Archeion.REGISTRY_ENV => "/from/env") do
        @test Archeion.registry_root(; root="/explicit") == "/explicit"
        @test Archeion.registry_root(; config=cfg) == "/from/config"
        @test Archeion.registry_root() == "/from/env"
        # an explicit argument still wins over both
        @test Archeion.registry_root(; root="/explicit", config=cfg) == "/explicit"
    end
    withenv(Archeion.REGISTRY_ENV => nothing) do
        @test Archeion.registry_root() == joinpath(homedir(), "registry")
        # a config without an [archeion] root falls through rather than erroring
        bare = joinpath(mktempdir(), "bare.toml")
        write(bare, "[study]\nproject_name = \"x\"\n")
        @test Archeion.registry_root(; config=bare) == joinpath(homedir(), "registry")
    end
end

@testset "read_records: absent root, any depth, newest first" begin
    @test isempty(Archeion.read_records(joinpath(mktempdir(), "not-created")))

    root = mktempdir()
    for (rel, date) in [("a/one", "2026-01-01"), ("b/deeper/two", "2026-09-01")]
        dir = joinpath(root, rel)
        mkpath(dir)
        Archeion.write_record(
            Archeion.Record(;
                id=rel,
                project=first(split(rel, "/")),
                title=rel,
                gallery="$(rel)/index.html",
                date=date,
            ),
            dir,
        )
    end
    recs = Archeion.read_records(root)
    @test length(recs) == 2
    @test [r.id for r in recs] == ["b/deeper/two", "a/one"]   # newest first, at any depth
end

@testset "deposit writes the record, the copy and the index" begin
    root = mktempdir()
    res = Archeion.deposit(
        _built();
        project="Open Boundary",
        source="phase 1",
        title="Does it work?",
        root=root,
    )
    @test res.dir == joinpath(root, "open-boundary", "phase-1")
    @test res.record.gallery == joinpath("open-boundary", "phase-1", "index.html")
    @test res.record.project == "open-boundary"
    @test isfile(joinpath(res.dir, "index.html"))
    @test isfile(joinpath(res.dir, "assets", "fig1.svg"))
    @test isfile(joinpath(res.dir, "record.toml"))
    @test Archeion.read_record(res.dir).title == "Does it work?"
    @test isfile(joinpath(root, "index.html"))
    @test occursin("Does it work?", read(joinpath(root, "index.html"), String))
    @test isempty(res.pruned)
end

@testset "a re-deposit prunes its own stale files and keeps every sidecar" begin
    root = mktempdir()
    first_build = _built(; extra=Dict("assets/old.svg" => "<svg/>"))
    r1 = Archeion.deposit(first_build; project="p", source="s", title="T", root=root)

    # things this package did not write: an annotation store, a note, a hand-made PDF
    write(joinpath(r1.dir, "note.md"), "read this")
    mkpath(joinpath(r1.dir, "sidecar", "ann"))
    write(joinpath(r1.dir, "sidecar", "ann", "souta.jsonl"), "{\"op\":\"add\"}\n")

    r2 = Archeion.deposit(_built(); project="p", source="s", title="T", root=root)
    @test joinpath("assets", "old.svg") in r2.pruned                  # a figure the render dropped
    @test !isfile(joinpath(r2.dir, "assets", "old.svg"))
    @test isfile(joinpath(r2.dir, "note.md"))                         # the sidecars survive
    @test isfile(joinpath(r2.dir, "sidecar", "ann", "souta.jsonl"))
    @test isfile(joinpath(r2.dir, "assets", "fig1.svg"))              # and the render is current
    @test length(Archeion.read_records(root)) == 1                    # same record, not a second one
end

@testset "an untitled record is refused, and a doc can supply the title" begin
    root = mktempdir()
    @test_throws ErrorException Archeion.deposit(
        _built(); project="p", source="s", root=root
    )
    # the error has to name the fix, not just the failure
    err = try
        Archeion.deposit(_built(); project="p", source="s", root=root)
    catch e
        sprint(showerror, e)
    end
    @test occursin("title", err)

    res = Archeion.deposit(
        _built(); project="p", source="s", root=root, doc=(; meta=(; title="From the doc"))
    )
    @test res.record.title == "From the doc"
end

@testset "deposit refuses a directory nested with the record directory" begin
    root = mktempdir()
    recdir = joinpath(root, "p", "s")
    mkpath(recdir)
    write(joinpath(recdir, "index.html"), "<h1>x</h1>")
    @test_throws ErrorException Archeion.deposit(
        recdir; project="p", source="s", title="T", root=root
    )
end

@testset "reindex derives the index from whatever is on disk" begin
    root = mktempdir()
    Archeion.deposit(_built(); project="p", source="s", title="First", root=root)
    # a record this package never deposited, dropped in by hand
    hand = joinpath(root, "by-hand", "slides")
    mkpath(hand)
    write(joinpath(hand, "index.html"), "<h1>slides</h1>")
    Archeion.write_record(
        Archeion.Record(;
            id="by-hand/slides",
            project="by-hand",
            title="Hand-made slides",
            gallery=joinpath("by-hand", "slides", "index.html"),
        ),
        hand,
    )
    idx = read(Archeion.reindex(root), String)
    @test occursin("Hand-made slides", idx)
    @test occursin("First", idx)
end

if Sys.which("git") !== nothing
    function _repo(d)
        run(`git -C $d init -q`)
        run(`git -C $d config user.email t@example.com`)
        run(`git -C $d config user.name tester`)
        write(joinpath(d, "Project.toml"), "name = \"X\"\n")
        run(`git -C $d add -A`)
        run(`git -C $d commit -q -m init`)
        return d
    end

    @testset "srcdir records the provenance, and a dirty tree says so" begin
        root = mktempdir()
        src = _repo(mktempdir())
        res = Archeion.deposit(
            _built(); project="p", source="clean", title="T", root=root, srcdir=src
        )
        @test occursin(r"^[0-9a-f]{40}$", res.record.git_commit)
        @test res.record.git_dirty == false
        @test isfile(joinpath(res.dir, "repro", "reproduce.sh"))
        @test Archeion.read_record(res.dir).git_commit == res.record.git_commit

        write(joinpath(src, "untracked.txt"), "x")
        dirty = @test_logs (:warn,) match_mode = :any Archeion.deposit(
            _built(); project="p", source="dirty", title="T", root=root, srcdir=src
        )
        @test dirty.record.git_dirty == true
        # the dirty flag has to reach the card, where the commit is actually read
        @test occursin("+dirty", read(joinpath(root, "index.html"), String))

        @test_throws ErrorException Archeion.deposit(
            _built();
            project="p",
            source="strict",
            title="T",
            root=root,
            srcdir=src,
            strict=true,
        )
    end
else
    @info "git CLI not found: skipping the provenance half of the registry tests"
end

@testset "the catalogue is titled by the registry, and provenance is captured before writing" begin
    # A catalogue titled "Archeion" says which tool made it, not which registry this is.
    root = mktempdir()
    Archeion.deposit(_built(); project="p", source="s", title="T", root=root)
    @test occursin("<title>Archeion</title>", read(joinpath(root, "index.html"), String))

    named = joinpath(mktempdir(), "Lab")
    Archeion.create_registry(named; name="Lab Registry", git=false)
    Archeion.deposit(_built(); project="p", source="s", title="T", root=named)
    @test occursin(
        "<title>Lab Registry</title>", read(joinpath(named, "index.html"), String)
    )

    # A `strict` refusal must leave no half-written record: the capture happens first.
    if Sys.which("git") !== nothing
        src = mktempdir()
        run(`git -C $src init -q`)
        write(joinpath(src, "untracked.txt"), "x")
        reg = mktempdir()
        @test_throws ErrorException Archeion.deposit(
            _built(); project="p", source="s", title="T", root=reg, srcdir=src, strict=true
        )
        @test !isfile(joinpath(reg, "p", "s", "index.html"))
        @test !isfile(joinpath(reg, "p", "s", "record.toml"))
    end
end
