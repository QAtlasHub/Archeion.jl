# restore / verify: a revision is laid out from what it holds, recomputed with nothing else, and
# earns `capability.verified` only when every point's result file comes out the same. A revision
# may come from someone else's registry, so what it names is checked before it becomes a path.

# Its own names: the shards run the test files apart, so nothing from test_provenance.jl is here.
const R_OBS1 = "obs1-20260922T000000Z-1a2b-0123456789abcdef"
const R_OBS2 = "obs1-20260922T000001Z-1a2b-0123456789abcdee"
const R_UUID = "5f0a6c4e-1d2b-4c3a-9e8f-7a6b5c4d3e2f"

function r_point(key, observation, result)
    return (;
        key,
        file="data/$key.bin",
        read_sha256=result,
        result_sha256=result,
        observation,
        completed_at="2026-09-22T00:00:00Z",
    )
end

# A study of one script that writes `bytes` to `$DATAVAULT_OUTDIR/data/<key>.bin` for each key.
function script_text(keys, bytes)
    lines = ["out = ENV[\"DATAVAULT_OUTDIR\"]", "mkpath(joinpath(out, \"data\"))"]
    append!(
        lines, ["write(joinpath(out, \"data\", \"$k.bin\"), $(repr(bytes)))" for k in keys]
    )
    return join(lines, "\n") * "\n"
end

# A snapshot of the study plus `extra` rows: (root, path, type, content). Returns its id.
function script_snapshot!(sources, script; extra=())
    mkpath(joinpath(sources, "blobs"))
    rows = [("config", "run.jl", "file", script)]
    append!(rows, extra)
    lines = ["src1"]
    for (root, path, type, content) in rows
        sha = bytes2hex(sha256(content))
        write(joinpath(sources, "blobs", sha), content)
        push!(
            lines, join((root, escape_string(path), type, "-", sizeof(content), sha), '\t')
        )
    end
    tsv = join(lines, "\n") * "\n"
    id = "src1-" * bytes2hex(sha256(tsv))
    mkpath(joinpath(sources, id))
    write(joinpath(sources, id, "files.tsv"), tsv)
    write(joinpath(sources, id, "state.toml"), "recipe = \"src1\"\n")
    return id
end

# One observation of such a study, as DataVault 0.8.7 writes it, with `roots` beyond the study.
function script_observation!(observations, token, source; roots=(), exe_sha=nothing)
    exe = joinpath(Sys.BINDIR, Base.julia_exename())
    study = "/origin/study"                                # where it lived; never read
    extra = join([
        ", {name = \"$(r.name)\", kind = \"$(r.kind)\", dir = \"/origin/x\", " *
        "head = \"$(r.head)\", dirty = \"unknown\", loaded = \"not-loaded\", " *
        "object_format = \"sha1\"}" for r in roots
    ],)
    mkpath(observations)
    return write(
        joinpath(observations, "$token.toml"),
        """
        observation_version = 1
        token = "$token"
        source = "$source"
        binding = "unverified"
        binding_reasons = []
        program = "$study/run.jl"
        main_files = []
        roots = [{name = "config", kind = "plain", dir = "$study", head = "unknown", dirty = "unknown", loaded = "not-loaded", object_format = "unknown"}$extra]
        [julia]
        version = "$VERSION"
        bindir = "$(escape_string(Sys.BINDIR))"
        executable_sha256 = "$(something(exe_sha, bytes2hex(open(sha256, exe))))"
        threads = 1
        blas_threads = 1
        """,
    )
end

# `result` is what the revision says each file held; `tokens` are the processes that computed the
# points, one point each, all from the same snapshot.
function script_store(;
    bytes="42\n", result=bytes, tokens=[R_OBS1], extra=(), roots=(), exe_sha=nothing
)
    dir = mktempdir()
    sources, observations = joinpath(dir, "sources"), joinpath(dir, "observations")
    keys = ["k$i" for i in eachindex(tokens)]
    id = script_snapshot!(sources, script_text(keys, bytes); extra)
    foreach(t -> script_observation!(observations, t, id; roots, exe_sha), tokens)
    reads = [
        r_point(k, t, result == "unknown" ? "unknown" : bytes2hex(sha256(result))) for
        (k, t) in zip(keys, tokens)
    ]
    return (; dir, observations, sources, reads)
