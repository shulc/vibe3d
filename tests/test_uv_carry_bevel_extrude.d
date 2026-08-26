// test_uv_carry_bevel_extrude.d — the bevel and extrude families carry the
// per-corner UV map (task 0697), asserted against the frozen reference capture
// in tests/fixtures/uv_corner_transfer.json.
//
// Pure-D unit test (no HTTP, no running vibe3d): the fixture's `before` mesh is
// rebuilt in process — geometry AND per-corner UV authored corner by corner —
// the kernel named by the case's `op` is run on it, and every corner of the
// result is compared with the fixture's `after`.
//
// What each family's frozen law says, and which machinery it needed:
//
//   * EDGE BEVEL — every vertex the bevel creates lies ON an original edge, so
//     its value is the two-endpoint lerp at its own geometric fraction. The hard
//     part is not the lerp, it is WHOSE lerp: a chamfer strip has TWO source
//     faces, one per side, so the map carry needs a source per CORNER, not per
//     face (`Mesh.carryPolyVertexMapsByCorner`). Same for a corner cap, whose
//     corners each come from a different face's slide.
//   * FACE BEVEL — the inset ring is the source face's own UV POLYGON inset by
//     `inset * uvPerimeter / geomPerimeter`. That is COMPUTED, not blended from
//     any corner, so it rides the generated-value channel
//     (`PolyVertexGen.InsetRing`). The nonuniform case separates the
//     perimeter-ratio scale from a per-axis parametric reading.
//   * FACE EXTRUDE — two measured wall laws, selected by `UvWallLaw`: `Copy`
//     (the wall's top corner keeps its base corner's value, so the wall is
//     degenerate in UV) and `SweepU` (u = 0 on the base ring, 1 on the top, v
//     from the base corner). The cap keeps the source values verbatim in both.
//
// Matching is by vertex POSITION, never by index: these operations renumber both
// faces and corners, and our face ORDER and winding legitimately differ from the
// reference's. Faces are paired by their set of corner positions, corners inside
// a paired face by position.
//
// Before this task edge bevel and face extrude were in mesh.d's "v1 DROP set"
// (every corner of the whole mesh zeroed), and face bevel was worse than
// dropped: its cap keeps its arity and its walls come in through `addFace`, so
// the map stayed length-correct and was KEPT — the cap silently carried the
// UN-inset source values while every wall read 0.

import std.json;
import std.math : fabs, sqrt;
import std.conv : to;

import mesh : Mesh, MeshMap, MapDomain, kUvMapName, UvWallLaw,
              MeshEditBatch, kPolyBevelEditScope, bevelFacesByMask;
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

private float g_tol = 1e-6f;               // the fixture's own tolerance field
private enum float kPosEps = 1e-5f;        // position identity between meshes

private float jnum(const JSONValue v) {
    if (v.type == JSONType.integer)  return cast(float)v.integer;
    if (v.type == JSONType.uinteger) return cast(float)v.uinteger;
    return cast(float)v.floating;
}

private bool samePos(Vec3 a, const JSONValue p) {
    return fabs(a.x - jnum(p[0])) < kPosEps
        && fabs(a.y - jnum(p[1])) < kPosEps
        && fabs(a.z - jnum(p[2])) < kPosEps;
}

private bool sameVec(Vec3 a, Vec3 b) {
    return fabs(a.x - b.x) < kPosEps && fabs(a.y - b.y) < kPosEps
        && fabs(a.z - b.z) < kPosEps;
}

private string posKey(Vec3 p) {
    return p.x.to!string ~ "/" ~ p.y.to!string ~ "/" ~ p.z.to!string;
}

// Build the fixture's `before` state: geometry + a per-corner UV map authored
// straight from `corner_uv` (so a seam — two faces disagreeing at a shared
// vertex — is authored as such, not derived from a per-vertex value).
private Mesh buildBefore(const JSONValue before) {
    Mesh m;
    foreach (v; before["vertices"].array)
        m.addVertex(Vec3(jnum(v[0]), jnum(v[1]), jnum(v[2])));
    foreach (f; before["faces"].array) {
        uint[] face;
        foreach (c; f.array) face ~= cast(uint)c.integer;
        m.addFace(face);
    }
    m.rebuildEdges();
    m.buildLoops();
    auto map = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(map !is null, "UV map registration failed");
    const auto cuv = before["corner_uv"].array;
    assert(cuv.length == m.faces.length, "fixture corner_uv/faces length mismatch");
    foreach (fi; 0 .. m.faces.length) {
        const auto fc = cuv[fi].array;
        assert(fc.length == m.faces[fi].length, "fixture corner_uv arity mismatch");
        foreach (c; 0 .. m.faces[fi].length) {
            const size_t slot = (m.faceLoop[fi] + c) * 2;
            map.data[slot]     = jnum(fc[c][0]);
            map.data[slot + 1] = jnum(fc[c][1]);
        }
    }
    return m;
}

