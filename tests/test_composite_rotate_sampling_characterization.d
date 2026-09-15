// A composite Rotate idle re-grade preserves the frozen run map.

import composite_sampling_characterization_helpers;

void main() {}

unittest {
    scope(exit) teardownCompositeCharacterization();
    auto result = characterizeCompositeSampling("rotate");
    assert(result.liveError > 1e-3,
        "6207 Rotate re-grade witness must distinguish live-pipe sampling");
}
