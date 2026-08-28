// THE FACING PREDICATE UNDER A NEGATIVE-DETERMINANT ITEM TRANSFORM (task 3110).
//
// `tests/unit/facing_predicate_test.d` pins WHICH NORMAL the rule builds. This
// file pins the other half, which nothing pinned before: WHICH QUESTION the
// rule answers once the layer carries an item transform that reverses
// handedness — a legitimate negative item scale.
//
// THE TWO FORMULAS, AND THE BRIDGE BETWEEN THEM. There are two ways to write
// "is this polygon turned away from the eye", and they are NOT two spellings of
// one rule once `det(L) < 0`:
//
//   LOCAL      cull iff  dot(N, v0 - eyeLocal) > 0            <- what we ship
//   DRAWN      cull iff  dot(Nw, v0w - eyeWorld) > 0          <- the rival
//                        Nw = cross(M*v1 - M*v0, M*vL - M*v0)
//
// and they are related by exactly one factor, which this file asserts rather
// than assumes:
//
//   dot(Nw, v0w - eyeWorld)  ==  det(L) * dot(N, v0 - eyeLocal)
//
// because cross(Lu, Lw) == det(L) * (L^-1)^T * cross(u, w) and
// dot((L^-1)^T n, L v) == dot(n, v). So the two agree wherever det(L) > 0 and
// are EXACT COMPLEMENTS wherever det(L) < 0.
//
// WHICH ONE IS "WHAT THE USER SEES", and this is the whole finding. A mirror
// moves the points and leaves the index order alone, so the DRAWN surface is
// inside-out: every polygon the user can see, they see from its back. Our mesh
// pass runs with no `GL_CULL_FACE` (`gpu_select.renderMode` disables it
// explicitly and nothing else enables it for geometry) and the draw path never
// reverses a ring — `matrixMirrorsWinding`'s callers are the IO/export and
// primitive-creation boundaries only. Therefore under a mirror:
//
//   * the LOCAL rule keeps the polygon whose drawn surface is NEAREST the eye
//     — the one the user is looking at;
//   * the DRAWN rule keeps the polygon whose drawn winding faces the eye —
//     which, the surface being inside-out, is the one HIDDEN behind it.
//
// The third column below is an INDEPENDENT oracle for that: a ray from the eye
// through each face's own drawn centroid, nearest hit wins, no winding term in
// it at all. It is this file's own arithmetic, deliberately not the app's.
//
// WHY NOT A CUBE — the project rule, and here it has a second edge. On a closed
// solid the two rules are still complements under a mirror, so a cube WOULD
// separate them; but a cube cannot show that the LOCAL answer is the visible
// one for a reason other than closure. The rig below is OPEN (two parallel
// walls, nothing else), so "nearest" is a property of the pair and not of a
// solid, and the face that is visible flips between the two walls when the
// mirror is applied.
//
// THE ANTI-VACUITY CELL is `scl = (-1,-1,1)`: two negative components, det > 0,
// NOT a mirror. Both rules must agree there. A predicate that keyed on "any
// negative scale component" instead of on the determinant passes every mirror
// cell above and fails this one.
module tests.unit.facing_mirror_determinant_test;

import std.format : format;

import math       : Vec3, ModelSpace, transformPoint, frontFacingLocal;
import item_xform : ItemXform;

// ---------------------------------------------------------------------------
// The rig: an OPEN mesh, two parallel outward-wound walls, and an eye on +X.
//
//   A: plane x = +1, ring normal +X  (outward, toward the eye)
//   B: plane x = -1, ring normal -X  (outward, away from the eye)
//
// At identity the eye sees A's front and B is both back-facing and occluded.
// Mirror on X and the two walls swap depth: B's surface becomes the near one.
// ---------------------------------------------------------------------------
private enum Vec3[8] RIG_VERTS = [
    Vec3( 1,-1,-1), Vec3( 1, 1,-1), Vec3( 1, 1, 1), Vec3( 1,-1, 1), // A 0..3 -> +X
    Vec3(-1,-1, 1), Vec3(-1, 1, 1), Vec3(-1, 1,-1), Vec3(-1,-1,-1), // B 4..7 -> -X
];
private enum uint[4][2] RIG_FACES = [[0u,1u,2u,3u], [4u,5u,6u,7u]];
private enum string[2] RIG_NAMES = ["A(x=+1, n=+X)", "B(x=-1, n=-X)"];