// Mask of the faces the op names by their corner POSITIONS.
private bool[] faceMask(ref Mesh m, const JSONValue faceList) {
    auto mask = new bool[](m.faces.length);
    size_t hits = 0;
    foreach (f; faceList.array) {
        foreach (fi; 0 .. m.faces.length) {
            if (m.faces[fi].length != f.array.length) continue;
            bool all = true;
            foreach (want; f.array) {
                bool hit = false;
                foreach (v; m.faces[fi]) if (samePos(m.vertices[v], want)) hit = true;
                if (!hit) { all = false; break; }
            }
            if (all) { mask[fi] = true; ++hits; }
        }
    }
    assert(hits == faceList.array.length, "op named a face the mesh does not have");
    return mask;
}

// Mask of the edges the op names by their endpoint POSITIONS.
private bool[] edgeMask(ref Mesh m, const JSONValue edgeList) {
    auto mask = new bool[](m.edges.length);
    foreach (e; edgeList.array) {
        uint a = ~0u, b = ~0u;
        foreach (vi, v; m.vertices) {
            if (samePos(v, e[0])) a = cast(uint)vi;
            if (samePos(v, e[1])) b = cast(uint)vi;
        }
        assert(a != ~0u && b != ~0u, "beveled edge endpoint not found by position");
        const uint ei = m.edgeIndex(a, b);
        assert(ei != ~0u, "beveled edge not present in the mesh");
        mask[ei] = true;
    }
    return mask;
}

// Run the case's operation. `wallOverride` forces a wall law other than the one
// the case names — used only by the anti-vacuity test below.
private size_t runOp(ref Mesh m, const JSONValue op, bool wallOverride = false,
                     UvWallLaw forced = UvWallLaw.Copy) {
    const string kind = op["kind"].str;
    if (kind == "edge_bevel")
        return m.bevelEdgesByMask(edgeMask(m, op["edges"]), jnum(op["offset"]), 0, false);
    if (kind == "face_bevel")
        return polyBevelOnce!bevelFacesByMask(m, faceMask(m, op["faces"]), jnum(op["inset"]),
                                  jnum(op["shift"]), false, 0, false);
    if (kind == "face_extrude") {
        const auto sh = op["shift"].array;
        const float dx = jnum(sh[0]), dy = jnum(sh[1]), dz = jnum(sh[2]);
        // The capture's shift is a VECTOR; our kernel takes a distance along the
        // region normal, which for these flat z=0 cases is the same magnitude.
        const float dist = sqrt(dx * dx + dy * dy + dz * dz);
        // The `uv_sweep` field is the fixture's own discriminating parameter and
        // is DRIVEN from here, not narrated: `none` and `u` are two different
        // measured laws and produce different wall values (pinned below).
        const UvWallLaw law = wallOverride ? forced
            : (op["uv_sweep"].str == "u" ? UvWallLaw.SweepU : UvWallLaw.Copy);
        return m.extrudeFacesByMask(faceMask(m, op["faces"]), dist, false, law);
    }
    assert(false, "unhandled op kind " ~ kind);
}

// Index of the fixture `after` face whose corner POSITIONS are the same set as
// our face `fi`'s. `~0u` when there is no such face.
private uint matchFace(ref Mesh m, uint fi, const JSONValue afterVerts,
                       const JSONValue afterFaces) {
    foreach (afi, af; afterFaces.array) {
        const auto ac = af.array;
        if (ac.length != m.faces[fi].length) continue;
        bool[size_t] used;
        bool all = true;
        foreach (c; 0 .. m.faces[fi].length) {
            const Vec3 p = m.vertices[m.faces[fi][c]];
            bool hit = false;
            foreach (k, av; ac) {
                if (k in used) continue;
                if (samePos(p, afterVerts[cast(size_t)av.integer])) {
                    used[k] = true; hit = true; break;
                }
            }
            if (!hit) { all = false; break; }
        }
        if (all) return cast(uint)afi;
    }
    return ~0u;
}

