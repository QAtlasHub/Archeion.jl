# publish: the one call a study makes. Render a vault through a recipe, deposit both faces with
# the table of what was read, and get the commit to the shared registry — tested end to end,
# because everything it wires together is only wired together here.

using DataVault, Pinax

# A vault with one point, actually computed and marked done, so `publish` has something to read.
function one_point_vault(; name="pub_study")
    dir = mktempdir()
    cfg = joinpath(dir, "study.toml")
    write(
        cfg,
        """
        [study]
        project_name = "$name"
        total_samples = 1
        outdir = "out"
        [datavault]
        path_keys = ["system.N"]
        [[paramsets]]
        [paramsets.system]
        N = [4]
        """,
    )
    vault = DataVault.Vault(cfg; outdir=joinpath(dir, "out"))
    token = DataVault.observe_sources(vault)
    for k in DataVault.keys(vault)
        saved = DataVault.save!(vault, k, Dict("x" => 1.0))
        DataVault.mark_done!(vault, k; result=saved, observation=token)
    end
    return vault
end

# A report with nothing in it that needs a plotting backend.
final_recipe(pairs) = @page :only "A report" status = :final begin
    @desc md"""one paragraph, and no figure."""
end
trial_recipe(pairs) = @page :only "A report" status = :trial begin
    @desc md"""one paragraph, and no figure."""
end

@testset "publish: renders, deposits and says what it did" begin
    with_git_fixture() do root, binding, src
        out = joinpath(mktempdir(), "rep")
        res = Archeion.publish(
            one_point_vault(),
            final_recipe;
            binding=binding,
            title="A report",
            out=out,
            status=:final,
            source_repo=root,
            remote=:local,
        )
        # the shape a study reads: what landed, how much was read, and where it went
        for k in (:record, :rev, :dir, :n, :reads, :pushed, :branch, :pr)
            @test haskey(res, k)
        end
        @test res.n == 1 && !res.pushed && res.pr === nothing
        @test isdir(res.dir) && isdir(joinpath(res.dir, "gallery"))

        # the entry says what the document said, and what this call vouched for
        e = TOML.parsefile(joinpath(res.dir, "entry.toml"))
        @test e["doc"]["title"] == "A report" && e["doc"]["status"] == "final"
        # and the points table is there, naming the observation the vault recorded
        @test isfile(joinpath(res.dir, "provenance", "points.tsv"))
        @test Archeion.validate(root).errors == String[]
    end
end

@testset "publish: what the pages say and what the call vouches for are not the same thing" begin
    with_git_fixture() do root, binding, src
        out = joinpath(mktempdir(), "rep")
        # the document's pages say `trial`; this deposit says `final`. The revision records what
        # was passed here (SPEC §5.4), and the disagreement is said out loud rather than resolved.
        res = @test_logs (:warn, r"pages say `trial`") match_mode = :any Archeion.publish(
            one_point_vault(),
            trial_recipe;
            binding=binding,
            title="A report",
            out=out,
            status=:final,
            source_repo=root,
            remote=:local,
        )
        @test TOML.parsefile(joinpath(res.dir, "entry.toml"))["doc"]["status"] == "final"
    end
end

@testset "publish: a status is stated, never inherited" begin
    with_git_fixture() do root, binding, src
        e = attempt(
            () -> Archeion.publish(
                one_point_vault(),
                final_recipe;
                binding=binding,
                title="A report",
                out=joinpath(mktempdir(), "rep"),
                status=:maybe,
                source_repo=root,
                remote=:local,
            ),
        )
        @test e isa ErrorException && occursin("status must be", e.msg)
    end
    # and a binding that is not there is said before anything is rendered
    e = attempt(
        () -> Archeion.publish(
            one_point_vault(),
            final_recipe;
            binding=joinpath(mktempdir(), "nope.toml"),
            title="A report",
            out=joinpath(mktempdir(), "rep"),
            status=:final,
            source_repo=pwd(),
            remote=:local,
        ),
    )
    @test e isa ErrorException && occursin("no binding at", e.msg)
end

@testset "doc_fields: what the document said, not what its output looks like" begin
    # status is derived: a document is `final` only when every page is.
    Pinax.reset!(; title="Two pages")
    @page :a "A" status = :final begin
        @desc md"""a"""
    end
    @page :b "B" status = :trial begin
        @desc md"""b"""
    end
    d = Archeion.doc_fields(Pinax.current_document())
    @test d.title == "Two pages"
    @test d.status == "trial"                     # one page short of final is not final

    Pinax.reset!(; title="All final")
    @page :a "A" status = :final begin
        @desc md"""a"""
    end
    @test Archeion.doc_fields(Pinax.current_document()).status == "final"

    # and the optional fields are carried through only when given
    d = Archeion.doc_fields(Pinax.current_document(); tags=["x", "y"])
    @test d.tags == ["x", "y"]
    @test !haskey(d, :question) && !haskey(d, :claim)
    d = Archeion.doc_fields(Pinax.current_document(); question="q?", claim="c.")
    @test d.question == "q?" && d.claim == "c."
end

@testset "anchors: which ids keep their meaning, and which are a position" begin
    # An id a person chose is stable; one a renderer numbered is not, because the number moves
    # when a figure is added above it — and a comment on a stable anchor must not follow it.
    a = Archeion.anchors(["logistic", "orbits", "orbits_fig1", "totals_tbl2"])
    @test a.stable == ["logistic", "orbits"]
    @test a.positional == ["orbits_fig1", "totals_tbl2"]

    # ids are strings however they arrive, and each is named once
    b = Archeion.anchors([:a, :a, "b", :c_fig1])
    @test b.stable == ["a", "b"] && b.positional == ["c_fig1"]

    # the convention is the caller's to state: another renderer numbers differently
    c = Archeion.anchors(["x1", "plot-2"]; auto=r"-\d+$")
    @test c.stable == ["x1"] && c.positional == ["plot-2"]

    d = Archeion.anchors(String[])
    @test isempty(d.stable) && isempty(d.positional)
end
