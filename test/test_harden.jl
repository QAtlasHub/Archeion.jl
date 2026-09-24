# The three ways a registry could be damaged by something it was told was fine.

@testset "deposit: a registry that has not committed its own work is not deposited into" begin
    with_git_fixture() do root, binding, src
        d1 = deposit(binding; src..., doc=DOC, source_repo=root, push=false)
        d2 = deposit(binding; src..., doc=DOC, source_repo=root, push=false)
        # what a deposit killed between writing the revision and committing it leaves behind:
        # the revision on disk, in no commit anywhere
        run(`git -C $root reset -q $("HEAD~1")`)
        @test isdir(d2.dir)
        @test isempty(
            readchomp(`git -C $root log --oneline --all -- $(relpath(d2.dir, root))`)
        )
        @test isempty(first(Archeion.validate(root)).errors)   # the tree itself is fine

        # Without the check the next deposit names that orphan as its parent and commits it, and
        # one `git clean` later the registry cites a revision whose bytes are nowhere.
        e = attempt(() -> deposit(binding; src..., doc=DOC, source_repo=root, push=false))
        @test e isa ErrorException && occursin("uncommitted changes of its own", e.msg)
        @test occursin(basename(d2.dir), e.msg)                # and says which
    end
end

@testset "deposit: only the registry's own work counts as unsettled" begin
    with_git_fixture() do root, binding, src
        # the binding lives under .registry/ and is untracked here; a site is derived. Neither is
        # anything a revision could come to depend on.
        mkpath(joinpath(root, "_site"))
        write(joinpath(root, "_site", "index.html"), "derived")
        write(joinpath(root, "scratch.txt"), "mine")
        res = deposit(binding; src..., doc=DOC, source_repo=root, push=false)
        @test isdir(res.dir)
    end
end

@testset "validate: SHA256SUMS lists the revision's own files and nothing else" begin
    for (what, line) in (
        ("an absolute path", "/etc/passwd"),
        ("a path that walks out", "../../../../../../etc/passwd"),
    )
        r = validated() do root, rec, rev
            sums = joinpath(rev, "SHA256SUMS")
            # a digest that would match, for a file that is not the revision's
            write(sums, read(sums, String) * "$(repeat("0", 64))  $line\n")
        end
        @test mentions(r.errors, "leaves the revision")
    end
end

@testset "build: a link that leaves the site is broken, however real it is here" begin
    with_fixture() do root, rec, rev
        page = joinpath(rev, "gallery", "index.html")
        write(
            page,
            replace(read(page, String), "<html" => "<html", count=1) *
            "\n<a href=\"../../../../../../../../etc/passwd\">out</a>\n",
        )
        Archeion.write_sums(rev)
        @test isempty(first(Archeion.validate(root)).errors)
        e = attempt(() -> Archeion.build(root))
        @test e isa ErrorException && occursin("leaves the site", e.msg)
    end
end