// Corner index inside fixture face `afi` sitting at position `p`.
private uint matchCorner(const JSONValue afterVerts, const JSONValue afterFace,
                         Vec3 p) {
    foreach (k, av; afterFace.array)
        if (samePos(p, afterVerts[cast(size_t)av.integer])) return cast(uint)k;
    return ~0u;
}

// Our UV at (face fi, corner c).
private float[2] uvAt(ref Mesh m, MeshMap* map, uint fi, size_t c) {
    const size_t slot = (m.faceLoop[fi] + c) * 2;
    float[2] r;
    r[0] = map.data[slot]; r[1] = map.data[slot + 1];
    return r;
}

// One fixture case compared corner for corner against the frozen `after`.
// `skipFaces` names faces (by their corner position sets) whose values are
// asserted elsewhere — the seam case's two divergences.
private void runParityCase(const JSONValue c, const Vec3[][] skipFaces = null) {
    const string name = c["name"].str;
    Mesh m = buildBefore(c["before"]);
    const size_t n = runOp(m, c["op"]);
    assert(n > 0, name ~ ": kernel reported a no-op");

    const auto after      = c["after"];
    const auto afterVerts = after["vertices"];
    const auto afterFaces = after["faces"];
    const auto afterUv    = after["corner_uv"];

    // Geometry first — if the operation landed somewhere else, a UV comparison
    // would be meaningless (and a green run would prove nothing).
    assert(m.vertices.length == afterVerts.array.length,
           name ~ ": vertex count " ~ m.vertices.length.to!string ~ " != frozen "
                ~ afterVerts.array.length.to!string);
    assert(m.faces.length == afterFaces.array.length,
           name ~ ": face count " ~ m.faces.length.to!string ~ " != frozen "
                ~ afterFaces.array.length.to!string);

    auto map = m.meshMap(kUvMapName);
    assert(map !is null, name ~ ": UV map lost by the operation");
    assert(map.data.length == m.loops.length * 2,
           name ~ ": UV map length " ~ map.data.length.to!string
                ~ " != loops*2 " ~ (m.loops.length * 2).to!string);

    size_t compared = 0, moved = 0, skipped = 0;
    foreach (fi; 0 .. cast(uint)m.faces.length) {
        bool skip = false;
        foreach (sf; skipFaces) {
            if (sf.length != m.faces[fi].length) continue;
            bool all = true;
            foreach (want; sf) {
                bool hit = false;
                foreach (v; m.faces[fi]) if (sameVec(m.vertices[v], want)) hit = true;
                if (!hit) { all = false; break; }
            }
            if (all) { skip = true; break; }
        }
        if (skip) { ++skipped; continue; }

        const uint afi = matchFace(m, fi, afterVerts, afterFaces);
        assert(afi != ~0u,
               name ~ ": our face " ~ fi.to!string
                    ~ " has no frozen counterpart (geometry diverged)");
        foreach (cIdx; 0 .. m.faces[fi].length) {
            const Vec3 p = m.vertices[m.faces[fi][cIdx]];
            const uint ac = matchCorner(afterVerts, afterFaces[afi], p);
            assert(ac != ~0u, name ~ ": corner position not found in frozen face");
            const float wantU = jnum(afterUv[afi][ac][0]);
            const float wantV = jnum(afterUv[afi][ac][1]);
            const float[2] got = uvAt(m, map, fi, cIdx);
            assert(fabs(got[0] - wantU) < g_tol && fabs(got[1] - wantV) < g_tol,
                   name ~ ": face " ~ fi.to!string ~ " corner at " ~ posKey(p)
                        ~ " uv (" ~ got[0].to!string ~ ", " ~ got[1].to!string
                        ~ ") != frozen (" ~ wantU.to!string ~ ", "
                        ~ wantV.to!string ~ ")");
            ++compared;
            if (fabs(wantU) > g_tol || fabs(wantV) > g_tol) ++moved;
        }
    }
    assert(skipped == skipFaces.length,
           name ~ ": expected to skip " ~ skipFaces.length.to!string
                ~ " named faces, skipped " ~ skipped.to!string);
    // Guard against a vacuous pass: the frozen state must actually carry
    // non-zero UV, otherwise "we match the fixture" would also hold for the drop
    // behaviour this task replaced.
    assert(moved == compared,
           name ~ ": frozen state has zero-valued corners — the comparison "
                ~ "cannot distinguish carry from drop");
    assert(compared > 0, name ~ ": nothing compared");
}

