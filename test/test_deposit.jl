# deposit: revisions go in through a binding, and a revision that does not validate never lands.

@testset "deposit: `repro` puts named files under repro/" begin
    with_git_fixture() do root, binding, src
        script = joinpath(mktempdir(), "run.jl")
        write(script, "# the script that made it\n")
        res = deposit(
            binding;
            src...,
            doc=DOC,
            source_repo=root,
            push=false,
            repro=Dict("scripts/run.jl" => script),
        )
        @test read(joinpath(res.dir, "repro", "scripts", "run.jl"), String) ==
            "# the script that made it\n"
        @test isempty(Archeion.validate(root).errors)
    end
end

@testset "deposit: a cleanup that fails keeps the failure it was cleaning up after" begin
    parent = mktempdir()
    dir = joinpath(parent, "rev")
    mkpath(dir)
    write(joinpath(dir, "entry.toml"), "x")
    chmod(parent, 0o500)                                  # the entry cannot be unlinked
    try
        @test_logs (:warn, r"could not remove") Archeion.discard!(dir)
        @test isdir(dir)                                  # and the caller still rethrows its own
    finally
        chmod(parent, 0o700)
        rm(parent; recursive=true, force=true)
    end
end

@testset "deposit: the file a render returns stands for its directory" begin
    with_git_fixture() do root, binding, src
        res = deposit(
            binding;
            gallery=joinpath(src.gallery, "index.html"),
            agent=joinpath(src.agent, "agent.json"),
            doc=DOC,
            source_repo=root,
            push=false,
        )
        @test isfile(joinpath(res.dir, "gallery", "index.html"))
        @test isfile(joinpath(res.dir, "agent", "agent.json"))
        @test isempty(Archeion.validate(root).errors)
    end
    with_git_fixture() do root, binding, src
        e = attempt(
            () -> deposit(
                binding;
                gallery=joinpath(root, "no-such-dir"),
                agent=src.agent,
                doc=DOC,
                source_repo=root,
                push=false,
            ),
        )
        @test e isa ErrorException && occursin("is not a directory", e.msg)
        incoming = joinpath(root, "_incoming")
        @test commits(root) == 1 && (!isdir(incoming) || isempty(readdir(incoming)))
    end
end

