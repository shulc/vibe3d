// test_uv_untouched_faces.d — a LOCAL face-adding edit must not wipe the
// per-corner (UV) map of the faces it never touched (task 0690).
//
// The failure this pins is NOT the documented "new geometry has no UV yet"
// drop. It is one level worse: a kernel that appends faces straight into
// `faces` (bypassing `addFace`, which grows every PolyVertex map atomically)
// leaves `data.length != loops.length * dim`, and the tail `buildLoops` →
// `resizePolyVertexMaps` then makes the map length-correct by ZEROING IT
// WHOLE — the untouched half of the mesh loses its UV too. Duplicating one
// polygon must not cost the other polygon its texture coordinates.
//
// So every case here asserts BOTH halves of the contract:
//   * the pre-existing corners are byte-identical afterwards, and
//   * the appended corners are zero (the honest v1 drop for NEW geometry).
//
// `mesh.addPoint` is the exception that carries rather than zeroes: inserting
// a point on an edge is exactly the edge-split case whose law is frozen in
// tests/fixtures/uv_corner_transfer.json (task 0682) — `lerp(uv(a), uv(b), t)`
// resolved PER FACE, so a UV seam across the split edge survives as a seam.
//
// Pure-D unit test: no HTTP, no running vibe3d.

import std.conv : to;
import std.math : fabs;

import mesh : Mesh, MeshMap, MapDomain, kUvMapName,
              MeshEditBatch, kPolyBevelEditScope, insetFacesByMask,
              spikeFacesByMask;
// Task 1903 Stage F2: the polygon-bevel entries are free functions over
// `ref MeshEditBatch` in `source/mesh_ops/poly_bevel.d`, so this test opens the
// batch itself. UNRECORDED — the fixture compares MAP payloads, not an op-log.
private auto polyBevelOnce(alias kernel, Args...)(ref Mesh m, auto ref Args args) {
    auto ed = MeshEditBatch.unrecorded(m, kPolyBevelEditScope);
    auto n = kernel(ed, args);
    ed.close();
    return n;
}

import math : Vec3;

void main() {}

// --- fixture -------------------------------------------------------------
// Two quads sharing edge (1,2):
//
//   3---2---5
//   | f0| f1|
//   0---1---4
//
// UV is authored per CORNER (not per vertex) and the two faces deliberately
// DISAGREE at the shared verts 1 and 2 — that is a UV seam, and it must stay
// one. Values are distinct and non-zero so any zeroing is unmistakable.
private enum float[] kUv = [
    0.10f, 0.20f,   // loop 0 — f0 @ v0
    0.30f, 0.40f,   // loop 1 — f0 @ v1
    0.50f, 0.60f,   // loop 2 — f0 @ v2
    0.70f, 0.80f,   // loop 3 — f0 @ v3
    0.11f, 0.22f,   // loop 4 — f1 @ v1  (seam: differs from loop 1)
    0.33f, 0.44f,   // loop 5 — f1 @ v4
    0.55f, 0.66f,   // loop 6 — f1 @ v5
    0.77f, 0.88f,   // loop 7 — f1 @ v2  (seam: differs from loop 2)
];

private Mesh twoQuadsWithUv() {
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),  // 0
        Vec3(1, 0, 0),  // 1
        Vec3(1, 1, 0),  // 2
        Vec3(0, 1, 0),  // 3
        Vec3(2, 0, 0),  // 4
        Vec3(2, 1, 0),  // 5
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([1u, 4u, 5u, 2u]);
    m.buildLoops();
    m.resetSelection();

    auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv !is null, "failed to register the UV map");
    assert(uv.data.length == 16, "UV map must be sized to 8 corners * dim 2");
    uv.data = kUv.dup;
    return m;
}

private const(MeshMap)* uvOf(ref Mesh m, string what) {
    auto p = m.meshMap(kUvMapName);
    assert(p !is null, what ~ ": the UV map itself disappeared");
    return p;
}