private JSONValue g_fx;

private JSONValue caseNamed(string name) {
    foreach (c; g_fx["cases"].array)
        if (c["name"].str == name) return c;
    assert(false, "no frozen case named " ~ name);
}

private void loadFixture() {
    enum string json = import("fixtures/uv_corner_transfer.json");
    g_fx = parseJSON(json);
    if ("tolerance" in g_fx) g_tol = jnum(g_fx["tolerance"]);
}

unittest { // every frozen bevel/extrude case except the seam divergence
    loadFixture();
    size_t ran = 0;
    foreach (c; g_fx["cases"].array) {
        const string kind = c["op"]["kind"].str;
        if (kind != "edge_bevel" && kind != "face_bevel" && kind != "face_extrude")
            continue;
        if (c["name"].str == "edge_bevel_uv_seam") continue;  // its own test below
        runParityCase(c);
        ++ran;
    }
    assert(ran == 8, "expected 8 frozen parity cases (3 edge bevel, 3 face bevel, "
                   ~ "2 face extrude), ran " ~ ran.to!string);
}

// --- the seam: parity everywhere except two named, PERMANENT divergences ----
//
// The reference does not reproduce both islands on the geometry a bevel creates
// at a seam: the chamfer strip takes ONE island on both sides (the far side
// extrapolated across the seam) and the two corner caps get values matching
// neither island. Its own capture note flags this as measured-not-endorsed. We
// diverge deliberately — a per-corner source is exactly what lets each side of
// the strip stay in its own island — so these are marked `permanent` in the
// fixture's `classification.divergences`, not as gaps to be closed.
//
// The shape of the assertions follows the divergence contract: check that we
// still DIFFER from the frozen value FIRST (that is the marker), then that we
// equal what our own law says, then that everything else on the same read is at
// live parity (10 of the 12 faces, plus the strip's near side) so the divergence
// rows cannot be vacuously green on a broken channel.
unittest {
    loadFixture();
    const auto c  = caseNamed("edge_bevel_uv_seam");
    const auto div = g_fx["classification"]["divergences"];

    // A `permanent` entry must never sprout an open/closed branch: converting one
    // means deciding to reproduce a defect, which needs a fresh capture and a
    // deliberate edit here, not a silent status flip.
    foreach (key; ["seam_strip_far_side", "seam_corner_caps"]) {
        const string st = div[key]["status"].str;
        assert(st == "permanent" || st == "open" || st == "closed",
               key ~ ": unknown divergence status token '" ~ st ~ "'");
        assert(st == "permanent",
               key ~ ": status is '" ~ st ~ "', but this test only knows how to "
               ~ "assert a PERMANENT divergence. Reproducing the reference here "
               ~ "would collapse a user's UV seam onto one island — if that is "
               ~ "really the decision, re-measure and rewrite this test.");
    }

    Mesh m = buildBefore(c["before"]);
    assert(runOp(m, c["op"]) > 0, "seam: kernel reported a no-op");
    auto map = m.meshMap(kUvMapName);
    assert(map !is null, "seam: UV map lost");

    // The before-state's two islands, read straight off the fixture's authored
    // corners: the LEFT faces carry the ordinary quadratic UV, the RIGHT faces a
    // different parameterisation, and they disagree at the shared vertices.
    float[2] uvIn(const JSONValue before, Vec3 facePos0, Vec3 facePos1,
                  Vec3 facePos2, Vec3 facePos3, Vec3 at) {
        const auto verts = before["vertices"];
        const auto faces = before["faces"];
        const Vec3[4] want = [facePos0, facePos1, facePos2, facePos3];
        foreach (fi, f; faces.array) {
            if (f.array.length != 4) continue;
            bool all = true;
            foreach (w; want) {
                bool hit = false;
                foreach (av; f.array)
                    if (samePos(w, verts[cast(size_t)av.integer])) hit = true;
                if (!hit) { all = false; break; }
            }
            if (!all) continue;
            foreach (k, av; f.array)
                if (samePos(at, verts[cast(size_t)av.integer])) {
                    float[2] r;
                    r[0] = jnum(before["corner_uv"][fi][k][0]);
                    r[1] = jnum(before["corner_uv"][fi][k][1]);
                    return r;
                }
        }
        assert(false, "seam: no before-face with those four corners");
    }
    float[2] lerpUv(float[2] a, float[2] b, float t) {
        float[2] r;
        r[0] = a[0] + t * (b[0] - a[0]);
        r[1] = a[1] + t * (b[1] - a[1]);
        return r;
    }

    const auto before = c["before"];
    // The two faces that meet at the beveled edge (1,1)-(1,2).
    const Vec3 L0 = Vec3(0,1,0), L1 = Vec3(1,1,0), L2 = Vec3(1,2,0), L3 = Vec3(0,2,0);
    const Vec3 R0 = Vec3(1,1,0), R1 = Vec3(2,1,0), R2 = Vec3(2,2,0), R3 = Vec3(1,2,0);
    // Faces below/above the edge, used by the corner caps.
    const Vec3 B0 = Vec3(1,0,0), B1 = Vec3(2,0,0), B2 = Vec3(2,1,0), B3 = Vec3(1,1,0);
    const Vec3 T0 = Vec3(0,2,0), T1 = Vec3(1,2,0), T2 = Vec3(1,3,0), T3 = Vec3(0,3,0);
    enum float t = 0.2f;   // the op's offset over the (unit) edge length

    // Every new vertex, with the island our kernel reads it in and the lerp that
    // island produces. This IS our law, spelled out — not a frozen literal.
    struct Want { Vec3 p; float[2] uv; }
    Want[] leftStrip = [
        Want(Vec3(0.8f,1,0), lerpUv(uvIn(before,L0,L1,L2,L3,Vec3(1,1,0)),
                                    uvIn(before,L0,L1,L2,L3,Vec3(0,1,0)), t)),
        Want(Vec3(0.8f,2,0), lerpUv(uvIn(before,L0,L1,L2,L3,Vec3(1,2,0)),
                                    uvIn(before,L0,L1,L2,L3,Vec3(0,2,0)), t)),
    ];
    Want[] rightStrip = [
        Want(Vec3(1.2f,1,0), lerpUv(uvIn(before,R0,R1,R2,R3,Vec3(1,1,0)),
                                    uvIn(before,R0,R1,R2,R3,Vec3(2,1,0)), t)),
        Want(Vec3(1.2f,2,0), lerpUv(uvIn(before,R0,R1,R2,R3,Vec3(1,2,0)),
                                    uvIn(before,R0,R1,R2,R3,Vec3(2,2,0)), t)),
    ];
    // The caps' third corner slides along the edge that leaves the seam: at
    // (1,1) downward into the RIGHT-island face below, at (1,2) upward into the
    // LEFT-island face above. Which of the two adjacent faces a cap corner reads
    // is our deterministic choice (the slot's own face f_k); changing it is a
    // legitimate but DELIBERATE change and must land here.
    const Want capBelow = Want(Vec3(1,0.8f,0),
        lerpUv(uvIn(before,B0,B1,B2,B3,Vec3(1,1,0)),
               uvIn(before,B0,B1,B2,B3,Vec3(1,0,0)), t));
    const Want capAbove = Want(Vec3(1,2.2f,0),
        lerpUv(uvIn(before,T0,T1,T2,T3,Vec3(1,2,0)),
               uvIn(before,T0,T1,T2,T3,Vec3(1,3,0)), t));

    const auto after      = c["after"];
    const auto afterVerts = after["vertices"];
    const auto afterFaces = after["faces"];
    const auto afterUv    = after["corner_uv"];

    // The three faces that carry the divergence, by their corner positions.
    const Vec3[] stripFace = [Vec3(0.8f,1,0), Vec3(1.2f,1,0),
                              Vec3(1.2f,2,0), Vec3(0.8f,2,0)];
    const Vec3[] capA      = [Vec3(0.8f,1,0), Vec3(1,0.8f,0), Vec3(1.2f,1,0)];
    const Vec3[] capB      = [Vec3(1,2.2f,0), Vec3(0.8f,2,0), Vec3(1.2f,2,0)];

    bool isFace(uint fi, const Vec3[] want) {
        if (m.faces[fi].length != want.length) return false;
        foreach (w; want) {
            bool hit = false;
            foreach (v; m.faces[fi]) if (sameVec(m.vertices[v], w)) hit = true;
            if (!hit) return false;
        }
        return true;
    }

    size_t differed = 0, matchedOurLaw = 0, agreedWithReference = 0;
    foreach (fi; 0 .. cast(uint)m.faces.length) {
        const bool strip = isFace(fi, stripFace);
        const bool cap   = isFace(fi, capA) || isFace(fi, capB);
        if (!strip && !cap) continue;
        const uint afi = matchFace(m, fi, afterVerts, afterFaces);
        assert(afi != ~0u, "seam: divergent face has no frozen counterpart");
        foreach (cIdx; 0 .. m.faces[fi].length) {
            const Vec3 p = m.vertices[m.faces[fi][cIdx]];
            const uint ac = matchCorner(afterVerts, afterFaces[afi], p);
            assert(ac != ~0u, "seam: corner position not found in frozen face");
            const float refU = jnum(afterUv[afi][ac][0]);
            const float refV = jnum(afterUv[afi][ac][1]);
            const float[2] got = uvAt(m, map, fi, cIdx);

            // Our expectation for this corner, from the table above.
            float[2] want; bool haveWant = false;
            foreach (w; leftStrip ~ rightStrip ~ [capBelow, capAbove])
                if (sameVec(p, w.p)) { want = w.uv; haveWant = true; }
            assert(haveWant, "seam: unexpected corner at " ~ posKey(p)
                           ~ " on a divergent face");

            const bool same = fabs(got[0] - refU) < g_tol
                           && fabs(got[1] - refV) < g_tol;
            if (same) ++agreedWithReference; else ++differed;
            assert(fabs(got[0] - want[0]) < g_tol
                && fabs(got[1] - want[1]) < g_tol,
                   "seam: corner at " ~ posKey(p) ~ " uv ("
                 ~ got[0].to!string ~ ", " ~ got[1].to!string
                 ~ ") is not the island lerp our law asks for ("
                 ~ want[0].to!string ~ ", " ~ want[1].to!string ~ ")");
            ++matchedOurLaw;
        }
    }
    // The marker itself: we must still differ from the reference somewhere here,
    // or the divergence is closed and its `permanent` entries are wrong.
    assert(differed >= 6,
           "seam: only " ~ differed.to!string ~ " corners differ from the frozen "
         ~ "reference — the divergence marked PERMANENT in the fixture has "
         ~ "narrowed or closed. Re-read classification.divergences before "
         ~ "editing anything.");
    // …and we must still AGREE on the strip's near side, or the "differs" above
    // could be produced by any garbage.
    assert(agreedWithReference == 2,
           "seam: expected the strip's near-side corners to agree with the "
         ~ "reference, saw " ~ agreedWithReference.to!string ~ " agreements");
    assert(matchedOurLaw == 10, "seam: expected 10 divergent-face corners, saw "
                              ~ matchedOurLaw.to!string);

    // Live parity on the same read: every OTHER face of this very case must match
    // the frozen capture corner for corner. Without this the divergence rows
    // would pass just as well on a broken carry.
    runParityCase(c, [stripFace, capA, capB]);
}

