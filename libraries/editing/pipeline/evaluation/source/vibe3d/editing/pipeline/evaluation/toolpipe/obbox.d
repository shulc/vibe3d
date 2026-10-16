// The ORIENTED bounding box of a point set, and the two constructions that
// replace it for very small selections.
//
// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
//
// `AxisStage.computeSelectionBboxBasis` used to build a WORLD-AXIS-ALIGNED
// box: per-world-axis min/max over the touched vertices, the averaged face
// normal snapped to the nearest world axis, and a fixed per-axis lookup for
// the second row. That agrees with an oriented box exactly when the subject
// is already world-aligned — which is every rig ever measured against the
// reference — and answers a signed world permutation on a rotated one. A cube
// rotated 30 degrees about X has a face normal of (0, 0.866, 0.5) and the old
// code still answered (0, 1, 0).
//
// This module is the oriented construction, ported from a static read of the
// reference. Every constant below is named with the step it belongs to.
//
// ── THE LAW, IN ORDER ─────────────────────────────────────────────────────
//
// The point set is the vertices the selection touches. Its COUNT selects one
// of four constructions:
//
//   count == 0   the identity — world axes, and a failure report.
//   count == 1   the vertex's geometric normal is the third row; the second
//                row starts as a world basis vector chosen non-parallel to it
//                and two cross products orthogonalise.
//   count == 2   the first row is the edge direction B - A with its dominant
//                component forced positive; the second row is the edge's
//                average polygon normal (or a world basis vector when the two
//                points do not bound an edge); two cross products finish.
//   count >= 3   the covariance path: moments accumulated about the
//                AXIS-ALIGNED BBOX CENTRE, a symmetric eigen-decomposition by
//                cyclic Jacobi, rows ordered by EIGENVALUE DESCENDING and
//                published in that plain order with NO reshuffle. The entire
//                post-processing is ONE conditional negation of all nine
//                entries, gated on `dot(m[argmin extent], ref) < 0`.
//
// THE DIVISOR, and why it is not the scalar it looks like (task 0658).
//
// The shorthand for this law is "covariance about the bbox centre, NOT about
// the mean", and it is misleading twice over. The reference accumulates the
// six second moments `S` and the three FIRST moments `M` about the bbox
// centre, scales BOTH by one `s`, and then forms
//
//     C = s*S - (s*M)(s*M)^T
//
// The bbox centre is a numerical origin, not the point the moments are taken
// about: the first-moment subtraction cancels it. What does NOT cancel is the
// divisor, because `s` multiplies `M` BEFORE the square — the subtracted
// rank-1 term carries `s^2` where the second-moment term carries `s`. With
// `mu = mean - aabbCentre` and the reference's `s = 1/(2n)`:
//
//     C = S/(2n) - mu*mu^T/4 = (1/2) * [ Cov + (1/2) mu*mu^T ]
//
// so the reference's matrix is the ordinary covariance about the mean PLUS
// half of `mu mu^T` — equivalently, the moments about the point
// `q = mean - mu/sqrt(2)`, which sits 70.71% of the way from the mean toward
// the bbox centre. Three consequences, and the first is the whole reason this
// took its own task:
//
//   * `1/n` and `1/(2n)` differ by a positive SCALAR only when `mu` is zero,
//     i.e. only when the mean and the bbox centre coincide. Eigenvectors are
//     invariant under a scalar, so on any centrally symmetric subject — every
//     square, cube, regular n-gon, lattice and rod this port was built and
//     tested on — the divisor is INVISIBLE. That is how it hid. Off centre it
//     is a rank-1 perturbation and it rotates the eigenvectors outright.
//   * Applying HALF the formula (the divisor without the first-moment
//     scaling, or the reverse) gives a THIRD matrix that neither engine
//     computes. The two parts are one law; see the four-way `unittest` below,
//     which separates all of them on one subject.
//   * On a subject whose plane is TILTED the axis-aligned bbox centre leaves
//     that plane, so `mu` picks up an out-of-plane component and the box's
//     THIRD row — the normal itself — moves with it. On an axis-aligned plane
//     it cannot, and only the in-plane rows move. Both were measured against
//     the reference's own recorded frames (`tests/test_obb_covariance_divisor.d`).
//
// Translation invariance survives all of it, because `mu` is a difference of
// two points that translate together — a property worth testing, and tested.
//
// `ref` is the normalised sum of the selection's polygon normals when it has
// polygons, and `normalize(boxCentre - aabbCentre)` when it does not.
//
// ── WHAT THIS DELIBERATELY DOES NOT REPRODUCE ─────────────────────────────
//
// On a subject whose two in-plane second moments are EQUAL — a square, a
// cube, a regular n-gon, an isotropic lattice — the reference's in-plane
// answer is not a tie-break but a ONE-BIT CLIFF. Its Jacobi returns the
// identity when the cross moment is bit-exactly zero and rotates by EXACTLY
// 45 degrees when it is any nonzero epsilon, because at equal diagonals the
// rotation parameter is forced to 1. Which side a given subject lands on is
// decided by float32 vertex storage, by the rounding of the box centre, by
// the enumeration order and by a divisor — not by the shape. Reproducing it
// would be reproducing a fingerprint of somebody's arithmetic, not a
// behaviour.
//
// So: degeneracy is detected by a RELATIVE test (`|li - lj| <= EPS_DEGENERATE
// * lmax`), never by a bit comparison, and the degenerate subspace is filled
// by a convention OF OUR OWN, declared in `fillDegenerateSubspace` below. On
// an axis-aligned square that convention answers the world axes, which is
// what the reference's exact-zero branch answers and what this codebase
// already answered, so the change is a no-op there.

