module vibe3d.util.math.math_geometry;

import vibe3d.util.math.math_vector;
import vibe3d.util.math.math_quaternion;
import vibe3d.util.math.math_matrix;
import std.math : tan, sin, cos, sqrt, PI, abs, acos, asin, atan2, round, isFinite;
version (unittest) import std.math : isClose;


/// The face normal the face VBO carries: `cross(v1 - v0, v2 - v0)` of the
/// first three corners, normalised, or `(0,1,0)` when its length is at most
/// 1e-6 (then `degenerate` is true). ONE definition of "which way a face
/// points" for the fill and anything that must agree with it (the retopology
/// dot cull); the float operation order is the upload's, so the buffer bytes
/// do not change. Not a Newell normal: for a non-planar face it is the normal
/// of fan triangle 0 only.
Vec3 faceNormalFirst3(Vec3 v0, Vec3 v1, Vec3 v2, out bool degenerate)
    @safe pure nothrow @nogc
{
    float ax = v1.x - v0.x, ay = v1.y - v0.y, az = v1.z - v0.z;
    float bx = v2.x - v0.x, by = v2.y - v0.y, bz = v2.z - v0.z;
    float cx = ay*bz - az*by;
    float cy = az*bx - ax*bz;
    float cz = ax*by - ay*bx;
    float nlen = sqrt(cx*cx + cy*cy + cz*cz);
    if (nlen > 1e-6f) {
        degenerate = false;
        float inv = 1.0f / nlen;
        return Vec3(cx*inv, cy*inv, cz*inv);
    }
    degenerate = true;
    return Vec3(0, 1, 0);
}


// 2D point-in-polygon test (ray casting, works for convex and concave polygons).
bool pointInPolygon2D(float px, float py, float[] xs, float[] ys) {
    int n = cast(int)xs.length;
    bool inside = false;
    for (int i = 0, j = n - 1; i < n; j = i++) {
        if (((ys[i] > py) != (ys[j] > py)) &&
            (px < (xs[j] - xs[i]) * (py - ys[i]) / (ys[j] - ys[i]) + xs[i]))
            inside = !inside;
    }
    return inside;
}

// ---------------------------------------------------------------------------
// THE FACING PREDICATE — one rule, one home (task 0832).
//
// "Is this face turned away from the eye" used to be written out THREE times,
// and audit 4 (§P1) measured that they were not three copies of one rule but
// three DIFFERENT rules: the plane of the first triangle in double
// (`Mesh.visibleVertices`), the cross of the first triangle in float
// (`snap.d`'s `faceVisible`), and a Newell sum over the whole ring (`app.d`'s
// lasso). They part company on exactly the face an edge split leaves behind —
// so the snapper and the lasso could disagree about the same polygon, and
// nothing in the tree said which answer was right.
//
// THE RULE BELOW IS THE REFERENCE EDITOR'S, and it is here for PARITY. It was
// read under a debugger at the reference's own compute site (task 0726 — the
// arguments at the call, matched against offline arithmetic to the last
// printed digit), and the owner adopted it on 2026-08-15:
//
//     N = cross(v1 - v0, v[n-1] - v0)   the corner triangle at the FIRST ring
//                                       vertex; the third point is the LAST
//                                       ring entry, NOT the second
//     cull  iff  dot(N, v0 - eye) > 0   strictly, against a literal 0
//
// THE BILL, measured and accepted deliberately. Write it down here so nobody
// later reads any of it as an oversight and "repairs" it:
//
//   * N depends on the ring's STARTING VERTEX. Four rotations of one quad give
//     four different normals; only the rotation is different, the polygon is
//     the same polygon.
//   * On a planar polygon whose ring STARTS at a reflex corner, N is turned
//     180° from the surface it belongs to, so the face answers backwards.
//   * On the face an edge split leaves, when the inserted midpoint lands at
//     ring index 0, its two ring neighbours are collinear with it and N is
//     EXACTLY the zero vector — and such a polygon is then front-facing from
//     BOTH sides, because `dot(0, anything) > 0` is false.
//
// That last line is why the comparison is strict and why "N == 0 is never
// culled" needs no clause of its own: it falls out of `> 0`. The rule our tree
// used before culled at `>= 0`, which is the opposite answer for every
// zero-normal and every exactly-edge-on face.
//
// `Mesh.faceNormal` (Newell, area-weighted over the whole ring) is strictly
// more robust than this and disagreed with the reference on 19 of 72 measured
// cells. It stays where it is for GEOMETRY (bevels, workplanes, UV projection);
// it is deliberately NOT what decides facing. Do not "fix" this predicate by
// reaching for it — that would be neither parity nor honesty.
//
// LOCAL SPACE. `eyeLocal` is the eye in the same space `verts` are expressed
// in (`projectionSpace(vp, ms).eye`, i.e. `M⁻¹·eyeWorld`). A front-facing test
// done ENTIRELY in local space needs no `ms.mirrored` correction, mirrored or
// not — see `ModelSpace.mirrored`'s doc comment above for the identity, and for
// the flip that used to be XOR'd onto all three copies of this test and was
// wrong. Do not reintroduce it here.
//
// NEGATIVE DETERMINANT — the same question asked from the REFERENCE's side in
// task 3110, and answered by measurement rather than by the identity above.
// There are two ways to write this rule and they are related by exactly one
// factor:
//
//     dot(Nw, v0w - eyeWorld)  ==  det(L) * dot(N, v0 - eyeLocal)
//
// where `Nw` is the corner cross of the DRAWN ring — the form a SCREEN-space
// test computes, item transform applied before projecting. The two therefore
// agree wherever `det(L) > 0` and are exact COMPLEMENTS wherever `det(L) < 0`.
//
// We keep the LOCAL form, and not as a preference: a mirror moves the points
// and leaves the index order alone, so the DRAWN surface is inside-out — every
// polygon the user can see under a mirror, they see from its back. The picker's
// pass has no `GL_CULL_FACE` (`gpu_select.renderMode` disables it explicitly);
// every display face pass that culls — a lit style's surface cull (model M6)
// and the retopology `FacePass` — flips `glFrontFace` by `det(L)`, i.e. culls
// in this LOCAL form (captured C7f), and no DRAW path reverses a ring
// (`matrixMirrorsWinding`'s callers are the IO/export and primitive-creation
// boundaries only). So under a mirror the winding-front polygon is the
// OCCLUDED one, and carrying `det(L)` in here makes the lasso and the snapper
// answer about geometry that is behind the model. That is the same wrong
// answer the `ms.mirrored` XOR gave before it was removed — a `det(L)` term
// here IS that XOR, arrived at from the other direction.
//
// Measured, with the three checks that redden on the `det(L)` arm:
// `tests/unit/facing_mirror_determinant_test.d` (an OPEN rig, plus the bridge
// identity above asserted rather than quoted), `tests/unit/mesh_test.d`'s
// mirrored-corner pin, and `tests/test_pick_item_transform.d`'s M1 against an
// independent GPU-depth oracle. `doc/measured_laws.md` §3 carries the reading
// and what is still unmeasured about the reference's own behaviour here.
//
// PRECISION. The cross and the dot are carried in DOUBLE while the positions
// stay float, the same choice `Mesh.visibleVertices`'s depth gate already
// documents. Products of float32 values are exact in double, so the sign this
// returns is the correctly-rounded sign of the exact float32 arithmetic — and,
// the part that matters for the rule above, a truly collinear corner yields an
// EXACT zero rather than float noise with an arbitrary sign. That is a
// property of evaluating this formula, not a different formula: the three
// sites disagreed on precision too (double / float / float), and one home has
// to pick one.
//
// WHERE THIS IS USED, and where it deliberately is not:
//
//   * lasso over polygons (`app.d`) — MEASURED. This is the gesture task 0726
//     drove, and the rule is the reference's answer for it.
//   * snap — the POLYGON leg (`snap.d`'s `faceVisible`) and the occluder set
//     of `mesh_visibility`; vertex / edge candidates have no facing term
//     (`doc/measured_laws.md` §3).
//   * single click — NOT this rule and not any rule. Our click path has no
//     facing term at all (pinned by task 0576: `bvh_pick.pickFace` is a
//     nearest-hit ray-cast; `gpu_select` decides by depth). The reference does
//     cull there, but by a per-triangle determinant sign that never touches the
//     polygon normal — so giving click a facing term is a separate behaviour
//     change, not a consequence of this one.
//
/// True when the face `ring` (indices into `verts`) faces `eyeLocal` — i.e.
/// when it is NOT culled. `ring` shorter than 3 is not a face and answers
/// false. All coordinates are in ONE space; `eyeLocal` must be in that space.
bool frontFacingLocal(const(Vec3)[] verts, const(uint)[] ring, Vec3 eyeLocal)
    @safe pure nothrow @nogc
{
    if (ring.length < 3) return false;
    const Vec3 v0 = verts[ring[0]];
    const Vec3 v1 = verts[ring[1]];
    const Vec3 vL = verts[ring[$ - 1]];
    // N = cross(v1 - v0, vL - v0), in double (see PRECISION above).
    const double ux = cast(double)v1.x - v0.x,
                 uy = cast(double)v1.y - v0.y,
                 uz = cast(double)v1.z - v0.z;
    const double wx = cast(double)vL.x - v0.x,
                 wy = cast(double)vL.y - v0.y,
                 wz = cast(double)vL.z - v0.z;
    const double nx = uy * wz - uz * wy,
                 ny = uz * wx - ux * wz,
                 nz = ux * wy - uy * wx;
    const double dx = cast(double)v0.x - eyeLocal.x,
                 dy = cast(double)v0.y - eyeLocal.y,
                 dz = cast(double)v0.z - eyeLocal.z;
    // Strictly `> 0` culls. Equality — a zero N, or a face exactly edge-on —
    // is kept, which is the whole of the "N == 0 is never culled" clause.
    return !(nx * dx + ny * dy + nz * dz > 0.0);
}

