# provenance: a revision's point table and the observations it names go in with the revision, and
# a table that disagrees with its summary, or an observation that is not what it names, is caught.

using DataVault

# A data store's provenance directories, written by hand: one snapshot of one source file (its
# contents kept), and one observation of it with the given binding.
const OBS = "obs1-20260922T000000Z-1a2b-0123456789abcdef"

function synthetic_store(; binding="unverified", version=1)
    dir = mktempdir()
    blob = "module P\nend\n"
    bsha = bytes2hex(sha256(blob))
    tsv = "src1\nconfig\tsrc/P.jl\tfile\t-\t$(sizeof(blob))\t$bsha\n"
    id = "src1-" * bytes2hex(sha256(tsv))
    sources = joinpath(dir, "sources")
    mkpath(joinpath(sources, id))
    write(joinpath(sources, id, "files.tsv"), tsv)
    write(joinpath(sources, id, "state.toml"), "recipe = \"src1\"\n")
    mkpath(joinpath(sources, "blobs"))
    write(joinpath(sources, "blobs", bsha), blob)
    token = OBS
    observations = joinpath(dir, "observations")
    mkpath(observations)
    write(
        joinpath(observations, "$token.toml"),
        "observation_version = $version\ntoken = \"$token\"\nsource = \"$id\"\n" *
        "binding = \"$binding\"\nbinding_reasons = []\n",
    )
    return (; dir, observations, sources, token, id, bsha)
end

const SHA_A = "a"^64
function point(key, observation; read=SHA_A, result=read)
    return (;
        key,
        file="data/$key.jld2",
        read_sha256=read,
        result_sha256=result,
        observation,
        completed_at="2026-09-22T00:00:00Z",
    )
end

# Deposit into the git fixture with provenance from `store`; `f(root, res)` sees the result (or the
# exception, if the deposit refused).
function deposited(f, reads; store=synthetic_store(), kw...)
    try
        with_git_fixture() do root, binding, src
            prov = (;
                reads, observations_dir=store.observations, sources_dir=store.sources, kw...
            )
            res = attempt(
                () -> deposit(
                    binding;
                    src...,
                    doc=DOC,
                    source_repo=root,
                    push=false,
                    provenance=prov,
                ),
            )
            return f(root, res)
        end
    finally
        rm(store.dir; recursive=true)
    end
end

# The deposited revision, broken by `mutate!(dir)` with SHA256SUMS rewritten to stay true, so the
# break is what the validator names.
function broken(mutate!, reads=[point("k1", OBS)])
    deposited(reads) do root, res
        mutate!(res.dir)
        Archeion.write_sums(res.dir)
        r, _ = Archeion.validate(root)
        return (; errors=r.errors, warnings=r.warnings)
    end
end
rewrite!(path, f) = write(path, f(read(path, String)))

@testset "provenance: a deposit carries its points and what they name" begin
    store = synthetic_store()
    t = store.token
    reads = [point("k2", t), point("k1", t), point("k3", "unknown"; result="unknown")]
    deposited(reads; store) do root, res
        r, _ = Archeion.validate(root)
        @test isempty(r.errors) && isempty(r.warnings)
        p = TOML.parsefile(joinpath(res.dir, "provenance.toml"))
        @test p["schema"] == "registry.provenance/1" && p["points"] == 3
        @test p["counts"] == Dict(
            "read_matches_result" => 2,
            "read_differs_from_result" => 0,
            "result_unknown" => 1,
        )
        @test p["bindings"] == Dict("unverified" => 2, "unknown" => 1)
        @test p["observations"] == [t] && isempty(p["missing_observations"])
        rows = readlines(joinpath(res.dir, "provenance", "points.tsv"))
        @test first.(split.(rows[2:end], '\t')) == ["k1", "k2", "k3"]
        @test isfile(joinpath(res.dir, "repro", "observations", "$t.toml"))
        snap = joinpath(res.dir, "repro", "sources", store.id[6:37])
        @test isfile(joinpath(snap, "files.tsv")) && isfile(joinpath(snap, "state.toml"))
        @test isfile(joinpath(res.dir, "repro", "blobs", store.bsha[1:32]))
        sums = read(joinpath(res.dir, "SHA256SUMS"), String)
        @test occursin("  provenance/points.tsv", sums) &&
            occursin("  provenance.toml", sums)

        site = joinpath(mktempdir(), "_site")
        Archeion.build(root, site)
        rec = relpath(dirname(dirname(res.dir)), root)
        page = read(joinpath(site, rec, "index.html"), String)
        served = joinpath(site, relpath(res.dir, root))
        @test isfile(joinpath(served, "provenance.toml")) &&
            isdir(joinpath(served, "gallery"))
        @test !ispath(joinpath(served, "provenance")) && !ispath(joinpath(served, "repro"))
        @test occursin("3 points: 2 read as recorded", page) &&
            occursin("1 unrecorded", page)
        @test occursin("code unknown 1, unverified 2", page)
        rm(dirname(site); recursive=true)
    end
end

@testset "provenance: without contents, only the inventory is kept" begin
    store = synthetic_store()
    deposited([point("k1", store.token)]; store, source_contents=false) do root, res
        @test isempty(first(Archeion.validate(root)).errors)
        @test !isdir(joinpath(res.dir, "repro", "blobs"))
        @test TOML.parsefile(joinpath(res.dir, "provenance.toml"))["source_contents"] ==
            false
    end
end

