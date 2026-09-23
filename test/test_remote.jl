# remote: what happens around the deposit commit — is this clone current, is the code the revision
# cites published, and how the commit reaches the shared repository.

# A bare "remote" with the fixture registry pushed to it, and a clone of it.
function with_remote(f)
    with_git_fixture() do root, binding, src
        remote = mktempdir()
        run(`git -C $remote init -q --bare`)
        run(`git -C $root remote add origin $remote`)
        run(`git -C $root push -q --set-upstream origin HEAD:refs/heads/master`)
        clone = mktempdir()
        run(`git clone -q $remote $clone`)
        for c in (`config user.name t`, `config user.email t@t`)
            run(`git -C $clone $c`)
        end
        try
            f(root, binding, src, remote, clone)
        finally
            rm(remote; recursive=true, force=true)
            rm(clone; recursive=true, force=true)
        end
    end
end

# The fixture, its binding committed (so a clone of it can deposit too), on a bare remote.
function with_shared_registry(f)
    with_git_fixture() do root, binding, src
        run(`git -C $root add -A`)
        run(`git -C $root -c user.name=t -c user.email=t@t commit -qm binding`)
        remote = mktempdir()
        run(`git -C $remote init -q --bare`)
        run(`git -C $root remote add origin $remote`)
        run(`git -C $root push -q --set-upstream origin HEAD:refs/heads/master`)
        clone = mktempdir()
        run(`git clone -q $remote $clone`)
        for c in (`config user.name t`, `config user.email t@t`)
            run(`git -C $clone $c`)
        end
        try
            f(root, binding, src, remote, clone)
        finally
            rm(remote; recursive=true, force=true)
            rm(clone; recursive=true, force=true)
        end
    end
end

# A commit in `dir` that only `dir` has.
function commit_in!(dir, name)
    write(joinpath(dir, name), "x\n")
    run(`git -C $dir add -- $name`)
    run(`git -C $dir -c user.name=t -c user.email=t@t commit -qm $name`)
    return strip(read(`git -C $dir rev-parse HEAD`, String))
end

tracked(dir, ref) = read(`git -C $dir ls-tree -r --name-only $ref`, String)

@testset "sync!: a clone that is behind is brought forward, a dirty one is refused" begin
    with_remote() do root, binding, src, remote, clone
        commit_in!(root, "later.txt")
        run(`git -C $root push -q`)
        @test !isfile(joinpath(clone, "later.txt"))
        Archeion.sync!(clone)
        @test isfile(joinpath(clone, "later.txt"))          # fast-forwarded to the remote

        write(joinpath(clone, "scratch.txt"), "uncommitted\n")
        e = attempt(() -> Archeion.sync!(clone))
        @test e isa ErrorException && occursin("uncommitted changes", e.msg)
        rm(joinpath(clone, "scratch.txt"))
    end
end

@testset "sync!: a clone that has diverged is not fixed silently" begin
    with_remote() do root, binding, src, remote, clone
        commit_in!(root, "theirs.txt")
        run(`git -C $root push -q`)
        commit_in!(clone, "mine.txt")
        e = attempt(() -> Archeion.sync!(clone))
        @test e isa ErrorException && occursin("cannot fast-forward", e.msg)
    end
end

@testset "sync!: no remote is a warning, not a failure" begin
    with_git_fixture() do root, binding, src
        run(`git -C $root add -A`)                          # the binding, written after the commit
        run(`git -C $root -c user.name=t -c user.email=t@t commit -qm binding`)
        @test_logs (:warn, r"tracks no remote") Archeion.sync!(root)
    end
end

@testset "sync!: a remote that cannot be reached is worked around, not hidden" begin
    with_remote() do root, binding, src, remote, clone
        run(`git -C $clone remote set-url origin $(joinpath(remote, "gone"))`)
        @test_logs (:warn, r"could not fetch") Archeion.sync!(clone)
    end
end

@testset "check_source_published: a commit only this clone has is named" begin
    with_remote() do root, binding, src, remote, clone
        run(`git -C $clone remote set-head origin master`)
        @test Archeion.check_source_published(clone)        # HEAD is what the remote has
        commit_in!(clone, "unpublished.jl")
        @test_logs (:warn, r"not on origin/master") (@test !Archeion.check_source_published(
            clone
        ))
        run(`git -C $clone push -q`)
        @test Archeion.check_source_published(clone)        # published: the citation resolves
    end
