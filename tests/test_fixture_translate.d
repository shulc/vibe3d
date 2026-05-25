// Reference-parity fixture pilot: proves the capture -> freeze -> vibe3d-only
// test loop. The golden is a frozen reference capture for "translate the +Y
// top face of a unit cube by +1.0 Y"; the test replays the same op in vibe3d
// and asserts it lands where the reference put it, with no external engine at
// runtime. Vertex-order differences are resolved by before-position
// correspondence in runParityFixture.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/translate_top_face_y.json");
    runParityFixture(json);
}
