// Reference-parity: flare = push-along-(smooth)normals + linear falloff
// (xfrm.flare preset). A seg-4 cube is pushed along each vertex's smooth normal
// — the uniform average of incident face normals (the reference engine's
// default; per-vertex-type: face=axis, edge=45°, corner=diagonal) — by
// dist × linear-weight; every vertex is asserted against the frozen reference.
// Push is linear in weight (v + w·dist·normal). A plain seg cube (no
// subdivision) keeps the topology — hence the uniform-average normals —
// identical in both engines (a Catmull-Clark mesh leaves a ~0.3° normal
// residual from differing subdivision connectivity, documented separately).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/flare.json");
    runParitySuite(json);
}
