# deposit: revisions go in through a binding, and a revision that does not validate never lands.

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
        @test isempty(first(Archeion.validate(root)).errors)
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
        r, summary = Archeion.validate(root)
        @test res.parents == [REV_NAME]
        @test isempty(r.errors) && occursin("current $(res.rev)", only(summary))
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
            () -> new_binding(binding; registry=root, project="p_z7ne42dt", slug="again")
        )
        @test e isa ErrorException && occursin("created once", e.msg)
    end

    with_git_fixture() do root, binding, src
        nb = joinpath(root, ".registry", "bindings", "second.toml")
        new_binding(nb; registry=root, project="p_z7ne42dt", slug="second-question")
        res = deposit(nb; src..., doc=DOC, source_repo=root, push=false)
        r, summary = Archeion.validate(root)
        @test isempty(r.errors) && length(summary) == 2 && res.parents == []
        @test isfile(joinpath(dirname(dirname(res.dir)), "record.toml"))
    end

    with_git_fixture() do root, binding, src
        rec = joinpath(root, REC_REL)
        second_revision!(rec, joinpath(root, REV_REL); parent=false)
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
