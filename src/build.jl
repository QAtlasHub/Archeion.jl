# build.jl — render the registry as a static site.
#
# The site is plain files with relative links, so it can be served from any directory, over any
# static server or an SSH-forwarded one, or opened with file://. It refuses to build a registry
# that does not validate, and fails if any link in its own output does not resolve. Everything
# here is derived (SPEC.md §9): nothing it writes is committed.

const MARKER = ".registry-site"

function html_escape(s)
    return replace(
        string(s),
        "&" => "&amp;",
        "<" => "&lt;",
        ">" => "&gt;",
        "\"" => "&quot;",
        "'" => "&#39;",
    )
end
day(t) = t isa DateTime ? Dates.format(t, "yyyy-mm-dd") : ""
stamp(t) = t isa DateTime ? Dates.format(t, "yyyy-mm-dd HH:MM") * "Z" : ""

# ── reading ───────────────────────────────────────────────────────────────────────────────────

function read_registry(root)
    projects = Dict{String,Any}()
    for f in readdir(joinpath(root, "projects"); join=true)
        d = TOML.parsefile(f)
        projects[d["id"]] = d
    end
    records = []
    base = joinpath(root, "records")
    for year in sort(readdir(base)), rec in sort(readdir(joinpath(base, year)))
        dir = joinpath(base, year, rec)
        record = TOML.parsefile(joinpath(dir, "record.toml"))
        revs = [
            (
                name=n,
                dir=joinpath(dir, "revisions", n),
                entry=TOML.parsefile(joinpath(dir, "revisions", n, "entry.toml")),
                provenance=let f = joinpath(dir, "revisions", n, "provenance.toml")
                    isfile(f) ? TOML.parsefile(f) : nothing
                end,
            ) for n in sort(readdir(joinpath(dir, "revisions")))
        ]
        evdir = joinpath(dir, "events")
        events =
            isdir(evdir) ? [TOML.parsefile(f) for f in sort(readdir(evdir; join=true))] : []
        revinfo = Dict(r.name => (; parents=r.entry["parents"]) for r in revs)
        heads = current(revinfo, events)
        push!(records, (; dir, rel=relpath(dir, root), record, revs, events, heads))
    end
    return projects, records
end

function subjects(events, kind)
    return Set(getpath(e, "subject", "rev") for e in events if get(e, "kind", "") == kind)
end

function state(rec)
    length(rec.heads) == 1 && return "current"
    return isempty(rec.heads) ? "withdrawn" : "conflict"
end

# The revision a card speaks for: the current one, else the newest head, else the newest revision.
function shown(rec)
    names = isempty(rec.heads) ? [last(rec.revs).name] : rec.heads
    return only(filter(r -> r.name == last(sort(names)), rec.revs))
end

function thumbnail(rev)
    assets = joinpath(rev.dir, "gallery", "assets")
    isdir(assets) || return nothing
    for (dir, _, files) in walkdir(assets), f in sort(files)
        any(endswith(lowercase(f), e) for e in (".svg", ".png", ".jpg", ".jpeg")) &&
            return relpath(joinpath(dir, f), rev.dir)
    end
    return nothing
end

comment_text(e) = something(getpath(e, "body", "text"), get(e, "text", nothing), "")

# ── pages ─────────────────────────────────────────────────────────────────────────────────────