/// An eye deliberately OFF the mirror axes, so no cell is decided by a
/// coordinate that happens to be zero.
private enum Vec3 EYE_WORLD = Vec3(10.0f, 0.3f, 0.2f);

// ---------------------------------------------------------------------------
// This file's own arithmetic. None of the three helpers below calls the app.
// ---------------------------------------------------------------------------

/// The corner normal at ring[0], closed with the LAST ring entry — the adopted
/// normal, recomputed here so the assertions can name the dot they are about.
private double[3] cornerNormal(const Vec3[] vs, const uint[] ring) {
    const Vec3 a = vs[ring[0]], b = vs[ring[1]], c = vs[ring[$ - 1]];
    const double ux = cast(double)b.x - a.x, uy = cast(double)b.y - a.y,
                 uz = cast(double)b.z - a.z;
    const double wx = cast(double)c.x - a.x, wy = cast(double)c.y - a.y,
                 wz = cast(double)c.z - a.z;
    return [uy*wz - uz*wy, uz*wx - ux*wz, ux*wy - uy*wx];
}

/// `dot(N, v0 - eye)` for a ring, in whatever space `vs` and `eye` share.
private double facingDot(const Vec3[] vs, const uint[] ring, Vec3 eye) {
    const auto n = cornerNormal(vs, ring);
    const Vec3 a = vs[ring[0]];
    return n[0]*(cast(double)a.x - eye.x)
         + n[1]*(cast(double)a.y - eye.y)
         + n[2]*(cast(double)a.z - eye.z);
}

/// Nearest-hit parameter of a ray against one quad, or +inf. Two triangles,
/// Moeller-Trumbore, in double, with NO facing term — a back-facing hit counts,
/// which is the whole point: the mesh pass has no `GL_CULL_FACE` either.
private double rayQuad(Vec3 org, Vec3 dir, const Vec3[4] q) {
    static double tri(Vec3 o, Vec3 d, Vec3 a, Vec3 b, Vec3 c) {
        const double e1x = cast(double)b.x - a.x, e1y = cast(double)b.y - a.y,
                     e1z = cast(double)b.z - a.z;
        const double e2x = cast(double)c.x - a.x, e2y = cast(double)c.y - a.y,
                     e2z = cast(double)c.z - a.z;
        const double px = cast(double)d.y*e2z - cast(double)d.z*e2y,
                     py = cast(double)d.z*e2x - cast(double)d.x*e2z,
                     pz = cast(double)d.x*e2y - cast(double)d.y*e2x;
        const double det = e1x*px + e1y*py + e1z*pz;
        if (det > -1e-12 && det < 1e-12) return double.infinity;
        const double tx = cast(double)o.x - a.x, ty = cast(double)o.y - a.y,
                     tz = cast(double)o.z - a.z;
        const double u = (tx*px + ty*py + tz*pz) / det;
        if (u < -1e-9 || u > 1.0 + 1e-9) return double.infinity;
        const double qx = ty*e1z - tz*e1y, qy = tz*e1x - tx*e1z, qz = tx*e1y - ty*e1x;
        const double v = (cast(double)d.x*qx + cast(double)d.y*qy + cast(double)d.z*qz) / det;
        if (v < -1e-9 || u + v > 1.0 + 1e-9) return double.infinity;
        const double t = (e2x*qx + e2y*qy + e2z*qz) / det;
        return t > 1e-9 ? t : double.infinity;
    }
    const double t1 = tri(org, dir, q[0], q[1], q[2]);
    const double t2 = tri(org, dir, q[0], q[2], q[3]);
    return t1 < t2 ? t1 : t2;
}