// The map must always be length-correct for the CURRENT corner count — that
// invariant is what `resizePolyVertexMaps` enforces (by zeroing, if a kernel
// left it inconsistent), so it holds before and after the fix. It is asserted
// only to catch an out-of-step map, never as evidence of carry.
private void checkLengths(ref Mesh m, string what) {
    auto uv = uvOf(m, what);
    assert(uv.data.length == m.loops.length * 2,
           what ~ ": UV map length " ~ uv.data.length.to!string ~
           " != loops " ~ m.loops.length.to!string ~ " * 2");
}

// The two original faces still occupy corners 0..7 (every case below only
// APPENDS faces, which land after them in CSR order) — so their values must
// come back byte-identical.
private void checkOriginalCornersIntact(ref Mesh m, string what) {
    auto uv = uvOf(m, what);
    assert(uv.data.length >= 16, what ~ ": UV map shrank below the 8 original corners");
    foreach (i; 0 .. 16)
        assert(uv.data[i] == kUv[i],
               what ~ ": UV of an UNTOUCHED face was destroyed — corner slot " ~
               i.to!string ~ " is " ~ uv.data[i].to!string ~
               ", expected " ~ kUv[i].to!string);
}

// Corners of the freshly appended faces: honest v1 drop ⇒ zero, never NaN
// (float.init is NaN, so this also pins the explicit zero-fill).
private void checkAppendedCornersZero(ref Mesh m, string what) {
    auto uv = uvOf(m, what);
    foreach (i; 16 .. uv.data.length)
        assert(uv.data[i] == 0.0f,
               what ~ ": appended corner slot " ~ i.to!string ~
               " should be 0, is " ~ uv.data[i].to!string);
}

private bool[] maskFace0(ref Mesh m) {
    auto mask = new bool[](m.faces.length);
    mask[0] = true;
    return mask;
}

// --- cases ---------------------------------------------------------------

unittest { // duplicateSelectedFaces: the copy costs the other face nothing
    Mesh m = twoQuadsWithUv();
    m.selectFace(0);
    const n = m.duplicateSelectedFaces();
    assert(n == 1, "expected 1 duplicated face, got " ~ n.to!string);
    assert(m.faces.length == 3, "expected 3 faces after duplicate");
    checkLengths(m, "duplicateSelectedFaces");
    checkOriginalCornersIntact(m, "duplicateSelectedFaces");
    checkAppendedCornersZero(m, "duplicateSelectedFaces");
}

unittest { // mirror (winding-flipped clone, no weld)
    Mesh m = twoQuadsWithUv();
    const n = m.mirrorFaces(maskFace0(m), 'X', Vec3(0, 0, 0), 0.0f, true);
    assert(n == 1, "expected 1 mirrored face, got " ~ n.to!string);
    checkLengths(m, "mirrorFaces");
    checkOriginalCornersIntact(m, "mirrorFaces");
    checkAppendedCornersZero(m, "mirrorFaces");
}

unittest { // mirror with a weld pass (the clone folds onto the seam verts)
    Mesh m = twoQuadsWithUv();
    // Mirror face 0 about the plane x = 0: verts 0 and 3 sit ON the plane, so
    // the weld folds the clone back onto them — the remap path, on top of the
    // append. The originals must survive both.
    const n = m.mirrorFaces(maskFace0(m), 'X', Vec3(0, 0, 0), 0.001f, true);
    assert(n == 1, "expected 1 mirrored face, got " ~ n.to!string);
    checkLengths(m, "mirrorFaces+weld");
    checkOriginalCornersIntact(m, "mirrorFaces+weld");
    checkAppendedCornersZero(m, "mirrorFaces+weld");
}

