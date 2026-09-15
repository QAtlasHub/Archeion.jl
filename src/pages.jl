# The public face of a PUBLIC registry. `gh-pages` is derived from the registry the same way
# `index.html` is derived from the records: nothing is authored here, so the branch carries one
# commit and is force-pushed. Everything that has history already has it on `main`.
#
# Two refusals carry this file. A private registry cannot serve Pages at all below a paid plan,
# and a `gh-pages` that is not ours is almost certainly Documenter's, where a force push would
# delete the documentation. The third guard is the one experience asks for: a push to `gh-pages`
# succeeds whether or not Pages is enabled, so a green publish can serve nobody. Ask GitHub
# whether the site exists, rather than trusting that the push means anything.

# Never interpolate a remote URL into an error or a log: a push URL can carry a token
# (`https://x-access-token:<token>@github.com/...`). Errors name the REMOTE, and git's own output
# is masked before it is shown.
_mask(s::AbstractString) = replace(String(s), r"https://[^@\s/]+@" => "https://***@")

# github.com[:/]owner/name(.git) in any of the ssh, https and tokenized-https spellings.
function _slug_from_url(url::AbstractString)
    s = replace(strip(String(url)), r"\.git$" => "")
    m = match(r"github\.com[:/]([^/\s]+)/([^/\s]+)$", s)
    m === nothing && error(
        "publish_pages: the remote is not a github.com URL, so there is no Pages site to check. " *
        "Pass `check = false` to publish anyway.",
    )
    return string(m.captures[1], "/", m.captures[2])
end

"""
    remote_slug(root=registry_root(); remote="origin") -> String

`owner/name` of the registry's `remote`. Raises when the remote is missing or is not a github.com
URL. The URL itself never appears in the error: a push URL can carry a token.
"""
function remote_slug(root::AbstractString=registry_root(); remote::AbstractString="origin")
    ok, url = _git_try(root, ["remote", "get-url", remote])
    ok || error(
        "remote_slug: the registry at `$(root)` has no remote `$(remote)`. Add one, or record it " *
        "in $(REGISTRY_FILE) and pass it as `remote`.",
    )
    return _slug_from_url(url)
end

"""
    pages_status(slug) -> (; private, enabled, url)

Ask GitHub whether `owner/name` is private and whether it serves a Pages site. Uses the `gh` CLI,
so it sees private repositories the caller can see.

This exists because the obvious signal is wrong: pushing to `gh-pages` succeeds whether or not
Pages is enabled, so a green deploy reports that the push happened and never that the site is
reachable.
"""
function pages_status(slug::AbstractString)
    gh = Sys.which("gh")
    gh === nothing && error(
        "pages_status: the `gh` CLI was not found, so whether $(slug) serves a site cannot be " *
        "checked. Install gh, or pass `check = false` and accept that a green push can serve nobody.",
    )
    out = IOBuffer()
    okp = success(
        pipeline(`$gh api repos/$(slug) --jq .private`; stdout=out, stderr=devnull)
    )
    okp || error(
        "pages_status: could not read `repos/$(slug)`; is the name right and `gh` logged in?",
    )
    private = strip(String(take!(out))) == "true"

    url = IOBuffer()
    enabled = success(
        pipeline(`$gh api repos/$(slug)/pages --jq .html_url`; stdout=url, stderr=devnull)
    )
    return (;
        private=private, enabled=enabled, url=enabled ? strip(String(take!(url))) : ""
    )
end

# Copy the registry into a fresh directory, leaving git's own state behind.
function _copy_site(root::AbstractString, dest::AbstractString)
    for (dir, _, files) in walkdir(root)
        rel = relpath(dir, root)
        (rel == ".git" || startswith(rel, ".git" * Base.Filesystem.path_separator)) &&
            continue
        for f in files
            target = joinpath(dest, rel == "." ? f : joinpath(rel, f))
            mkpath(dirname(target))
            cp(joinpath(dir, f), target; force=true)
        end
    end
    return dest
