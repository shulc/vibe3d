// Task 1320 — the convex-ring gap task 1280 declared, now CLOSED and asserted
// as parity.
//
// The reference has two triangulators for this command. Its bare invocation
// runs a convex-only zig-zag STRIP; the ear CLIP is that strip's own fallback.
// Task 1280 ported the clip alone, so on a CONVEX ring the two engines parted
// company and these four cells declared that gap. Task 1320 ported the strip,
// so every case here now declares an EMPTY gap — which `runKnownDivergenceSuite`
// asserts exactly as strictly as a non-empty one: our live output must equal the
// frozen reference output on every channel the case carries.
//
// WHY THE QUAD IS STILL THE ONE THAT MATTERS, and why it cannot be dropped now
// that the numbers agree. At four corners the two paths emit the SAME two
// triangles, wound the same way, across the same diagonal — the strip walks from
// the corner the chooser picks, and on a quad that fixes the diagonal exactly as
// the clip's first ear does. All that differs is where each tuple begins:
//
//     strip     (s, s+1, s+3)   (s+2, s+3, s+1)
//     clip      (s+3, s, s+1)   (s+1, s+2, s+3)
//
// Every face comparison in `fixture_helpers.d` — this runner's, the topology
// runner's and the orbit runner's — matches rings with `ringEq`, which tries all
// n rotations. So a quad reads as parity in all of them WHETHER OR NOT THE PORT
// LANDED, and this case is the only thing in the suite that can tell the two
// apart: it declares its parity on the `face_tuples` channel, which compares
// rings as sequences. Delete it and nothing anywhere witnesses that the DEFAULT
// path is the one running.
//
// From FIVE corners up the triangle sets themselves diverge, so the ordinary
// channel carries those. They now carry `face_tuples` as well, so the whole file
// pins tuple starts rather than merely triangle sets.
//
// WHAT A GREEN RUN MEANS. Our side is re-read live and asserted verbatim, the
// reference side is frozen from the capture, and the gap between them is
// recomputed and checked against the declaration — which is now empty. So this
// reddens if our triangulation drifts in either direction: back to the clip on a
// convex ring, or off the strip's own law.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/triangulate_convex_strip_divergence.json");
    runKnownDivergenceSuite(json);
}