unittest { // arrayFaces — the linear array / Clone path
    Mesh m = twoQuadsWithUv();
    const n = m.arrayFaces(maskFace0(m), 3, Vec3(0, 5, 0), 0.0f);
    assert(n == 2, "expected 2 array copies, got " ~ n.to!string);
    checkLengths(m, "arrayFaces");
    checkOriginalCornersIntact(m, "arrayFaces");
    checkAppendedCornersZero(m, "arrayFaces");
}

unittest { // radialArrayFaces
    Mesh m = twoQuadsWithUv();
    const n = m.radialArrayFaces(maskFace0(m), 4, 'Y', Vec3(0, 0, 0),
                                 6.2831853f, Vec3(0, 0, 0), 0.0f);
    assert(n == 3, "expected 3 radial copies, got " ~ n.to!string);
    checkLengths(m, "radialArrayFaces");
    checkOriginalCornersIntact(m, "radialArrayFaces");
    checkAppendedCornersZero(m, "radialArrayFaces");
}

unittest { // arrayFacesGrid — plain (no merge)
    Mesh m = twoQuadsWithUv();
    const n = m.arrayFacesGrid(maskFace0(m), 2, 2, 1,
                               Vec3(0, 5, 5), Vec3(0, 0, 0), Vec3(1, 1, 1),
                               Vec3(0, 0, 0), false, false, false, false, 0.0f);
    assert(n == 3, "expected 3 grid copies, got " ~ n.to!string);
    checkLengths(m, "arrayFacesGrid");
    checkOriginalCornersIntact(m, "arrayFacesGrid");
    checkAppendedCornersZero(m, "arrayFacesGrid");
}

unittest { // arrayFacesGrid with Merge Vertices — the weld + face-dedup tail
    Mesh m = twoQuadsWithUv();
    // Zero offset ⇒ the clone lands exactly on the source, welds onto it, and
    // the fingerprint dedup drops the now-identical face. The ORIGINALS are
    // what survives, so the map must come back exactly as authored: this case
    // covers the `faces = keptFaces` rebuild, which a tail grow alone cannot
    // save (it re-lays the whole corner space).
    const n = m.arrayFacesGrid(maskFace0(m), 2, 1, 1,
                               Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1),
                               Vec3(0, 0, 0), false, false, false, true, 0.001f);
    assert(n == 1, "expected 1 grid copy before the dedup, got " ~ n.to!string);
    assert(m.faces.length == 2,
           "the doubled face should have been deduped away, faces=" ~
           m.faces.length.to!string);
    checkLengths(m, "arrayFacesGrid+merge");
    checkOriginalCornersIntact(m, "arrayFacesGrid+merge");
}

unittest { // appendGeometry — the clipboard PASTE path
    Mesh m = twoQuadsWithUv();
    Vec3[] clipVerts = [Vec3(0, 3, 0), Vec3(1, 3, 0), Vec3(1, 4, 0), Vec3(0, 4, 0)];
    uint[][] clipFaces = [[0u, 1u, 2u, 3u]];
    const n = m.appendGeometry(clipVerts, clipFaces, [false], [0u]);
    assert(n == 1, "expected 1 pasted face, got " ~ n.to!string);
    checkLengths(m, "appendGeometry");
    checkOriginalCornersIntact(m, "appendGeometry");
    // The clipboard carries no UV channel at all, so a pasted corner has
    // nothing to carry — zero is the honest answer here, not a lost value.
    checkAppendedCornersZero(m, "appendGeometry");
}

unittest { // insetFacesByMask — CONTROL: arity-preserving in-place rewrite +
           // addFace ring quads already keeps the map length-correct, so the
           // untouched face was never at risk. Pins that this stays true.
    Mesh m = twoQuadsWithUv();
    const n = polyBevelOnce!insetFacesByMask(m, maskFace0(m), 0.2f);
    assert(n == 1, "expected 1 inset face, got " ~ n.to!string);
    checkLengths(m, "insetFacesByMask");
    auto uv = uvOf(m, "insetFacesByMask");
    // Face 1 is untouched and, since face 0 kept its arity, still sits at
    // corners 4..7.
    foreach (i; 8 .. 16)
        assert(uv.data[i] == kUv[i],
               "insetFacesByMask: untouched face 1 lost UV at slot " ~ i.to!string);
}

