# additions: a deposit only adds to a registry, and anything else it does is named. This is what a
# pull request is merged on without a person, so each way of touching what is already there has to
# be caught by name.

_ad_git(root, args...) = run(`git -C $root -c user.name=t -c user.email=t@t $args`)
_ad_head(root) = readchomp(`git -C $root rev-parse HEAD`)
_ad_commit(root, msg) = (_ad_git(root, "add", "-A"); _ad_git(root, "commit", "-qm", msg))

# The fixture as a git repository, with one deposit on top of `base`.
function with_deposit(f)
    with_git_fixture() do root, binding, src
        base = _ad_head(root)
        deposit(binding; src..., doc=DOC, source_repo=root, push=false)
        return f(root, base)
    end
end

@testset "additions: a deposit only adds, and says what" begin
    with_deposit() do root, base
        a = Archeion.additions(root; base)
        @test a.ok && isempty(a.violations)
        @test any(p -> occursin("/revisions/", p) && endswith(p, "entry.toml"), a.added)
        @test Archeion.additions(root; base=_ad_head(root)).ok == false  # nothing added: not ok
    end
end

@testset "additions: touching what is already there is named" begin
    # (what it does to the tree after the deposit, what the violation must say)
    cases = [
        (
            root -> write(
                joinpath(root, REV_REL, "entry.toml"),
                read(joinpath(root, REV_REL, "entry.toml"), String) * "\n# edited\n",
            ),
            "entry.toml: modified",
        ),
        (root -> rm(joinpath(root, REV_REL, "README.md")), "README.md: deleted"),
        (
            root -> (
                mkpath(joinpath(root, ".github", "workflows"));
                write(joinpath(root, ".github", "workflows", "x.yml"), "on: push\n")
            ),
            ".github/workflows/x.yml: added outside",
        ),
        (
            root -> write(
                joinpath(root, "registry.toml"),
                replace(
                    read(joinpath(root, "registry.toml"), String),
                    r"^name = .*$"m => "name = \"renamed\"",
                ),
            ),
            "registry.toml: changed outside its index tables",
        ),
    ]
    for (mutate!, says) in cases
        with_deposit() do root, base
            mutate!(root)
            _ad_commit(root, "and something else")
            a = Archeion.additions(root; base)
            @test !a.ok
            @test any(v -> occursin(says, v), a.violations)
        end
    end
end

@testset "additions: the command line answers by its exit code" begin
    cli(args) = redirect_stdout(() -> Archeion.main(args), devnull)
    with_deposit() do root, base
        @test cli(["additions", root, "--base=$base"]) == 0
        @test cli(["additions", root]) == 2                     # usage: a base is needed
        rm(joinpath(root, REV_REL, "README.md"))
        _ad_commit(root, "delete")
        @test cli(["additions", root, "--base=$base"]) == 1
    end
end

@testset "setup_pages: the deposit workflow merges only what was checked" begin
    root = mktempdir()
    try
        w = Archeion.setup_pages(root; branch="main", automerge=true)
        @test ".github/workflows/deposit.yml" in w.written
        yml = read(joinpath(root, ".github", "workflows", "deposit.yml"), String)
        @test occursin("startsWith(github.head_ref, 'deposit/')", yml)
        @test occursin(
            "github.event.pull_request.head.repo.full_name == github.repository", yml
        )
        @test occursin("-m Archeion validate .", yml)
        @test occursin("-m Archeion additions . --base=origin/", yml)
        @test occursin("--match-head-commit", yml) && occursin("--merge", yml)
        # The checks are the default branch's (pull_request_target), the branch is only read,
        # and Archeion's environment is made where the branch cannot have put one.
        @test occursin("pull_request_target:", yml) && !occursin("\n  pull_request:", yml)
        @test occursin("persist-credentials: false", yml)
        @test occursin("--project=\${{ runner.temp }}/archeion-env", yml)
        @test !occursin("--project=archeion-env", yml)
        @test occursin("if: failure()", yml) && occursin("gh pr comment", yml)
        @test occursin("gh workflow run pages.yml --ref main", yml)
        @test occursin("rev=\"v$(pkgversion(Archeion))\"", yml)
        # A private registry's site is site.yml, and that is what gets rebuilt.
        Archeion.setup_pages(root; branch="main", automerge=true, site="/srv/registry")
        yml = read(joinpath(root, ".github", "workflows", "deposit.yml"), String)
        @test occursin("gh workflow run site.yml --ref main", yml)
        # Off unless asked for.
        root2 = mktempdir()
        @test !any(p -> endswith(p, "deposit.yml"), Archeion.setup_pages(root2).written)
        rm(root2; recursive=true)
    finally
        rm(root; recursive=true)
    end
