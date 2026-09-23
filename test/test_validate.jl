# validate: the fixture passes, and each way of breaking it is named.

@testset "validate" begin
    @test isempty(validated((root, rec, rev) -> nothing).errors)

    # (description, expected fragment of an error, how to break the copy)
    breaks = [
        (
            "a changed payload byte",
            "does not match its sha256",
            (root, rec, rev) ->
                edit!(joinpath(rev, "gallery", "index.html"), "<html", "<HTML"),
        ),
        (
            "a file added to a frozen revision",
            "not listed in SHA256SUMS",
            (root, rec, rev) -> write(joinpath(rev, "gallery", "extra.txt"), "late"),
        ),
        (
            "a revision without SHA256SUMS",
            "the revision is incomplete",
            (root, rec, rev) -> rm(joinpath(rev, "SHA256SUMS")),
        ),
        (
            "names equal once lower-cased",
            "only in case",
            (root, rec, rev) -> write(joinpath(rev, "gallery", "Index.html"), ""),
        ),
        (
            "a colon in a file name",
            "`:` in a path",
            (root, rec, rev) -> write(joinpath(rev, "gallery", "a:b.txt"), ""),
        ),
        (
            "a non-ASCII file name",
            "outside ASCII",
            (root, rec, rev) -> write(joinpath(rev, "gallery", "é.txt"), ""),
        ),
        (
            "entry.toml naming another record",
            "`id.record`",
            (root, rec, rev) ->
                edit!(entry(rev), "record = \"r_4aehb2y5\"", "record = \"r_00000000\""),
        ),
        (
            "a completion state in a revision",
            "not what is computed",
            (root, rec, rev) ->
                open(io -> print(io, "\n[extra]\ncompleted = 70\n"), entry(rev), "a"),
        ),
        (
            "a short commit",
            "40 hexadecimal",
            (root, rec, rev) ->
                edit!(entry(rev), "340c965b8c3a8fab38857671a410ecfe13107c31", "340c965"),
        ),
        (
            "time.frozen disagreeing with the directory",
            "does not match the directory's time",
            (root, rec, rev) -> edit!(entry(rev), "07:19:40Z", "07:19:41Z"),
        ),
        (
            "a time without Z",
            "has no `Z`",
            (root, rec, rev) -> edit!(entry(rev), "07:19:40Z", "07:19:40"),
        ),
        (
            "a time with an offset",
            "offset other than Z",
            (root, rec, rev) ->
                edit!(entry(rev), "2026-09-15T07:19:40Z", "2026-09-15T16:19:40+09:00"),
        ),
        (
            "a parent that is not a revision of this record",
            "is not another revision",
            (root, rec, rev) ->
                edit!(entry(rev), "parents = []", "parents = [\"20260101T000000Z-0000\"]"),
        ),
        (
            "a preservation level claimed rather than earned",
            "earned by events",
            (root, rec, rev) -> edit!(entry(rev), "level = \"read\"", "level = \"render\""),
        ),
        (
            "one record id in two directories",
            "is also used by",
            (root, rec, rev) -> cp(
                rec,
                joinpath(dirname(rec), replace(basename(rec), "logistic-map" => "copy")),
            ),
        ),
        (
            "a record whose project does not exist",
            "is not in projects/",
            (root, rec, rev) -> rm(joinpath(root, "projects", "p_z7ne42dt.toml")),
        ),
    ]
    for (name, expect, mutate!) in breaks
        @testset "$name" begin
            @test mentions(validated(mutate!).errors, expect)
        end
    end

    @testset "a kind registry/1 does not know is kept, with a warning" begin
        v = validated() do root, rec, rev
            edit!(joinpath(rec, "record.toml"), "kind = \"report\"", "kind = \"diary\"")
            edit!(entry(rev), "kind = \"report\"", "kind = \"diary\"")
            Archeion.write_sums(rev)
        end
        @test isempty(v.errors) && mentions(v.warnings, "record kind `diary`")
        @test length(v.summary) == 1                   # the record is still there
    end

    @testset "which revision is current (§7.1)" begin
        @test mentions(
            validated((root, rec, rev) -> second_revision!(rec, rev; parent=true)).summary,
            "current 20260916T000000Z-2222",
        )
        @test mentions(
            validated((root, rec, rev) -> second_revision!(rec, rev; parent=false)).summary,
            "in conflict",
        )
        @test mentions(
            validated((root, rec, rev) -> event!(rec, "yank", REV_NAME)).summary,
            "withdrawn",
        )
    end

    @testset "events that point nowhere are kept and reported" begin
        @test mentions(
            validated(
                (root, rec, rev) -> event!(rec, "comment", REV_NAME; anchor="orbits_fig1")
            ).warnings,
            "local to its revision",
        )
        @test mentions(
            validated((root, rec, rev) -> event!(rec, "comment", "20991231T000000Z-zzzz")).warnings,
            "dangling",
        )
    end
end