// ===========================================================================
// ringStartCornerSign — the OTHER measured rule that reads WHERE a polygon's
// vertex ring starts. Task 1230; divergence-ledger rows 41 / 42 / 47 / 49.
// ===========================================================================
//
// Same corner triangle as `frontFacingLocal` directly above, a different
// question, a different answer — which is exactly why it sits BESIDE it and
// not inside it:
//
//     N0 = cross(ring[1] - ring[0], ring[$-1] - ring[0])   corner at index 0
//     s  = sign( dot(N0, Newell(ring)) )
//
// "Is the corner the ring HAPPENS TO START AT convex with respect to the
// ring's own normal." `frontFacingLocal` measures that same `N0` against the
// EYE and answers a visibility question; this measures it against the ring's
// own area-weighted normal and answers an ORIENTATION one. No camera enters
// it, and its zero is not `frontFacingLocal`'s "visible from both sides" — it
// is a class of its own that three callers answer three different ways.
//
// THREE CLASSES, and the third is load-bearing:
//   +1  ring starts at a CONVEX corner    — the ordinary case; every op in the
//                                           offset family behaves here exactly
//                                           as it did before this rule existed
//   -1  ring starts at a REFLEX corner    — N0 is turned 180 degrees from the
//                                           surface it belongs to
//    0  ring starts at a COLLINEAR corner — N0 is EXACTLY the zero vector and
//                                           there is no second corner to fall
//                                           back to
//
// WHY THIS EXISTS AT ALL — it is a DECISION, not an improvement. Rotating a
// polygon's ring does not change the polygon, so an op that reads the start is
// answering a question about bookkeeping. Ours did not read it; the reference
// does, and the owner chose to match the reference (task 1230). We are
// deliberately INTRODUCING a ring-order dependence in the offset family. The
// sibling rule for triangulation went the other way in task 1190 — there the
// reference is the ring-INVARIANT one and we were the ones reading the start —
// so the two must not be reasoned about as one thing. This predicate does NOT
// govern triangulation: measured over 25 orbits it is violated on 11 of them,
// and `tests/fixtures/ring_order_orbit_divergence.json` keeps the
// counterexample declared `violated` on purpose.
//
// WHERE IT IS MEASURED AND WHERE IT IS APPLIED (all three read it separately,
// because one input gets three different answers out of them — ledger row 49):
//   * `Mesh.insetFacesByMask` (inset / outset)       — signed offset, and the
//     ZERO class REFUSES the face outright.
//   * `Mesh.bevelFacesByMask` (poly.bevel)           — offset scaled by `s`
//     itself, so the zero class builds the ring with NO offset.
//   * `Mesh.extrudeFacesByMask`, smooth-shift branch only — the
//     COARSE reading, in which zero merges with +1, so a collinear ring start
//     is not noticed at all.
// Scored 58/58 exact on the offset families over the frozen orbit corpus, and
// 8/8 on smooth shift under the coarse reading.
//
// PRECISION, AND WHY THE ZERO TEST IS RELATIVE. The cross, the Newell sum and
// the dot are all carried in DOUBLE while the positions stay float, for the
// same reason `frontFacingLocal` gives above: products of float32 values are
// exact in double, so a truly collinear corner yields an EXACT zero instead of
// noise with an arbitrary sign — and here the zero is a CLASS, so getting it
// wrong picks the wrong branch, not merely the wrong side of a tie.
//
// The degeneracy test is therefore made on the corner triangle ITSELF and
// SCALE-FREE — `|cross| <= 1e-9 · |a| · |b|`, i.e. `sin(theta) <= 1e-9` — and
// NOT on the dot product against an absolute floor. That was the first thing
// written here and it was WRONG: `dot(cross, Newell)` grows as the FOURTH
// power of the ring's size, so on the 0.002-unit square of
// `tests/fixtures/poly_inset_dirty_parity.json`'s `inset_tiny_next_big` an
// ordinary RIGHT ANGLE evaluates to 3.2e-11, an absolute 1e-9 floor calls it
// collinear, and the inset operation then REFUSES a face it must inset. The frozen
// agreement caught it — 15 vertices expected, 11 produced. A small polygon is
// not a degenerate one, and only a relative test knows the difference.
//
// The fixture runner carries a twin of this formula (`corner0Sign` in
// `tests/fixture_helpers.d`) which still reads the ABSOLUTE form. The two
// classify the measured corpus identically — every ring there is 1 to 4 units
// across, where a non-degenerate corner's dot is of order 1 and a degenerate
// one is EXACTLY zero — so the frozen `sign_predicate` blocks still describe
// what these kernels do. The implementations are deliberately kept apart so
// those frozen classes stay an INDEPENDENT oracle; they can part company only
// on geometry far from unit scale, which is exactly the geometry the orbit
// corpus does not contain. If you change the reading here, check it there.
//
/// The reference's ring-start corner sign for the polygon `ring` (positions).
/// +1 convex, -1 reflex, 0 collinear/degenerate. A ring shorter than 3 is not
/// a polygon and answers 0.
int ringStartCornerSign(const(Vec3)[] ring) @safe pure nothrow @nogc {
    immutable size_t n = ring.length;
    if (n < 3) return 0;
    const Vec3 r0 = ring[0], r1 = ring[1], rL = ring[n - 1];
    const double ux = cast(double)r1.x - r0.x,
                 uy = cast(double)r1.y - r0.y,
                 uz = cast(double)r1.z - r0.z;
    const double wx = cast(double)rL.x - r0.x,
                 wy = cast(double)rL.y - r0.y,
                 wz = cast(double)rL.z - r0.z;
    const double cx = uy * wz - uz * wy,
                 cy = uz * wx - ux * wz,
                 cz = ux * wy - uy * wx;
    // The ZERO class is a degenerate CORNER TRIANGLE, judged against the
    // corner's own two edges so the answer cannot depend on how big the
    // polygon is: |cross| <= 1e-9 * |a| * |b| is sin(theta) <= 1e-9.
    if (cx*cx + cy*cy + cz*cz
        <= 1e-18 * (ux*ux + uy*uy + uz*uz) * (wx*wx + wy*wy + wz*wz))
        return 0;
    // Newell over the WHOLE ring — the reference frame the corner is judged
    // against. It reverses with the ring, which is why a REVERSED ring answers
    // the same as the original (both terms flip) while a ROTATED one does not
    // (only the corner moves). That asymmetry is the finding.
    double nx = 0.0, ny = 0.0, nz = 0.0;
    foreach (i; 0 .. n) {
        const Vec3 p = ring[i], q = ring[(i + 1) % n];
        nx += (cast(double)p.y - q.y) * (cast(double)p.z + q.z);
        ny += (cast(double)p.z - q.z) * (cast(double)p.x + q.x);
        nz += (cast(double)p.x - q.x) * (cast(double)p.y + q.y);
    }
    const double d = cx * nx + cy * ny + cz * nz;
    // Reaching here the corner triangle is non-degenerate, so a zero can only
    // mean the ring's own normal is zero (a degenerate ring) or stands exactly
    // perpendicular to the corner (a non-planar oddity no measurement covers).
    // Both answer "no class" rather than guessing one.
    if (d > 0.0) return  1;
    if (d < 0.0) return -1;
    return 0;
}

