// Our composite Transform Rotate idle re-grade samples geometry-derived pipe
// state from the live post-gesture mesh while T and S remain held. This is a
// characterization of the current application policy, not a parity claim.

import composite_sampling_characterization_helpers;
import std.format : format;

void main() {}

unittest {
    scope(exit) teardownCompositeCharacterization();
    auto result = characterizeCompositeSampling("rotate");
    assert(result.liveError < 3e-3 && result.baselineError > 1e-3,
        format("composite Rotate idle re-grade must keep our live-sampling policy: "
             ~ "candidates differ by %g at v%d.%s; live error=%g at v%d.%s; "
             ~ "baseline error=%g at v%d.%s; pivots baseline=(%g,%g,%g) "
             ~ "live=(%g,%g,%g)",
               result.candidateGap, result.gapVertex, result.gapComponent,
               result.liveError, result.liveErrorVertex, result.liveErrorComponent,
               result.baselineError, result.baselineErrorVertex,
               result.baselineErrorComponent,
               result.baselinePivot.x, result.baselinePivot.y,
               result.baselinePivot.z, result.livePivot.x,
               result.livePivot.y, result.livePivot.z));
}
