# migrate: a registry/1 tree becomes a registry/2 one, and no frozen revision is touched doing it.

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
        Archeion.write_index!(root, reg["projects"], reg["records"])
        @test mentions(errors_of(root), "the index says")

        Archeion.reindex!(root)                              # settled by the tree, not by hand
        @test isempty(errors_of(root))
    end
end

@testset "migrate: the licence the conversion leaves runs out when the conversion does" begin
    root = v1_copy()
    Archeion.migrate!(root)
    recdir = joinpath(root, "records", "2026", "logistic-map")
    rec = TOML.parsefile(joinpath(recdir, "record.toml"))
    @test rec["migrated"]["at"] isa Dates.DateTime      # when the older values stopped being ok

    # A revision frozen after the conversion, saying what only a frozen one may say.
    rev = joinpath(recdir, "revisions", REV_NAME)
    for (name, tweak) in (
        "20270101T000000Z-1111" =>
            e -> edit!(e, "spec = \"registry/1\"", "spec = \"registry/2\""),
        "20270101T000000Z-2222" => e -> nothing,          # still says registry/1
    )
        new = joinpath(dirname(rev), name)
        cp(rev, new)
        edit!(entry(new), "rev = \"$REV_NAME\"", "rev = \"$name\"")
        edit!(entry(new), "frozen = 2026-09-15T07:19:40Z", "frozen = 2027-01-01T00:00:00Z")
        tweak(entry(new))
        sums = joinpath(new, "SHA256SUMS")
        write(
            sums,
            join(
                [
                    if endswith(l, "  entry.toml")
                        bytes2hex(open(sha256, entry(new))) * "  entry.toml"
                    else
                        l
                    end for l in eachline(sums)
                ],
                "\n",
            ) * "\n",
        )
    end
    errs = errors_of(root)
    @test mentions(errs, "20270101T000000Z-2222") && mentions(errs, "`spec` must be")
    @test mentions(errs, "`id.record` is r_4aehb2y5")   # the old name, in a new revision
    rm(root; recursive=true)
end

@testset "migrate: a conversion that cannot finish never starts" begin
    root = v1_copy()
    old = joinpath(root, "records", "2026", "2026-09-15-logistic-map-r_4aehb2y5")
    twin = joinpath(root, "records", "2026", "2026-09-16-logistic-map-r_4aehb2y6")
    cp(old, twin)                                       # same slug, a second identifier
    edit!(joinpath(twin, "record.toml"), "r_4aehb2y5", "r_4aehb2y6")
    before = sort(readdir(joinpath(root, "records", "2026")))

    e = attempt(() -> Archeion.migrate!(root))
    @test e isa ErrorException && occursin("would be called logistic-map", e.msg)
    # nothing was renamed, nothing was rewritten: the tree is still the one it was handed
    @test sort(readdir(joinpath(root, "records", "2026"))) == before
    @test TOML.parsefile(joinpath(old, "record.toml"))["id"] == "r_4aehb2y5"
    @test TOML.parsefile(joinpath(root, "projects", "p_z7ne42dt.toml"))["id"] ==
        "p_z7ne42dt"
    @test Archeion.spec_of(root) == "registry/1"
    rm(root; recursive=true)
end

@testset "migrate: a registry under git is converted from a clean tree only" begin
    root = v1_copy()
    for c in (
        `init -q`,
        `config user.name t`,
        `config user.email t@t`,
        `add -A`,
        `commit -qm base`,
    )
        run(`git -C $root $c`)
    end
    write(
        joinpath(root, "projects", "p_z7ne42dt.toml"),
        read(joinpath(root, "projects", "p_z7ne42dt.toml"), String) * "\n# mine\n",
    )
    e = attempt(() -> Archeion.migrate!(root))
    @test e isa ErrorException && occursin("uncommitted", e.msg)

    run(`git -C $root checkout -q .`)
    @test Archeion.migrate!(root).records == 1          # clean again, and it goes through
    rm(root; recursive=true)
end

