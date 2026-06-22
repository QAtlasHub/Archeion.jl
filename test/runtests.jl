ENV["GKSwstype"] = "100"

using Archeion
using Test, Aqua
const dirs = ["."]

const FIG_BASE = joinpath(pkgdir(Archeion), "docs", "src", "assets")
const PATHS = Dict()
mkpath.(values(PATHS))

@testset "tests" begin
    # ----- Test the module itself. -----
    @testset "Aqua tests" begin
        # ParamIO is declared in [deps] only to carry its git-url source (a transitive dep
        # of DataVault, not used directly here) until it lands in the General registry.
        Aqua.test_all(Archeion; stale_deps=(ignore=[:ParamIO],))
    end
    # ----- Test files in the "test" directory. -----
    test_args = copy(ARGS)
    println("Passed arguments ARGS = $(test_args) to tests.")
    @time for dir in dirs
        dirpath = joinpath(@__DIR__, dir)
        println("\nTest $(dirpath)")
        files = sort(
            filter(f -> startswith(f, "test_") && endswith(f, ".jl"), readdir(dirpath))
        )
        if isempty(files)
            println("  No test files found in $(dirpath).")
            @test false
        else
            for f in files
                @testset "$f" begin
                    filepath = joinpath(dirpath, f)
                    @time begin
                        println("  Including $(filepath)")
                        include(filepath)
                    end
                end
            end
        end
    end
end
