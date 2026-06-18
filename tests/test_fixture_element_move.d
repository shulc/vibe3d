// Reference-parity: ElementMove (xfrm.elementMove preset) = a translate
// weighted by an ELEMENT falloff (a sphere anchored at the picked element).
// Captured from a real interactive pick+drag in the reference engine (element
// falloff cannot be driven by synthetic/headless input — only a live viewport
// pick anchors it). A 4x4x4 cube, the -X+Y-Z corner picked, element-falloff
// Range 0.5, linear shape, dragged in the screen plane; the recovered center,
// radius, and full translate are replayed through vibe3d's xfrm.elementMove
// preset (falloff type=element + dist + ACEN.userPlaced center + TX/TY/TZ) and
// vibe3d reproduces every vertex bit-for-bit. 7 verts fall inside the sphere
// (corner weight 1, ring@0.25 weight 0.5, ring@0.354 weight 0.293 = linear
// 1 - d/0.5). Built on an empty reset so the welded cube is the only geometry.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/element_move.json");
    runParitySuite(json);
}
