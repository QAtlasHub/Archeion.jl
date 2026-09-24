# appearance.jl — one control, for the catalogue and for the reports in it.
#
# `dark.jl` derives a dark layer for a frozen report; this decides *when* that layer applies.
# Three states, not two: the reader's system, unless they have said otherwise, and `data-theme` on
# `<html>` is that saying. A registry sets the default in `registry.toml`'s `[site] appearance`;
# the reader's own choice outranks it and is remembered per origin.
#
# The key is Pinax's, deliberately. A catalogue and the reports it links to are one site to read,
# and a reader who turns the lights down on a record page has not asked to have them turned back
# up when they follow a link into the report. Archeion cannot depend on Pinax — a registry has to
# build without a plotting stack — so it names the same string, and `test_theme.jl` is what fails
# when either side moves it.
const APPEARANCE_KEY = "pinax-appearance"
const APPEARANCES = ("system", "light", "dark")

# A report frozen before any of this brings no dark rules of its own, so the derived layer is
# served as a second stylesheet gated by `media`. That attribute is the whole mechanism: the
# browser applies the layer while the query matches, and the scripts below rewrite the query to
# `all` or `not all` once the reader has chosen. No selector in the frozen sheet is rewritten, and
# a reader without JavaScript keeps exactly what they had before — the system's answer.
const DARK_LINK_MARK = "data-appearance-dark"
const DARK_MEDIA = "(prefers-color-scheme: dark)"

# The `media` for each state, as one expression shared by both scripts, so the two cannot disagree.
const MEDIA_JS = """m=v==="dark"?"all":v==="light"?"not all":"$DARK_MEDIA\""""

# Ahead of every stylesheet, so a reader whose answer is dark never watches the page turn white on
# its way there.
function appearance_head(default)
    return """
<script>(function(){var d="$default",v,m;try{v=localStorage.getItem("$APPEARANCE_KEY")}catch(e){}\
if(v!=="light"&&v!=="dark"&&v!=="system")v=d;\
if(v!=="system")document.documentElement.setAttribute("data-theme",v);\
$MEDIA_JS;\
var l=document.querySelectorAll("link[$DARK_LINK_MARK]");\
for(var i=0;i<l.length;i++)l[i].media=m;})()</script>"""
end

# Hidden until the script unhides it. Without JavaScript there is nothing for it to do, and a dead
# button in the corner of every page is worse than no button — the media query still works.
const APPEARANCE_BUTTON = """<button class="pinax-appearance" type="button" hidden></button>"""

# The control, after the button exists. Three states rather than a toggle: `system` is a real
# answer, and a reader who lands on a registry that defaults to dark needs the way back to
# following their desktop, not only the way to light.
function appearance_foot(default)
    return """
<script>(function(){var d="$default",K="$APPEARANCE_KEY",r=document.documentElement,
b=document.querySelector(".pinax-appearance");if(!b)return;
function read(){var v;try{v=localStorage.getItem(K)}catch(e){}
return (v==="light"||v==="dark"||v==="system")?v:d}
function next(v){return v==="system"?"light":v==="light"?"dark":"system"}
function show(v){var m;if(v==="system"){r.removeAttribute("data-theme")}else{r.setAttribute("data-theme",v)}
$MEDIA_JS;
var l=document.querySelectorAll("link[$DARK_LINK_MARK]");
for(var i=0;i<l.length;i++)l[i].media=m;
b.textContent=v==="dark"?"\\u263e dark":v==="light"?"\\u2600 light":"\\u25d0 system";
b.setAttribute("aria-label","Colour scheme: "+v+". Click for "+next(v)+".");b.hidden=false}
show(read());
b.addEventListener("click",function(){var v=next(read());try{localStorage.setItem(K,v)}catch(e){}show(v)})})()</script>"""
end

# The control's own styling, in the site's palette. A frozen report has no rule for a button that
# did not exist when it was rendered, so the styling travels with the control; the fallbacks are
# for a report whose palette is not tokenised.
const APPEARANCE_CSS = """
.pinax-appearance{position:fixed;top:.55rem;right:.55rem;z-index:99;font:600 12px/1 system-ui,sans-serif;
color:var(--mut,#57606a);background:var(--card,#fff);border:1px solid var(--line,#e2e5e9);
border-radius:999px;padding:.42rem .72rem;cursor:pointer;opacity:.75}
.pinax-appearance:hover,.pinax-appearance:focus-visible{opacity:1}
@media print{.pinax-appearance{display:none}}"""

# ── injecting the control into a copy of a frozen report ──────────────────────────────────────

# Where a tag closes, or where the one that opens ends. Case-insensitive, because a frozen file is
# whatever it was written as; `nothing` when there is no such tag, because an HTML fragment is not
# a page and is better left alone than guessed at.
function _before_close(html, tag)
    m = match(Regex("</\\s*$tag\\s*>", "i"), html)
    return m === nothing ? nothing : m.offset
end

function _after_open(html, tag)
    m = match(Regex("<\\s*$tag\\b[^>]*>", "i"), html)
    return m === nothing ? nothing : m.offset + ncodeunits(m.match)
end

_insert(html, at, text) = html[1:prevind(html, at)] * text * html[at:end]

"""
    inject_appearance(html, default, dark_hrefs) -> Union{String,Nothing}

`html` with the colour-scheme control in it, or `nothing` when it should not have one.

`dark_hrefs` are the derived dark stylesheets to serve beside the page's own, each linked with
`media` set to the system query — which is what a reader without JavaScript keeps. There is no
control without one: a button that sets `data-theme` on a page where nothing answers to it is
worse than no button, so a page Archeion could not derive a layer for is left as it is.

Returns `nothing` for such a page, for one that already carries the control (a report rendered by
a Pinax that brings its own), and for anything that is not a whole page.

This only ever runs on `_site`, which `build` rewrites every time; the revision it was copied from
is frozen and is not touched.
"""
function inject_appearance(html, default, dark_hrefs)
    isempty(dark_hrefs) && return nothing                     # nothing would answer the button
    occursin("pinax-appearance", html) && return nothing      # it brought its own
    head = _before_close(html, "head")
    body_open = _after_open(html, "body")
    body_close = _before_close(html, "body")
    (head === nothing || body_open === nothing || body_close === nothing) && return nothing

    # Inserted back to front, so each offset still points at the text it was measured in.
    out = _insert(html, body_close, appearance_foot(default))
    out = _insert(out, body_open, APPEARANCE_BUTTON)
    links = join((
        """<link rel="stylesheet" href="$h" media="$DARK_MEDIA" $DARK_LINK_MARK>""" for
        h in dark_hrefs
    ),)
    return _insert(
        out, head, links * "<style>$APPEARANCE_CSS</style>" * appearance_head(default)
    )
end