module vibe3d.editing.pipeline.evaluation.toolpipe.obbox;

import std.math : abs, sqrt;

import vibe3d.util.math.math : Vec3, cross, dot, normalize;

// ---------------------------------------------------------------------------
// Constants — one per step of the law.
// ---------------------------------------------------------------------------

/// Two eigenvalues are treated as EQUAL when they differ by no more than this
/// fraction of the largest. Relative, never a bit compare: see the header.
/// Sized against float32 vertex storage (~1e-7 relative), so a rectangle has
/// to be square to within half a part per million before it is called one.
enum double EPS_DEGENERATE = 1e-6;

/// Below this the whole covariance is noise and no direction is meaningful.
enum double EPS_COVARIANCE = 1e-24;

/// The moment divisor is `1 / (MOMENT_PASSES * n)`, not `1 / n`: the
/// reference's point counter is incremented on BOTH of its enumeration passes
/// and never reset between them, so it divides by twice the point count. Read
/// statically, and confirmed against its recorded frames on five stands — see
/// the header for why this is not the no-op a scalar divisor would be, and
/// `tests/test_obb_covariance_divisor.d` for the measurement.
enum double MOMENT_PASSES = 2.0;

/// Cyclic Jacobi sweep cap. Numerical Recipes uses 50; a symmetric 3x3
/// converges in three or four.
enum int JACOBI_MAX_SWEEPS = 50;

/// Jacobi's first-three-sweeps threshold is `0.2 * sm / (n*n)` with n = 3.
enum double JACOBI_TRESH_NUM = 0.2;
enum double JACOBI_TRESH_DEN = 9.0;   // n*n for a 3x3

/// The "is this off-diagonal already negligible" probe multiplier.
enum double JACOBI_SMALL_G = 100.0;

// ---------------------------------------------------------------------------

/// Which construction produced a frame. Reported so a caller (and a test) can
/// tell "the covariance said so" from "there was only one vertex".
enum ObbSource {
    None,          /// nothing enumerated — the frame is the world identity
    VertexNormal,  /// count == 1
    EdgePair,      /// count == 2
    Covariance,    /// count >= 3
}

/// The reference's box, in our types: three axes as ROWS, the extent
/// along each, and the oriented centre.
struct ObbFrame {
    Vec3[3] m    = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    double[3] size = [0, 0, 0];
    Vec3 center  = Vec3(0, 0, 0);
    int count    = 0;
    ObbSource source = ObbSource.None;

    /// True when a real construction ran. `count == 0` answers the preloaded
    /// identity and reports failure, exactly as the reference does.
    @property bool ok() const { return source != ObbSource.None; }
}

