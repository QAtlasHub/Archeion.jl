module ArcheionPinaxExt

using Archeion
using Pinax

# Every id a comment could point at: pages, sections, and their figures and tables. Which of them
# keep their meaning across revisions is decided by `Archeion.anchors`: Pinax numbers a figure or
# table without an explicit id by position (`<section>_fig<N>`), so those are revision-local.
function anchor_ids(doc::Pinax.Document)
    ids = Symbol[]
    for pg in doc.pages
        push!(ids, pg.id)
        append!(ids, (f.id for f in pg.figures))
        append!(ids, (t.id for t in pg.tables))
        for sec in pg.sections
            push!(ids, sec.id)
            append!(ids, (f.id for f in sec.figures))
            append!(ids, (t.id for t in sec.tables))
        end
    end
    return ids
end

function Archeion.doc_fields(
    doc::Pinax.Document; tags=String[], question=nothing, claim=nothing
)
    status = all(pg.status === :final for pg in doc.pages) ? "final" : "trial"
    fields = (; title=doc.meta.title, status, Archeion.anchors(anchor_ids(doc))...)
    isempty(tags) || (fields = merge(fields, (; tags=collect(String, tags))))
    question === nothing || (fields = merge(fields, (; question=String(question))))
    claim === nothing || (fields = merge(fields, (; claim=String(claim))))
    return fields
end

end