const CSS = """
:root{--bg:#fbfaf7;--fg:#1d1d1b;--mut:#6b6a66;--line:#e2e0da;--card:#fff;--acc:#2f5d8a;
--warn:#9a5b00;--bad:#a1332b;--ok:#2e6b3a}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--fg:#ecebe7;--mut:#a3a19b;--line:#33322f;
--card:#1f1f1d;--acc:#8fb4dc;--warn:#e0a44a;--bad:#e4867e;--ok:#8cc79a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:1080px;margin:0 auto;padding:24px 16px 64px}a{color:var(--acc)}
h1{font-size:1.5rem;margin:0 0 4px}h2{font-size:1.1rem;margin:28px 0 8px}
.mut{color:var(--mut)}.state{display:flex;flex-wrap:wrap;gap:8px 20px;margin:16px 0;
padding:12px 14px;border:1px solid var(--line);border-radius:8px;background:var(--card)}
.state b{font-variant-numeric:tabular-nums}.warn{color:var(--warn)}.bad{color:var(--bad)}
.ok{color:var(--ok)}.filters{display:flex;flex-wrap:wrap;gap:8px;margin:12px 0}
.filters select,.filters input{font:inherit;padding:6px 8px;border:1px solid var(--line);
border-radius:6px;background:var(--card);color:var(--fg)}.filters input{flex:1;min-width:160px}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px}
.card{display:block;border:1px solid var(--line);border-radius:8px;background:var(--card);
color:inherit;text-decoration:none;overflow:hidden}.card:hover{border-color:var(--acc)}
.thumb{height:140px;background:#fff;display:flex;align-items:center;justify-content:center;
border-bottom:1px solid var(--line)}.thumb img{max-width:100%;max-height:140px}
.body{padding:10px 12px}.title{font-weight:600}.meta{font-size:.85rem;color:var(--mut)}
.badge{display:inline-block;font-size:.75rem;padding:0 6px;border:1px solid currentColor;
border-radius:10px;margin-right:4px}table{border-collapse:collapse;width:100%;font-size:.9rem}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
.yanked td{text-decoration:line-through;color:var(--mut)}.wrap{overflow-x:auto}
.event{border-left:3px solid var(--line);padding:4px 10px;margin:8px 0}
.event pre{white-space:pre-wrap;font:inherit;margin:4px 0 0}
.bars{display:flex;align-items:flex-end;gap:3px;height:70px;margin:10px 0 4px}
.bar{flex:1;max-width:28px;display:flex;flex-direction:column;justify-content:flex-end;
height:100%;text-align:center}.bar>div{background:var(--acc);border-radius:2px 2px 0 0;min-height:2px}
.bar span{font-size:.7rem;color:var(--mut)}h2{font-size:1.05rem;margin:22px 0 6px}
.pick{color:var(--acc)}
"""

# Everything the search needs is already in the page, so it works from a file:// window as well as
# over http (ssh-browser gives a real origin, but the site must not depend on having one). Words
# are ANDed: typing two of them narrows rather than widens.
const FILTER_JS = """
(function(){var q=function(s){return document.querySelector(s)};
function apply(){var p=q('#f-project').value,s=q('#f-status').value,t=q('#f-tag').value,
w=q('#f-text').value.toLowerCase().split(/\\s+/).filter(Boolean),n=0;
document.querySelectorAll('.card').forEach(function(c){var d=c.dataset,
ok=(!p||d.project===p)&&(!s||d.status===s)&&(!t||(' '+d.tags+' ').indexOf(' '+t+' ')>=0)&&
w.every(function(x){return d.text.indexOf(x)>=0});
c.style.display=ok?'':'none';if(ok)n++});
q('#shown').textContent=n}
['#f-project','#f-status','#f-tag','#f-text'].forEach(function(id){q(id).addEventListener('input',apply)});
document.querySelectorAll('.pick').forEach(function(a){a.addEventListener('click',function(e){
e.preventDefault();q('#f-project').value=a.dataset.project;apply();
document.querySelector('.cards').scrollIntoView({behavior:'smooth'})})});
apply()})();
"""

function page(title, body)
    return """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>$(html_escape(title))</title>
<style>$CSS</style></head><body><main>$body</main></body></html>
"""
end

function options(values)
    return join(
        (
            "<option value=\"$(html_escape(v))\">$(html_escape(v))</option>" for
            v in sort(collect(values))
        ),
        "",
    )
end

# Everything about a record a reader might search for: not only the current revision's title, but
# every revision's, the question and claim it states, its tags, its identifiers, and what people
# said about it in comments. A search that only sees card titles finds what you already see.
function searchable(rec, proj)
    e = shown(rec).entry
    parts = [proj, rec.record["id"], get(rec.record, "kind", "report")]
    for r in rec.revs
        push!(parts, r.entry["doc"]["title"], r.name)
        for k in ("question", "claim")
            v = getpath(r.entry, "doc", k)
            v === nothing || push!(parts, string(v))
        end
        append!(parts, String.(something(getpath(r.entry, "doc", "tags"), String[])))
    end
    for ev in rec.events
        push!(parts, get(ev, "kind", ""))
        push!(parts, comment_text(ev))
    end
    return lowercase(join(parts, " "))
end

month(t) = t isa DateTime ? Dates.format(t, "yyyy-mm") : ""