end

@testset "publish_revision!: local keeps it here, push sends it" begin
    with_remote() do root, binding, src, remote, clone
        res = deposit(binding; src..., doc=DOC, source_repo=root, push=false)
        sent = Archeion.publish_revision!(root, res.rev, "t"; remote=:local)
        @test !sent.pushed && sent.pr === nothing
        @test !occursin(basename(res.dir), tracked(remote, "master"))

        sent = Archeion.publish_revision!(root, res.rev, "t"; remote=:push)
        @test sent.pushed && sent.branch == "master"
        @test occursin(basename(res.dir), tracked(remote, "master"))
    end
end

@testset "publish_revision!: a remote that moved is rebased onto, then revalidated" begin
    with_shared_registry() do root, binding, src, remote, clone
        theirs = deposit(binding; src..., doc=DOC, source_repo=root, push=false)
        Archeion.publish_revision!(root, theirs.rev, "theirs"; remote=:push)

        # This clone knew nothing of that revision when it deposited its own.
        mine = deposit(
            joinpath(clone, relpath(binding, root));
            gallery=joinpath(clone, relpath(src.gallery, root)),
            agent=joinpath(clone, relpath(src.agent, root)),
            doc=DOC,
            source_repo=clone,
            push=false,
        )
        sent = Archeion.publish_revision!(clone, mine.rev, "mine"; remote=:push)
        @test sent.pushed
        on_remote = tracked(remote, "master")
        @test occursin(theirs.rev, on_remote) && occursin(mine.rev, on_remote)
        # Both name the same parent, so the record is in conflict — said, not resolved by time.
        r, summary = Archeion.validate(clone)
        @test isempty(r.errors) && occursin("in conflict", only(summary))
    end
end

@testset "check_source_published: a repository with no remote says so" begin
    with_git_fixture() do root, binding, src
        @test_logs (:warn, r"no origin/HEAD") (@test !Archeion.check_source_published(root))
    end
end

@testset "publish_revision!: with no tool to open the request, the branch still goes up" begin
    with_shared_registry() do root, binding, src, remote, clone
        res = deposit(binding; src..., doc=DOC, source_repo=root, push=false)
        sent = @test_logs (:info, r"is not installed") Archeion.publish_revision!(
            root, res.rev, "t"; remote=:pr, gh="gh-that-is-not-installed"
        )
        @test sent.pushed && sent.pr === nothing
        @test occursin(basename(res.dir), tracked(remote, "deposit/$(res.rev)"))
    end
end

@testset "publish_revision!: the request it opened is what is returned" begin
    with_shared_registry() do root, binding, src, remote, clone
        fake = joinpath(mktempdir(), "gh")
        write(fake, "#!/bin/sh\necho https://example.invalid/pr/1\n")
        chmod(fake, 0o755)
        res = deposit(binding; src..., doc=DOC, source_repo=root, push=false)
        sent = Archeion.publish_revision!(root, res.rev, "t"; remote=:pr, gh=fake)
        @test sent.pr == "https://example.invalid/pr/1"
    end
end

@testset "publish_revision!: pr pushes a branch of its own" begin
    with_remote() do root, binding, src, remote, clone
        res = deposit(binding; src..., doc=DOC, source_repo=root, push=false)
        # The remote is a bare repository on disk, so `gh pr create` has nothing to talk to: the
        # branch still goes up, and not opening the request is reported, never fatal.
        sent = Archeion.publish_revision!(root, res.rev, "a title"; remote=:pr)
        @test sent.pushed && sent.branch == "deposit/$(res.rev)"
        @test occursin(basename(res.dir), tracked(remote, "deposit/$(res.rev)"))
        # master is untouched: the revision is proposed, not published
        @test !occursin(basename(res.dir), tracked(remote, "master"))
    end
    @test Archeion.deposit_branch("20260923T000000Z-abcd") ==
        "deposit/20260923T000000Z-abcd"
    e = attempt(() -> Archeion.publish_revision!(".", "r", "t"; remote=:elsewhere))
    @test e isa ErrorException && occursin("must be :pr, :push or :local", e.msg)
end