/// One cell, fully evaluated. Every field is measured, none is assumed.
private struct Cell {
    bool   shipped;      /// `math.frontFacingLocal` — the LOCAL rule, as shipped
    bool   drawnRule;    /// the rival: the corner cross of the DRAWN ring
    bool   userSees;     /// independent oracle: nearest drawn surface at this centroid
    double localDot;     /// dot(N, v0 - eyeLocal)
    double drawnDot;     /// dot(Nw, v0w - eyeWorld)
    double det;          /// det of the item transform's linear part
}

private Cell evalCell(const ModelSpace ms, float detSigned, size_t fi) {
    Vec3[8] verts = RIG_VERTS;
    Vec3[8] drawn;
    foreach (i, v; verts) drawn[i] = ms.isIdentity ? v : transformPoint(ms.m, v);
    const Vec3 eyeLocal = ms.isIdentity ? EYE_WORLD : ms.toLocalPoint(EYE_WORLD);
    const uint[4] ring = RIG_FACES[fi];

    Cell c;
    c.det       = detSigned;
    c.shipped   = frontFacingLocal(verts[], ring[], eyeLocal);
    c.localDot  = facingDot(verts[], ring[], eyeLocal);
    c.drawnDot  = facingDot(drawn[], ring[], EYE_WORLD);
    c.drawnRule = !(c.drawnDot > 0.0);

    // The oracle. Ray from the eye through THIS face's own drawn centroid;
    // whichever wall it meets first is the one on screen at that pixel.
    Vec3 ctr = Vec3(0, 0, 0);
    foreach (vi; ring) ctr = ctr + drawn[vi];
    ctr = ctr / 4.0f;
    const Vec3 dir = ctr - EYE_WORLD;
    double best = double.infinity;
    size_t bestFace = size_t.max;
    foreach (gi; 0 .. RIG_FACES.length) {
        Vec3[4] quad;
        foreach (k, vi; RIG_FACES[gi]) quad[k] = drawn[vi];
        const double t = rayQuad(EYE_WORLD, dir, quad);
        if (t < best) { best = t; bestFace = gi; }
    }
    c.userSees = (bestFace == fi);
    return c;
}

private string why(string label, size_t fi, const Cell c) {
    return format("\n    %s, face %d %s:"
        ~ "\n      det(L)                 = %+.3f"
        ~ "\n      dot(N, v0-eyeLocal)    = %+.6g   -> shipped(LOCAL) front=%s"
        ~ "\n      dot(Nw, v0w-eyeWorld)  = %+.6g   -> rival  (DRAWN) front=%s"
        ~ "\n      nearest drawn surface at this centroid is this face = %s",
        label, fi, RIG_NAMES[fi], c.det,
        c.localDot, c.shipped, c.drawnDot, c.drawnRule, c.userSees);
}

/// The four transforms the law is asserted over, with the determinant each one
/// is supposed to have. `pos` is non-zero so a cell cannot be decided by the
/// item sitting on the mirror plane.
private struct Case { string label; Vec3 scl; float det; bool mirrored; }
private enum Case[5] CASES = [
    Case("identity",           Vec3( 1,  1,  1),  1.0f, false),
    Case("mirror X",           Vec3(-1,  1,  1), -1.0f, true ),
    Case("mirror Y",           Vec3( 1, -1,  1), -1.0f, true ),
    Case("mirror Z",           Vec3( 1,  1, -1), -1.0f, true ),
    Case("two negatives (det>0, NOT a mirror)",
                               Vec3(-1, -1,  1),  1.0f, false),
];

private ModelSpace spaceFor(const Case cs) {
    ItemXform xf;
    xf.scl = cs.scl;
    return xf.modelSpace();
}