/// Index-addressed form: `ring` are indices into `verts`. Same rule.
int ringStartCornerSign(const(Vec3)[] verts, const(uint)[] ring)
    @safe pure nothrow @nogc
{
    immutable size_t n = ring.length;
    if (n < 3) return 0;
    // Cannot slice `verts` by an index ring, so the formula is spelled once
    // more rather than allocating a positions copy in an @nogc predicate.
    const Vec3 r0 = verts[ring[0]], r1 = verts[ring[1]], rL = verts[ring[n - 1]];
    const double ux = cast(double)r1.x - r0.x,
                 uy = cast(double)r1.y - r0.y,
                 uz = cast(double)r1.z - r0.z;
    const double wx = cast(double)rL.x - r0.x,
                 wy = cast(double)rL.y - r0.y,
                 wz = cast(double)rL.z - r0.z;
    const double cx = uy * wz - uz * wy,
                 cy = uz * wx - ux * wz,
                 cz = ux * wy - uy * wx;
    // The ZERO class is a degenerate CORNER TRIANGLE, judged against the
    // corner's own two edges so the answer cannot depend on how big the
    // polygon is: |cross| <= 1e-9 * |a| * |b| is sin(theta) <= 1e-9.
    if (cx*cx + cy*cy + cz*cz
        <= 1e-18 * (ux*ux + uy*uy + uz*uz) * (wx*wx + wy*wy + wz*wz))
        return 0;
    double nx = 0.0, ny = 0.0, nz = 0.0;
    foreach (i; 0 .. n) {
        const Vec3 p = verts[ring[i]], q = verts[ring[(i + 1) % n]];
        nx += (cast(double)p.y - q.y) * (cast(double)p.z + q.z);
        ny += (cast(double)p.z - q.z) * (cast(double)p.x + q.x);
        nz += (cast(double)p.x - q.x) * (cast(double)p.y + q.y);
    }
    const double d = cx * nx + cy * ny + cz * nz;
    // Reaching here the corner triangle is non-degenerate, so a zero can only
    // mean the ring's own normal is zero (a degenerate ring) or stands exactly
    // perpendicular to the corner (a non-planar oddity no measurement covers).
    // Both answer "no class" rather than guessing one.
    if (d > 0.0) return  1;
    if (d < 0.0) return -1;
    return 0;
}

// Closest distance from point (px,py) to segment (ax,ay)-(bx,by).
// t is the interpolation parameter [0..1] of the closest point on segment.
float closestOnSegment2D(float px, float py,
                          float ax, float ay, float bx, float by,
                          out float t) {
    float dx = bx - ax, dy = by - ay;
    float len2 = dx*dx + dy*dy;
    if (len2 < 1e-6f) { t = 0.0f; return sqrt((px-ax)*(px-ax)+(py-ay)*(py-ay)); }
    t = ((px-ax)*dx + (py-ay)*dy) / len2;
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    float cx = ax + t*dx, cy = ay + t*dy;
    return sqrt((px-cx)*(px-cx) + (py-cy)*(py-cy));
}

// Optimized version that returns squared distance (avoids sqrt)
float closestOnSegment2DSquared(float px, float py,
                                 float ax, float ay, float bx, float by,
                                 out float t) {
    float dx = bx - ax, dy = by - ay;
    float len2 = dx*dx + dy*dy;
    if (len2 < 1e-6f) { t = 0.0f; return (px-ax)*(px-ax)+(py-ay)*(py-ay); }
    t = ((px-ax)*dx + (py-ay)*dy) / len2;
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    float cx = ax + t*dx, cy = ay + t*dy;
    return (px-cx)*(px-cx) + (py-cy)*(py-cy);
}

// Intersect ray (origin + t*dir) with plane (point on plane + normal).
// Returns false when ray is parallel to the plane.
bool rayPlaneIntersect(Vec3 origin, Vec3 dir, Vec3 planePoint, Vec3 n,
                               out Vec3 hit)
{
    import std.math : abs;
    float denom = dot(n, dir);
    if (abs(denom) < 1e-6f) return false;
    Vec3 d = planePoint - origin;
    float t = dot(n, d) / denom;
    hit = origin + dir * t;
    return true;
}

