# build: the site is made from a valid registry only, with every link resolving.

# Build a copy after `mutate!`; the site directory and the result (or the error).
function built(mutate!)
    with_fixture() do root, rec, rev
        mutate!(root, rec, rev)
        res = attempt(() -> Archeion.build(root))
        site = joinpath(root, "_site")
        page = if isfile(joinpath(site, REC_REL, "index.html"))
            read(joinpath(site, REC_REL, "index.html"), String)
        else
            ""
        end
        index = if isfile(joinpath(site, "index.html"))
            read(joinpath(site, "index.html"), String)
        else
            ""
        end
        return (;
            res,
            page,
            index,
            report=isfile(joinpath(site, REV_REL, "gallery", "index.html")),
            kept=isfile(joinpath(site, "mine.txt")),
        )
    end
end

@testset "build" begin
    b = built((root, rec, rev) -> nothing)
    @test b.res isa NamedTuple && b.res.records == 1
    @test b.report

    b = built() do root, rec, rev
        second_revision!(rec, rev; parent=true)
        event!(rec, "comment", REV_NAME; extra="text = \"<script>alert(1)</script>\"\n")
    end
    @test occursin("current revision 20260916T000000Z-2222", b.page)
    @test occursin("&lt;script&gt;alert(1)&lt;/script&gt;", b.page)
    @test !occursin("<script>alert", b.page)

    b = built((root, rec, rev) -> event!(rec, "yank", REV_NAME))
    @test occursin("withdrawn", b.page) && occursin("<b>1</b> withdrawn", b.index)

    b = built((root, rec, rev) -> rm(joinpath(rev, "SHA256SUMS")))
    @test b.res isa ErrorException && occursin("does not validate", b.res.msg)

    b = built() do root, rec, rev
        mkpath(joinpath(root, "_site"))
        write(joinpath(root, "_site", "mine.txt"), "keep")
    end
    @test b.res isa ErrorException && occursin("refusing to replace", b.res.msg) && b.kept

    site = mktempdir()
    write(
        joinpath(site, "index.html"), """<a href="missing.html">x</a><img src="/abs.png">"""
    )
    bad = Archeion.broken_links(site)
    @test length(bad) == 2
    @test mentions(bad, "does not exist") && mentions(bad, "sub-path")
    rm(site; recursive=true)
end