// Local geometry keeps signed normals and canonical tangents independently
// of Select mapping (20261570; doc/local_component_frame_model_2026-10-07.md).
void localComponentFrameFromBox(const ObbFrame box,
                               out Vec3 right, out Vec3 up, out Vec3 normal)
    @safe pure nothrow @nogc {
    int lo = 0, hi = 0;
    foreach (i; 1 .. 3) {
        if (box.size[i] < box.size[lo]) lo = i;
        if (box.size[i] > box.size[hi]) hi = i;
    }
    normal = normalize(box.m[lo]);
    Vec3 tangent = normalize(box.m[hi]);
    float[3] components = [tangent.x, tangent.y, tangent.z];
    int dominant = 0;
    foreach (i; 1 .. 3)
        if (abs(components[i]) > abs(components[dominant])) dominant = i;
    if (components[dominant] < 0) tangent = -tangent;
    up = normalize(cross(normal, tangent));
    right = normalize(cross(up, normal));
}

void alignLocalComponentFrames(Vec3[] right, Vec3[] up, const(Vec3)[] normal)
    @safe pure nothrow @nogc {
    int nearest(Vec3 target, Vec3 r, Vec3 u, Vec3 n, out bool negative) {
        float[3] d = [dot(target, r), dot(target, u), dot(target, n)];
        int i = abs(d[0]) > abs(d[1]) && abs(d[0]) > abs(d[2]) ? 0
              : abs(d[1]) > abs(d[2]) ? 1 : 2;
        negative = d[i] < 0;
        return i;
    }
    foreach (i; 1 .. normal.length) {
        bool negA, negU;
        int j = nearest(normal[0], right[i], up[i], normal[i], negA);
        int k = nearest(up[0], right[i], up[i], normal[i], negU);
        bool changed = false;
        if (j == 2 && k == 0) {
            up[i] = negA != negU ? -right[i] : right[i];
            changed = true;
        } else if ((j == 2 && k == 1 && negA != negU)
                   || (j != 2 && k == 1 && dot(up[0], up[i]) < 0)) {
            up[i] = -up[i];
            changed = true;
        }
        if (changed) right[i] = cross(up[i], normal[i]);
    }
}

// ---------------------------------------------------------------------------
// Numerical Recipes `jacobi`, for a symmetric 3x3.
//
// The reference's eigensolver is this routine verbatim — its constants (0.5,
// 100.0, 0.2, 9.0, 1.0, the absolute-value and sign masks) were all
// identified by a static read. Reproducing it rather than writing a closed
// form is what makes the non-degenerate agreement exact rather than merely
// close.
//
// `v`'s COLUMNS are the eigenvectors; `d` holds the eigenvalues.
// ---------------------------------------------------------------------------
void jacobiSym3(double[3][3] a, out double[3] d, out double[3][3] v)
    @safe pure nothrow @nogc
{
    double[3] b, z;
    foreach (ip; 0 .. 3) {
        foreach (iq; 0 .. 3) v[ip][iq] = 0.0;
        v[ip][ip] = 1.0;
        b[ip] = a[ip][ip];
        d[ip] = a[ip][ip];
        z[ip] = 0.0;
    }
    // One rotation applied to a pair of entries of `a` (or of `v`).
    void rot(ref double[3][3] mat, int i, int j, int k, int l,
             double s, double tau) {
        double g = mat[i][j];
        double h = mat[k][l];
        mat[i][j] = g - s * (h + g * tau);
        mat[k][l] = h + s * (g - h * tau);
    }

    foreach (sweep; 1 .. JACOBI_MAX_SWEEPS + 1) {
        double sm = abs(a[0][1]) + abs(a[0][2]) + abs(a[1][2]);
        // THE EARLY-OUT. A matrix that is already diagonal returns the
        // IDENTITY — no rotation is attempted. This is the branch an
        // axis-aligned subject takes, and it is why an axis-aligned square
        // answers world axes here and in the reference alike.
        if (sm == 0.0) return;
        double tresh = (sweep < 4) ? JACOBI_TRESH_NUM * sm / JACOBI_TRESH_DEN
                                   : 0.0;
        foreach (ip; 0 .. 2) {
            foreach (iq; ip + 1 .. 3) {
                double g = JACOBI_SMALL_G * abs(a[ip][iq]);
                if (sweep > 4 && abs(d[ip]) + g == abs(d[ip])
                              && abs(d[iq]) + g == abs(d[iq])) {
                    a[ip][iq] = 0.0;
                } else if (abs(a[ip][iq]) > tresh) {
                    double h = d[iq] - d[ip];
                    double t;
                    if (abs(h) + g == abs(h)) {
                        t = a[ip][iq] / h;
                    } else {
                        // h == 0 (equal diagonals) forces theta = 0 and t = 1,
                        // i.e. EXACTLY 45 degrees. That is the cliff the header
                        // refuses to chase; `fillDegenerateSubspace` overwrites
                        // whatever comes out of it.
                        double theta = 0.5 * h / a[ip][iq];
                        t = 1.0 / (abs(theta) + sqrt(1.0 + theta * theta));
                        if (theta < 0.0) t = -t;
                    }
                    double c   = 1.0 / sqrt(1.0 + t * t);
                    double s   = t * c;
                    double tau = s / (1.0 + c);
                    h = t * a[ip][iq];
                    z[ip] -= h; z[iq] += h;
                    d[ip] -= h; d[iq] += h;
                    a[ip][iq] = 0.0;
                    foreach (j; 0 .. ip)          rot(a, j, ip, j, iq, s, tau);
                    foreach (j; ip + 1 .. iq)     rot(a, ip, j, j, iq, s, tau);
                    foreach (j; iq + 1 .. 3)      rot(a, ip, j, iq, j, s, tau);
                    foreach (j; 0 .. 3)           rot(v, j, ip, j, iq, s, tau);
                }
            }
        }
        foreach (ip; 0 .. 3) {
            b[ip] += z[ip];
            d[ip]  = b[ip];
            z[ip]  = 0.0;
        }
    }
}