// --- the wall law is a real choice, driven from the fixture -----------------
unittest {
    loadFixture();
    // The two extrude cases differ ONLY in `uv_sweep`, so if the parameter were
    // ignored one of them would have to fail. Prove it directly: run the swept
    // case's op under the OTHER law and require a mismatch.
    const auto c = caseNamed("face_extrude_uv_sweep_u");
    Mesh m = buildBefore(c["before"]);
    assert(runOp(m, c["op"], true, UvWallLaw.Copy) > 0, "no-op");
    auto map = m.meshMap(kUvMapName);

    const auto after      = c["after"];
    const auto afterVerts = after["vertices"];
    const auto afterFaces = after["faces"];
    const auto afterUv    = after["corner_uv"];
    size_t mismatches = 0;
    foreach (fi; 0 .. cast(uint)m.faces.length) {
        const uint afi = matchFace(m, fi, afterVerts, afterFaces);
        if (afi == ~0u) continue;
        foreach (cIdx; 0 .. m.faces[fi].length) {
            const Vec3 p = m.vertices[m.faces[fi][cIdx]];
            const uint ac = matchCorner(afterVerts, afterFaces[afi], p);
            if (ac == ~0u) continue;
            const float[2] got = uvAt(m, map, fi, cIdx);
            if (fabs(got[0] - jnum(afterUv[afi][ac][0])) > g_tol
             || fabs(got[1] - jnum(afterUv[afi][ac][1])) > g_tol) ++mismatches;
        }
    }
    assert(mismatches > 0,
           "the swept case's frozen values are reproduced by the COPY law too — "
         ~ "`uv_sweep` would then be selecting nothing and both extrude cases "
         ~ "would be one case");
}

