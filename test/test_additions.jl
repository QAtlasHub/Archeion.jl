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