# The registry at a glance: who has how much, and when it was last touched. A catalogue that only
# lists cards answers "what is there"; this answers "where is the work".
function overview(projects, records)
    rows = Dict{String,Any}()
    for rec in records
        proj = get(
            get(projects, rec.record["project"], Dict()), "name", rec.record["project"]
        )
        r = get!(
            rows, proj, Dict("records" => 0, "revisions" => 0, "final" => 0, "last" => "")
        )
        r["records"] += 1
        r["revisions"] += length(rec.revs)
        shown(rec).entry["doc"]["status"] == "final" && (r["final"] += 1)
        d = day(shown(rec).entry["time"]["frozen"])
        d > r["last"] && (r["last"] = d)
    end
    isempty(rows) && return ""
    body = IOBuffer()
    for proj in sort(collect(keys(rows)))
        r = rows[proj]
        print(
            body,
            """<tr><td><a href="#" class="pick" data-project="$(html_escape(proj))">$(html_escape(proj))</a></td>
<td>$(r["records"])</td><td>$(r["revisions"])</td><td>$(r["final"]) final</td><td>$(r["last"])</td></tr>
""",
        )
    end
    return """<h2>Projects</h2><div class="wrap"><table><tr><th>project</th><th>records</th>
<th>revisions</th><th>of them</th><th>last frozen</th></tr>$(String(take!(body)))</table></div>"""
end

# When revisions were frozen, by month, as bars whose height is a count. Twelve months of nothing
# is itself worth seeing.
function activity(records)
    per = Dict{String,Int}()
    for rec in records, r in rec.revs
        m = month(r.entry["time"]["frozen"])
        isempty(m) || (per[m] = get(per, m, 0) + 1)
    end
    isempty(per) && return ""
    months = sort(collect(keys(per)))
    top = maximum(values(per))
    bars = join(
        (
            """<div class="bar" title="$(html_escape(m)): $(per[m]) revision(s)">
<div style="height:$(round(Int, 100 * per[m] / top))%"></div><span>$(html_escape(m[6:7]))</span></div>"""
            for m in months
        ),
        "",
    )
    return """<h2>Activity</h2><div class="bars">$bars</div>
    <div class="mut">$(first(months)) to $(last(months)), $(sum(values(per))) revision(s)</div>"""
end

function index_page(name, projects, records)
    counts = Dict("current" => 0, "withdrawn" => 0, "conflict" => 0)
    publish_only = 0
    comments = 0
    for rec in records
        counts[state(rec)] += 1
        getpath(shown(rec).entry, "source", "captured") in (nothing, "publish") &&
            (publish_only += 1)
        comments += count(e -> get(e, "kind", "") == "comment", rec.events)
    end
    nrev = sum(length(r.revs) for r in records; init=0)
    cards = IOBuffer()
    tags = Set{String}()
    for rec in records
        rev = shown(rec)
        e = rev.entry
        proj = get(
            get(projects, rec.record["project"], Dict()), "name", rec.record["project"]
        )
        rtags = String.(something(getpath(e, "doc", "tags"), String[]))
        union!(tags, rtags)
        status = e["doc"]["status"]
        st = state(rec)
        th = thumbnail(rev)
        img = if th === nothing
            ""
        else
            "<img src=\"$(html_escape(rec.rel))/revisions/$(html_escape(rev.name))/$(html_escape(th))\" alt=\"\">"
        end
        badge = if st == "current"
            ""
        else
            "<span class=\"badge $(st == "conflict" ? "warn" : "bad")\">$st</span>"
        end
        text = searchable(rec, proj)
        print(
            cards,
            """<a class="card" href="$(html_escape(rec.rel))/index.html" data-project="$(html_escape(proj))"
data-status="$(html_escape(status))" data-tags="$(html_escape(join(rtags, " ")))"
data-month="$(html_escape(month(e["time"]["frozen"])))" data-text="$(html_escape(text))">
<div class="thumb">$img</div><div class="body">$badge<div class="title">$(html_escape(e["doc"]["title"]))</div>
<div class="meta">$(html_escape(proj)) · $(html_escape(status)) · $(length(rec.revs)) revision(s) · $(day(e["time"]["frozen"]))</div>
$(isempty(rtags) ? "" : "<div class=\"meta\">$(html_escape(join(rtags, ", ")))</div>")</div></a>
""",
        )
    end
    pnames = Set(get(p, "name", id) for (id, p) in projects)
    body = """<h1>$(html_escape(name))</h1><div class="mut">Built from the registry tree; nothing here is edited by hand.</div>
    <div class="state"><span><b>$(length(records))</b> records</span><span><b>$nrev</b> revisions</span>
    <span class="$(counts["withdrawn"] > 0 ? "bad" : "")"><b>$(counts["withdrawn"])</b> withdrawn</span>
    <span class="$(counts["conflict"] > 0 ? "warn" : "")"><b>$(counts["conflict"])</b> in conflict</span>
    <span class="$(publish_only > 0 ? "warn" : "")"><b>$publish_only</b> with code state read only at publish</span>
    <span><b>$comments</b> comments</span></div>
    <div class="filters"><select id="f-project"><option value="">all projects</option>$(options(pnames))</select>
    <select id="f-status"><option value="">trial and final</option><option>trial</option><option>final</option></select>
    <select id="f-tag"><option value="">all tags</option>$(options(tags))</select>
    <input id="f-text" type="search" placeholder="search titles, questions, claims, tags, comments, ids"></div>
    $(overview(projects, records))
    $(activity(records))
    <h2>Records</h2>
    <div class="mut"><span id="shown">$(length(records))</span> shown</div>
    <div class="cards">$(String(take!(cards)))</div><script>$FILTER_JS</script>
    """
    return page(name, body)
