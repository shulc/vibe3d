// Pure tests for the depth half of `Mesh.visibleVertices`'s occlusion gate.
//
// The gate has two independently-owned halves:
//
//   * WHO may occlude (the occluder set) — not exercised here; these fixtures
//     keep the occluder and the candidate in the same `Mesh`, which is what
//     the current occluder set supports.
//   * WHAT the depth compare decides once an occluder's surface has been hit.
//     That is what this file pins:
//       - the compare is STRICT: a candidate behind the occluder is culled
//         with no tolerance of its own,
//       - a separate COINCIDENCE EXEMPTION keeps a candidate that sits on the
//         occluder's hit point, with a tolerance RELATIVE to the candidate's
//         own largest coordinate — `max(maxabs(C) / 3_360_000, 1e-10)` — and
//         it SHORT-CIRCUITS the depth compare.
//
// Every fixture below is a two-quad mesh viewed down -Z from (0,0,10):
// a large occluder quad in the plane z = 0, and a small four-vertex "probe"
// quad at z = -delta whose projection lands well inside the occluder. Both
// quads are wound so their normals point at the eye (+Z), so both are
// front-facing and every vertex enters the gate as a live candidate; the
// probe's own face never occludes its own corners.
//
// The knob is `delta`, and every prediction below is stated as the two
// world-space quantities the gate actually compares:
//   |H - C| = (1 - t) * |C - eye|   — how far the probe sits behind the hit
//   tol     = maxabs(C) / 3_360_000 — the coincidence tolerance at C

import std.format : format;
import std.math : PI, sqrt, fabs;

import math : Vec3, Viewport, ModelSpace, lookAt, perspectiveMatrix;
import mesh : Mesh;

void main() {}

private enum float EYE_Z = 10.0f;
private enum float OCC_HALF = 3.0f;   // occluder quad spans [-3, 3] in x and y
private enum float PROBE_LO = 0.9f;   // probe quad spans [0.9, 1.0] in x and y
private enum float PROBE_HI = 1.0f;

private Viewport testViewport() {
    Viewport vp;
    vp.eye    = Vec3(0, 0, EYE_Z);
    vp.focus  = Vec3(0, 0, 0);
    vp.view   = lookAt(vp.eye, vp.focus, Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f, 800.0f / 600.0f,
                                  0.1f, 5000.0f);
    vp.width  = 800;
    vp.height = 600;
    return vp;
}

// Occluder quad (verts 0..3) in the plane z = 0, probe quad (verts 4..7) at
// z = -delta. Winding is CCW seen from +Z, so `cross(v1-v0, v2-v0)` is +Z and
// both faces are front-facing from an eye on +Z.
private Mesh twoQuads(float delta) {
    Mesh m;
    const float a = OCC_HALF;
    const float z = -delta;
    m.vertices = [
        Vec3(-a, -a, 0), Vec3(a, -a, 0), Vec3(a, a, 0), Vec3(-a, a, 0),
        Vec3(PROBE_LO, PROBE_LO, z), Vec3(PROBE_HI, PROBE_LO, z),
        Vec3(PROBE_HI, PROBE_HI, z), Vec3(PROBE_LO, PROBE_HI, z),
    ];
    m.addFace([0, 1, 2, 3]);
    m.addFace([4, 5, 6, 7]);
    m.buildLoops();
    return m;
}

// The two quantities the gate compares, for probe corner `vi` of `m`.
// Mirrors the gate's own algebra so a failure message can say WHY.
private void probeQuantities(const ref Mesh m, size_t vi,
                             out double distHC, out double tol)
{
    const Vec3 c = m.vertices[vi];
    const double ex = 0.0, ey = 0.0, ez = EYE_Z;
    const double dx = cast(double)c.x - ex;
    const double dy = cast(double)c.y - ey;
    const double dz = cast(double)c.z - ez;
    const double lenDir = sqrt(dx * dx + dy * dy + dz * dz);
    // Occluder plane is z = 0, so t = ez / (ez - c.z) and 1 - t = -c.z/(ez-c.z).
    const double oneMinusT = (-cast(double)c.z) / (ez - cast(double)c.z);
    distHC = fabs(oneMinusT) * lenDir;
    double ma = fabs(cast(double)c.x);
    if (fabs(cast(double)c.y) > ma) ma = fabs(cast(double)c.y);
    if (fabs(cast(double)c.z) > ma) ma = fabs(cast(double)c.z);
    tol = ma / 3_360_000.0;
    if (tol < 1e-10) tol = 1e-10;
}

private string report(const ref Mesh m, const bool[] vis) {
    string s;
    foreach (vi; 4 .. 8) {
        double d, t;
        probeQuantities(m, vi, d, t);
        s ~= format("\n  v%d vis=%s |H-C|=%.6g tol=%.6g", vi, vis[vi], d, t);
    }
    return s;
}