@testset "deposit" begin
    with_git_fixture() do root, binding, src
        res = deposit(binding; src..., doc=DOC, source_repo=root, push=false)
        r = Archeion.validate(root)
        @test res.parents == [REV_NAME]
        @test isempty(r.errors) && occursin("current $(res.rev)", only(r.summary))
        changed = split(readchomp(`git -C $root show --name-only --format= HEAD`), '\n')
        @test commits(root) == 2 &&
            all(startswith(c, relpath(res.dir, root)) for c in changed)
        e = TOML.parsefile(joinpath(res.dir, "entry.toml"))
        @test e["doc"]["title"] == DOC.title && e["anchors"]["local"] == ["orbits_fig1"]
        @test e["source"]["captured"] == "publish" &&
            length(e["source"]["repo"][1]["commit"]) == 40
    end

    with_git_fixture() do root, binding, src
        gallery = mktempdir()
        cp(src.gallery, joinpath(gallery, "g"))
        write(joinpath(gallery, "g", ".pinax-manifest.toml"), "cache")
        res = deposit(
            binding;
            gallery=joinpath(gallery, "g"),
            agent=src.agent,
            doc=DOC,
            source_repo=root,
            push=false,
        )
        @test !isfile(joinpath(res.dir, "gallery", ".pinax-manifest.toml"))
        rm(gallery; recursive=true)
    end

    with_git_fixture() do root, binding, src
        e = attempt(
            () -> deposit(
                joinpath(root, "nope.toml");
                src...,
                doc=DOC,
                source_repo=root,
                push=false,
            ),
        )
        @test e isa ErrorException && occursin("no binding", e.msg)
        e = attempt(
            () -> new_binding(binding; root=root, project=PROJECT_UUID, slug="again")
        )
        @test e isa ErrorException && occursin("created once", e.msg)
    end

    with_git_fixture() do root, binding, src
        nb = joinpath(root, ".registry", "bindings", "note.toml")
        new_binding(nb; root=root, project=PROJECT_UUID, slug="lab-notes", kind="note")
        res = deposit(nb; src..., doc=DOC, source_repo=root, push=false)
        record = TOML.parsefile(joinpath(dirname(dirname(res.dir)), "record.toml"))
        @test record["kind"] == "note"
        @test TOML.parsefile(joinpath(res.dir, "entry.toml"))["id"]["kind"] == "note"
        @test isempty(Archeion.validate(root).errors)
        site = joinpath(mktempdir(), "_site")
        Archeion.build(root, site)
        page = read(
            joinpath(site, relpath(dirname(dirname(res.dir)), root), "index.html"), String
        )
        @test occursin("· note", page)
        rm(dirname(site); recursive=true)

        bad = joinpath(root, ".registry", "bindings", "diary.toml")
        e = attempt(
            () -> new_binding(
                bad; root=root, project=PROJECT_UUID, slug="diary", kind="diary"
            ),
        )
        @test e isa ErrorException && occursin("kind must be one of", e.msg)
    end

    with_git_fixture() do root, binding, src
        nb = joinpath(root, ".registry", "bindings", "second.toml")
        new_binding(nb; root=root, project=PROJECT_UUID, slug="second-question")
        res = deposit(nb; src..., doc=DOC, source_repo=root, push=false)
        r = Archeion.validate(root)
        @test isempty(r.errors) && length(r.summary) == 2 && res.parents == []
        @test isfile(joinpath(dirname(dirname(res.dir)), "record.toml"))
    end

    with_git_fixture() do root, binding, src
        rec = joinpath(root, REC_REL)
        second_revision!(rec, joinpath(root, REV_REL); parent=false)
        # committed, so that what refuses the deposit is the conflict and not the unsettled tree
        run(`git -C $root add -A`)
        run(`git -C $root -c user.name=t -c user.email=t@t commit -qm "a second head"`)
        n = commits(root)
        e = attempt(() -> deposit(binding; src..., doc=DOC, source_repo=root, push=false))
        @test e isa ErrorException && occursin("in conflict", e.msg) && commits(root) == n
    end

    with_git_fixture() do root, binding, src
        bad = mktempdir()
        cp(src.gallery, joinpath(bad, "gallery"))
        write(joinpath(bad, "gallery", "Index.HTML"), "")    # equal to index.html once lower-cased
        n = commits(root)
        e = attempt(
            () -> deposit(
                binding;
                gallery=joinpath(bad, "gallery"),
                agent=src.agent,
                doc=DOC,
                source_repo=root,
                push=false,
            ),
        )
        @test e isa ErrorException &&
            occursin("taken back out", e.msg) &&
            commits(root) == n
        @test length(readdir(joinpath(root, REC_REL, "revisions"))) == 1
        @test isempty(readdir(joinpath(root, "_incoming")))
        rm(bad; recursive=true)
    end
end

@testset "deposit: what a binding says is checked where it is used, not only where it was written" begin
    for (field, value, says) in (
        ("slug", "../../elsewhere", "is not a slug"),
        ("project", "p_z7ne42dt", "is not a UUID"),
        ("record", "not-a-uuid", "is not a UUID"),
        ("kind", "whatever", "is not one of"),
    )
        with_git_fixture() do root, binding, src
            b = TOML.parsefile(binding)
            b[field] = value
            open(io -> TOML.print(io, b; sorted=true), binding, "w")
            e = attempt(
                () -> deposit(binding; src..., doc=DOC, source_repo=root, push=false)
            )
            @test e isa ErrorException && occursin(says, e.msg)
            # and it was refused before anything was written outside the registry
            @test !ispath(joinpath(dirname(root), "elsewhere"))
            @test isempty(Archeion.validate(root).errors)
        end
    end
end

@testset "deposit: a new record is refused the name another of its year already has" begin
    with_git_fixture() do root, binding, src
        second = joinpath(root, ".registry", "bindings", "twin.toml")
        new_binding(
            second;
            root=root,
            project=PROJECT_UUID,
            slug="logistic-map",              # the slug the fixture's record already has
        )
        e = attempt(() -> deposit(second; src..., doc=DOC, source_repo=root, push=false))
        @test e isa ErrorException && occursin("already called logistic-map", e.msg)
        @test commits(root) == 1                          # nothing was committed
        @test isempty(Archeion.validate(root).errors)
    end