@testset "the index is written beside a registry, not instead of one" begin
    root = mktempdir()
    Archeion.init(root; name="demo", title="Demo", tagline="a tagline", pages=false)
    before = read(joinpath(root, "registry.toml"), String)
    @test occursin("# [[site.links]]", before)            # the template init leaves to be filled in

    Archeion.reindex!(root)                               # what every deposit does
    after = read(joinpath(root, "registry.toml"), String)
    @test after == before                                 # nothing to index yet, nothing changed

    # and with something to index, everything above the index is still the file init wrote
    cp(joinpath(FIXTURE, "projects"), joinpath(root, "projects"); force=true)
    cp(joinpath(FIXTURE, "records"), joinpath(root, "records"); force=true)
    Archeion.reindex!(root)
    after = read(joinpath(root, "registry.toml"), String)
    @test startswith(after, rstrip(before) * "\n\n[projects]\n")
    @test occursin("# [[site.links]]", after) && occursin("tagline = \"a tagline\"", after)
    @test occursin(RECORD_UUID, after)

    rm(joinpath(root, "registry.toml"))
    e = attempt(() -> Archeion.reindex!(root))
    @test e isa ErrorException && occursin("no registry.toml", e.msg)
    @test !isfile(joinpath(root, "registry.toml"))        # and it did not invent one
    rm(root; recursive=true)
end

@testset "a registry without registry.toml is not a registry" begin
    with_fixture() do root, rec, rev
        rm(joinpath(root, "registry.toml"))
        @test mentions(errors_of(root), "no registry.toml")
    end
end

@testset "a record answers to its uuid, whatever its directory is called" begin
    with_git_fixture() do root, binding, src
        moved = joinpath(dirname(rstrip(joinpath(root, REC_REL), '/')), "renamed-by-hand")
        mv(joinpath(root, REC_REL), moved)                 # R6: a slug may be renamed freely
        @test Archeion.find_record(root, RECORD_UUID) == moved   # the index is stale; the tree is not
        @test mentions(errors_of(root), "the index says")
        Archeion.reindex!(root)
        @test isempty(errors_of(root))
        @test Archeion.find_record(root, RECORD_UUID) == moved
    end
end

@testset "slugify: what a directory may be called" begin
    @test Archeion.slugify("Open boundary") == "open-boundary"
    @test Archeion.slugify("already-a-slug") == "already-a-slug"
    @test Archeion.slugify("λ₁ across ρ (Lorenz)") == "across-lorenz"
    @test Archeion.slugify("  --Trailing--  ") == "trailing"
    @test attempt(() -> Archeion.slugify("λ₁")) isa ErrorException   # nothing to name it with
end

@testset "migrate: an event written before the conversion still names what it named" begin
    root = v1_copy()
    old = joinpath(root, "records", "2026", "2026-09-15-logistic-map-r_4aehb2y5")
    mkpath(joinpath(old, "events"))
    event(dir, at, id) = write(
        joinpath(dir, "events", "$(at)-loc-note.toml"),
        """
        spec = "registry/1"
        kind = "comment"
        at = $(at[1:4])-$(at[5:6])-$(at[7:8])T$(at[10:11]):$(at[12:13]):$(at[14:15])Z
        [subject]
        record = "$id"
        rev = "$REV_NAME"
        """,
    )
    event(old, "20260916T000000Z", "r_4aehb2y5")          # written while registry/1 was the format
    Archeion.migrate!(root)

    recdir = joinpath(root, "records", "2026", "logistic-map")
    @test isempty(errors_of(root))                        # the old name still reads, through migrated
    @test occursin(
        "r_4aehb2y5",
        read(joinpath(recdir, "events", "20260916T000000Z-loc-note.toml"), String),
    )

    event(recdir, "20270101T000000Z", "r_4aehb2y5")       # and the same thing, dated after
    errs = errors_of(root)
    @test mentions(errs, "20270101T000000Z") && mentions(errs, "is not this record")
    rm(root; recursive=true)
end

@testset "migrate: what each identifier became is what a binding needs" begin
    root = v1_copy()
    res = Archeion.migrate!(root)
    rec = TOML.parsefile(joinpath(root, "records", "2026", "logistic-map", "record.toml"))
    # the map is the conversion's one output nothing else can reconstruct without walking the tree
    @test res.ids["r_4aehb2y5"] == rec["uuid"]
    @test res.ids["p_z7ne42dt"] == rec["project"]
    @test all(Archeion.is_uuid, values(res.ids))
    rm(root; recursive=true)

    root = v1_copy()                                     # and the command says so
    log = tempname()
    open(log, "w") do io
        @test redirect_stdout(() -> Archeion.main(["migrate", root]), io) == 0
    end
    said = read(log, String)
    @test occursin("update every binding", said)
    @test occursin(
        "r_4aehb2y5 -> " *
        TOML.parsefile(joinpath(root, "records", "2026", "logistic-map", "record.toml"))["uuid"],
        said,
    )
    rm(root; recursive=true)
end