unittest {
    // Sanity: with the probe clearly IN FRONT of the occluder plane nothing is
    // culled, and with it clearly BEHIND everything is. Neither reading
    // changed in this port; they pin that the compare was not inverted.
    auto vp = testViewport();

    auto inFront = twoQuads(-0.5f);           // z = +0.5, between eye and plane
    auto visFront = inFront.visibleVertices(vp.eye, vp, ModelSpace.world());
    foreach (vi; 0 .. 8)
        assert(visFront[vi],
            "nothing may be culled when the probe is in front" ~ report(inFront, visFront));

    auto behind = twoQuads(0.5f);             // z = -0.5, behind the plane
    auto visBehind = behind.visibleVertices(vp.eye, vp, ModelSpace.world());
    foreach (vi; 4 .. 8)
        assert(!visBehind[vi],
            "a probe half a unit behind the occluder must be culled"
            ~ report(behind, visBehind));
    foreach (vi; 0 .. 4)
        assert(visBehind[vi], "the occluder's own corners must survive");
}

unittest {
    // THE EPSILON. delta = 1e-4 puts the probe 1.0e-4 behind the hit point,
    // i.e. 1e-5 of the eye-to-vertex distance. That is INSIDE the 1e-4
    // relative epsilon the depth compare used to carry, so the old gate kept
    // these four corners. The reference puts no epsilon on the compare at
    // all, and 1.0e-4 is ~360x the coincidence tolerance at these
    // coordinates (~2.8e-7), so the exemption does not rescue them either.
    auto vp = testViewport();
    auto m = twoQuads(1e-4f);
    auto vis = m.visibleVertices(vp.eye, vp, ModelSpace.world());

    foreach (vi; 4 .. 8) {
        double d, tol;
        probeQuantities(m, vi, d, tol);
        assert(d > tol * 100.0,
            "fixture drifted: the probe must sit far outside the coincidence"
            ~ " tolerance" ~ report(m, vis));
        assert(!vis[vi],
            "a candidate strictly behind the occluder must be culled; the"
            ~ " depth compare carries no epsilon of its own" ~ report(m, vis));
    }
}

unittest {
    // THE COINCIDENCE EXEMPTION, both sides of its threshold. The tolerance is
    // relative to the CANDIDATE's largest coordinate, so with the probe at
    // |x|,|y| in [0.9, 1.0] it is 2.68e-7 .. 2.98e-7 — and the lever that
    // reaches it is how close the probe sits to the hit point, not how far
    // away the camera is.
    auto vp = testViewport();

    // delta = 1e-7  ->  |H-C| ~ 1.01e-7, about 2.7x INSIDE the tolerance.
    auto near = twoQuads(1e-7f);
    auto visNear = near.visibleVertices(vp.eye, vp, ModelSpace.world());
    foreach (vi; 4 .. 8) {
        double d, tol;
        probeQuantities(near, vi, d, tol);
        assert(d < tol,
            "fixture drifted: this rung must be inside the tolerance"
            ~ report(near, visNear));
        assert(visNear[vi],
            "a candidate coincident with the occluder's hit point is kept by"
            ~ " the exemption even though the depth compare would cull it"
            ~ report(near, visNear));
    }

    // delta = 1e-6  ->  |H-C| ~ 1.01e-6, about 3.4x OUTSIDE it. Still 100x
    // inside the epsilon the old compare carried, so this rung is what
    // separates "no epsilon + an exemption" from "a relative epsilon".
    auto far = twoQuads(1e-6f);
    auto visFar = far.visibleVertices(vp.eye, vp, ModelSpace.world());
    foreach (vi; 4 .. 8) {
        double d, tol;
        probeQuantities(far, vi, d, tol);
        assert(d > tol,
            "fixture drifted: this rung must be outside the tolerance"
            ~ report(far, visFar));
        assert(!visFar[vi],
            "once past the coincidence tolerance the strict depth compare"
            ~ " culls, with nothing else to catch the candidate"
            ~ report(far, visFar));
    }
}

unittest {
    // Coplanar neighbour: the probe lies EXACTLY in the occluder's plane, so
    // the compare's two distances are equal to the last bit and |H - C| is 0.
    // This is the configuration a flat multi-face surface produces at every
    // shared vertex, and it must never be culled.
    //
    // Note which clause actually saves it: the exemption, not the boundary of
    // the depth compare. Because our ray is cast THROUGH the candidate,
    // |O-C| == |O-H| implies H == C, so the exemption (|H-C| = 0 <= tol) always
    // fires first. See the gate's own comment in source/mesh.d.
    auto vp = testViewport();
    auto m = twoQuads(0.0f);
    auto vis = m.visibleVertices(vp.eye, vp, ModelSpace.world());
    foreach (vi; 0 .. 8)
        assert(vis[vi],
            "a candidate exactly on the occluder's plane must survive"
            ~ report(m, vis));
}

