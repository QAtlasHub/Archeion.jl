module ArcheionDataVaultExt

using Archeion
using DataVault

# `report` is what `Pinax.report` returned for this vault: its `reads` (one record per point, from
# `DataVault.load_recorded`) and `render_observation`. Where the observations and snapshots live is
# DataVault's business, so it is asked rather than assumed.
function Archeion.provenance_from(
    vault::DataVault.Vault, report; allow_mismatch::Bool=false, source_contents::Bool=true
)
    return (;
        reads=report.reads,
        observations_dir=DataVault._observations_dir(vault),
        sources_dir=DataVault._sources_dir(vault),
        render_observation=report.render_observation,
        allow_mismatch,
        source_contents,
    )
end

end