unittest { // the rig is honest: it must SEPARATE the two rules, not agree with itself
    // Without this, every assertion below could be satisfied by a rig on which
    // the LOCAL and DRAWN rules never part company — which is exactly the shape
    // of check this project pays for most.
    foreach (cs; CASES) {
        const ms = spaceFor(cs);
        assert(ms.mirrored == cs.mirrored,
            format("rig: `%s` must have mirrored=%s (det is the PRODUCT of the"
                ~ " three scale components, not `any component negative`) — got %s",
                cs.label, cs.mirrored, ms.mirrored));
        foreach (fi; 0 .. RIG_FACES.length) {
            const c = evalCell(ms, cs.det, fi);
            assert(c.localDot != 0.0 && c.drawnDot != 0.0,
                "rig: neither dot may be zero, or the cell is decided by the"
                ~ " `> 0` tie-break instead of by the rule" ~ why(cs.label, fi, c));
        }
    }
    // On this rig the two walls must genuinely swap which one is on screen when
    // the mirror is applied — otherwise "the visible face flips" is untested.
    const idA = evalCell(spaceFor(CASES[0]), CASES[0].det, 0);
    const mxA = evalCell(spaceFor(CASES[1]), CASES[1].det, 0);
    assert(idA.userSees && !mxA.userSees,
        "rig: wall A must be the visible one at identity and the hidden one"
        ~ " under the X mirror, or the fixture cannot exhibit the phenomenon"
        ~ why("identity", 0, idA) ~ why("mirror X", 0, mxA));
}

unittest { // THE BRIDGE: dot(Nw, v0w - eye) == det(L) * dot(N, v0 - eyeLocal)
    // The audit's identity, asserted rather than quoted. This is what makes the
    // two formulas complements under a mirror and equal without one, so every
    // assertion below rests on a measured relation, not on prose.
    foreach (cs; CASES) {
        const ms = spaceFor(cs);
        foreach (fi; 0 .. RIG_FACES.length) {
            const c = evalCell(ms, cs.det, fi);
            const double predicted = cast(double)cs.det * c.localDot;
            const double tol = 1e-9 * (predicted < 0 ? -predicted : predicted);
            const double diff = c.drawnDot - predicted;
            assert((diff < 0 ? -diff : diff) <= tol,
                format("the drawn-winding dot must equal det(L) times the local"
                    ~ " dot; predicted %+.6g", predicted) ~ why(cs.label, fi, c));
        }
    }
}

unittest { // THE LAW: the shipped rule answers "what is on screen", under any det
    // For every cell, on every transform, `frontFacingLocal` must agree with the
    // independent nearest-surface oracle. This is the assertion that would go
    // red if the predicate started carrying `det(L)`.
    foreach (cs; CASES) {
        const ms = spaceFor(cs);
        foreach (fi; 0 .. RIG_FACES.length) {
            const c = evalCell(ms, cs.det, fi);
            assert(c.shipped == c.userSees,
                format("`%s`: the facing predicate must keep the polygon whose"
                    ~ " DRAWN surface the user is looking at. A mirror leaves the"
                    ~ " ring order alone, so the drawn surface is inside-out and"
                    ~ " the winding-front polygon is the OCCLUDED one; carrying"
                    ~ " det(L) into this predicate selects through the model.",
                    cs.label) ~ why(cs.label, fi, c));
        }
    }
}

unittest { // SEPARATION: identity agrees, every single-axis mirror disagrees
    // The anti-vacuity half of the law above. If these ever stop separating,
    // the previous unittest has become a check that cannot come out
    // differently and is no longer evidence for anything.
    foreach (cs; CASES) {
        const ms = spaceFor(cs);
        foreach (fi; 0 .. RIG_FACES.length) {
            const c = evalCell(ms, cs.det, fi);
            if (cs.mirrored)
                assert(c.shipped != c.drawnRule,
                    format("`%s`: det(L) < 0, so the drawn-winding rule must be"
                        ~ " the exact COMPLEMENT of the shipped one — if it"
                        ~ " agrees here the cell separates nothing", cs.label)
                        ~ why(cs.label, fi, c));
            else
                assert(c.shipped == c.drawnRule,
                    format("`%s`: det(L) > 0, so the two rules must AGREE —"
                        ~ " a disagreement here means the divergence is not the"
                        ~ " determinant after all", cs.label)
                        ~ why(cs.label, fi, c));
        }
    }
}