unittest { // spikeFacesByMask — an in-place arity change (N-gon → fan of tris)
           // re-lays the corner space, so this one relocates rather than grows.
    Mesh m = twoQuadsWithUv();
    const n = polyBevelOnce!spikeFacesByMask(m, maskFace0(m), 0.5f);
    assert(n == 1, "expected 1 spiked face, got " ~ n.to!string);
    checkLengths(m, "spikeFacesByMask");

    // Face 1 is untouched — every one of its corners must be exactly as
    // authored, wherever the rebuild put them.
    foreach (v; [1u, 4u, 5u, 2u]) {
        auto got = cornerUv(m, 1, v);
        auto want = (v == 1) ? [0.11f, 0.22f]
                  : (v == 4) ? [0.33f, 0.44f]
                  : (v == 5) ? [0.55f, 0.66f]
                             : [0.77f, 0.88f];
        near(got[0], want[0], "spike: untouched face1 u @ v" ~ v.to!string);
        near(got[1], want[1], "spike: untouched face1 v @ v" ~ v.to!string);
    }
    // The spiked face's RIM corners keep the source face's values too — only
    // the apex (a brand-new vertex with no measured law) reads zero.
    near(cornerUv(m, 0, 0)[0], 0.10f, "spike: rim u @ v0");
    near(cornerUv(m, 0, 1)[1], 0.40f, "spike: rim v @ v1");
    const uint apex = cast(uint)(m.vertices.length - 1);
    auto ap = cornerUv(m, 0, apex);
    assert(ap[0] == 0.0f && ap[1] == 0.0f,
           "spike: apex corner should be the honest zero, got " ~
           ap[0].to!string ~ "," ~ ap[1].to!string);
}

// --- mesh.addPoint: carry, not drop --------------------------------------

private uint edgeIndexOf(ref Mesh m, uint a, uint b) {
    foreach (i, e; m.edges)
        if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a))
            return cast(uint)i;
    assert(false, "edge (" ~ a.to!string ~ "," ~ b.to!string ~ ") not found");
}

// Corner value of `face` at `vertex` in the CURRENT mesh.
private float[2] cornerUv(ref Mesh m, uint fi, uint vertex) {
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null);
    const uint base = m.faceLoop[fi];
    foreach (k, v; m.faces[fi])
        if (v == vertex) {
            const size_t s = (base + k) * 2;
            return [uv.data[s], uv.data[s + 1]];
        }
    assert(false, "vertex " ~ vertex.to!string ~ " is not a corner of face " ~ fi.to!string);
}

private void near(float got, float want, string what) {
    assert(fabs(got - want) < 1e-6f,
           what ~ ": got " ~ got.to!string ~ ", want " ~ want.to!string);
}

