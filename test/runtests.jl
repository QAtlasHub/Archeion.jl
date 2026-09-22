using Archeion
using Test
using TestShards, Aqua

# Shared fixtures go ABOVE the shard block: a helper included inside would become a unit of its
# own, land on one shard, and fail every test file on the others.
include("helpers.jl")

# Every `test_*.jl` under `test/`, in a deterministic order, each one its own shardable unit.
# Anything that is not a `test_*.jl` file must be named: the glob silently skips it.
TestShards.@shard begin
    for f in sort(readdir(@__DIR__))
        startswith(f, "test_") && endswith(f, ".jl") || continue
        include(joinpath(@__DIR__, f))
    end
    TestShards.@unit "aqua" begin
        Aqua.test_all(Archeion)
    end
end
