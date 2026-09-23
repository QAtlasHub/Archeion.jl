# remote.jl — the git side of depositing into a registry that other clones also write to.
#
# `deposit` writes one revision and commits it. Everything around that commit — is this clone up to
# date, does the code the revision cites exist anywhere but here, how does the commit reach the
# shared repository — is here, because it is the same for every study and easy to get wrong once
# per study.

"""
    sync!(reg)

Bring the registry clone to its remote before anything is validated or written: a deposit checks
the state it is about to add to, so that state must be the shared one. Refuses a dirty working
tree, and a history that is not a fast-forward of its remote (a rebase is the caller's call, not
this function's). A clone with no remote, or a remote that cannot be reached, is left alone with a
warning: depositing offline is normal.
"""
function sync!(reg)
    isempty(git(reg, "status", "--porcelain")) ||
        error("$reg has uncommitted changes; commit or clean them before depositing")
    branch = git(reg, "rev-parse", "--abbrev-ref", "HEAD")
    upstream = git(
        reg, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"; ok=true
    )
    if upstream === nothing
        @warn "$reg: $branch tracks no remote branch; depositing into this clone only"
        return nothing
    end
    if git(reg, "fetch", "--quiet"; ok=true) === nothing
        @warn "$reg: could not fetch $upstream; depositing against the state on disk"
        return nothing
    end
    behind = git(reg, "rev-list", "--count", "HEAD..$upstream")
    if behind != "0"
        git(reg, "merge", "--ff-only", upstream; ok=true) === nothing && error(
            "$reg is $behind commit(s) behind $upstream and cannot fast-forward; rebase or " *
            "merge it yourself, then deposit again",
        )
        @info "fast-forwarded $reg to $upstream ($behind commit(s))"
    end
    return nothing
end

"""
    check_source_published(repo) -> Bool

Whether `repo`'s HEAD — the commit a revision deposited now names as the code that rendered it —
is reachable from the remote's default branch. When it is not, the citation points at something
only this clone has: a squash merge of the branch it sits on would replace it, and the revision
would name a commit no one can resolve. Warns rather than refuses, because depositing while the
work is still in review is a reasonable thing to do; merging that branch with a merge commit is
what keeps the citation good.
"""
function check_source_published(repo)
    head = git(repo, "rev-parse", "HEAD"; ok=true)
    head === nothing && return false
    remote_head = git(repo, "rev-parse", "--abbrev-ref", "origin/HEAD"; ok=true)
    if remote_head === nothing
        @warn "$repo has no origin/HEAD; cannot tell whether $(head[1:7]) is published"
        return false
    end
    if git(repo, "merge-base", "--is-ancestor", head, remote_head; ok=true) === nothing
        @warn """
              the rendering commit $(head[1:7]) is not on $remote_head; the revision cites it, so \
              merge its branch with a merge commit (a squash merge writes a different commit and \
              leaves this one unresolvable), or deposit again once it is merged"""
        return false
    end
    return true
end

# The branch a deposit goes on when it is published as a pull request. One branch per deposit: two
# deposits made before either is merged stay separate pull requests.
deposit_branch(rev) = "deposit/$rev"

"""
    publish_revision!(reg, rev, title; remote = :pr) -> NamedTuple

Get the commit `deposit` just made in `reg` to the shared repository. `:pr` pushes it on a branch
of its own and opens a pull request with `gh`, `:push` pushes the current branch, rebasing onto
the remote once if it moved and revalidating before it does, and `:local` leaves it alone.
Returns what happened — `pushed`, the `branch`, and the `pr` URL when there is one.
"""
function publish_revision!(reg, rev, title; remote::Symbol=:pr, gh="gh")
    remote in (:pr, :push, :local) ||
        error("remote must be :pr, :push or :local (got $(repr(remote)))")
    remote === :local && return (; pushed=false, branch=nothing, pr=nothing)
    if remote === :push
        if git(reg, "push", "--quiet"; ok=true) === nothing
            git(reg, "pull", "--quiet", "--rebase")       # someone else deposited meanwhile
            r, _ = validate(reg)
            isempty(r.errors) || error(
                "after rebasing onto the remote the registry does not validate:\n  " *
                join(r.errors, "\n  "),
            )
            git(reg, "push", "--quiet")
        end
        return (;
            pushed=true, branch=git(reg, "rev-parse", "--abbrev-ref", "HEAD"), pr=nothing
        )
    end
    branch = deposit_branch(rev)
    git(reg, "push", "--quiet", "--set-upstream", "origin", "HEAD:refs/heads/$branch")
    return (; pushed=true, branch, pr=open_pull_request(reg, branch, title; gh=gh))
end

# `gh` is how a pull request is opened; without it the branch is pushed and the caller is told what
# to run. A registry that requires review is the common case, so this is not a failure. The
# executable is a parameter so a test can hand it one that is missing, or one that answers.
function open_pull_request(reg, branch, title; gh="gh")
    if Sys.which(gh) === nothing
        @info "$gh is not installed; the branch is pushed" branch next = "$gh pr create --head $branch"
        return nothing
    end
    out, err = IOBuffer(), IOBuffer()
    body =
        "Deposited by Archeion. Merge with a merge commit: revisions cite commits of the " *
        "repositories that rendered them.\n"
    cmd = setenv(
        `$gh pr create --head $branch --title $title --body $body`; dir=abspath(reg)
    )
    proc = run(pipeline(ignorestatus(cmd); stdout=out, stderr=err))
    if !success(proc)
        @warn "$gh pr create failed; the branch is pushed" branch reason = strip(
            String(take!(err))
        )
        return nothing
    end
    return strip(String(take!(out)))
end
