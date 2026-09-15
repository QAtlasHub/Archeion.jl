# Publishing a registry as a site. The claims worth pinning are the refusals: a force push to the
# wrong branch destroys documentation, and a push that lands on a repository without Pages enabled
# is a green operation that serves nobody. Nothing here talks to GitHub; `check = false` skips the
# one step that needs the network, and that step is exercised by its own parsing tests.

using Archeion
using Test

function _pages_gitenv()
    return [
        "GIT_AUTHOR_NAME" => "tester",
        "GIT_AUTHOR_EMAIL" => "t@example.com",
        "GIT_COMMITTER_NAME" => "tester",
        "GIT_COMMITTER_EMAIL" => "t@example.com",
    ]
end

withgit_pages(f) = withenv(f, _pages_gitenv()...)

function _page_dir(title="a page")
    d = mktempdir()
    write(joinpath(d, "index.html"), "<!doctype html><h1>$(title)</h1>")
    return d
end

# a registry with one record, and a bare remote to push it to
function _registry_with_remote()
    remote = joinpath(mktempdir(), "origin.git")
    run(`git init -q --bare $remote`)
    root = joinpath(mktempdir(), "Registry")
    Archeion.create_registry(root; name="Registry", repo=remote)
    Archeion.deposit(
        _page_dir("the figure");
        project="demo",
        source="run1",
        title="A demo record",
        root=root,
    )
    return (root, remote)
end

@testset "a remote URL yields owner/name in every spelling, and a token never escapes" begin
    @test Archeion._slug_from_url("git@github.com:QAtlasHub/archeion-demo.git") ==
        "QAtlasHub/archeion-demo"
    @test Archeion._slug_from_url("https://github.com/QAtlasHub/archeion-demo") ==
        "QAtlasHub/archeion-demo"
    @test Archeion._slug_from_url(
        "https://x-access-token:SECRETVALUE@github.com/QAtlasHub/archeion-demo.git"
    ) == "QAtlasHub/archeion-demo"
    @test_throws ErrorException Archeion._slug_from_url("/srv/git/local.git")

    masked = Archeion._mask(
        "fatal: https://x-access-token:SECRETVALUE@github.com/o/r.git denied"
    )
    @test !occursin("SECRETVALUE", masked)
    @test occursin("***", masked)
end

@testset "publish_pages refuses what is not a registry repo" begin
    plain = mktempdir()
    @test_throws ErrorException Archeion.publish_pages(plain; check=false)

    nogit = joinpath(mktempdir(), "R")
    Archeion.create_registry(nogit; name="R", git=false)
    @test_throws ErrorException Archeion.publish_pages(nogit; check=false)
end

@testset "the published branch is the registry, plus .nojekyll" begin
    withgit_pages() do
        root, remote = _registry_with_remote()
        Archeion.publish_pages(root; check=false, search=false)

        site = joinpath(mktempdir(), "site")
        run(`git clone -q --branch gh-pages $remote $site`)
        @test isfile(joinpath(site, "index.html"))
        @test isfile(joinpath(site, Archeion.REGISTRY_FILE))
        @test isfile(joinpath(site, "demo", "run1", "index.html"))
        @test isfile(joinpath(site, "demo", "run1", "record.toml"))
        # Pages runs Jekyll otherwise, which drops paths beginning with an underscore
        @test isfile(joinpath(site, ".nojekyll"))
        # git's own state is not part of the site
        @test !isdir(joinpath(site, ".git", "refs", "remotes", "origin", "main"))
    end
end

@testset "the site branch is derived, so it keeps exactly one commit" begin
    withgit_pages() do
        root, remote = _registry_with_remote()
        Archeion.publish_pages(root; check=false, search=false)
        Archeion.deposit(
            _page_dir("second"); project="demo", source="run2", title="Another", root=root
        )
        Archeion.publish_pages(root; check=false, search=false)

        site = joinpath(mktempdir(), "site")
        run(`git clone -q --branch gh-pages $remote $site`)
        @test length(split(strip(read(`git -C $site log --format=%H`, String)), "\n")) == 1
        @test isfile(joinpath(site, "demo", "run2", "index.html"))
    end
end

@testset "a gh-pages that is not ours is not force-pushed over" begin
    withgit_pages() do
        root, remote = _registry_with_remote()

        # what a Documenter branch looks like from here: content, no registry identity
        docs = mktempdir()
        run(`git -C $docs init -q`)
        mkpath(joinpath(docs, "dev"))
        write(joinpath(docs, "dev", "index.html"), "<h1>the documentation</h1>")
        write(joinpath(docs, "versions.js"), "var DOC_VERSIONS = [];")
        run(`git -C $docs add -A`)
        run(`git -C $docs commit -q -m docs`)
        run(`git -C $docs push -q $remote HEAD:refs/heads/gh-pages`)

        err = try
            Archeion.publish_pages(root; check=false, search=false)
            "no error"
        catch e
            sprint(showerror, e)
        end
        @test occursin("gh-pages", err)
        @test occursin(Archeion.REGISTRY_FILE, err)

        # and the documentation is still there
        site = joinpath(mktempdir(), "site")
        run(`git clone -q --branch gh-pages $remote $site`)
        @test isfile(joinpath(site, "dev", "index.html"))
    end
end
