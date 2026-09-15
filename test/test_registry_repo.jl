# A registry is a git repository, so the claims worth pinning are the ones that make a clone
# usable somewhere else: the identity file is there, a deposit is a commit, and a push followed
# by a clone reproduces the record. Git identity comes from the environment rather than from
# `git config`, so these run on a machine that has never configured one.

using Archeion
using Test

const GITENV = Dict(
    "GIT_AUTHOR_NAME" => "tester",
    "GIT_AUTHOR_EMAIL" => "t@example.com",
    "GIT_COMMITTER_NAME" => "tester",
    "GIT_COMMITTER_EMAIL" => "t@example.com",
)

withgit(f) = withenv(f, GITENV...)

function _built(title="a page")
    d = mktempdir()
    write(joinpath(d, "index.html"), "<!doctype html><h1>$(title)</h1>")
    return d
end

_log(root) = (strip(read(`git -C $root log --oneline --format=%s`, String)))

@testset "create_registry writes an identity and a first commit" begin
    withgit() do
        root = joinpath(mktempdir(), "Registry")
        p = Archeion.create_registry(
            root; name="Lab", description="records", repo="https://example.com/r.git"
        )
        @test p == abspath(root)
        @test Archeion.is_registry(root)
        @test isfile(joinpath(root, "README.md"))

        info = Archeion.registry_info(root)
        @test info.name == "Lab"
        @test info.repo == "https://example.com/r.git"
        @test info.description == "records"
        @test occursin(
            r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", info.uuid
        )

        @test isdir(joinpath(root, ".git"))
        @test occursin("Create the Lab registry", _log(root))
        # the recorded remote is wired up, so a clone target needs no extra step
        @test strip(read(`git -C $root remote get-url origin`, String)) ==
            "https://example.com/r.git"
    end
end

@testset "create_registry refuses to overwrite, and git = false leaves no repo" begin
    withgit() do
        root = joinpath(mktempdir(), "R")
        Archeion.create_registry(root; name="R")
        @test_throws ErrorException Archeion.create_registry(root; name="R")

        bare = joinpath(mktempdir(), "plain")
        Archeion.create_registry(bare; name="plain", git=false)
        @test Archeion.is_registry(bare)
        @test !isdir(joinpath(bare, ".git"))
    end
end

@testset "registry_info names the fix when the directory is not a registry" begin
    d = mktempdir()
    @test !Archeion.is_registry(d)
    err = try
        Archeion.registry_info(d)
    catch e
        sprint(showerror, e)
    end
    @test occursin("create_registry", err)
end

@testset "the uuid is derived, so two clones of one registry agree" begin
    a = Archeion._registry_uuid("Lab", "https://example.com/r.git", "2026-09-15T00:00:00")
    b = Archeion._registry_uuid("Lab", "https://example.com/r.git", "2026-09-15T00:00:00")
    c = Archeion._registry_uuid("Other", "https://example.com/r.git", "2026-09-15T00:00:00")
    @test a == b
    @test a != c
end

@testset "a deposit is a commit, and an unchanged re-deposit is not" begin
    withgit() do
        root = joinpath(mktempdir(), "Registry")
        Archeion.create_registry(root; name="Registry")

        r1 = Archeion.deposit(_built(); project="p", source="s", title="First", root=root)
        @test !isempty(r1.commit)
        @test occursin("deposit p/s: First", _log(root))
        # the record and the index are both in the commit, by explicit path
        tracked = read(`git -C $root ls-files`, String)
        @test occursin("p/s/record.toml", tracked)
        @test occursin("index.html", tracked)

        # A re-deposit is a new event: `date` defaults to now, so `record.toml` changes and the
        # commit is real. That is the honest reading of "this was rendered again".
        r2 = Archeion.deposit(_built(); project="p", source="s", title="First", root=root)
        @test !isempty(r2.commit)

        # Pin the date and nothing moves, which is the branch that must not report failure.
        fixed = (; project="p", source="s", title="First", root=root, date="2026-09-15")
        Archeion.deposit(_built(); fixed...)
        again = Archeion.deposit(_built(); fixed...)
        @test again.commit == ""
    end
end

@testset "deposit outside a git repo still writes, and commit = false stages nothing" begin
    withgit() do
        plain = mktempdir()
        r = Archeion.deposit(_built(); project="p", source="s", title="T", root=plain)
        @test r.commit == ""
        @test isfile(joinpath(r.dir, "record.toml"))

        root = joinpath(mktempdir(), "R")
        Archeion.create_registry(root; name="R")
        r2 = Archeion.deposit(
            _built(); project="p", source="s", title="T", root=root, commit=false
        )
        @test r2.commit == ""
        @test isfile(joinpath(r2.dir, "record.toml"))
        @test !occursin("deposit", _log(root))
        # `-uall` because porcelain collapses an untracked directory to `?? p/`
        @test occursin(
            "p/s/record.toml", read(`git -C $root status --porcelain -uall`, String)
        )
    end
end

@testset "sync refuses clearly without a repo or a remote" begin
    withgit() do
        plain = mktempdir()
        @test_throws ErrorException Archeion.sync(plain)

        root = joinpath(mktempdir(), "R")
        Archeion.create_registry(root; name="R")          # no repo= given, so no origin
        @test_throws ErrorException Archeion.sync(root)
    end
end

@testset "push then clone reproduces the record somewhere else" begin
    withgit() do
        remote = joinpath(mktempdir(), "origin.git")
        run(`git init -q --bare $remote`)

        root = joinpath(mktempdir(), "Registry")
        Archeion.create_registry(root; name="Registry", repo=remote)
        Archeion.deposit(
            _built("the figure");
            project="OpenBoundary",
            source="phase1",
            title="Does it work?",
            root=root,
        )
        @test Archeion.sync(root; pull=false)

        clone = joinpath(mktempdir(), "clone")
        run(`git clone -q $remote $clone`)
        @test Archeion.is_registry(clone)
        @test Archeion.registry_info(clone).name == "Registry"
        recs = Archeion.read_records(clone)
        @test length(recs) == 1
        @test recs[1].title == "Does it work?"
        # `_slug` lowercases and replaces runs of invalid characters; "OpenBoundary" has none, so
        # it does NOT gain a separator (that only happens for "Open Boundary").
        @test isfile(joinpath(clone, "openboundary", "phase1", "index.html"))
    end
end