// ---------------------------------------------------------------------------
// closestOnSegmentToRay — the parameter on the world segment a→b of the point
// of CLOSEST APPROACH to the ray LINE (origin, dir), clamped to [0, 1].
//
// This is the ordinary 3D line/segment closest approach, and it is the law a
// cursor-to-edge election runs on. It is NOT the screen-nearest point on the
// segment, and the difference is not a rounding term: the two agree only when
// the eye, the cursor ray and the edge are coplanar, and disagree by up to 0.61
// in parameter otherwise (a clamp disagreement — one model wants a point past
// an endpoint and the other does not). Anyone reaching for "the point that
// projects nearest the cursor" wants a different function; the RANK that goes
// with this election is the re-projected screen distance of the point this
// returns, which the caller computes, not this.
//
// The construction, written as the perpendicular it is:
//
//     E = b − a
//     M = (dir × E) × dir      -- E's component perpendicular to `dir`, times
//                                 |dir|²; the plane the closest approach lives in
//     t = dot(origin − a, M) / dot(E, M)
//
// The usual statement of this normalises M first. That is redundant here and
// deliberately skipped: M appears once in the numerator and once in the
// denominator, so any positive scale on it cancels exactly, and dropping the
// normalise removes both a square root and its epsilon. `dot(E, M)` is then
// |M|²/|dir|² — always non-negative — so the single `> 0` denominator test
// below covers BOTH degeneracies the normalising form needs two tests for:
// a zero-length segment, and a segment parallel to the ray (where M vanishes).
//
// `dir` need not be unit-length; the ratio is invariant under its scale.
//
// DEGENERATE ⇒ false, with `t = 0`. A segment parallel to the view ray projects
// to a single pixel, so every parameter on it is equally near the cursor in
// screen space and no choice among them is more correct than another; `t = 0`
// is a choice, not a measurement, and the `false` return lets a caller that
// cares say so.
bool closestOnSegmentToRay(Vec3 origin, Vec3 dir, Vec3 a, Vec3 b, out float t)
{
    t = 0.0f;
    Vec3 e = b - a;
    Vec3 m = cross(cross(dir, e), dir);
    float den = dot(e, m);
    if (!(den > 0.0f)) return false;      // also rejects NaN
    float u = dot(origin - a, m) / den;
    if (u < 0.0f) u = 0.0f;
    else if (u > 1.0f) u = 1.0f;
    t = u;
    return true;
}

// An orthonormal pair spanning the plane PERPENDICULAR to `dir`. Returns false
// when `dir` is degenerate. `u`, `v` and `dir/|dir|` form a right-handed
// frame; which of the infinitely many rotations about `dir` is produced does
// not matter to any caller here, because every quantity they take from it is
// a LENGTH in that plane, which is rotation-invariant.
bool perpendicularFrame(Vec3 dir, out Vec3 u, out Vec3 v) @safe pure nothrow @nogc
{
    u = Vec3(0, 0, 0);
    v = Vec3(0, 0, 0);
    immutable float len = sqrt(dot(dir, dir));
    if (!(len > 1e-9f)) return false;
    immutable Vec3 d = dir * (1.0f / len);
    // Cross with the axis LEAST aligned with `d`, so the cross product is the
    // best conditioned of the three available.
    immutable float ax = abs(d.x), ay = abs(d.y), az = abs(d.z);
    Vec3 helper = (ax <= ay && ax <= az) ? Vec3(1, 0, 0)
                : (ay <= az)             ? Vec3(0, 1, 0)
                                         : Vec3(0, 0, 1);
    Vec3 a = cross(d, helper);
    immutable float alen = sqrt(dot(a, a));
    if (!(alen > 1e-9f)) return false;
    u = a * (1.0f / alen);
    v = cross(d, u);            // unit already: |d| = |u| = 1 and d ⊥ u
    return true;
}

// Möller-Trumbore ray/triangle intersection, DOUBLE-SIDED (a back-facing
// triangle hits). `t` is along `dir` — NOT clamped to positive here, because
// the caller's behind-the-eye rule is its own decision and is stated at the
// call site. `u`/`v` are the barycentric coordinates of the hit:
//   hit == v0 + u*(v1 - v0) + v*(v2 - v0) == origin + t*dir.
// All three out-params are 0 on a miss.
bool rayTriangleIntersect(Vec3 origin, Vec3 dir, Vec3 v0, Vec3 v1, Vec3 v2,
                          out float t, out float u, out float v)
    @safe pure nothrow @nogc
{
    t = 0.0f; u = 0.0f; v = 0.0f;
    immutable Vec3 e1 = v1 - v0;
    immutable Vec3 e2 = v2 - v0;
    immutable Vec3 p  = cross(dir, e2);
    immutable float det = dot(e1, p);
    if (!(det > 1e-12f) && !(det < -1e-12f)) return false;   // also rejects NaN
    immutable float inv = 1.0f / det;
    immutable Vec3 s = origin - v0;
    immutable float uu = dot(s, p) * inv;
    if (uu < 0.0f || uu > 1.0f) return false;
    immutable Vec3 q = cross(s, e1);
    immutable float vv = dot(dir, q) * inv;
    if (vv < 0.0f || uu + vv > 1.0f) return false;
    t = dot(e2, q) * inv;
    u = uu;
    v = vv;
    return true;
}

// Squared distance from (px,py) to the SOLID triangle (a,b,c) in 2D, with the
// closest point returned in the triangle's own barycentric coordinates:
//   closest == a + u*(b - a) + v*(c - a).
//
// Written as "inside ⇒ zero, otherwise the best of the three edges" rather
// than as the Voronoi-region form, because that shape needs no guard for a
// zero-area triangle: a degenerate triangle is simply never "inside", and its
// three edges still answer correctly.
float closestPointOnTriangle2D(float px, float py,
                               float ax, float ay,
                               float bx, float by,
                               float cx, float cy,
                               out float u, out float v)
    @safe pure nothrow @nogc
{
    u = 0.0f; v = 0.0f;
    immutable float abx = bx - ax, aby = by - ay;
    immutable float acx = cx - ax, acy = cy - ay;
    immutable float apx = px - ax, apy = py - ay;

    immutable float d00 = abx*abx + aby*aby;
    immutable float d01 = abx*acx + aby*acy;
    immutable float d11 = acx*acx + acy*acy;
    immutable float den = d00*d11 - d01*d01;
    if (den > 1e-20f) {
        immutable float d20 = apx*abx + apy*aby;
        immutable float d21 = apx*acx + apy*acy;
        immutable float bu = (d11*d20 - d01*d21) / den;
        immutable float bv = (d00*d21 - d01*d20) / den;
        if (bu >= 0.0f && bv >= 0.0f && bu + bv <= 1.0f) {
            u = bu; v = bv;
            return 0.0f;
        }
    }

    // Local rather than `closestOnSegment2DSquared`, which is unannotated and
    // would cost this function every one of its four attributes. Same formula,
    // and the zero-length case clamps to the start point exactly as that one
    // does.
    static float seg(float qx, float qy, float sx0, float sy0,
                     float sx1, float sy1, out float t) @safe pure nothrow @nogc
    {
        immutable float ex = sx1 - sx0, ey = sy1 - sy0;
        immutable float len2 = ex*ex + ey*ey;
        t = 0.0f;
        if (len2 > 1e-20f) {
            t = ((qx - sx0)*ex + (qy - sy0)*ey) / len2;
            if (t < 0.0f) t = 0.0f;
            else if (t > 1.0f) t = 1.0f;
        }
        immutable float rx = qx - (sx0 + t*ex), ry = qy - (sy0 + t*ey);
        return rx*rx + ry*ry;
    }

    float best = float.infinity;
    float t;
    // AB: q = a + t*(b - a)  ->  (u, v) = (t, 0)
    float d2 = seg(px, py, ax, ay, bx, by, t);
    if (d2 < best) { best = d2; u = t;        v = 0.0f; }
    // AC: q = a + t*(c - a)  ->  (u, v) = (0, t)
    d2 = seg(px, py, ax, ay, cx, cy, t);
    if (d2 < best) { best = d2; u = 0.0f;     v = t; }
    // BC: q = b + t*(c - b) = a + (1-t)*(b-a) + t*(c-a)  ->  (1-t, t)
    d2 = seg(px, py, bx, by, cx, cy, t);
    if (d2 < best) { best = d2; u = 1.0f - t; v = t; }
    return best;
}

