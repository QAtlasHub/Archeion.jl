module ArcheionPinaxDataVaultExt

using Archeion
using DataVault
using Pinax

# One call for the path every study repeats: render both faces of a vault, deposit them as a new
# revision of one record with the table of what was read, and get that commit to the shared
# registry. What is study-specific is the recipe and the binding; everything else is this.

# The document settings `Pinax.report` does not take. It resets the document with the title before
# calling the recipe, so a recipe that wants more has to say it itself — which every study was
# copying. `katex = :local` vendors the math assets, so a deposited revision reads with no network.
function _with_settings(recipe, title, setup)
    return function (pairs)
        Pinax.reset!(; title=title, setup...)
        return recipe(pairs)
    end
end

function Archeion.publish(
    vault::DataVault.Vault,
    recipe::Function;
    binding,
    title::AbstractString,
    out::AbstractString,
    status::Symbol,
    source_repo,
    study=nothing,
    tags=String[],
    question=nothing,
    claim=nothing,
    parents=nothing,
    external=String[],
    repro=Dict{String,String}(),
    remote::Symbol=:pr,
    observe::Bool=true,
    allow_mismatch::Bool=false,
    source_contents::Bool=true,
    setup=(; katex=:local),
)
    status in (:trial, :final) ||
        error("status must be :trial or :final (got $(repr(status)))")
    isfile(binding) || error(
        "no binding at $binding; create one with `new_binding` (once per record) and commit it",
    )
    reg = Archeion.registry_of(binding)
    Archeion.sync!(reg)
    Archeion.check_source_published(source_repo)

    rep = Pinax.report(
        vault,
        _with_settings(recipe, title, setup);
        title=title,
        out=out,
        study=study,
        observe=observe,
    )
    doc = Archeion.doc_fields(Pinax.current_document(); tags=collect(tags))
    doc.status == String(status) || @warn(
        "the document's pages say `$(doc.status)`, this deposit says `$status`; the revision " *
            "records what was passed here (SPEC §5.4: `final` presents the claims to a third party)"
    )
    fields = (; doc..., status=String(status))
    question === nothing || (fields = (; fields..., question))
    claim === nothing || (fields = (; fields..., claim))

    res = Archeion.deposit(
        binding;
        gallery=rep.gallery,
        agent=rep.agent,
        doc=fields,
        source_repo=source_repo,
        external=external,
        repro=repro,
        parents=parents,
        push=false,
        provenance=Archeion.provenance_from(
            vault, rep; allow_mismatch=allow_mismatch, source_contents=source_contents
        ),
    )
    sent = Archeion.publish_revision!(reg, res.rev, "$title ($(res.rev))"; remote=remote)
    return (; res..., rep.n, rep.reads, sent.pushed, sent.branch, sent.pr)
end

end
