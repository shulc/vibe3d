module uv_transform;

/// Pure affine UV transform kernel + affected-corner collector + pivot helpers.
///
/// All operations work on a `MeshMap` of domain `MapDomain.PolyVertex` and
/// `dim == 2`.  No mesh-level side-effects (no `commitChange`, no version
/// bumps); the owning command calls `commitChange(MeshEditScope.Material)`.
///
/// Rotate convention: CCW (counter-clockwise) — a 90° CCW rotation about
/// (0.5, 0.5) cycles the unit-square corners (0,0)→(1,0)→(1,1)→(0,1)→(0,0),
/// i.e. maps (1,0)↦(1,1).

import mesh : Mesh, MeshMap, MapDomain;

// ---------------------------------------------------------------------------
// Public API enums
// ---------------------------------------------------------------------------

enum UvAxis  { U, V }
enum UvPivot { Unit, Origin, Centroid }

// ---------------------------------------------------------------------------
// Affine transform — a 2×2 linear part (row-major) plus a 2-element
// translation.  Maps (u,v) → lin·[u,v]ᵀ + trans, where lin[row][col].
// ---------------------------------------------------------------------------

struct UvAffine {
    float[2][2] lin   = [[1, 0], [0, 1]]; // identity (row 0 = [1,0], row 1 = [0,1])
    float[2]    trans = [0, 0];
}

// ---------------------------------------------------------------------------
// Apply an affine transform to every loop in `loops` within the given MeshMap.
//
// Preconditions (caller-enforced):
//   - map !is null && map.dim == 2
//   - every index l in `loops` satisfies l * 2 + 1 < map.data.length
//
// The caller (collectAffectedUvLoops) guarantees the in-range invariant for
// valid meshes; no redundant bounds check is repeated here.
// ---------------------------------------------------------------------------

void applyUvAffine(MeshMap* map, const size_t[] loops, in UvAffine a) {
    assert(map !is null);
    assert(map.dim == 2);
    foreach (l; loops) {
        const size_t b = l * 2;
        const float  u = map.data[b];
        const float  v = map.data[b + 1];
        map.data[b]     = a.lin[0][0] * u + a.lin[0][1] * v + a.trans[0];
        map.data[b + 1] = a.lin[1][0] * u + a.lin[1][1] * v + a.trans[1];
    }
}

// ---------------------------------------------------------------------------
// Collect the loop indices that a UV command should affect.
//
// * If any face is currently selected (isFaceSelected), only those faces'
//   corners are included.  Selection is EditMode-agnostic: stale face marks
//   from a prior face-mode selection are honoured regardless of current mode.
//   Document this footgun in command help strings — a face-scoped UV edit can
//   fire even when the user is in vertex/edge mode.
// * If no face is selected, the whole map (all loops 0 .. m.loops.length) is
//   affected.
// ---------------------------------------------------------------------------