end

# One line for a revision's per-point provenance (§5.5): how many points, how many of them read
# the bytes their computation recorded, and how far the code that computed them was checked.
function provenance_line(p)
    p === nothing && return "per-point provenance: none"
    c = get(p, "counts", Dict())
    parts = [
        "$(get(p, "points", 0)) points: $(get(c, "read_matches_result", 0)) read as recorded",
    ]
    d = get(c, "read_differs_from_result", 0)
    d > 0 && push!(parts, "<span class=\"warn\">$d read other bytes</span>")
    u = get(c, "result_unknown", 0)
    u > 0 && push!(parts, "$u unrecorded")
    b = get(p, "bindings", Dict())
    push!(
        parts,
        "code " * join(("$(html_escape(k)) $(b[k])" for k in sort(collect(keys(b)))), ", "),
    )
    m = length(get(p, "missing_observations", []))
    m > 0 && push!(parts, "<span class=\"warn\">$m observation(s) missing</span>")
    return join(parts, " · ")
end

# A record says what it holds; only a kind other than the default is worth a word on the page.
function kind_note(record)
    return if get(record, "kind", "report") == "report"
        ""
    else
        " · " * html_escape(string(get(record, "kind", "report")))
    end
end

function record_page(name, projects, rec)
    rev = shown(rec)
    yanked = subjects(rec.events, "yank")
    superseded = subjects(rec.events, "supersede")
    proj = get(get(projects, rec.record["project"], Dict()), "name", rec.record["project"])
    up = join(fill("..", length(splitpath(rec.rel))), "/")
    st = state(rec)
    stline = if st == "current"
        "<span class=\"ok\">current revision $(html_escape(only(rec.heads)))</span>"
    elseif st == "withdrawn"
        "<span class=\"bad\">withdrawn: every revision is yanked or replaced</span>"
    else
        "<span class=\"warn\">in conflict: $(html_escape(join(rec.heads, ", "))) are all current; nothing is chosen by time</span>"
    end
    rows = IOBuffer()
    for r in reverse(rec.revs)
        e = r.entry
        marks = String[]
        r.name in rec.heads && push!(marks, "<span class=\"badge ok\">current</span>")
        r.name in yanked && push!(marks, "<span class=\"badge bad\">yanked</span>")
        r.name in superseded && push!(marks, "<span class=\"badge warn\">superseded</span>")
        cap = getpath(e, "source", "captured")
        p = "revisions/$(html_escape(r.name))"
        print(
            rows,
            """<tr class="$(r.name in yanked ? "yanked" : "")"><td><code>$(html_escape(r.name))</code><br>$(join(marks))</td>
<td>$(html_escape(e["doc"]["title"]))<div class="meta">$(html_escape(e["doc"]["status"])) · frozen $(stamp(e["time"]["frozen"]))
· code state $(cap === nothing ? "unknown" : "read at " * html_escape(cap)) · $(html_escape(e["preservation"]["level"]))
<br>$(provenance_line(r.provenance))</div></td>
<td><a href="$p/gallery/index.html">report</a> · <a href="$p/agent/agent.json">agent.json</a>
· <a href="$p/README.md">README</a> · <a href="$p/entry.toml">entry</a>$(r.provenance === nothing ? "" : " · <a href=\"$p/provenance.toml\">provenance</a>")</td></tr>
""",
        )
    end
    evs = IOBuffer()
    for e in sort(rec.events; by=e -> get(e, "at", DateTime(0)))
        kind = get(e, "kind", "?")
        by = something(getpath(e, "by", "login"), getpath(e, "by", "name"), "")
        where = join(
            filter(
                !isnothing, [getpath(e, "subject", "rev"), getpath(e, "subject", "anchor")]
            ),
            " · ",
        )
        text = kind == "comment" ? "<pre>$(html_escape(comment_text(e)))</pre>" : ""
        print(
            evs,
            """<div class="event"><b>$(html_escape(kind))</b> <span class="meta">$(stamp(get(e, "at", nothing)))
 $(isempty(by) ? "" : "· " * html_escape(by)) $(isempty(where) ? "" : "· " * html_escape(where))</span>$text</div>
 """,
        )
    end
    body = """<div class="mut"><a href="$up/index.html">$(html_escape(name))</a> / $(html_escape(proj))</div>
    <h1>$(html_escape(rev.entry["doc"]["title"]))</h1><div class="mut">record <code>$(html_escape(rec.record["id"]))</code>
    · created $(day(rec.record["created"]))$(kind_note(rec.record))</div><div class="state">$stline</div>
    <p><a href="revisions/$(html_escape(rev.name))/gallery/index.html">Open the report →</a></p>
    <h2>Revisions</h2><div class="wrap"><table><tr><th>revision</th><th>what</th><th>files</th></tr>
    $(String(take!(rows)))</table></div>
    <h2>Events</h2>$(isempty(rec.events) ? "<div class=\"mut\">none</div>" : String(take!(evs)))
    """
    return page(rev.entry["doc"]["title"], body)
