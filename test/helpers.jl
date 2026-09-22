# Shared by every test file. Included above the shard block in runtests.jl, so each shard has it.
#
# The fixture is a registry with one project and one record holding one revision: the
# hand-converted first revision of the archeion-demo record, with its payload cut down to a page
# and a figure. Tests copy it, break it one way at a time, and require the break to be named.

using Archeion, Test, TOML, SHA, Dates

const FIXTURE = joinpath(@__DIR__, "fixture")
const REC_REL = joinpath("records", "2026", "2026-09-15-logistic-map-r_4aehb2y5")
const REV_NAME = "20260915T071940Z-3ve4"
const REV_REL = joinpath(REC_REL, "revisions", REV_NAME)

# A fresh copy of the fixture; returns (root, record dir, revision dir).
function fixture_copy()
    root = mktempdir()
    for d in ("projects", "records")
        cp(joinpath(FIXTURE, d), joinpath(root, d))
    end
    return root, joinpath(root, REC_REL), joinpath(root, REV_REL)
end

function with_fixture(f)
    root, rec, rev = fixture_copy()
    try
        f(root, rec, rev)
    finally
        rm(root; recursive=true)
    end
end

# Validate a copy after `mutate!`; the errors, warnings and summary lines.
function validated(mutate!)
    with_fixture() do root, rec, rev
        mutate!(root, rec, rev)
        r, summary = Archeion.validate(root)
        return (; errors=r.errors, warnings=r.warnings, summary)
    end
end
mentions(lines, s) = any(l -> occursin(s, l), lines)

edit!(path, from, to) = write(path, replace(read(path, String), from => to; count=1))
entry(rev) = joinpath(rev, "entry.toml")

# A second revision next to the first, optionally naming it as parent; SHA256SUMS kept true.
function second_revision!(rec, rev; parent)
    new = joinpath(dirname(rev), "20260916T000000Z-2222")
    cp(rev, new)
    edit!(entry(new), "rev = \"$REV_NAME\"", "rev = \"20260916T000000Z-2222\"")
    edit!(entry(new), "frozen = 2026-09-15T07:19:40Z", "frozen = 2026-09-16T00:00:00Z")
    parent && edit!(entry(new), "parents = []", "parents = [\"$REV_NAME\"]")
    sums = joinpath(new, "SHA256SUMS")
    lines = [
        if endswith(l, "  entry.toml")
            bytes2hex(open(sha256, entry(new))) * "  entry.toml"
        else
            l
        end for l in eachline(sums)
    ]
    write(sums, join(lines, "\n") * "\n")
    return new
end

function event!(rec, kind, rev; anchor=nothing, extra="")
    mkpath(joinpath(rec, "events"))
    a = anchor === nothing ? "" : "anchor = \"$anchor\"\n"
    name = "20260917T000000Z-loc-$(String(rand('a':'h', 4))).toml"
    return write(
        joinpath(rec, "events", name),
        "spec = \"registry/1\"\nkind = \"$kind\"\nat = 2026-09-17T00:00:00Z\n$extra" *
        "[subject]\nrecord = \"r_4aehb2y5\"\nrev = \"$rev\"\n$a",
    )
end

# A copy of the fixture that is its own git repository (never pushed), with a binding to the
# fixture's record at .registry/bindings/logistic.toml.
function with_git_fixture(f)
    with_fixture() do root, rec, rev
        write(joinpath(root, ".gitignore"), "_incoming/\n_site/\n")
        for c in (
            `init -q`,
            `config user.name t`,
            `config user.email t@t`,
            `add -A`,
            `commit -qm base`,
        )
            run(`git -C $root $c`)
        end
        binding = joinpath(root, ".registry", "bindings", "logistic.toml")
        mkpath(dirname(binding))
        write(
            binding,
            "spec = \"registry/1\"\nregistry = \"../..\"\nproject = \"p_z7ne42dt\"\n" *
            "record = \"r_4aehb2y5\"\nslug = \"logistic-map\"\n",
        )
        return f(
            root,
            binding,
            (; gallery=joinpath(rev, "gallery"), agent=joinpath(rev, "agent")),
        )
    end
end
commits(root) = parse(Int, readchomp(`git -C $root rev-list --count HEAD`))
attempt(f) =
    try
        f()
    catch e
        e
    end

const DOC = (;
    title="The logistic map, as a model record",
    status="final",
    tags=["example"],
    Archeion.anchors(["logistic", "orbits", "orbits_fig1"])...,
)