unittest { // addEdgePoint on a BOUNDARY edge — only face 0 gains a corner
    Mesh m = twoQuadsWithUv();
    const uint ei = edgeIndexOf(m, 0, 1);
    const uint a  = m.edges[ei][0];
    const float t = 0.25f;
    const uint vi = m.addEdgePoint(ei, t);
    assert(vi != uint.max, "addEdgePoint refused a valid edge/parameter");
    checkLengths(m, "addEdgePoint(boundary)");

    // Face 1 never saw this edge: byte-identical corners.
    foreach (v; [1u, 4u, 5u, 2u]) {
        auto got = cornerUv(m, 1, v);
        auto want = (v == 1) ? [0.11f, 0.22f]
                  : (v == 4) ? [0.33f, 0.44f]
                  : (v == 5) ? [0.55f, 0.66f]
                             : [0.77f, 0.88f];
        near(got[0], want[0], "face1 u @ v" ~ v.to!string);
        near(got[1], want[1], "face1 v @ v" ~ v.to!string);
    }
    // Face 0 keeps its four original corners...
    near(cornerUv(m, 0, 0)[0], 0.10f, "face0 u @ v0");
    near(cornerUv(m, 0, 1)[0], 0.30f, "face0 u @ v1");
    near(cornerUv(m, 0, 2)[1], 0.60f, "face0 v @ v2");
    near(cornerUv(m, 0, 3)[1], 0.80f, "face0 v @ v3");
    // ...and the inserted corner is the measured lerp along the split edge.
    // `t` runs from edges[ei][0] to edges[ei][1]; normalise to the (v0 → v1)
    // direction the authored values are written in.
    const float s = (a == 0) ? t : (1.0f - t);
    auto ins = cornerUv(m, 0, vi);
    near(ins[0], 0.10f + s * (0.30f - 0.10f), "inserted corner u");
    near(ins[1], 0.20f + s * (0.40f - 0.20f), "inserted corner v");
}

unittest { // addEdgePoint on the SHARED edge — the seam must survive as a seam
    Mesh m = twoQuadsWithUv();
    const uint ei = edgeIndexOf(m, 1, 2);
    const uint a  = m.edges[ei][0];
    const float t = 0.25f;
    const uint vi = m.addEdgePoint(ei, t);
    assert(vi != uint.max, "addEdgePoint refused the shared edge");
    checkLengths(m, "addEdgePoint(shared)");
    assert(m.faces[0].length == 5 && m.faces[1].length == 5,
           "both incident faces should have gained the corner");

    const float s = (a == 1) ? t : (1.0f - t);   // fraction from v1 toward v2

    // Face 0 interpolates INSIDE ITS OWN island: (0.30,0.40) → (0.50,0.60).
    auto i0 = cornerUv(m, 0, vi);
    near(i0[0], 0.30f + s * (0.50f - 0.30f), "face0 inserted u");
    near(i0[1], 0.40f + s * (0.60f - 0.40f), "face0 inserted v");
    // Face 1 interpolates inside ITS island: (0.11,0.22) → (0.77,0.88).
    auto i1 = cornerUv(m, 1, vi);
    near(i1[0], 0.11f + s * (0.77f - 0.11f), "face1 inserted u");
    near(i1[1], 0.22f + s * (0.88f - 0.22f), "face1 inserted v");
    // The two must DISAGREE — that is the seam surviving the split.
    assert(fabs(i0[0] - i1[0]) > 1e-3f,
           "the UV seam collapsed: both faces read the same u at the new corner");

    // Every pre-existing corner is untouched on both faces.
    near(cornerUv(m, 0, 0)[0], 0.10f, "face0 u @ v0");
    near(cornerUv(m, 0, 3)[1], 0.80f, "face0 v @ v3");
    near(cornerUv(m, 1, 4)[0], 0.33f, "face1 u @ v4");
    near(cornerUv(m, 1, 5)[1], 0.66f, "face1 v @ v5");
}

unittest { // no UV map registered ⇒ every path above must stay crash-free and
           // must not conjure a map out of nothing.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();
    assert(m.meshMap(kUvMapName) is null, "fixture should carry no UV map");

    m.selectFace(0);
    assert(m.duplicateSelectedFaces() == 1, "duplicate should have run");
    // Rebuild the mask against the GROWN face list — `mirrorFaces` refuses a
    // stale-length mask, and a refused call would exercise nothing.
    assert(m.mirrorFaces(maskFace0(m), 'X', Vec3(0, 0, 0), 0.0f, true) == 1,
           "mirror should have run");
    const uint ei = edgeIndexOf(m, 0, 1);
    assert(m.addEdgePoint(ei, 0.5f) != uint.max, "addEdgePoint should have run");
    assert(m.meshMap(kUvMapName) is null, "no UV map should have appeared");
}
