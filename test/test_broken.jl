# A tree that is not a registry is still handed to `validate`. SPEC's first page says a registry is
# valid when it satisfies the document "however written", which makes this the trust boundary: the
# only two answers it may give are "valid" and "these errors". A stack trace is neither, and in CI
# it replaces the name of the offending file with a backtrace through Archeion's internals.
#
# Written as a sweep rather than as cases, because the three bugs it first caught were in three
# different functions and none of them were found by reading.

const WAYS_TO_BREAK = [
    ("truncated to nothing", p -> write(p, "")),
    ("cut in half", p -> (b=read(p); write(p, b[1:max(1, end ÷ 2)]))),
    (
        "a NUL in the middle",
        p -> (b=read(p); write(p, vcat(b[1:(end ÷ 2)], UInt8(0), b[(end ÷ 2 + 1):end]))),
    ),
    ("invalid UTF-8", p -> (b=read(p); write(p, vcat(b, UInt8[0xff, 0xfe])))),
    ("not TOML at all", p -> write(p, "]]] this is not a document [[[\n")),
    # 100 000 characters in one value: `zone_less_times` strips quoted strings before looking for
    # a time, and the pattern that did it backtracked until PCRE's JIT stack gave out.
    (
        "a very long value",
        p -> write(p, read(p, String) * "x = \"" * repeat("a", 100_000) * "\"\n"),
    ),
    ("deleted", p -> rm(p)),
]

function fixture_files()
    return [relpath(joinpath(d, f), FIXTURE) for (d, _, fs) in walkdir(FIXTURE) for f in fs]
end

@testset "validate: a broken tree is reported, never thrown at the reader" begin
    threw = String[]
    for (what, break!) in WAYS_TO_BREAK, rel in fixture_files()
        root, _, _ = fixture_copy()
        try
            break!(joinpath(root, rel))
            try
                r = Archeion.validate(root)
                # and the answer is still the shape callers destructure
                @test r isa NamedTuple && hasproperty(r, :errors)
            catch e
                push!(threw, "$what -> $rel: $(first(split(sprint(showerror, e), '\n')))")
            end
        finally
            rm(root; recursive=true, force=true)
        end
    end
    isempty(threw) || @info "validate threw" cases = threw
    @test isempty(threw)
end

@testset "validate: a registry.toml that is not TOML names itself" begin
    # The particular one that mattered: `spec_of` parsed it straight through, so the first thing
    # `validate` did with an unreadable registry was throw out of its own first line.
    r = validated((root, rec, rev) -> write(joinpath(root, "registry.toml"), "]]] [[[\n"))
    @test any(e -> occursin("registry.toml", e), r.errors)
end