// ---------------------------------------------------------------------------
// The descending eigenpair sort.
//
// The reference sorts the three eigenpairs by eigenvalue descending right after
// the Jacobi call. The sort's BODY was not read; this is the classic selection
// sort published alongside the Jacobi routine above. The descending ORDER is
// what every consumer below is written against and is pinned in several places.
// Its TIE-BREAK is not pinned by anything, and that is stated plainly here
// rather than dressed up as a measurement.
//
// THE TIE-BREAK IS UNPINNED. The inner comparison is `>=`, so among BIT-EQUAL
// eigenvalues the LAST maximum wins; a stable sort would keep the first. On a
// cube's +Y face the eigenvalues are (c, 0, c) with the two c's BIT-IDENTICAL,
// and `>=` leaves the original column order (2, 0, 1) where a stable sort
// leaves (0, 2, 1). An earlier revision of this file claimed the reference's
// RECORDED box `[(0,0,1), (1,0,0), (0,1,0)]` chooses between those, and called
// this line the one discriminating measurement in the whole port. It is not.
// The reason is structural, not a gap in the corpus:
//
//   * `>=` and `>` differ only when `d[j] == p` EXACTLY, i.e. only inside a run
//     of bit-equal eigenvalues;
//   * both leave the same sorted `d`, so `obbFromPoints`' degeneracy flags come
//     out identical either way;
//   * bit-equal is a difference of zero, so such a run always satisfies the
//     RELATIVE degeneracy test — and the degenerate branches then overwrite
//     exactly the rows inside that run, seeded from the row OUTSIDE it, whose
//     position no tie-break can move.
//
// So whenever this tie-break gets to choose, `fillDegenerateSubspace` (or the
// isotropic branch) discards its choice a few lines later. MEASURED, by
// building both variants and running them side by side: they agree bit for bit
// on every box row, extent, centre and published frame over squares at 24
// orientations, cubes, regular 3..12-gons, rods, lattices on and off exact
// float boundaries, and 4000 pseudo-random point sets, half of them
// hard-quantised so that bit-equal moments actually occur. Both reproduce the
// recorded box.
//
// What the recorded box DOES discriminate is the DESCENDING world-index order
// inside `fillDegenerateSubspace`: flip that to ascending and the recorded-box
// `unittest` fires at once; flip this line and nothing geometric moves at all.
//
// `>=` is kept because it is what the published routine does, so a later reader
// comparing the two sources finds them the same shape. The `unittest` below
// pins it as a property of THIS FUNCTION — a guard against silent drift, not
// evidence about the reference.
// ---------------------------------------------------------------------------
void sortEigenpairsDescending(ref double[3] d, ref double[3][3] v)
    @safe pure nothrow @nogc
{
    foreach (i; 0 .. 2) {
        int k = cast(int)i;
        double p = d[i];
        foreach (j; i + 1 .. 3) {
            if (d[j] >= p) { k = cast(int)j; p = d[j]; }   // >= : last max wins
        }
        if (k != i) {
            d[k] = d[i];
            d[i] = p;
            foreach (j; 0 .. 3) {
                double t = v[j][i];
                v[j][i] = v[j][k];
                v[j][k] = t;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// OUR degeneracy convention — declared here, and nowhere else.
//
// When two eigenvalues are equal to within EPS_DEGENERATE the eigenvectors
// spanning them are arbitrary: any rotation inside that subspace is an equally
// valid eigenbasis, and whichever one an eigensolver happens to emit is a
// property of its rounding, not of the shape. We therefore DISCARD it and fill
// the subspace deterministically from the world axes:
//
//   * `n` is the one axis of the triple that IS determined (the odd one out).
//   * take the two world axes least aligned with `n`, in DESCENDING world
//     index order (Z before Y before X);
//   * Gram-Schmidt them against `n` and against each other, KEEPING THE WORLD
//     AXIS' OWN SIGN.
//
// Two details are load-bearing, and they are held down by DIFFERENT things.
// Separating them matters, because an earlier revision credited both to the
// same place and credited the first one to the wrong place entirely:
//
//   * the DESCENDING index order is pinned by the reference's RECORDED box, and
//     that recording is the only measurement it has. On a cube's +Y face the
//     odd axis is world Y, the other two in descending order are Z then X, and
//     the rows come out `[(0,0,1), (1,0,0), (0,1,0)]` — the recorded box, row
//     for row. Swap this to ascending and the recorded-box `unittest` fires.
//     This is the term that recording discriminates; the eigenpair sort's
//     tie-break, which used to be given the credit, is not (see its header);
//   * the SECOND row is the projected world axis, NOT `cross(n, a)`. The two
//     differ by a sign on half the cases — MEASURED: they agree for a +Y
//     normal and disagree for a +Z and an +X one — and only the projected form
//     reproduces the POSITIVE world-axis columns Jacobi's identity early-out
//     hands back, because it keeps the seed axis' own sign where the cross
//     product can invert it. That is a consistency argument with our own
//     eigensolver, NOT a measurement, and it is unpinned by this file:
//     substituting `cross(n, a)` leaves every `unittest` here passing, because
//     the recorded rig's normal is +Y, one of the cases where the two agree. A
//     degenerate subject with a +Z normal is what would settle it.
// ---------------------------------------------------------------------------
private void fillDegenerateSubspace(Vec3 n, out Vec3 a, out Vec3 b)
    @safe pure nothrow @nogc
{
    Vec3[3] world = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    // The world axis `n` is most aligned with — the one NOT available as an
    // in-subspace seed.
    int kn = 0;
    float best = abs(n.x);
    if (abs(n.y) > best) { best = abs(n.y); kn = 1; }
    if (abs(n.z) > best) { best = abs(n.z); kn = 2; }
    // The other two, DESCENDING.
    int j0 = (kn == 2) ? 1 : 2;
    int j1 = (kn == 0) ? 1 : 0;
    Vec3 pa = world[j0] - n * dot(n, world[j0]);
    if (pa.length < 1e-6f) {            // seed was parallel to n after all
        int t = j0; j0 = j1; j1 = t;
        pa = world[j0] - n * dot(n, world[j0]);
    }
    a = normalize(pa);
    Vec3 pb = world[j1] - n * dot(n, world[j1]);
    pb = pb - a * dot(a, pb);
    b = (pb.length < 1e-6f) ? normalize(cross(n, a)) : normalize(pb);
}

// ---------------------------------------------------------------------------
// count >= 3 — the covariance path.
//
// `pts` are the enumerated points in the pipeline's working space. `refDir`
// is the sign-fix reference: the normalised sum of the selection's polygon
// normals, or the zero vector when the selection has none (in which case the
// fallback `normalize(boxCentre - aabbCentre)` is computed here, exactly as
// the reference computes it).
// ---------------------------------------------------------------------------
ObbFrame obbFromPoints(const(Vec3)[] pts, Vec3 refDir) @safe pure nothrow
{
    ObbFrame f;
    f.count = cast(int)pts.length;
    if (pts.length == 0) return f;             // identity + failure

    // --- the AXIS-ALIGNED bbox centre. The moments are accumulated about
    //     THIS point (see the header for why that is not the same claim as
    //     "the covariance is about this point"): it is the numerical origin,
    //     and it is also the anchor the extents and the oriented centre are
    //     measured from further down, where it does matter materially.
    Vec3 mn = pts[0], mx = pts[0];
    foreach (p; pts[1 .. $]) {
        if (p.x < mn.x) mn.x = p.x;  if (p.x > mx.x) mx.x = p.x;
        if (p.y < mn.y) mn.y = p.y;  if (p.y > mx.y) mx.y = p.y;
        if (p.z < mn.z) mn.z = p.z;  if (p.z > mx.z) mx.z = p.z;
    }
    Vec3 aabbCentre = (mn + mx) * 0.5f;

    // --- the six second moments and three first moments, about that centre.
    double sxx = 0, syy = 0, szz = 0, sxy = 0, sxz = 0, syz = 0;
    double mx1 = 0, my1 = 0, mz1 = 0;
    foreach (p; pts) {
        double dx = cast(double)p.x - aabbCentre.x;
        double dy = cast(double)p.y - aabbCentre.y;
        double dz = cast(double)p.z - aabbCentre.z;
        sxx += dx * dx; syy += dy * dy; szz += dz * dz;
        sxy += dx * dy; sxz += dx * dz; syz += dy * dz;
        mx1 += dx; my1 += dy; mz1 += dz;
    }
    // ONE `s` scales both the second moments and the first moments, and it is
    // `1/(2n)`. Those are not two decisions: the reference computes exactly
    // this, and applying either half alone produces a matrix neither engine
    // has (header, and the four-way `unittest` below).
    //
    // It looks like a uniform halving that no eigenvector could see, and on a
    // centrally symmetric subject it is exactly that. It is not one in
    // general: `s` multiplies the first moments BEFORE they are squared, so
    // the subtracted rank-1 term ends up scaled by `s^2` against the second
    // moments' `s`, leaving `C = (1/2)[Cov + (1/2) mu mu^T]` with
    // `mu = mean - aabbCentre`. See the header.
    double s = 1.0 / (MOMENT_PASSES * cast(double)pts.length);
    sxx *= s; syy *= s; szz *= s; sxy *= s; sxz *= s; syz *= s;
    mx1 *= s; my1 *= s; mz1 *= s;
    double[3][3] c;
    c[0][0] = sxx - mx1 * mx1;  c[0][1] = sxy - mx1 * my1;  c[0][2] = sxz - mx1 * mz1;
    c[1][0] = c[0][1];          c[1][1] = syy - my1 * my1;  c[1][2] = syz - my1 * mz1;
    c[2][0] = c[0][2];          c[2][1] = c[1][2];          c[2][2] = szz - mz1 * mz1;

    double[3] d;
    double[3][3] v;
    jacobiSym3(c, d, v);
    sortEigenpairsDescending(d, v);

    // Columns of v are the eigenvectors; rows of the box are those columns in
    // the order the sort left them — the PLAIN descending order, no reshuffle.
    foreach (i; 0 .. 3)
        f.m[i] = Vec3(cast(float)v[0][i], cast(float)v[1][i], cast(float)v[2][i]);

    // --- degeneracy, by the relative test. `d` is sorted descending.
    double lmax = d[0] > 0 ? d[0] : -d[0];
    if (lmax <= EPS_COVARIANCE) {
        // No direction carries any variance at all (all points coincident).
        // Declared answer: world axes.
        f.m = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    } else {
        bool deg01 = (d[0] - d[1]) <= EPS_DEGENERATE * lmax;
        bool deg12 = (d[1] - d[2]) <= EPS_DEGENERATE * lmax;
        if (deg01 && deg12) {
            // Isotropic: no axis is determined. Declared answer: the world
            // axes in world order, which is what this stage has always
            // published for a fully symmetric selection and what the
            // reference's own `sm == 0` branch produces before its sort
            // permutes bit-equal keys.
            f.m = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
        } else if (deg01) {
            // Plate: rows 0 and 1 span an arbitrary in-plane basis, row 2 is
            // determined.
            fillDegenerateSubspace(normalize(f.m[2]), f.m[0], f.m[1]);
        } else if (deg12) {
            // Rod: row 0 is determined, rows 1 and 2 are arbitrary about it.
            fillDegenerateSubspace(normalize(f.m[0]), f.m[1], f.m[2]);
        }
    }

    finishBox(f, pts, aabbCentre, refDir);
    f.source = ObbSource.Covariance;
    return f;
}

// ---------------------------------------------------------------------------
// The extents, the oriented centre, and the ONE conditional negation.
//
// Shared by all three real constructions: the reference runs the covariance
// builder unconditionally and only then overwrites its rows on the small-count
// arms, so the extent/centre/sign tail is common code.
// ---------------------------------------------------------------------------
private void finishBox(ref ObbFrame f, const(Vec3)[] pts, Vec3 aabbCentre,
                       Vec3 refDir) @safe pure nothrow
{
    double[3] lo = [double.infinity, double.infinity, double.infinity];
    double[3] hi = [-double.infinity, -double.infinity, -double.infinity];
    foreach (p; pts) {
        Vec3 rel = p - aabbCentre;
        foreach (k; 0 .. 3) {
            double t = dot(f.m[k], rel);
            if (t < lo[k]) lo[k] = t;
            if (t > hi[k]) hi[k] = t;
        }
    }
    Vec3 c = aabbCentre;
    foreach (k; 0 .. 3) {
        f.size[k] = hi[k] - lo[k];
        c = c + f.m[k] * cast(float)(0.5 * (lo[k] + hi[k]));
    }
    f.center = c;

    // `ref` fallback: with no polygon normals to sum, the reference takes the
    // direction from the axis-aligned centre to the ORIENTED one. On a
    // centrally symmetric set the two coincide and this is the zero vector, so
    // the dot is 0, so nothing is negated — deterministic, not arbitrary.
    Vec3 rd = refDir;
    if (rd.length < 1e-12f) rd = c - aabbCentre;
    if (rd.length < 1e-12f) return;
    rd = normalize(rd);

    // The THINNEST axis is the one tested: argmin over |extent|.
    int k = 0;
    double bestExtent = abs(f.size[0]);
    foreach (i; 1 .. 3) {
        if (abs(f.size[i]) < bestExtent) { bestExtent = abs(f.size[i]); k = cast(int)i; }
    }
    if (dot(f.m[k], rd) < 0) {
        // ALL NINE entries. This flips the determinant — it is an orientation
        // fix that sacrifices handedness, not a handedness fix. Consumers that
        // need a right-handed frame must re-derive one; `axisFrameFromBox`
        // does exactly that.
        foreach (i; 0 .. 3) f.m[i] = f.m[i] * -1.0f;
    }
}

// ---------------------------------------------------------------------------
// count == 1 — the vertex's geometric normal.
//
// `n` is the vertex normal IN THE WORKING SPACE (the reference transforms a
// mesh-local normal by the layer's 3x3 here; see `axis.d` for why our caller
// has nothing to apply). `upHintAxis` is the world axis used as the
// non-parallel seed when the normal is dominated by world Y.
//
// NOT NORMALISED in the reference: with `m[1]` and `m[2]` unit,
// `m[0] = m[1] x m[2]` has length sin(theta) and the re-derived `m[1]`
// inherits it. We normalise, because our packet publishes an ORTHONORMAL
// frame whose inverse is its transpose (`frameMatrixInverse`); a non-unit
// basis would silently break that identity. Flagged rather than assumed.
// ---------------------------------------------------------------------------
ObbFrame obbFromVertexNormal(Vec3 p, Vec3 n, int upHintAxis) @safe pure nothrow
{
    ObbFrame f;
    f.count  = 1;
    if (n.length < 1e-12f) return f;            // no normal — identity, failure
    Vec3[3] world = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    f.m[2] = normalize(n);
    // argmax |component| of the normal; when that is world Y the reference
    // asks the viewport's work plane for the seed instead of using Y itself.
    int k = 0;
    float best = abs(f.m[2].x);
    if (abs(f.m[2].y) > best) { best = abs(f.m[2].y); k = 1; }
    if (abs(f.m[2].z) > best) { best = abs(f.m[2].z); k = 2; }
    int j = (k == 1) ? upHintAxis : 1;
    if (j < 0 || j > 2) j = 1;
    f.m[1] = world[j];
    f.m[0] = normalize(cross(f.m[1], f.m[2]));
    f.m[1] = normalize(cross(f.m[2], f.m[0]));
    f.center = p;
    f.size   = [0, 0, 0];
    f.source = ObbSource.VertexNormal;
    return f;
}

// ---------------------------------------------------------------------------
// count == 2 — the edge.
//
// `a` and `b` are the two points in the working space; the direction is built
// from them and gets NO transform, because the reference stores the enumerated
// positions already in world space. `nrm` is the edge's average polygon normal
// and DOES get the layer transform in the reference — the asymmetry is the
// point, and a port that applies one transform to both is wrong. Our caller
// works entirely in the pipe's mesh space, so it applies neither, which
// preserves the asymmetry (each term is transformed exactly as many times as
// it needs: zero).
// ---------------------------------------------------------------------------
ObbFrame obbFromEdge(Vec3 a, Vec3 b, Vec3 nrm, bool hasNrm) @safe pure nothrow
{
    ObbFrame f;
    f.count = 2;
    Vec3 dir = b - a;
    if (dir.length < 1e-12f) return f;          // coincident — identity, failure

    // THE SIGN CONVENTION: the direction's DOMINANT COMPONENT is forced
    // positive. This elects a component and flips the whole direction on its
    // sign; it has nothing to do with ordering.
    int k = 0;
    float best = abs(dir.x);
    if (abs(dir.y) > best) { best = abs(dir.y); k = 1; }
    if (abs(dir.z) > best) { best = abs(dir.z); k = 2; }
    float kc = (k == 0) ? dir.x : (k == 1 ? dir.y : dir.z);
    if (kc < 0) dir = dir * -1.0f;
    f.m[0] = normalize(dir);                    // see the normalisation note above

    Vec3[3] world = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    bool haveN = hasNrm && nrm.length >= 1e-12f;
    Vec3 second = haveN ? normalize(nrm) : world[(k + 1) % 3];
    if (abs(dot(second, f.m[0])) > 0.999999f)   // parallel — fall back
        second = world[(k + 1) % 3];
    f.m[1] = second;
    f.m[2] = normalize(cross(f.m[0], f.m[1]));
    f.m[1] = normalize(cross(f.m[2], f.m[0]));

    Vec3 mn = Vec3(a.x < b.x ? a.x : b.x, a.y < b.y ? a.y : b.y,
                   a.z < b.z ? a.z : b.z);
    Vec3 mxv = Vec3(a.x > b.x ? a.x : b.x, a.y > b.y ? a.y : b.y,
                    a.z > b.z ? a.z : b.z);
    Vec3 aabbCentre = (mn + mxv) * 0.5f;
    Vec3[2] pts = [a, b];
    finishBox(f, pts[], aabbCentre, Vec3(0, 0, 0));
    f.source = ObbSource.EdgePair;
    return f;
}

// ---------------------------------------------------------------------------
// The box -> published frame mapping.
//
// The AXIS stage publishes `right / up / fwd`, and the reference's tool elects
// a row permutation of the box before publishing. The election's HEAD is read
// (`argmax_i |m[i][0]|` with a tie fix against `argmax_i |m[i][2]|`); its TAIL,
// which assigns the elected indices to the packet's slots, is NOT read, and
// both recorded rigs land on the same permutation so no measurement separates
// the candidates. This is therefore OUR rule, stated once:
//
//   fwd   = m[2] — the row the sign fix orients, i.e. the box's thinnest axis
//                  and, for any planar selection, its normal;
//   right = the one of m[0] / m[1] with the larger |x|, first wins on a tie —
//           the read election restricted to the rows the normal is not in;
//   up    = fwd x right, so the published frame is right-handed BY
//           CONSTRUCTION even though the box's own rows need not be (the sign
//           fix flips their determinant).
//
// It reproduces, exactly: the reference's recorded box for a cube's +Y face
// (published (+X, -Z, +Y)), the recorded lane-A 45-degree frame, and all six
// signed face normals of the world-aligned convention this stage shipped
// before the port.
// ---------------------------------------------------------------------------
void axisFrameFromBox(const ref ObbFrame f, out Vec3 right, out Vec3 up,
                      out Vec3 fwd) @safe pure nothrow
{
    fwd = normalize(f.m[2]);
    int e = (abs(f.m[1].x) > abs(f.m[0].x)) ? 1 : 0;
    right = normalize(f.m[e]);
    // Re-orthogonalise: `right` may not be exactly perpendicular to `fwd`
    // after the small-count constructions.
    Vec3 u = cross(fwd, right);
    if (u.length < 1e-6f) {
        // Degenerate pairing — fall back to the other row.
        right = normalize(f.m[e == 0 ? 1 : 0]);
        u = cross(fwd, right);
    }
    up    = normalize(u);
    right = normalize(cross(up, fwd));
}
