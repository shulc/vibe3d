// A composite Move idle re-grade preserves the frozen run map.

import composite_sampling_characterization_helpers;

void main() {}

unittest {
    scope(exit) teardownCompositeCharacterization();
    auto result = characterizeCompositeSampling("move");
    assert(result.liveError > 1e-3,
        "6207 Move re-grade witness must distinguish live-pipe sampling");
}
