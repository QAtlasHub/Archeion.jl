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
    with_fixture() do root, rec, rev
        reg = TOML.parsefile(joinpath(root, "registry.toml"))
        delete!(reg["records"], RECORD_UUID)                  # an index that lost a record
        Archeion.write_index!(root, reg["projects"], reg["records"])
        @test quiet(() -> Archeion.main(["validate", root])) == 1
        @test quiet(() -> Archeion.main(["reindex", root])) == 0
        @test quiet(() -> Archeion.main(["validate", root])) == 0
    end
    let root = v1_copy()
        @test quiet(() -> Archeion.main(["migrate", root])) == 0
        @test TOML.parsefile(joinpath(root, "registry.toml"))["spec"] == "registry/2"
        @test quiet(() -> Archeion.main(["validate", root])) == 0
        rm(root; recursive=true)
    end
end
