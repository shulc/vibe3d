// Task 1054 §3.7 -- Loop Slice "Slice Selected" BAND WALK, the reference's
// own DELIBERATE, NOT-reproduced divergence (F2, doc/
// loop_slice_corner_plan.md §5 Phase 3 / §6). A chain terminal whose derived
// side faces a selected polygon that does not itself cut the shared edge
// gets a SECOND, frame-mirrored vertex in the reference -- a T-junction, and
// a non-manifold result (Euler 1 instead of 2) on exactly these 7 of the
// 54-case corpus. Our rail cache yields exactly one vertex per undirected
// cut edge ("first creator wins"), so we stay watertight (Euler 2) where the
// reference does not -- a DECIDED divergence (plan §3.7), not a bug: shipping
// the reference's T-junction would mean deliberately corrupting the mesh
// kernel's own watertight contract to match a non-manifold reference output.
//
// This is NOT a parity test. A green run here means: our output still
// matches its recorded prediction, the reference golden is still what it
// was measured to be, and the gap between them is EXACTLY the declared
// delta (our V = ref V-1, our E = ref E-2, F unchanged, one missing vertex,
// nothing extra -- see runKnownDivergenceSuite). If the gap ever narrows OR
// widens this suite goes red -- including if someone closes it, which is
// the moment this file should be retired into the F1 parity fixture.
//
// `vibe3d_current` is DERIVED (predict_ours.py's documented rail-cache law),
// not read off a running binary -- pre-registered per plan §3.7 before Phase
// 3 code existed. The Phase 3 kernel run reproduced it exactly (see task log).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_band_divergence.json");
    runKnownDivergenceSuite(json);
}
