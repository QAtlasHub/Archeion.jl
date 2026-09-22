# The command line returns what a CI job can act on.

@testset "main" begin
    quiet(f) = redirect_stdout(f, devnull)
    @test quiet(() -> Archeion.main(["validate", FIXTURE])) == 0
    with_fixture() do root, rec, rev
        rm(joinpath(rev, "SHA256SUMS"))
        @test quiet(() -> Archeion.main(["validate", root])) == 1
    end
    @test redirect_stderr(() -> Archeion.main(String[]), devnull) == 2
    with_fixture() do root, rec, rev
        @test quiet(() -> Archeion.main(["build", root])) == 0
        @test isfile(joinpath(root, "_site", "index.html"))
    end
end