// Triangulate a simple polygon given as world positions, returning index
// triples into `poly`. Returns null for fewer than three vertices.
//
// EAR CLIPPING, NOT A FAN, and the distinction is the whole reason this exists
// rather than the `[0, i, i+1]` loop the rest of the codebase uses for display
// and for BVH build. A fan of a NON-CONVEX polygon emits triangles that cover
// the notch — area the polygon does not occupy — so a hit test built on a fan
// reports the cursor as being ON a polygon it is beside. The union of the
// triangles this returns is the polygon itself, which is the property every
// caller actually depends on.
//
// Non-planar polygons are triangulated in the plane of their Newell normal,
// which is the standard best-fit and is what makes the answer independent of
// the viewer. The triangles then keep their true 3D vertices, so a saddle quad
// yields two genuinely non-coplanar triangles rather than a flattened one.
//
// A polygon that is self-intersecting, or degenerate enough that no ear can be
// found, falls back to a fan for whatever remains: an answer that is wrong in
// the way the old code was wrong is still better than a hang.
uint[3][] triangulatePolygonEarClip(const(Vec3)[] poly)
{
    immutable size_t n = poly.length;
    if (n < 3) return null;
    if (n == 3) return [cast(uint[3])[0u, 1u, 2u]];

    // Newell normal — robust for non-planar and non-convex rings alike.
    Vec3 nrm = Vec3(0, 0, 0);
    foreach (i; 0 .. n) {
        const Vec3 a = poly[i];
        const Vec3 b = poly[(i + 1) % n];
        nrm.x += (a.y - b.y) * (a.z + b.z);
        nrm.y += (a.z - b.z) * (a.x + b.x);
        nrm.z += (a.x - b.x) * (a.y + b.y);
    }

    uint[3][] fan() {
        auto outTris = new uint[3][](n - 2);
        foreach (i; 0 .. n - 2)
            outTris[i] = [0u, cast(uint)(i + 1), cast(uint)(i + 2)];
        return outTris;
    }

    immutable float nlen = sqrt(dot(nrm, nrm));
    if (!(nlen > 1e-20f)) return fan();
    immutable Vec3 nhat = nrm * (1.0f / nlen);

    Vec3 e1, e2;
    if (!perpendicularFrame(nhat, e1, e2)) return fan();

    auto xs = new float[](n);
    auto ys = new float[](n);
    foreach (i; 0 .. n) {
        immutable Vec3 d = poly[i] - poly[0];
        xs[i] = dot(d, e1);
        ys[i] = dot(d, e2);
    }
    // `e2 = nhat x e1` makes (e1, e2) right-handed about the Newell normal, so
    // the projected ring is counter-clockwise. Measured rather than assumed —
    // a ring that comes out clockwise is flipped so the convexity test below
    // has one sign to test against.
    float area2 = 0.0f;
    foreach (i; 0 .. n) {
        immutable size_t j = (i + 1) % n;
        area2 += xs[i]*ys[j] - xs[j]*ys[i];
    }
    if (area2 < 0.0f) foreach (i; 0 .. n) ys[i] = -ys[i];

    static float cross2(float ox, float oy, float ax, float ay,
                        float bx, float by) @safe pure nothrow @nogc
    {
        return (ax - ox)*(by - oy) - (ay - oy)*(bx - ox);
    }

    auto idx = new uint[](n);
    foreach (i; 0 .. n) idx[i] = cast(uint)i;

    auto tris = new uint[3][](n - 2);
    size_t produced = 0;
    size_t guard    = 0;                       // bounds the whole clip loop
    immutable size_t guardMax = n * n + 4;

    while (idx.length > 3 && guard++ < guardMax) {
        bool clipped = false;
        foreach (k; 0 .. idx.length) {
            immutable size_t kp = (k + idx.length - 1) % idx.length;
            immutable size_t kn = (k + 1) % idx.length;
            immutable uint ip = idx[kp], ic = idx[k], inx = idx[kn];
            // Convex corner?
            if (!(cross2(xs[ip], ys[ip], xs[ic], ys[ic], xs[inx], ys[inx]) > 0.0f))
                continue;
            // No other remaining vertex inside the candidate ear.
            bool blocked = false;
            foreach (m; 0 .. idx.length) {
                immutable uint iq = idx[m];
                if (iq == ip || iq == ic || iq == inx) continue;
                immutable float c0 = cross2(xs[ip], ys[ip], xs[ic],  ys[ic],  xs[iq], ys[iq]);
                immutable float c1 = cross2(xs[ic], ys[ic], xs[inx], ys[inx], xs[iq], ys[iq]);
                immutable float c2 = cross2(xs[inx], ys[inx], xs[ip], ys[ip], xs[iq], ys[iq]);
                if (c0 >= 0.0f && c1 >= 0.0f && c2 >= 0.0f) { blocked = true; break; }
            }
            if (blocked) continue;
            tris[produced++] = [ip, ic, inx];
            idx = idx[0 .. k] ~ idx[k + 1 .. $];
            clipped = true;
            break;
        }
        if (!clipped) break;                   // no ear found — fall through
    }

    if (idx.length == 3) {
        tris[produced++] = [idx[0], idx[1], idx[2]];
        return tris[0 .. produced];
    }
    // Stalled (self-intersecting / degenerate ring): fan the remainder.
    foreach (i; 1 .. idx.length - 1) {
        if (produced >= tris.length) break;
        tris[produced++] = [idx[0], idx[i], idx[i + 1]];
    }
    return tris[0 .. produced];
}