end

function with_script_revision(f; kw...)
    store = script_store(; kw...)
    try
        with_git_fixture() do root, binding, src
            res = deposit(
                binding;
                src...,
                doc=DOC,
                source_repo=root,
                push=false,
                provenance=(;
                    reads=store.reads,
                    observations_dir=store.observations,
                    sources_dir=store.sources,
                ),
            )
            return f(root, res)
        end
    finally
        rm(store.dir; recursive=true)
    end
end

sealed() = joinpath(mktempdir(), "sealed")

# A depot package of one file, and the tree git would pin it to.
function depot_package()
    content = "module Foo\nend\n"
    d = mktempdir()
    mkpath(joinpath(d, "src"))
    write(joinpath(d, "src", "Foo.jl"), content)
    tree = Archeion.git_tree_hash(d)
    rm(d; recursive=true)
    return content, tree
end

@testset "git_tree_hash: what git itself says" begin
    dir = mktempdir()
    try
        write(joinpath(dir, "a.jl"), "x = 1\n")
        mkpath(joinpath(dir, "src", "deep"))
        write(joinpath(dir, "src", "deep", "b.txt"), "b")
        write(joinpath(dir, "run.sh"), "#!/bin/sh\n")
        chmod(joinpath(dir, "run.sh"), 0o755)
        symlink("a.jl", joinpath(dir, "link.jl"))
        mkpath(joinpath(dir, "empty"))                     # git has no empty trees
        run(`git -C $dir init -q`)
        run(`git -C $dir add -A`)
        @test Archeion.git_tree_hash(dir) == readchomp(`git -C $dir write-tree`)
        write(joinpath(dir, "a.jl"), "x = 2\n")
        @test Archeion.git_tree_hash(dir) != readchomp(`git -C $dir write-tree`)
    finally
        rm(dir; recursive=true)
    end
end

@testset "verify: a revision recomputed from itself earns capability.verified" begin
    with_script_revision() do root, res
        dest = sealed()
        v = Archeion.verify(res.dir; dest)
        @test v.ok && v.compared == 1 && v.matched == ["k1"] && isempty(v.excluded)
        @test isfile(joinpath(dest, "study", "run.jl"))
        @test v.event !== nothing && isfile(v.event)
        ev = TOML.parsefile(v.event)
        @test ev["kind"] == "capability.verified" &&
            ev["subject"]["rev"] == basename(res.dir)
        @test ev["conditions"]["depot"] == "restored-only"
        @test ev["conditions"]["network"] == v.network
        @test ev["conditions"]["julia_as_recorded"] == true
        @test ev["conditions"]["not_held"] == 0
        @test isempty(Archeion.validate(root).errors)
        rm(dirname(dest); recursive=true)
    end
end

@testset "verify: a result that comes out otherwise earns nothing" begin
    with_script_revision(; result="43\n") do root, res
        v = Archeion.verify(res.dir; dest=sealed())
        @test !v.ok && v.differs == ["k1"] && v.event === nothing
        @test !isdir(joinpath(dirname(dirname(res.dir)), "events"))
    end
end

@testset "verify: every process's points are compared, not one process's" begin
    with_script_revision(; tokens=[R_OBS1, R_OBS2]) do root, res
        v = Archeion.verify(res.dir; dest=sealed())
        @test v.ok && v.compared == 2 && sort(v.matched) == ["k1", "k2"]
        @test sort(TOML.parsefile(v.event)["observations"]) == [R_OBS1, R_OBS2]
    end
end