// --- faces the operation never touched keep their corners BIT-identically ---
unittest {
    loadFixture();
    // A tolerance comparison against the fixture cannot see a 1-ulp drift, and a
    // kernel that rebuilt every corner from a re-projection would still pass it.
    // Assert exact equality against what we ourselves authored, for the faces
    // that are none of the operation's business. This is the 0690 failure mode:
    // a local edit charging the WHOLE mesh.
    foreach (name; ["edge_bevel_offset02", "face_bevel_connected",
                    "face_extrude_uv_sweep_u"]) {
        const auto c = caseNamed(name);
        Mesh m = buildBefore(c["before"]);
        auto pre = m.meshMap(kUvMapName);

        // Faces with no corner in the operation's neighbourhood: everything at
        // x >= 2 in these layouts (the ops all act around x = 1).
        float[2][string] want;
        size_t untouched = 0;
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            bool near = false;
            foreach (v; m.faces[fi]) if (m.vertices[v].x < 1.99f) near = true;
            if (near) continue;
            ++untouched;
            foreach (cIdx; 0 .. m.faces[fi].length) {
                const size_t slot = (m.faceLoop[fi] + cIdx) * 2;
                want[posKey(m.vertices[m.faces[fi][cIdx]])] =
                    [pre.data[slot], pre.data[slot + 1]];
            }
        }
        assert(untouched >= 2, name ~ ": expected untouched faces in this layout");

        assert(runOp(m, c["op"]) > 0, name ~ ": no-op");
        auto post = m.meshMap(kUvMapName);
        size_t checked = 0;
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            // A face is one of the untouched originals only if EVERY corner is a
            // pre-op corner we recorded. That excludes the walls, whose far side
            // is at x >= 2 as well but whose top ring is brand new.
            bool original = true;
            foreach (v; m.faces[fi])
                if (posKey(m.vertices[v]) !in want) { original = false; break; }
            if (!original) continue;
            foreach (cIdx; 0 .. m.faces[fi].length) {
                const string k = posKey(m.vertices[m.faces[fi][cIdx]]);
                auto w = k in want;
                if (w is null) continue;
                const size_t slot = (m.faceLoop[fi] + cIdx) * 2;
                assert(post.data[slot]     == (*w)[0]
                    && post.data[slot + 1] == (*w)[1],
                       name ~ ": untouched corner at " ~ k ~ " changed: ("
                     ~ post.data[slot].to!string ~ ", "
                     ~ post.data[slot + 1].to!string ~ ") != ("
                     ~ (*w)[0].to!string ~ ", " ~ (*w)[1].to!string ~ ")");
                ++checked;
            }
        }
        assert(checked >= 8, name ~ ": expected at least 8 untouched corners, saw "
                           ~ checked.to!string);
    }
}

// --- a mesh with NO per-corner map is unaffected (and must not crash) -------
unittest {
    import mesh : makeCube;
    foreach (which; 0 .. 3) {
        Mesh m = makeCube();
        m.buildLoops();
        assert(m.meshMap(kUvMapName) is null, "makeCube should register no UV map");
        auto fmask = new bool[](m.faces.length);
        fmask[0] = true;
        auto emask = new bool[](m.edges.length);
        emask[0] = true;
        size_t n;
        if (which == 0)      n = m.bevelEdgesByMask(emask, 0.2f, 0, false);
        else if (which == 1) n = polyBevelOnce!bevelFacesByMask(m, fmask, 0.2f, 0.1f, false, 0, false);
        else                 n = m.extrudeFacesByMask(fmask, 0.5f, false);
        assert(n > 0, "cube op should apply");
        assert(m.meshMap(kUvMapName) is null, "no UV map should have appeared");
    }
}