// ---------------------------------------------------------------------------
// Task 0576/0577 — the OTHER half of this gate: it has a FACING term, and that
// term is decided by winding alone, not by anything being in the way.
//
// This file's header says the occluder-set half is "not exercised here". It is
// now, for the one clause that matters to the wireframe question, because the
// record was wrong in BOTH directions within four days:
//
//   * task 0566 asserted a facing cull lives in the FACE PICKER. It does not —
//     `bvh_pick.pickFace` is a nearest-hit ray-cast with no normal in it, and
//     task 0576 pinned that in `source/bvh_pick.d`.
//   * task 0576 then generalised that reading to "there is no facing term
//     anywhere in picking". That is also false. It is right about the pickers
//     it grepped (`bvh_pick.d`, `gpu_select.d`) and wrong about the rest of the
//     tree: the front-facing dot below is live in `Mesh.visibleVertices`
//     (`source/mesh.d`, feeding snap via `source/snap.d`), is repeated verbatim
//     at `source/snap.d`'s own `faceVisible`, and again — twice — in the LASSO
//     POLYGON branch of `source/app.d`.
//
// Why no existing test caught either claim: every fixture that touches facing
// uses a CLOSED CUBE (`tests/test_toolpipe_snap.d`'s `occludedSnap`), and on a
// closed solid a back-facing face is ALSO occluded. The two rules agree on every
// such fixture, so those tests pass under either one and distinguish nothing.
//
// An OPEN mesh is what separates them. One quad, nothing else in the scene:
//   * a DEPTH rule keeps its corners under either winding — nothing is in front
//     of them;
//   * a FACING rule drops them when the quad is wound away from the eye.
// `visibleVertices` does the second. Reverse the winding and the same four
// vertices at the same coordinates change answer, which is the whole point.
// ---------------------------------------------------------------------------

private Mesh oneQuad(bool towardsEye) {
    Mesh m;
    const float a = OCC_HALF;
    m.vertices = [
        Vec3(-a, -a, 0), Vec3(a, -a, 0), Vec3(a, a, 0), Vec3(-a, a, 0),
    ];
    // CCW seen from +Z gives cross(v1-v0, v2-v0) = +Z, towards an eye on +Z.
    if (towardsEye) m.addFace([0, 1, 2, 3]);
    else            m.addFace([3, 2, 1, 0]);
    m.buildLoops();
    return m;
}

unittest {
    // Fixture self-check: the two windings really are front- and back-facing
    // for THIS eye, stated in the gate's own algebra (`dot(n, v0 - eye)`, front
    // iff < 0). Without this the test below could pass for the wrong reason.
    auto vp = testViewport();

    static double facingDot(const ref Mesh m, Vec3 eye) {
        const Vec3 v0 = m.vertices[m.faces[0][0]];
        const Vec3 v1 = m.vertices[m.faces[0][1]];
        const Vec3 v2 = m.vertices[m.faces[0][2]];
        const double ux = v1.x - v0.x, uy = v1.y - v0.y, uz = v1.z - v0.z;
        const double vx = v2.x - v0.x, vy = v2.y - v0.y, vz = v2.z - v0.z;
        const double nx = uy * vz - uz * vy;
        const double ny = uz * vx - ux * vz;
        const double nz = ux * vy - uy * vx;
        return nx * (v0.x - eye.x) + ny * (v0.y - eye.y) + nz * (v0.z - eye.z);
    }

    auto toward = oneQuad(true);
    auto away   = oneQuad(false);
    assert(facingDot(toward, vp.eye) < 0.0,
        "fixture: the `towardsEye` winding must be FRONT-facing for this eye");
    assert(facingDot(away, vp.eye) > 0.0,
        "fixture: the reversed winding must be BACK-facing for this eye");

    // Same four coordinates, nothing occluding them, opposite answers.
    auto visToward = toward.visibleVertices(vp.eye, vp, ModelSpace.world());
    foreach (vi; 0 .. 4)
        assert(visToward[vi],
            format("v%d of a front-facing lone quad must be visible", vi));

    auto visAway = away.visibleVertices(vp.eye, vp, ModelSpace.world());
    foreach (vi; 0 .. 4)
        assert(!visAway[vi],
            format("v%d: `Mesh.visibleVertices` HAS a facing term — a lone quad"
                ~ " wound away from the eye is invisible even though nothing is"
                ~ " in front of it. If this now passes as visible, the facing"
                ~ " term was removed, and that changes what SNAP grabs"
                ~ " (source/snap.d walkSource) — not just what a pass draws."
                ~ " If it was removed deliberately for a wireframe rule, see"
                ~ " doc/tasks/backlog/0577 first: the same predicate is"
                ~ " duplicated in three other places and they must move"
                ~ " together or the picker and the snapper disagree.", vi));
}
