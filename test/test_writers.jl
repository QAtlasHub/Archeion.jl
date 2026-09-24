# A writer may refuse. What it may not do is leave the registry changed on its way out — the next
# deposit reads the tree to decide what it is adding to, so a half-written refusal is the state
# that gets built on. The property is not "does not throw" but "after a refusal, byte for byte what
# it was handed".
#
# A sweep rather than cases, for the same reason as `test_broken.jl`: what this first caught was in
# three functions, and the next one will not be in those.

using SHA

# What the registry holds, by content, ignoring what is derived and git's own bookkeeping.
function fingerprint(root)
    out = Dict{String,String}()
    for (d, _, fs) in walkdir(root), f in fs
        rel = relpath(joinpath(d, f), root)
        (startswith(rel, "_site") || startswith(rel, ".git/")) && continue
        out[rel] = bytes2hex(open(sha256, joinpath(d, f)))
    end
    return out
end

const BREAKAGES = [
    ("truncated", p -> write(p, "")),
    ("not TOML", p -> write(p, "]]] [[[\n")),
    ("invalid UTF-8", p -> (b=read(p); write(p, vcat(b, UInt8[0xff, 0xfe])))),
    ("deleted", p -> rm(p)),
]

under(root) = [relpath(joinpath(d, f), root) for (d, _, fs) in walkdir(root) for f in fs]

# A committed git repository around a copy of the registry/1 fixture, broken at `rel` first: the
# conversion demands a clean tree, and the undo it performs is git's.
function committed_v1(rel, break!)
    root = v1_copy()
    for c in (
        `init -q`,
        `config user.name t`,
        `config user.email t@t`,
        `add -A`,
        `commit -qm base`,
    )
        run(pipeline(`git -C $root $c`; stdout=devnull, stderr=devnull))
    end
    break!(joinpath(root, rel))
    run(pipeline(`git -C $root add -A`; stdout=devnull, stderr=devnull))
    run(
        pipeline(
            `git -C $root -c user.name=t -c user.email=t@t commit -qm broken`;
            stdout=devnull,
            stderr=devnull,
        ),
    )
    return root
end

@testset "build: reads a broken tree without writing to it, and fails by name" begin
    threw, wrote = String[], String[]
    for (what, break!) in BREAKAGES, rel in under(FIXTURE)
        root, _, _ = fixture_copy()
        try
            break!(joinpath(root, rel))
            before = fingerprint(root)
            try
                Archeion.build(root, joinpath(mktempdir(), "site"))
            catch e
                # an `ErrorException` names the file; a parser error names nothing
                e isa ErrorException || push!(threw, "$what/$rel: $(typeof(e))")
            end
            fingerprint(root) == before || push!(wrote, "$what/$rel")
        finally
            rm(root; recursive=true, force=true)
        end
    end
    isempty(threw) || @info "build threw something other than an error" threw
    isempty(wrote) || @info "build changed the registry it was reading" wrote
    @test isempty(threw)
    @test isempty(wrote)
end

@testset "migrate!: a conversion that fails is undone, not left half done" begin
    # The clean working tree a conversion demands is what makes this possible. Until the tree was
    # put back, the claim in its docstring was not true: the failure that can only be found by
    # validating the result comes *after* every rename.
    threw, moved = String[], String[]
    for (what, break!) in BREAKAGES, rel in under(FIXTURE_V1)
        root = committed_v1(rel, break!)
        try
            before = fingerprint(root)
            failed = false
            try
                Archeion.migrate!(root)
            catch e
                failed = true
                e isa ErrorException || push!(threw, "$what/$rel: $(typeof(e))")
            end
            failed && fingerprint(root) != before && push!(moved, "$what/$rel")
        finally
            rm(root; recursive=true, force=true)
        end
    end
    isempty(threw) || @info "migrate! threw something other than an error" threw
    isempty(moved) || @info "migrate! refused but the tree moved" moved
    @test isempty(threw)
    @test isempty(moved)
end

@testset "migrate!: the undo is real, and says so when there is none" begin
    # Spelled out, because the sweep above only says "nothing moved" and this is the sentence
    # somebody reads while wondering what state their registry is in.
    root = committed_v1(
        joinpath(
            "records", "2026", basename(old_dir_of(".")), "revisions", REV_NAME, "README.md"
        ),
        rm,
    )
    e = attempt(() -> Archeion.migrate!(root))
    @test e isa ErrorException && occursin("the conversion was undone", e.msg)
    @test Archeion.spec_of(root) == "registry/1"          # and it really is back
    @test isdir(old_dir_of(root))
    rm(root; recursive=true)

    # Without git there is no undo, and the message says which of the two happened.
    root = v1_copy()
    rm(joinpath(old_dir_of(root), "revisions", REV_NAME, "README.md"))
    e = attempt(() -> Archeion.migrate!(root))
    @test e isa ErrorException && occursin("not under git", e.msg)
    rm(root; recursive=true)
end