end

@testset "additions: what a deposit may add — a new record, a project, an event alone" begin
    with_git_fixture() do root, binding, src
        # The bindings belong to whoever renders, not to a deposit: in the base, not the diff.
        b2 = joinpath(root, ".registry", "bindings", "another.toml")
        new_binding(b2; root, project=PROJECT_UUID, slug="another-record")
        _ad_commit(root, "the bindings")
        # A first deposit to a record that did not exist: its record.toml and its revision.
        base = _ad_head(root)
        deposit(b2; src..., doc=DOC, source_repo=root, push=false)
        a = Archeion.additions(root; base)
        @test a.ok
        @test any(p -> endswith(p, "another-record/record.toml"), a.added)
        # A project.
        base = _ad_head(root)
        write(
            joinpath(root, "projects", "second.toml"),
            "created = 2026-09-25T00:00:00.000Z\nname = \"second\"\nspec = \"registry/2\"\n" *
            "uuid = \"$(Archeion.new_uuid())\"\n",
        )
        Archeion.reindex!(root)
        _ad_commit(root, "a project")
        a = Archeion.additions(root; base)
        @test a.ok && a.added == ["projects/second.toml"]
        # An event alone: what `verify` adds to a revision already there.
        base = _ad_head(root)
        mkpath(joinpath(root, REC_REL, "events"))
        ev = joinpath(REC_REL, "events", "20260925T000000Z-loc-abcd.toml")
        write(
            joinpath(root, ev),
            "at = 2026-09-25T00:00:00.000Z\nkind = \"comment\"\nspec = \"registry/2\"\n" *
            "[subject]\nrecord = \"$RECORD_UUID\"\n",
        )
        _ad_commit(root, "an event")
        a = Archeion.additions(root; base)
        @test a.ok && a.added == [ev]
    end
end

@testset "additions: what is added and still not a deposit's is named" begin
    cases = [
        # A symbolic link in a new revision: a site built from it would carry the link.
        (
            (root, rev) -> symlink("../README.md", joinpath(rev, "gallery", "leak.txt")),
            "added as a symbolic link",
        ),
        # Beside a record, not in it.
        (
            (root, rev) -> write(joinpath(root, REC_REL, "notes.txt"), "x"),
            "notes.txt: added outside",
        ),
        # A mode change is a change.
        (
            (root, rev) -> chmod(joinpath(root, REV_REL, "README.md"), 0o755),
            "README.md: modified",
        ),
    ]
    for (mutate!, says) in cases
        with_git_fixture() do root, binding, src
            _ad_commit(root, "the binding")
            base = _ad_head(root)
            res = deposit(binding; src..., doc=DOC, source_repo=root, push=false)
            mutate!(root, res.dir)
            _ad_commit(root, "and this")
            a = Archeion.additions(root; base)
            @test !a.ok
            @test any(v -> occursin(says, v), a.violations)
        end
    end
end

@testset "additions: a base with no history in common is refused, and the CLI says so" begin
    cli(args) =
        redirect_stdout(() -> redirect_stderr(() -> Archeion.main(args), devnull), devnull)
    with_git_fixture() do root, binding, src
        # A commit with no parent and nothing in it, made without touching the working tree.
        empty = readchomp(
            pipeline(`git -C $root hash-object -t tree --stdin`; stdin=devnull)
        )
        other = readchomp(
            `git -C $root -c user.name=t -c user.email=t@t commit-tree $empty -m unrelated`
        )
        e = attempt(() -> Archeion.additions(root; base=other))
        @test e isa ErrorException && occursin("share no history", e.msg)
        @test cli(["additions", root, "--base=$other"]) == 2
    end
end

@testset "symbolic links in a revision: a warning from validate, and left out of the site" begin
    root, rec, rev = fixture_copy()
    try
        # Listed in SHA256SUMS (hashed through to its target), so nothing else is wrong with it.
        symlink("../README.md", joinpath(rev, "gallery", "leak.txt"))
        Archeion.write_sums(rev)
        r = Archeion.validate(root)
        @test isempty(r.errors)
        @test any(w -> occursin("leak.txt", w) && occursin("symbolic link", w), r.warnings)
        site = joinpath(mktempdir(), "_site")
        @test_logs (:warn, r"symbolic link") match_mode = :any Archeion.build(root, site)
        copied = joinpath(site, relpath(rev, root), "gallery", "leak.txt")
        @test !ispath(copied) && !islink(copied)
        rm(dirname(site); recursive=true)
    finally
        rm(root; recursive=true)
    end
end
