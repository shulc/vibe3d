// Task 1280 — the convex-ring gap this port deliberately leaves open, declared
// rather than left invisible.
//
// The reference has two triangulators for this command. Its bare invocation
// runs a convex-only zig-zag STRIP; the ear CLIP is that strip's own fallback,
// and the clip is the only one we ported (see `Mesh.earClipRingCorners`). On a
// CONCAVE ring the strip declines and both engines end up in the clip, which is
// why every fixture we already hold agrees. On a CONVEX ring they do not, and
// nothing in the suite said so until these four cells.
//
// WHY THE QUAD IS THE ONE THAT MATTERS. At four corners the two paths emit the
// SAME two triangles, wound the same way, across the same diagonal — the strip
// walks from the corner the chooser picks, and on a quad that fixes the
// diagonal exactly as the clip's first ear does. All that differs is where each
// tuple begins:
//
//     strip     (s, s+1, s+3)   (s+2, s+3, s+1)
//     clip      (s+3, s, s+1)   (s+1, s+2, s+3)
//
// Every face comparison in `fixture_helpers.d` — this runner's, the topology
// runner's and the orbit runner's — matches rings with `ringEq`, which tries
// all n rotations. So that difference is invisible to all of them, and the quad
// reads as PARITY everywhere it appears. It appears in
// `poly_flip_triple_dirty_parity.json` eight times, and it read as parity there
// for exactly this reason. This case declares its gap in the `face_tuples`
// channel, which compares rings as sequences, and is the only place in the
// suite where the difference is asserted at all.
//
// From FIVE corners up the triangle sets themselves diverge, so the ordinary
// channel carries it. Keeping both shapes here is the point: without the quad,
// the n>=5 cells would suggest the divergence starts at five, and the reader
// would conclude a convex quad is a place where we agree. We do not — we are
// merely not looking.
//
// WHAT A GREEN RUN MEANS. Our side is re-read live and asserted verbatim, the
// reference side is frozen from the capture, and the gap between them is
// recomputed and checked against the declaration. So this reddens if our
// triangulation drifts, if the declared gap stops describing the two sides, or
// — the case worth naming — if someone ports the strip and closes it. That last
// one is not a failure: it is the signal to convert these cells to parity and
// delete the declaration. See the task 1281 card for what porting the strip
// would take.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/triangulate_convex_strip_divergence.json");
    runKnownDivergenceSuite(json);
}