unittest { // triangulatePolygonEarClip — THE NON-CONVEX GUARD.
           //
           // The property is not "n-2 triangles come back"; it is that their
           // UNION is the polygon. The fixture is an L whose vertex 0 is chosen
           // so that a fan from it covers the notch — the test computes that
           // fan and asserts it DOES cover the notch, so the discriminator is
           // carried by the test rather than asserted in prose.
    immutable Vec3[6] L = [
        Vec3( 0,  2, 0),   // 0 — the fan pivot, and it cannot see the whole ring
        Vec3(-2,  2, 0),
        Vec3(-2, -2, 0),
        Vec3( 2, -2, 0),
        Vec3( 2,  0, 0),
        Vec3( 0,  0, 0),   // 5 — the reflex corner
    ];
    immutable float qx = 1.2f, qy = 0.5f;   // in the notch: outside the L

    static bool inTri(float px, float py, Vec3 a, Vec3 b, Vec3 c) {
        static float cr(float ox, float oy, float mx, float my, float nx, float ny) {
            return (mx - ox)*(ny - oy) - (my - oy)*(nx - ox);
        }
        immutable float c0 = cr(a.x, a.y, b.x, b.y, px, py);
        immutable float c1 = cr(b.x, b.y, c.x, c.y, px, py);
        immutable float c2 = cr(c.x, c.y, a.x, a.y, px, py);
        return (c0 >= 0 && c1 >= 0 && c2 >= 0) || (c0 <= 0 && c1 <= 0 && c2 <= 0);
    }

    // Premise 1: the probe really is outside the polygon.
    float[] xs, ys;
    foreach (p; L) { xs ~= p.x; ys ~= p.y; }
    assert(!pointInPolygon2D(qx, qy, xs, ys),
        "fixture: the probe must sit in the NOTCH, outside the L");

    // Premise 2: a fan from vertex 0 would cover it — this is the failure the
    // ear clip exists to avoid, computed here rather than claimed.
    bool fanCovers = false;
    foreach (i; 1 .. L.length - 1)
        if (inTri(qx, qy, L[0], L[i], L[i + 1])) { fanCovers = true; break; }
    assert(fanCovers,
        "fixture: a fan from vertex 0 must cover the notch, or this polygon "
        ~ "cannot tell a fan from a proper triangulation");

    auto tris = triangulatePolygonEarClip(L[]);
    assert(tris.length == L.length - 2,
        "a simple polygon must yield exactly n-2 triangles");
    foreach (t; tris)
        assert(!inTri(qx, qy, L[t[0]], L[t[1]], L[t[2]]),
            "NO ear-clipped triangle may cover the notch — a triangulation "
            ~ "whose union exceeds the polygon reports a cursor beside the "
            ~ "polygon as being on it");

    // And the union does cover a point that IS inside.
    bool covered = false;
    foreach (t; tris)
        if (inTri(-1.0f, -1.0f, L[t[0]], L[t[1]], L[t[2]])) { covered = true; break; }
    assert(covered, "the union must still cover the polygon's own interior");
}

// Build the cutting plane through the drawn Start→End line, PERPENDICULAR to
// the work plane. This is the SliceTool's plane law (mesh.sliceTool, S0) and a
// deliberate divergence from cameraPlaneFromScreenLine above: instead of the
// camera-eye plane, the cut plane contains the line direction AND has its
// normal lying IN the work plane, so a horizontal drag in a front view yields a
// clean axis-aligned cut regardless of camera pitch.
//
//   n = normalize(cross(end - start, workplaneNormal))   (n ⟂ line, n ⟂ wpN)
//   p = start                                            (any point on the line)
//
// Two planes are perpendicular iff their normals are perpendicular; n ⟂ wpN
// makes the cut plane ⟂ the work plane, and n ⟂ (end-start) makes it contain
// the drawn line. `workplaneNormal` need not be unit — only its direction is
// used. Returns false (p, n left undefined) when the line is degenerate
// (start ≈ end) or the line is parallel to the work-plane normal (cross ≈ 0,
// no unique plane).
bool planeFromLineAndWorkplane(Vec3 start, Vec3 end, Vec3 workplaneNormal,
                               out Vec3 p, out Vec3 n, float eps = 1e-6f)
{
    Vec3 dir = end - start;
    if (dot(dir, dir) < eps * eps) return false;
    Vec3 nRaw = cross(dir, workplaneNormal);
    if (nRaw.length < eps) return false;
    p = start;
    n = normalize(nRaw);
    return true;
}

// planeForSlice — the interactive Slice tool's cut-plane law (task 0269, S3;
// owner-revised task 0284). The `axis` is an EXTRUSION DIRECTION, NOT the normal:
// the slice plane is the drawn Start→End line EXTRUDED along the axis direction,
// so it ALWAYS contains the line (both endpoints satisfy (X - start)·n == 0).
//   n = normalize(cross(end - start, axisDir))   (n ⟂ line, n ⟂ axisDir)
//   p = start                                     (any point on the line)
// This mirrors the drag construction exactly (drag = extrude along the work-plane
// normal), so every axis mode yields a plane CONTAINING both drawn points. The
// `axisMode` selects `axisDir`:
//   0 = Free/drag — axisDir = workplaneNormal (= planeFromLineAndWorkplane; the
//                   base/default behavior).
//   1 = X, 2 = Y, 3 = Z — axisDir = that WORLD axis.
//   4 = Custom          — axisDir = vector.
// Returns false (p, n undefined) when the mode has no well-defined plane: a
// zero-length `vector` in Custom, or — the degenerate guard — a line that is
// (near-)parallel to `axisDir` so cross ≈ 0 (the caller keeps the previous plane
// rather than building a garbage one). A degenerate / zero-length line likewise
// yields false through the shared construction.
bool planeForSlice(Vec3 start, Vec3 end, Vec3 workplaneNormal,
                   int axisMode, Vec3 vector, out Vec3 p, out Vec3 n,
                   float eps = 1e-6f)
{
    Vec3 axisDir;
    switch (axisMode) {
        case 1: axisDir = Vec3(1, 0, 0); break;   // X
        case 2: axisDir = Vec3(0, 1, 0); break;   // Y
        case 3: axisDir = Vec3(0, 0, 1); break;   // Z
        case 4:                                    // Custom
            if (vector.length < eps) { p = start; return false; }
            axisDir = vector;
            break;
        default:                                   // 0 = Free/drag
            axisDir = workplaneNormal;
            break;
    }
    // Extrude the drawn line along axisDir. planeFromLineAndWorkplane builds the
    // identical plane (n = normalize(cross(end-start, axisDir)), p = start) and
    // carries the degenerate guards: false for a zero-length line OR a line
    // parallel to axisDir (cross ≈ 0).
    return planeFromLineAndWorkplane(start, end, axisDir, p, n, eps);
}






// ---------------------------------------------------------------------------
// Angle Snap (Slice tool, S5) — quantize a drawn line's in-work-plane angle to
// the nearest multiple of a step, so an endpoint drag lands on clean angles
// (0°, 45°, 90°, … for a 45° step). Pure + unit-tested; the SliceTool's
// interactive drag and its headless apply both route through these so the
// snapped line is identical either way.
// ---------------------------------------------------------------------------

/// Quantize `angleDeg` to the nearest multiple of `stepDeg` (both in degrees).
/// `stepDeg <= 0` disables snapping and returns `angleDeg` unchanged (a guard
/// against a zero/negative Angle param). Half-steps round away from zero
/// (std.math.round), so with a 45° step 22.5° → 45°, −22.5° → −45°.
float snapAngleToMultiple(float angleDeg, float stepDeg) {
    if (stepDeg <= 0) return angleDeg;
    return cast(float)(round(angleDeg / stepDeg) * stepDeg);
}