@testset "verify: a point that cannot be compared withholds the event" begin
    with_script_revision(; result="unknown") do root, res
        v = Archeion.verify(res.dir; dest=sealed())
        @test !v.ok && v.excluded == ["k1"] && v.event === nothing
    end
end

@testset "restore: points from two source states are not restored as one" begin
    store = script_store()
    other = script_snapshot!(store.sources, script_text(["k2"], "7\n"))
    script_observation!(store.observations, R_OBS2, other)
    push!(store.reads, r_point("k2", R_OBS2, bytes2hex(sha256("7\n"))))
    try
        with_git_fixture() do root, binding, src
            res = deposit(
                binding;
                src...,
                doc=DOC,
                source_repo=root,
                push=false,
                provenance=(;
                    reads=store.reads,
                    observations_dir=store.observations,
                    sources_dir=store.sources,
                ),
            )
            e = attempt(() -> Archeion.restore(res.dir, sealed()))
            @test e isa ErrorException && occursin("2 source states", e.msg)
        end
    finally
        rm(store.dir; recursive=true)
    end
end

@testset "restore: a path that leaves the restore is refused, and nothing is written" begin
    escape = "../../escaped-$(rand(UInt32)).txt"
    with_script_revision(; extra=[("config", escape, "file", "pwned")]) do root, res
        dest = sealed()
        e = attempt(() -> Archeion.restore(res.dir, dest))
        @test e isa ErrorException && occursin("cannot be restored safely", e.msg)
        @test occursin(escape, e.msg)
        @test !isfile(normpath(joinpath(dest, "study", escape)))
    end
    for bad in ("pkg:../up:$R_UUID", "pkg:Foo:not-a-uuid", "artifact:x:../../y")
        kind = startswith(bad, "artifact") ? "artifact" : "plain"
        with_script_revision(; roots=[(; name=bad, kind, head="unknown")]) do root, res
            e = attempt(() -> Archeion.restore(res.dir, sealed()))
            @test e isa ErrorException && occursin(repr(bad), e.msg)
        end
    end
end

@testset "restore: a symlink that leaves its root is not made, and is named" begin
    links = [
        ("config", "in.jl", "symlink", "run.jl"), ("config", "out", "symlink", "../..")
    ]
    with_script_revision(; extra=links) do root, res
        r = Archeion.restore(res.dir, sealed())
        @test islink(joinpath(r.study, "in.jl")) &&
            readlink(joinpath(r.study, "in.jl")) == "run.jl"
        @test !ispath(joinpath(r.study, "out"))
        @test any(m -> occursin("config:out (symlink leaving its root)", m), r.missing)
    end
end

@testset "restore: a depot package goes where Julia looks, and is held to its pin" begin
    content, tree = depot_package()
    name = "pkg:Foo:$R_UUID"
    row = [(name, "src/Foo.jl", "file", content)]
    with_script_revision(;
        extra=row, roots=[(; name, kind="depot", head=tree)]
    ) do root, res
        r = Archeion.restore(res.dir, sealed())
        slug = Base.version_slug(Base.UUID(R_UUID), Base.SHA1(tree))
        @test isfile(joinpath(r.depot, "packages", "Foo", slug, "src", "Foo.jl"))
        @test r.trees[name] == true
    end
    wrong = "0"^40
    with_script_revision(;
        extra=row, roots=[(; name, kind="depot", head=wrong)]
    ) do root, res
        e = attempt(() -> Archeion.verify(res.dir; dest=sealed()))
        @test e isa ErrorException && occursin("do not hash to their pins", e.msg)
        @test occursin(name, e.msg)
    end
end

@testset "restore: a Julia that is not the recorded binary is not run" begin
    with_script_revision(; exe_sha="f"^64) do root, res
        r = Archeion.restore(res.dir, sealed())
        @test r.julia === nothing && occursin("digest differs", r.julia_note)
        e = attempt(() -> Archeion.verify(res.dir; dest=sealed()))
        @test e isa ErrorException && occursin("no Julia to run", e.msg)
    end
end