end

# ── checking the output ───────────────────────────────────────────────────────────────────────

function broken_links(out)
    bad = String[]
    for (dir, _, files) in walkdir(out), f in files
        endswith(f, ".html") || continue
        path = joinpath(dir, f)
        for m in eachmatch(r"(?:href|src)=\"([^\"]*)\"", read(path, String))
            link = m[1]
            (
                isempty(link) ||
                startswith(link, "#") ||
                occursin(r"^(https?:|mailto:|data:|javascript:)", link)
            ) && continue
            startswith(link, "/") && (
                push!(
                    bad,
                    "$(relpath(path, out)): absolute link $link breaks under a sub-path",
                );
                continue
            )
            target = normpath(joinpath(dir, first(split(link, r"[?#]"))))
            isdir(target) && (target = joinpath(target, "index.html"))
            ispath(target) || push!(bad, "$(relpath(path, out)): $link does not exist")
        end
    end
    return bad
end

# ── build ─────────────────────────────────────────────────────────────────────────────────────

# What of a revision the site serves: everything a reader opens, not the evidence behind it. The
# point table and `repro/` (observations, source snapshots and contents) stay in the repository:
# a table of 80_000 points is 24 MiB per revision, and a site that copied it would carry it once
# per revision ever deposited. The summary, `provenance.toml`, is served and links nowhere.
const SITE_SKIP = ("provenance", "repro")

function copy_revision(src, dest)
    mkpath(dest)
    for name in readdir(src)
        name in SITE_SKIP && isdir(joinpath(src, name)) && continue
        cp(joinpath(src, name), joinpath(dest, name))
    end
end

function build(root, out=joinpath(root, "_site"); name=basename(abspath(root)))
    r, _ = validate(root)
    isempty(r.errors) || error(
        "the registry does not validate; run tools/validate.jl:\n  " *
        join(r.errors, "\n  "),
    )
    if ispath(out)
        isfile(joinpath(out, MARKER)) ||
            error("$out exists and was not written by build.jl; refusing to replace it")
        rm(out; recursive=true)
    end
    mkpath(out)
    write(joinpath(out, MARKER), "written by tools/build.jl; replaced on every build\n")
    projects, records = read_registry(root)
    for rec in records
        dest = joinpath(out, rec.rel)
        mkpath(joinpath(dest, "revisions"))
        for rev in rec.revs
            copy_revision(rev.dir, joinpath(dest, "revisions", rev.name))
        end
        write(joinpath(dest, "index.html"), record_page(name, projects, rec))
    end
    write(joinpath(out, "index.html"), index_page(name, projects, records))
    bad = broken_links(out)
    isempty(bad) || error("the site has broken links:\n  " * join(bad, "\n  "))
    bytes = sum(filesize(joinpath(d, f)) for (d, _, fs) in walkdir(out) for f in fs)
    return (; out, records=length(records), bytes)
end
