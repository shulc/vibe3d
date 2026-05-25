// Reference-parity suite: rigid rotations captured from the reference engine
// with no action center (acen=none), across varied selection / drag start /
// angle / axis. Each case replays the recovered rigid rotation (explicit
// axis/angle/pivot via rotate_about -> /api/transform) and asserts vibe3d
// lands on the engine's actual post-op vertices — pinning vibe3d's rotation
// math independent of any gizmo/action-center pivot policy.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/rotate_none.json");
    runParitySuite(json);
}
