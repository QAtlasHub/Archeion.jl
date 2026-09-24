# Shared by every test file. Included above the shard block in runtests.jl, so each shard has it.
#
# The fixture is a registry with one project and one record holding one revision: the
# hand-converted first revision of the archeion-demo record, with its payload cut down to a page
# and a figure. Tests copy it, break it one way at a time, and require the break to be named.

using Archeion, Test, TOML, SHA, Dates

const FIXTURE = joinpath(@__DIR__, "fixture")
const FIXTURE_V1 = joinpath(@__DIR__, "fixture-v1")      # what `migrate!` is given
const REC_REL = joinpath("records", "2026", "logistic-map")
const REV_NAME = "20260915T071940Z-3ve4"
const REV_REL = joinpath(REC_REL, "revisions", REV_NAME)

# Identity lives in the files now (R5), so the tests read it from there rather than knowing it.
const RECORD_UUID = TOML.parsefile(joinpath(FIXTURE, REC_REL, "record.toml"))["uuid"]
const PROJECT_UUID = TOML.parsefile(joinpath(FIXTURE, REC_REL, "record.toml"))["project"]

# A fresh copy of the fixture; returns (root, record dir, revision dir).
function fixture_copy()
    root = mktempdir()
    for d in ("projects", "records")
        cp(joinpath(FIXTURE, d), joinpath(root, d))
    end
    cp(joinpath(FIXTURE, "registry.toml"), joinpath(root, "registry.toml"))
    return root, joinpath(root, REC_REL), joinpath(root, REV_REL)
end

# The registry/1 fixture, copied somewhere it may be converted.
function v1_copy()
    root = mktempdir()
    for e in readdir(FIXTURE_V1)
        cp(joinpath(FIXTURE_V1, e), joinpath(root, e))
    end
    return root
end

# The registry/1 fixture's one record directory, by its registry/1 name.
old_dir_of(root) = joinpath(root, "records", "2026", "2026-09-15-logistic-map-r_4aehb2y5")

# Removing a temp tree can lose a race with git. A repository does background housekeeping in
# `.git/objects` and deletes its own scratch files, so a recursive walk can see one and find it
# gone before it unlinks it. Measured on CI 2026-09-24:
#
#     IOError: unlink("/tmp/jl_9Tw1ZW/.git/objects/bitmap-ref-tips_UxqjeQ"): ENOENT
#
# reported as a failure of `test_publish.jl`, whose assertions had all passed. Failing a green test
# because a directory under /tmp outlived the run is reporting the wrong thing — so this retries
# once the race has had a moment to settle, and then lets the directory go. The OS reaps /tmp, and
# a leaked temp directory is not a defect in the thing under test.
function rm_tree(path; tries=3)
    for i in 1:tries
        try
            rm(path; recursive=true, force=true)
            return true
        catch e
            e isa Base.IOError || rethrow()
            i == tries && return false
            sleep(0.1i)
        end
    end
    return false
end

function with_fixture(f)
    root, rec, rev = fixture_copy()
    try
        f(root, rec, rev)
    finally
        rm_tree(root)
    end
end

# Validate a copy after `mutate!`; the errors, warnings and summary lines.
function validated(mutate!)
    with_fixture() do root, rec, rev
        mutate!(root, rec, rev)
        return Archeion.validate(root)
    end
end
# Does the revision in `dir` still check out against the SHA256SUMS beside it?
function sums_verify(dir)
    return success(
        pipeline(setenv(`sha256sum -c SHA256SUMS`; dir=dir); stdout=devnull, stderr=devnull)
    )
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
        "spec = \"registry/2\"\nkind = \"$kind\"\nat = 2026-09-17T00:00:00Z\n$extra" *
        "[subject]\nrecord = \"$RECORD_UUID\"\nrev = \"$rev\"\n$a",
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
            "spec = \"registry/2\"\nregistry = \"../..\"\nproject = \"$PROJECT_UUID\"\n" *
            "record = \"$RECORD_UUID\"\nslug = \"logistic-map\"\n",
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

# ── a report's stylesheet ──────────────────────────────────────────────────────────────────────
#
# Shared rather than kept in `test_dark.jl`: the shards run the files apart, so a fixture two of
# them need has to be here (runtests.jl).

const LIGHT_SHEET = """
body{background:#fafafa;color:#24292f}
a{color:#0366d6}
section.section{background:#fff;border:1px solid #e2e5e9}
figcaption{color:#444}
.pinax-verdict-fail{background:#ffebe9;border:1px solid #cf222e;color:#a40e26}
figure iframe.pinax-pdf{background:#fff}
"""

# Add a stylesheet to a copied fixture's revision and keep SHA256SUMS true, so the registry it
# lands in is one `validate` accepts.
function with_stylesheet!(rev, css=LIGHT_SHEET)
    rel = joinpath("gallery", "style.css")
    write(joinpath(rev, rel), css)
    # …and the page links it. A report is a page and its stylesheet, and the control reaches the
    # second through the first: a sheet nothing links is a sheet nothing can switch.
    page = joinpath(rev, "gallery", "index.html")
    if isfile(page)
        html = read(page, String)
        occursin("style.css", html) || write(
            page,
            replace(
                html, "</head>" => """<link rel="stylesheet" href="style.css"></head>"""
            ),
        )
    end
    Archeion.write_sums(rev)
    return joinpath(rev, rel)
end
