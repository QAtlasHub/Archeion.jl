# migrate: a registry/1 tree becomes a registry/2 one, and no frozen revision is touched doing it.

# The v1 fixture, copied somewhere it may be converted.
function v1_copy()
    root = mktempdir()
    for e in readdir(FIXTURE_V1)
        cp(joinpath(FIXTURE_V1, e), joinpath(root, e))
    end
    return root
end

errors_of(root) = first(Archeion.validate(root)).errors
function sums_verify(dir)
    return success(
        pipeline(setenv(`sha256sum -c SHA256SUMS`; dir=dir); stdout=devnull, stderr=devnull)
    )
end

@testset "migrate: identity moves into the files, the paths become names" begin
    root = v1_copy()
    before = joinpath(root, "records", "2026", "2026-09-15-logistic-map-r_4aehb2y5")
    res = Archeion.migrate!(root)
    @test res.projects == 1 && res.records == 1

    @test !ispath(before)                                    # the old path is gone
    recdir = joinpath(root, "records", "2026", "logistic-map")
    @test isdir(recdir) && readdir(joinpath(root, "projects")) == ["demo.toml"]

    rec = TOML.parsefile(joinpath(recdir, "record.toml"))
    @test Archeion.is_uuid(rec["uuid"]) && Archeion.is_uuid(rec["project"])
    @test rec["spec"] == "registry/2"
    @test rec["title"] == "The logistic map, as a model record"   # from the revision shown
    # what it was called before, because its revisions still say so and may not be rewritten
    @test rec["migrated"]["id"] == "r_4aehb2y5"
    @test rec["migrated"]["project"] == "p_z7ne42dt"
    @test rec["migrated"]["spec"] == "registry/1"

    reg = TOML.parsefile(joinpath(root, "registry.toml"))
    @test reg["spec"] == "registry/2" && Archeion.is_uuid(reg["uuid"])
    @test collect(keys(reg["records"])) == [rec["uuid"]]
    @test reg["records"][rec["uuid"]]["path"] == "records/2026/logistic-map"
    @test reg["projects"][rec["project"]]["name"] == "demo"
    rm(root; recursive=true)
end

@testset "migrate: a frozen revision comes through byte for byte" begin
    root = v1_copy()
    before = joinpath(root, "records", "2026", "2026-09-15-logistic-map-r_4aehb2y5")
    digests = Dict(
        f => open(sha256, joinpath(before, "revisions", REV_NAME, f)) for
        f in ("entry.toml", "SHA256SUMS", "README.md")
    )
    Archeion.migrate!(root)
    revdir = joinpath(root, "records", "2026", "logistic-map", "revisions", REV_NAME)
    for (f, d) in digests
        @test open(sha256, joinpath(revdir, f)) == d
    end
    @test sums_verify(revdir)                                # and it still checks out
    # the entry still names the identifiers of its day, and the registry validates anyway
    @test occursin("r_4aehb2y5", read(joinpath(revdir, "entry.toml"), String))
    @test isempty(errors_of(root))
    rm(root; recursive=true)
end

@testset "migrate: runs once, and says so the second time" begin
    root = v1_copy()
    Archeion.migrate!(root)
    e = attempt(() -> Archeion.migrate!(root))
    @test e isa ErrorException && occursin("registry/2", e.msg)
    rm(root; recursive=true)
end

@testset "validate: a registry/1 tree is refused, with the way out" begin
    root = v1_copy()
    @test mentions(errors_of(root), "convert it with `Archeion.migrate!`")
    rm(root; recursive=true)
end

@testset "reindex: the index follows the tree, and a validator says when it does not" begin
    with_fixture() do root, rec, rev
        @test isempty(errors_of(root))
        reg = TOML.parsefile(joinpath(root, "registry.toml"))
        reg["records"][RECORD_UUID]["name"] = "something else"
        Archeion.write_registry_toml(root, reg)
        @test mentions(errors_of(root), "the index says")

        Archeion.reindex!(root)                              # settled by the tree, not by hand
        @test isempty(errors_of(root))
    end
end
