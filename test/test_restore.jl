# restore / verify: a revision is laid out from what it holds, recomputed with nothing else, and
# earns `capability.verified` only when every point's result file comes out the same.

# Its own names: the shards run the test files apart, so nothing from test_provenance.jl is here.
const R_OBS1 = "obs1-20260922T000000Z-1a2b-0123456789abcdef"
const R_OBS2 = "obs1-20260922T000001Z-1a2b-0123456789abcdee"

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

# A snapshot of a study of one script that writes `bytes` to `$DATAVAULT_OUTDIR/data/<key>.bin`.
function script_snapshot!(sources, key, bytes)
    script = """
    out = ENV["DATAVAULT_OUTDIR"]
    mkpath(joinpath(out, "data"))
    write(joinpath(out, "data", "$key.bin"), $(repr(bytes)))
    """
    ssha = bytes2hex(sha256(script))
    tsv = "src1\nconfig\trun.jl\tfile\t-\t$(sizeof(script))\t$ssha\n"
    id = "src1-" * bytes2hex(sha256(tsv))
    mkpath(joinpath(sources, id))
    write(joinpath(sources, id, "files.tsv"), tsv)
    write(joinpath(sources, id, "state.toml"), "recipe = \"src1\"\n")
    mkpath(joinpath(sources, "blobs"))
    write(joinpath(sources, "blobs", ssha), script)
    return id
end

# One observation of such a study, recorded as DataVault 0.8.7 writes it: the script it ran, the
# study root, and the Julia binary by digest.
function script_observation!(observations, token, source)
    exe = joinpath(Sys.BINDIR, Base.julia_exename())
    study = "/origin/study"                                # where it lived; never read
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
        roots = [{name = "config", kind = "plain", dir = "$study", head = "unknown", dirty = "unknown", loaded = "not-loaded", object_format = "unknown"}]
        [julia]
        version = "$VERSION"
        bindir = "$(escape_string(Sys.BINDIR))"
        executable_sha256 = "$(bytes2hex(open(sha256, exe)))"
        threads = 1
        blas_threads = 1
        """,
    )
end

# `result` is what the revision says k1's file held; `second` adds a point computed from other code.
function script_store(; bytes="42\n", result=bytes, second=false)
    dir = mktempdir()
    sources, observations = joinpath(dir, "sources"), joinpath(dir, "observations")
    script_observation!(observations, R_OBS1, script_snapshot!(sources, "k1", bytes))
    reads = [r_point("k1", R_OBS1, bytes2hex(sha256(result)))]
    if second
        script_observation!(observations, R_OBS2, script_snapshot!(sources, "k2", "7\n"))
        push!(reads, r_point("k2", R_OBS2, bytes2hex(sha256("7\n"))))
    end
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
        dest = joinpath(mktempdir(), "sealed")
        v = Archeion.verify(res.dir; dest)
        @test v.ok && v.compared == 1 && v.matched == ["k1"]
        @test isfile(joinpath(dest, "study", "run.jl"))
        @test v.event !== nothing && isfile(v.event)
        ev = TOML.parsefile(v.event)
        @test ev["kind"] == "capability.verified" &&
            ev["subject"]["rev"] == basename(res.dir)
        @test ev["conditions"]["depot"] == "restored-only"
        @test ev["conditions"]["network"] == v.network
        @test isempty(Archeion.validate(root).errors)
        rm(dirname(dest); recursive=true)
    end
end

@testset "verify: a result that comes out otherwise earns nothing" begin
    with_script_revision(; result="43\n") do root, res
        dest = joinpath(mktempdir(), "sealed")
        v = Archeion.verify(res.dir; dest)
        @test !v.ok && v.differs == ["k1"] && v.event === nothing
        @test !isdir(joinpath(dirname(dirname(res.dir)), "events"))
        rm(dirname(dest); recursive=true)
    end
end

@testset "restore: points from two source states are not restored as one" begin
    with_script_revision(; second=true) do root, res
        e = attempt(() -> Archeion.restore(res.dir, joinpath(mktempdir(), "r")))
        @test e isa ErrorException && occursin("2 source states", e.msg)
    end
end