end

# Refuse to force-push over a branch that is not an Archeion site. The case this is written for is
# a repository whose `gh-pages` belongs to Documenter.
function _guard_site_branch(
    root::AbstractString, remote::AbstractString, branch::AbstractString
)
    ok, _ = _git_try(root, ["fetch", "--quiet", remote, branch])
    ok || return nothing                       # no such branch yet, so there is nothing to protect
    ours, _ = _git_try(root, ["cat-file", "-e", "FETCH_HEAD:" * REGISTRY_FILE])
    ours && return nothing
    return error(
        "publish_pages: `$(branch)` on `$(remote)` exists and has no $(REGISTRY_FILE) at its root, " *
        "so it is not this registry's site (a Documenter branch looks like this). Refusing to " *
        "force-push over it.",
    )
end

"""
    publish_pages(root=registry_root(); remote="origin", branch="gh-pages", check=true,
                  search=true, message="") -> String

Publish the registry at `root` as a static site on `branch` of `remote`, and return the URL GitHub
serves it at (empty when `check = false`, since that is the answer only GitHub has).

The site IS the registry: the same `index.html`, the same record directories. What the publish adds
is `.nojekyll` (Pages runs Jekyll otherwise, which drops paths beginning with an underscore) and,
with `search = true`, the Pagefind index.

It refuses in three cases, each of which otherwise produces a green publish that serves nothing or
destroys something:

* the repository is **private** (Pages needs a paid plan there, and no plan below Enterprise gives
  an access-controlled site) -- a private registry is read from its clone instead;
* **Pages is not enabled** on the repository;
* `branch` exists and is **not this registry's site**, which is what a Documenter `gh-pages` looks
  like.

The branch is force-pushed with a single commit: it is derived from the registry, so its history
would only duplicate `main`'s.
"""
function publish_pages(
    root::AbstractString=registry_root();
    remote::AbstractString="origin",
    branch::AbstractString="gh-pages",
    check::Bool=true,
    search::Bool=true,
    message::AbstractString="",
)
    is_registry(root) || error(
        "publish_pages: `$(root)` is not an Archeion registry (no $(REGISTRY_FILE)). " *
        "Create one with `create_registry`.",
    )
    isdir(joinpath(root, ".git")) || error(
        "publish_pages: `$(root)` is not a git repository; there is nothing to push from.",
    )
    _require_git("publish_pages")

    url = ""
    if check
        st = pages_status(remote_slug(root; remote=remote))
        st.private && error(
            "publish_pages: that repository is private. GitHub Pages is unavailable for private " *
            "repositories below a paid plan, and no plan below Enterprise serves one with access " *
            "control. Read a private registry from its clone; publish by depositing into a public " *
            "registry.",
        )
        st.enabled || error(
            "publish_pages: Pages is not enabled on that repository, so a push to `$(branch)` " *
            "would succeed and serve nobody. Enable it first (Settings > Pages, source `$(branch)` /).",
        )
        url = st.url
    end
    _guard_site_branch(root, remote, branch)

    site = mktempdir()
    _copy_site(root, site)
    touch(joinpath(site, ".nojekyll"))
    search && add_search(site)

    n = length(read_records(root))
    msg = isempty(message) ? "Publish $(n) record$(n == 1 ? "" : "s")" : String(message)
    _git_try(site, ["init", "-q"])
    _git_try(site, ["checkout", "-q", "-b", branch])
    _git_try(site, ["add", "-A"])     # this tree was just built by us, so there is nothing to sweep
    ok, out = _git_try(site, ["commit", "-q", "-m", msg])
    ok || error("publish_pages: could not commit the site: " * _mask(out))

    _, push_url = _git_try(root, ["remote", "get-url", "--push", remote])
    ok, out = _git_try(
        site, ["push", "--force", strip(push_url), "HEAD:refs/heads/$(branch)"]
    )
    ok || error("publish_pages: the push to `$(branch)` failed: " * _mask(out))
    return url
end