end

@testset "deposit: a new record puts itself in the index, and commits it there" begin
    with_git_fixture() do root, binding, src
        second = joinpath(root, ".registry", "bindings", "other.toml")
        id =
            new_binding(second; root=root, project=PROJECT_UUID, slug="another-question").record
        res = deposit(second; src..., doc=DOC, source_repo=root, push=false)
        @test occursin(id, read(joinpath(root, "registry.toml"), String))
        committed = split(readchomp(`git -C $root show --name-only --format= HEAD`), '\n')
        @test "registry.toml" in committed
        # nothing of the registry's own is left uncommitted (the binding is this test's, and
        # in real use lives in the repository that renders the report, not in this one)
        @test isempty(readchomp(`git -C $root status --porcelain --untracked-files=no`))
        @test isempty(Archeion.validate(root).errors)
    end
end

@testset "deposit: a registry without git still gets its revision" begin
    # What makes a revision what it is — its files, their digests, the parent it answers after —
    # is true of a directory. `validate` says so before the commit is even attempted. Refusing
    # here used to throw a raw `git add` failure *after* the revision was in place, which left it
    # written, valid, and reported as a failure: the worst of both.
    with_fixture() do root, rec, rev
        @test !isdir(joinpath(root, ".git"))              # the fixture is a plain directory
        src = (; gallery=joinpath(rev, "gallery"), agent=joinpath(rev, "agent"))
        binding = joinpath(mktempdir(), "b.toml")
        write(
            binding,
            "spec = \"registry/2\"\nregistry = \"$root\"\nproject = \"$PROJECT_UUID\"\n" *
            "record = \"$RECORD_UUID\"\nslug = \"logistic-map\"\n",
        )
        # the rendering repository is still a git repository; only the registry is not
        study = mktempdir()
        for c in (`init -q`, `config user.name t`, `config user.email t@t`)
            run(pipeline(`git -C $study $c`; stdout=devnull, stderr=devnull))
        end
        write(joinpath(study, "run.jl"), "# the script")
        run(pipeline(`git -C $study add -A`; stdout=devnull, stderr=devnull))
        run(
            pipeline(
                `git -C $study -c user.name=t -c user.email=t@t commit -qm base`;
                stdout=devnull,
                stderr=devnull,
            ),
        )

        r = @test_logs (:warn, r"is not a git repository") match_mode = :any deposit(
            binding; gallery=src.gallery, agent=src.agent, source_repo=study, doc=DOC
        )
        @test r.commit === nothing                        # and it says which part did not happen
        @test r.pushed == false
        @test isdir(r.dir) && sums_verify(r.dir)          # the revision is there, and checks out
        @test isempty(Archeion.validate(root).errors)     # the registry is still valid
    end
end

@testset "deposit: what a non-git registry does NOT get" begin
    # The leniency is `deposit`'s, and it stops there. `publish` syncs with a remote and pushes,
    # neither of which means anything without git — so it refuses at the front door rather than
    # failing three calls later inside `git rev-parse`, which is what it used to do.
    root = mktempdir()
    Archeion.init(root; name="t", pages=false)
    e = attempt(() -> Archeion.sync!(root))
    @test e isa ErrorException
    @test occursin("nothing to sync it with", e.msg)
    @test occursin("`deposit` will still write a revision", e.msg)

    for r in (:pr, :push)
        e = attempt(
            () -> Archeion.publish_revision!(root, "20260101T000000Z-aaaa", "t"; remote=r)
        )
        @test e isa ErrorException && occursin("nothing to push", e.msg)
    end
    # …and the one mode that claims no remote is allowed through
    e = attempt(
        () -> Archeion.publish_revision!(root, "20260101T000000Z-aaaa", "t"; remote=:local)
    )
    @test !(e isa ErrorException && occursin("nothing to push", something(e.msg, "")))
    rm(root; recursive=true)
end
