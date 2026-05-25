// Reference-parity suite: translate without an explicit action center,
// driven through vibe3d's move tool, across element mode (vertex/edge/
// polygon) × selection pattern (none/one/adjacent/islands). Goldens are a
// frozen reference capture; the empty-selection cases verify the
// "no selection => whole mesh" semantics, which match the reference tool
// (and differ from the /api/transform primitive's no-op).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/translate_no_acen.json");
    runParitySuite(json);
}
