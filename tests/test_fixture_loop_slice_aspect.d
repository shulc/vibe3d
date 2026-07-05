// Loop Slice Keep Aspect (task 0259: aspect). When ON, the profile's Inset is
// AUTO-DERIVED from the cut's world span so the normalized profile keeps its own
// height:width proportions, instead of using the manual Inset (depth). The rule is
// isotropic scaling: effectiveDepth = cut span (the world length of the seed rail
// the profile is pressed across), so 1 normalized profile unit maps to the same
// world distance along BOTH the along-cut and the inset axes.
//
// Analytic self-golden on a wide flat strip (middle quad 3 units wide, so the cut
// span 3 is distinct from the Inset 2). Vee profile: aspect OFF displaces the loops
// by -h*depth = [-1,-2,-1] (byte-for-byte the 0256/0258 raw-depth cut), aspect ON
// by -h*span = -h*3 = [-1.5,-3,-1.5]. Same topology (14 verts / 19 edges / 6 faces).
//
// SCOPE/HONESTY: aspect (Keep Aspect, bool) is a live-captured reference option
// (spec.json 'automatically sets the Inset value from the profile's aspect ratio',
// greyed until a Profile loads). The mapping (effectiveDepth = cut span) is DERIVED
// — the canonical aspect-preserving construction — not the exact reference formula:
// the loop-slice gesture is human-VNC-only and the profile preset library is closed
// source (see 0256), so the Vee curve is a vibe3d-defined stand-in and the reference
// geometry was NOT live-recaptured. vibe3d ships aspect DEFAULT OFF (a documented
// deviation from the reference default true) so the default tool state and every
// 0256-0258 profile cut stay byte-for-byte. Flagged in the fixture `source`.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_aspect.json");
    runTopologyDiffSuite(json);
}