/// Snap the line `anchor → moving` so its direction — projected into the
/// orthonormal work-plane basis (`axis1`, `axis2`) — lands on the nearest
/// multiple of `stepDeg`. The line LENGTH is preserved; only the direction
/// rotates. Returns the new `moving` endpoint. Degenerate inputs return
/// `moving` unchanged: `stepDeg <= 0` (snap off), a zero-length line, or a line
/// perpendicular to the work plane (no defined in-plane angle). The rebuilt
/// endpoint always lies in the work plane through `anchor` — the interactive
/// Slice keeps its line in the work plane, so that is the identity there.
Vec3 snapLineEndpointToAngle(Vec3 anchor, Vec3 moving, Vec3 axis1, Vec3 axis2,
                             float stepDeg) {
    if (stepDeg <= 0) return moving;
    Vec3 dir = moving - anchor;
    float len = dir.length;
    if (len < 1e-9f) return moving;
    float u = dot(dir, axis1);
    float v = dot(dir, axis2);
    if (u * u + v * v < 1e-18f) return moving;   // line ⟂ plane: no in-plane angle
    float ang     = atan2(v, u) * 180.0f / cast(float)PI;
    float snapped = snapAngleToMultiple(ang, stepDeg) * cast(float)PI / 180.0f;
    Vec3 nd = axis1 * cos(snapped) + axis2 * sin(snapped);
    return anchor + nd * len;
}




// Closest point on segment [a, b] to ray (origin O, unit direction D).
// Standard parameterisation: P(t) = a + t·(b-a), Q(s) = O + s·D.
// Minimises |P(t) - Q(s)|² over (s, t); t is then clamped to [0, 1]
// so the result stays on the segment. D is expected unit length —
// callers typically pass `screenRay(...)`. Used by element-falloff
// click-pick to anchor the falloff sphere at the exact click-point
// on an edge rather than its midpoint.
Vec3 closestPointOnSegmentToRay(Vec3 a, Vec3 b, Vec3 O, Vec3 D)
    @safe pure nothrow @nogc
{
    import std.math : abs;
    Vec3 u   = b - a;
    Vec3 w   = a - O;
    float uu = dot(u, u);
    if (uu < 1e-12f) return a;            // degenerate segment
    float uD = dot(u, D);
    float Dw = dot(D, w);
    float uw = dot(u, w);
    // 2x2 normal equations (D assumed unit, so DD = 1):
    //   [uu  -uD] [t]   [-uw]
    //   [-uD  1 ] [s] = [ Dw]
    float denom = uu - uD * uD;
    float t;
    if (abs(denom) < 1e-9f) {
        // Ray ∥ segment: project (a − O) onto u.
        t = -uw / uu;
    } else {
        t = (uD * Dw - uw) / denom;
    }
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    return a + u * t;
}


/// Closest world point on an INFINITE LINE (center + t*dir) to a cursor ray
/// (O + s*D). Unlike `closestPointOnSegmentToRay`, t is unclamped — the result
/// may lie anywhere along the infinite line. D is expected unit length.
/// Used by the LINE constraint primitive in snap.d (WorldAxis candidates).
Vec3 closestPointOnLineToRay(Vec3 center, Vec3 dir, Vec3 O, Vec3 D)
    @safe pure nothrow @nogc
{
    import std.math : abs;
    Vec3  w   = center - O;
    float uu  = dot(dir, dir);
    if (uu < 1e-12f) return center;     // degenerate direction
    float uD  = dot(dir, D);
    float Dw  = dot(D, w);
    float uw  = dot(dir, w);
    // Normal equations (D assumed unit, DD = 1):
    //   [uu  -uD] [t]   [-uw]
    //   [-uD  1 ] [s] = [ Dw]
    float denom = uu - uD * uD;
    float t;
    if (abs(denom) < 1e-9f) {
        // Ray parallel to line: project ray origin onto line.
        t = -uw / uu;
    } else {
        t = (uD * Dw - uw) / denom;
    }
    return center + dir * t;  // t unclamped — infinite line
}


// offsetInPlane: direction perpendicular to edgeDir inside a face.
//
// edgeDir  — normalized direction of the bevel edge (va→vb for F1, vb→va for F2)
// faceNorm — unit normal of the face the new vertex lives in
//
// Returns unit vector d such that  orig + d * width  places the new vertex at
// perpendicular distance width from the bevel-edge line, lying in the face plane.
// Formula: cross(faceNorm, edgeDir), normalised — points INTO the face.
Vec3 offsetInPlane(Vec3 edgeDir, Vec3 faceNorm) @safe pure nothrow @nogc {
    Vec3 p = cross(faceNorm, edgeDir);
    float len = p.length;
    return len > 1e-6f ? p / len : Vec3(0, 1, 0);
}

// offsetMeetDir: junction-vertex offset direction.
//
// e1 — unit vector FROM jv toward prevV in the gap face (face winding prevV→jv→nextV)
// e2 — unit vector FROM jv toward nextV in the gap face
// faceNorm — unit normal of the gap face
//
// In the gap face, prevV arrives INTO jv (F2 winding → edge direction = -e1),
// while nextV departs FROM jv (F1 winding → edge direction = +e2).
// So the two offset lines are:
//   L1: p1 + t*e1,  where p1 = offsetInPlane(-e1, faceNorm)  ← prevV / F2 side
//   L2: p2 + s*e2,  where p2 = offsetInPlane( e2, faceNorm)  ← nextV / F1 side
// Returns direction d s.t.  jv + d*width  = intersection of L1 and L2.
Vec3 offsetMeetDir(Vec3 e1, Vec3 e2, Vec3 faceNorm) @safe pure nothrow @nogc {
    Vec3 p1 = offsetInPlane(-e1, faceNorm); // prevV side: negate (F2 winding)
    Vec3 p2 = offsetInPlane(e2,  faceNorm); // nextV side: direct (F1 winding)

    Vec3  rhs   = p2 - p1;
    Vec3  n     = cross(e1, e2);
    float denom = dot(n, n);
    if (denom < 1e-12f) {
        return safeNormalize((p1 + p2) * 0.5f);
    }
    float t = dot(cross(rhs, e2), n) / denom;
    return p1 + e1 * t;
}

// offsetMeet: junction offset with per-edge widths.
//
// Same geometry as offsetMeetDir but the two offset lines may be displaced
// by different amounts (wPrev for the prevV side, wNext for the nextV side).
// Returns the absolute world-space intersection point. Useful when one
// EdgeHalf is beveled (wEdge = width) and the other is not (wEdge = 0).
//
// Parallel-edge fallback (the two edges are collinear inside the face):
//   - Both bev: the perpendicular offsets coincide (p1 ≈ p2) — return
//     their midpoint, the correct in-face perpendicular displacement
//     (this is the "pipe" case).
//   - One bev + one non-bev: return the offset-side position. The boundary
//     vertex stays at the perpendicular slide (like a normal cube-corner
//     BV) and a separate edge-slide vertex for the TRI_FAN cap is
//     materialized higher up, not by offsetMeet.
//   - Both non-bev: caller shouldn't invoke this (no BV needed).
Vec3 offsetMeet(Vec3 jv, Vec3 ePrev, Vec3 eNext, Vec3 faceNorm,
                float wPrev, float wNext) @safe pure nothrow @nogc {
    import std.math : abs;
    Vec3 p1 = jv + offsetInPlane(-ePrev, faceNorm) * wPrev;
    Vec3 p2 = jv + offsetInPlane( eNext, faceNorm) * wNext;
    Vec3 r  = p2 - p1;
    float denom = dot(cross(ePrev, eNext), faceNorm);
    if (abs(denom) < 1e-6f) {
        if (wPrev > 0 && wNext == 0) return p1;
        if (wNext > 0 && wPrev == 0) return p2;
        return (p1 + p2) * 0.5f;
    }
    float t = dot(cross(r, eNext), faceNorm) / denom;
    return p1 + ePrev * t;
}

