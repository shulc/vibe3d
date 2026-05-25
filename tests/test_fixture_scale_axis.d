// Reference-parity suite: single-axis scale about the world origin, across
// element mode × selection {none,one,adjacent,islands}. Per-mode axis
// (vertices=X, edges=Y, polygons=Z). Engine-neutral (fixed pivot, no recovery,
// no drag — per-axis tool scale is mode-gated headless, so the reference value
// is the deterministic per-axis math).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/scale_axis.json");
    runParitySuite(json);
}