@testset "provenance: bytes read other than recorded are refused, or let in and said" begin
    t = OBS
    reads = [point("k1", t; result="b"^64)]
    deposited(reads) do root, res
        @test res isa ErrorException && occursin("allow_mismatch", res.msg)
        incoming = joinpath(root, "_incoming")
        @test commits(root) == 1 && (!isdir(incoming) || isempty(readdir(incoming)))
    end
    deposited(reads; allow_mismatch=true) do root, res
        r, _ = Archeion.validate(root)
        @test isempty(r.errors)
        @test mentions(r.warnings, "1 point(s) read bytes that differ") &&
            mentions(r.warnings, "allow_mismatch")
    end
end

@testset "provenance: an observation the store does not have is listed, not dropped" begin
    other = "obs1-20260922T000001Z-1a2b-fedcba9876543210"
    deposited([point("k1", other)]) do root, res
        r, _ = Archeion.validate(root)
        @test isempty(r.errors) && mentions(r.warnings, "$other was not available")
        p = TOML.parsefile(joinpath(res.dir, "provenance.toml"))
        @test p["missing_observations"] == [other] && p["bindings"] == Dict("unknown" => 1)
    end
end

@testset "provenance: a match is not taken at its word" begin
    store = synthetic_store(; binding="loaded-matches-disk")
    deposited([point("k1", store.token)]; store) do root, res
        r, _ = Archeion.validate(root)
        @test isempty(r.errors)
        @test mentions(r.warnings, "it is counted as `unverified`")
        p = TOML.parsefile(joinpath(res.dir, "provenance.toml"))
        @test p["bindings"] == Dict("unverified" => 1)       # never counted as a match
    end
    store = synthetic_store(; binding="loaded-differs-from-disk")
    deposited([point("k1", store.token)]; store) do root, res
        r, _ = Archeion.validate(root)
        @test isempty(r.warnings)
        @test TOML.parsefile(joinpath(res.dir, "provenance.toml"))["bindings"] ==
            Dict("loaded-differs-from-disk" => 1)
    end
end

@testset "provenance: a name that is not a token never becomes a path" begin
    deposited([point("k1", "../../escape")]) do root, res
        @test res isa ErrorException && occursin("not an observation token", res.msg)
        @test commits(root) == 1
    end
end

@testset "provenance: what the validator refuses" begin
    points(dir) = joinpath(dir, "provenance", "points.tsv")
    summary(dir) = joinpath(dir, "provenance.toml")
    t = OBS

    v = broken(d -> rewrite!(points(d), s -> replace(s, "k1" => "k0")))
    @test mentions(v.errors, "`points_digest` does not match")

    v = broken(d -> rewrite!(summary(d), s -> replace(s, "points = 1" => "points = 2")))
    @test mentions(v.errors, "`points` is 2 but")

    v = broken() do d
        rewrite!(
            summary(d),
            s -> replace(s, "read_matches_result = 1" => "read_matches_result = 0"),
        )
    end
    @test mentions(v.errors, "`counts.read_matches_result` does not match")

    v = broken(d -> rm(joinpath(d, "repro", "observations", "$t.toml")))
    @test mentions(v.errors, "$t is named but not in repro/observations")

    v = broken() do d
        obs = joinpath(d, "repro", "observations", "$t.toml")
        rewrite!(
            obs, s -> replace(s, "binding = \"unverified\"" => "binding = \"trust-me\"")
        )
    end
    @test mentions(v.errors, "\"trust-me\" is not one of")
    @test mentions(v.errors, "`bindings` does not match")

    v = broken() do d
        snap = only(readdir(joinpath(d, "repro", "sources"); join=true))
        rewrite!(joinpath(snap, "files.tsv"), s -> s * "config\tx.jl\tfile\t-\t0\t$SHA_A\n")
    end
    @test mentions(v.errors, "does not hash to its snapshot id")

    v = broken(d -> rm(joinpath(d, "repro", "sources"); recursive=true))
    @test mentions(v.errors, "is not in repro/sources")

    v = broken(d -> rewrite!(summary(d), s -> replace(s, "registry.provenance/1" => "x/1")))
    @test mentions(v.errors, "`schema` must be")

    v = broken(d -> rewrite!(points(d), s -> replace(s, "read_sha256" => "read")))
    @test mentions(v.errors, "the header is not")
end

@testset "provenance_from: a real vault, observed and completed" begin
    dir = mktempdir()
    try
        cfg = joinpath(dir, "study.toml")
        write(
            cfg,
            """
            [study]
            project_name = "prov_study"
            total_samples = 1
            outdir = "out"
            [datavault]
            path_keys = ["system.N"]
            [[paramsets]]
            [paramsets.system]
            N = [4, 8]
            """,
        )
        vault = DataVault.Vault(cfg; outdir=joinpath(dir, "out"))
        token = DataVault.observe_sources(vault)
        for k in DataVault.keys(vault)
            saved = DataVault.save!(vault, k, Dict("x" => 1.0))
            DataVault.mark_done!(vault, k; result=saved, observation=token)
        end
        reads = [last(DataVault.load_recorded(vault, k)) for k in DataVault.keys(vault)]
        prov = Archeion.provenance_from(vault, (; reads, render_observation=token))
        with_git_fixture() do root, binding, src
            res = deposit(
                binding; src..., doc=DOC, source_repo=root, push=false, provenance=prov
            )
            r, _ = Archeion.validate(root)
            @test isempty(r.errors)
            p = TOML.parsefile(joinpath(res.dir, "provenance.toml"))
            @test p["points"] == 2 && p["counts"]["read_matches_result"] == 2
            @test p["observations"] == [token] && p["render_observation"] == token
            @test sum(values(p["bindings"])) == 2 && !haskey(p["bindings"], "unknown")
        end
    finally
        rm(dir; recursive=true)
    end
end