// bevelMiterPoint: where an EDGE bevel puts the vertex at a face corner whose
// BOTH ring edges are bevelled. Task 1170; the law is measured, not derived.
//
// THE PLANE IS THE TWO EDGES, AND NO FACE NORMAL DECIDES IT. This is the
// whole content of the finding (divergence-ledger row 1, toolcard
// `edge_bevel_offset_normal`, 53 cells / 520 created vertices / 117 mitred
// corners, worst residual 1.53e-5 x inset — the reference's float32 vertex
// storage floor). The point is the one in `span{ePrev, eNext}` at
// perpendicular distance `wPrev` from the ePrev line and `wNext` from the
// eNext line:
//
//     p = jv + sign * (wPrev*eNext + wNext*ePrev) / sin(theta)
//
// (write p = alpha*eNext + beta*ePrev; the distance from the ePrev line is
// |alpha|*sin(theta), so alpha = wPrev/sin(theta), and symmetrically. With
// wPrev == wNext == inset this is exactly the measured
// `inset * (a + b) / sin(theta)`, the bisector at length inset/sin(theta/2).)
//
// `ringNormal` — Newell over the WHOLE ring — appears in exactly ONE place:
// the branch. Both `+(...)` and `-(...)` sit at those two distances, and the
// engine takes the one pointing into the face:
//
//     sign = +1  iff  dot(cross(eNext, ePrev), ringNormal) > 0     (strict)
//
// i.e. "is this corner convex with respect to its own ring's normal". That
// scored 117/117 overall and 16/16 on the corners built reflex to separate
// the sign candidates, while the rule that owns the PLANE (the corner
// triangle at the moving vertex) is the WORST rule for the branch at 106/117.
// Plane and branch are two different questions and are ported as two — do not
// collapse them back into one normal. The operand order in that cross product
// is load-bearing and was pinned by data, not by derivation: `cross(eNext,
// ePrev)` reproduces all 117 corners and `cross(ePrev, eNext)` reproduces 0.
//
// NOT `offsetMeet` — and deliberately not a change TO it. `offsetMeet`
// intersects the two offset LINES by projecting along `faceNorm`, so on a
// non-planar face its answer lies in no plane at all (the measured 4.86 deg
// of direction error, 8 % of the bevel width). It stays as it is because
// poly.bevel's `insetCorner` is its other caller and answers to a separately
// measured law. On a PLANAR face the two functions agree identically by
// construction (offsetMeet's own offset directions cross(faceNorm, -+e) are
// the same orientation convention as `sign` here), which is why the mitres on
// planar faces do not move.
//
// Degenerate corner (the two edges collinear — a straight-through "pipe"
// corner, sin(theta) ~ 0): there is no unique such point, and the reference
// was never measured there. Delegates to `offsetMeet`, whose own degenerate
// branch then answers exactly as it does today.
Vec3 bevelMiterPoint(Vec3 jv, Vec3 ePrev, Vec3 eNext, Vec3 ringNormal,
                     float wPrev, float wNext) @safe pure nothrow @nogc {
    Vec3  n    = cross(eNext, ePrev);
    float sinT = n.length;              // |a x b| = sin(theta) for unit a, b
    if (sinT < 1e-6f)
        return offsetMeet(jv, ePrev, eNext, ringNormal, wPrev, wNext);
    immutable float sign = dot(n, ringNormal) > 0 ? 1.0f : -1.0f;
    return jv + (eNext * wPrev + ePrev * wNext) * (sign / sinT);
}


// bevelArcPoints: Edge Bevel Round Level — TRUE CIRCULAR ARC generator
// (task 0391, capture-verified law: edge.bevel spec `behavior.round_level_law`).
//
// Given a cross-section root `center` (the ORIGINAL, un-beveled edge vertex)
// and two unit directions `dirA`/`dirB` (the flat L=0 chamfer-corner
// directions, e.g. the two adjacent-edge slide directions already used by
// `Mesh.bevelEdgesByMask`), returns `2^level + 1` points evenly spaced BY
// ANGLE on the circle of radius `radius` centered at `center`, sweeping from
// `center + dirA*radius` (t=0) to `center + dirB*radius` (t=2^level).
// `level == 0` returns exactly the 2 flat endpoints (today's straight-chord
// behavior — byte-identical, no rounding).
//
// Deliberately NOT the same law as poly.bevel's Segments (see
// `Mesh.bevelFacesByMask`'s segment-ring loop): Segments is a LINEAR lerp
// staircase, this is a geodesic angular sweep on a true circle — the two
// tools were independently capture-verified to use DIFFERENT laws
// (`vibe3d-divergence` note, doc/bevel_full_plan.md Phase 3).
//
// Degenerate fallback (dirA/dirB parallel or antiparallel, cross product
// too small to define a rotation axis): falls back to a linear lerp between
// the 2 endpoints (matches offsetMeetDir's own parallel-edge fallback
// convention above) rather than dividing by a near-zero axis length.
Vec3[] bevelArcPoints(Vec3 center, Vec3 dirA, Vec3 dirB, float radius, int level)
    @safe pure nothrow {
    import std.math : acos, sin, cos;
    immutable int n = 1 << level;   // segment count; n+1 points
    auto pts = new Vec3[](n + 1);

    Vec3 axis = cross(dirA, dirB);
    immutable float axisLen = axis.length;
    if (axisLen < 1e-9f) {
        // Parallel/antiparallel — no well-defined rotation plane; degrade to
        // a linear lerp between the two flat endpoints (never divides by
        // the near-zero axis length).
        foreach (t; 0 .. n + 1) {
            immutable float f = cast(float)t / cast(float)n;
            pts[t] = center + (dirA * (1.0f - f) + dirB * f) * radius;
        }
        return pts;
    }
    axis = axis / axisLen;

    float cosTheta = dot(dirA, dirB);
    if (cosTheta > 1.0f)  cosTheta = 1.0f;
    if (cosTheta < -1.0f) cosTheta = -1.0f;
    immutable float theta = acos(cosTheta);

    foreach (t; 0 .. n + 1) {
        immutable float ang = theta * (cast(float)t / cast(float)n);
        immutable float ct  = cos(ang), st = sin(ang);
        // Rodrigues' rotation of dirA about `axis` by `ang`; the third term
        // (axis * dot(axis,v) * (1-cosθ)) drops out because axis ⟂ dirA by
        // construction (axis = normalize(cross(dirA,dirB))).
        Vec3 rotated = dirA * ct + cross(axis, dirA) * st;
        pts[t] = center + rotated * radius;
    }
    return pts;
}