size_t[] collectAffectedUvLoops(const ref Mesh m) {
    // Determine mode by scanning for any selected face.
    bool anyFaceSelected = false;
    foreach (fi; 0 .. m.faces.length) {
        if (m.isFaceSelected(fi)) { anyFaceSelected = true; break; }
    }

    if (!anyFaceSelected) {
        // Whole-map mode: all loops.
        size_t[] all = new size_t[](m.loops.length);
        foreach (i; 0 .. m.loops.length) all[i] = i;
        return all;
    }

    // Selected-faces mode: gather each selected face's corners.
    size_t[] result;
    foreach (uint fi; 0 .. cast(uint) m.faces.length) {
        if (!m.isFaceSelected(fi)) continue;
        const uint nc = cast(uint) m.faces[fi].length;
        foreach (uint c; 0 .. nc) {
            const size_t loop = m.faceCornerLoop(fi, c);
            if (loop == size_t.max) continue;   // bounds guard from faceCornerLoop
            result ~= loop;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Compute the pivot point for a UvPivot mode over the affected corners.
//
// Unit     → (0.5, 0.5)  — centre of the canonical [0..1]² UV square.
// Origin   → (0.0, 0.0)
// Centroid → bbox centre ((min+max)/2) of the affected corners' UVs.
//            NOT the arithmetic mean — bbox-centre is the correct choice for
//            in-place mirror symmetry (the mirror of a corner at one bbox edge
//            lands on the opposite bbox edge).
// ---------------------------------------------------------------------------

float[2] computePivot(const(MeshMap)* map, const size_t[] loops, UvPivot p) {
    final switch (p) {
        case UvPivot.Unit:   return [0.5f, 0.5f];
        case UvPivot.Origin: return [0.0f, 0.0f];
        case UvPivot.Centroid:
            if (loops.length == 0) return [0.5f, 0.5f];
            float umin = float.infinity, umax = -float.infinity;
            float vmin = float.infinity, vmax = -float.infinity;
            foreach (l; loops) {
                const size_t b = l * 2;
                const float  u = map.data[b];
                const float  v = map.data[b + 1];
                if (u < umin) umin = u;
                if (u > umax) umax = u;
                if (v < vmin) vmin = v;
                if (v > vmax) vmax = v;
            }
            return [(umin + umax) * 0.5f, (vmin + vmax) * 0.5f];
    }
}

// ---------------------------------------------------------------------------
// Affine builders for specific operations.
//
// For a linear map M about pivot p: trans = p − M·p
// so that M·p + trans == p (the pivot is a fixed point of the transform).
// ---------------------------------------------------------------------------

/// Flip-U: M = diag(−1, 1)  →  u' = 2·pivot.u − u,  v' = v
UvAffine makeFlipU(float[2] pivot) {
    UvAffine a;
    a.lin      = [[-1, 0], [0, 1]];
    a.trans[0] = pivot[0] - (a.lin[0][0] * pivot[0] + a.lin[0][1] * pivot[1]);
    a.trans[1] = pivot[1] - (a.lin[1][0] * pivot[0] + a.lin[1][1] * pivot[1]);
    return a;
}

/// Flip-V: M = diag(1, −1)  →  u' = u,  v' = 2·pivot.v − v
UvAffine makeFlipV(float[2] pivot) {
    UvAffine a;
    a.lin      = [[1, 0], [0, -1]];
    a.trans[0] = pivot[0] - (a.lin[0][0] * pivot[0] + a.lin[0][1] * pivot[1]);
    a.trans[1] = pivot[1] - (a.lin[1][0] * pivot[0] + a.lin[1][1] * pivot[1]);
    return a;
}

/// Rotate CCW by `angleDeg` degrees: M = [[cos, −sin], [sin, cos]]
UvAffine makeRotate(float angleDeg, float[2] pivot) {
    import std.math : cos, sin, PI;
    const float r = angleDeg * (PI / 180.0f);
    const float c = cos(r);
    const float s = sin(r);
    UvAffine a;
    a.lin      = [[c, -s], [s, c]];
    a.trans[0] = pivot[0] - (a.lin[0][0] * pivot[0] + a.lin[0][1] * pivot[1]);
    a.trans[1] = pivot[1] - (a.lin[1][0] * pivot[0] + a.lin[1][1] * pivot[1]);
    return a;
}

// ---------------------------------------------------------------------------
// Module-level unit tests — analytic golden contracts on the kernel algebra.
// These are run by `dub test --config=modeling` (the mandatory gate for any
// change touching a core module).
// ---------------------------------------------------------------------------

unittest {
    import std.math : fabs;
    enum float eps = 1e-5f;
    bool feq(float a, float b) pure { return fabs(a - b) < eps; }

    auto eval(in UvAffine a, float u, float v) {
        import std.typecons : tuple;
        return tuple(
            a.lin[0][0] * u + a.lin[0][1] * v + a.trans[0],
            a.lin[1][0] * u + a.lin[1][1] * v + a.trans[1]);
    }

    // ----------------------------------------------------------------
    // flip-U about (0.5, 0.5): u' = 1 − u, v unchanged.
    {
        auto a = makeFlipU([0.5f, 0.5f]);
        auto r = eval(a, 0.3f, 0.7f);
        assert(feq(r[0], 0.7f), "flip-U: u' = 1-u");
        assert(feq(r[1], 0.7f), "flip-U: v unchanged");
    }

    // flip-V about (0.5, 0.5): v' = 1 − v, u unchanged.
    {
        auto a = makeFlipV([0.5f, 0.5f]);
        auto r = eval(a, 0.3f, 0.7f);
        assert(feq(r[0], 0.3f), "flip-V: u unchanged");
        assert(feq(r[1], 0.3f), "flip-V: v' = 1-v");
    }

    // ----------------------------------------------------------------
    // Rotate 90° CCW about (0.5, 0.5): cycles the unit-square corners.
    //   (0,0)→(1,0)→(1,1)→(0,1)→(0,0)  — so (1,0)↦(1,1)  [CCW].
    {
        auto a = makeRotate(90.0f, [0.5f, 0.5f]);
        // (1, 0) → (1, 1)
        auto r = eval(a, 1.0f, 0.0f);
        assert(feq(r[0], 1.0f), "rotate 90°: (1,0) u'=1");
        assert(feq(r[1], 1.0f), "rotate 90°: (1,0) v'=1");
        // (0, 0) → (1, 0)
        r = eval(a, 0.0f, 0.0f);
        assert(feq(r[0], 1.0f), "rotate 90°: (0,0) u'=1");
        assert(feq(r[1], 0.0f), "rotate 90°: (0,0) v'=0");
        // (1, 1) → (0, 1)
        r = eval(a, 1.0f, 1.0f);
        assert(feq(r[0], 0.0f), "rotate 90°: (1,1) u'=0");
        assert(feq(r[1], 1.0f), "rotate 90°: (1,1) v'=1");
        // (0, 1) → (0, 0)
        r = eval(a, 0.0f, 1.0f);
        assert(feq(r[0], 0.0f), "rotate 90°: (0,1) u'=0");
        assert(feq(r[1], 0.0f), "rotate 90°: (0,1) v'=0");
    }

    // rotate 0°: identity.
    {
        auto a = makeRotate(0.0f, [0.5f, 0.5f]);
        auto r = eval(a, 0.3f, 0.7f);
        assert(feq(r[0], 0.3f), "rotate 0°: identity u");
        assert(feq(r[1], 0.7f), "rotate 0°: identity v");
    }

    // rotate 360°: ≈ identity within float tolerance.
    {
        auto a = makeRotate(360.0f, [0.5f, 0.5f]);
        auto r = eval(a, 0.3f, 0.7f);
        assert(feq(r[0], 0.3f), "rotate 360°: ≈identity u");
        assert(feq(r[1], 0.7f), "rotate 360°: ≈identity v");
    }

    // ----------------------------------------------------------------
    // computePivot: Centroid is bbox-centre, NOT the arithmetic mean.
    // Corners: (0,0), (6,0), (0,2) — bbox centre = (3,1), mean = (2,0.67).
    {
        MeshMap fakeMap;
        fakeMap.dim    = 2;
        fakeMap.domain = MapDomain.PolyVertex;
        fakeMap.data   = [0.0f, 0.0f,  6.0f, 0.0f,  0.0f, 2.0f];
        const size_t[] loops = [0, 1, 2];
        auto pivot = computePivot(&fakeMap, loops, UvPivot.Centroid);
        assert(feq(pivot[0], 3.0f), "bbox-centre u = 3 (mean would be 2)");
        assert(feq(pivot[1], 1.0f), "bbox-centre v = 1 (mean would be 0.67)");
        // Confirm it differs from the arithmetic mean.
        assert(!feq(pivot[0], 2.0f), "bbox-centre must differ from mean");
    }

    // ----------------------------------------------------------------
    // applyUvAffine: identity transform leaves data unchanged.
    {
        MeshMap m2;
        m2.dim    = 2;
        m2.domain = MapDomain.PolyVertex;
        m2.data   = [0.2f, 0.3f,  0.8f, 0.7f];
        const size_t[] loops = [0, 1];
        UvAffine id;   // default-init is identity
        applyUvAffine(&m2, loops, id);
        assert(feq(m2.data[0], 0.2f) && feq(m2.data[1], 0.3f), "identity: corner 0");
        assert(feq(m2.data[2], 0.8f) && feq(m2.data[3], 0.7f), "identity: corner 1");
    }
}
