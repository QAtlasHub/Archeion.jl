# ids.jl — what names a thing (SPEC.md §1, R5 and R6).
#
# A registry names the same thing twice: a UUID, which never changes and never appears in a path,
# and a slug, which is what a reader sees in a directory listing and may be renamed freely. Both
# live here, so the rules are in one place rather than in every writer.

using UUIDs

const UUID_RE = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
const SLUG_RE = r"^[a-z0-9]+(-[a-z0-9]+)*$"
const TAG_ALPHABET = collect("0123456789abcdefghjkmnpqrstvwxyz")   # Crockford, lower case

"A fresh identifier: version 4, from the system's own randomness, written as R5 asks."
new_uuid() = string(uuid4(Random.RandomDevice()))

is_uuid(s) = s isa AbstractString && occursin(UUID_RE, s)
is_slug(s) = s isa AbstractString && occursin(SLUG_RE, s)

"The tag that tells apart two revisions frozen in the same second."
tag(n=4) = String(rand(Random.RandomDevice(), TAG_ALPHABET, n))

"""
    slugify(text) -> String

A slug from something written for people: lower case, `[a-z0-9]` words joined by `-`. What is
already a slug comes back unchanged. Refuses to invent one from nothing, because a directory named
`untitled-3` helps nobody — the caller knows what the thing is called.
"""
function slugify(text)
    s = lowercase(String(text))
    s = replace(s, r"[^a-z0-9]+" => "-")
    s = strip(s, '-')
    isempty(s) && error("cannot make a slug from $(repr(text)): name it yourself")
    return String(s)
end
