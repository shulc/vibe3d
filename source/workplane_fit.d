/// Pure plane-fitting arithmetic behind `workplane.alignToSelection`.
///
/// The skew-edge-pair rule (task 7120): two selected edges that share no
/// endpoint and no polygon fit the plane by least squares `n . p = 1` over
/// their endpoints — anchored at the WORLD origin, so the result depends on
/// position — and roll it along the major axis of the smallest bounding
/// rectangle among the 2-D hull's diameter and the four hull edges at the
/// diameter's ends. Read, step for step, from
/// `tests/fixtures/workplane_align_and_primitive_placement.json`
/// (`laws.skew_edge_pair`); law and provenance in `doc/measured_laws.md` §23.
/// The tie branch (square hull) is a static decode that was not driven.
module workplane_fit;

import math : Vec3;
import std.math : sqrt, abs, atan2, sin, cos;

alias D3 = double[3];
alias D2 = double[2];

/// Outcome of `skewEdgePairFrame`. Every non-`ok` value is a refusal: the
/// reference arithmetic for it was not captured.
enum SkewFit {
    ok,
    /// `sum p p^T` is singular: every endpoint lies on a plane through the
    /// world origin (reference "not exercised"; we refuse).
    singular,
    /// Fewer than two distinct points in the 2-D hull.
    degenerate,
    /// The fitted normal is exactly opposite its dominant axis, where the
    /// shortest-arc rotation is undefined (reference branch not decoded).
    antiparallel,
}

/// `AxisMaxExtent` with the reference's tie rules.
int axisMaxExtent(D3 v) pure nothrow @nogc @safe {
    const a = abs(v[0]), b = abs(v[1]), c = abs(v[2]);
    if (a > b && a > c) return 0;
    if (b >= a && b > c) return 1;
    return 2;
}

/// Least-squares plane `n . p = 1` through `pts`: `n = (sum p p^T)^-1 (sum p)`,
/// flipped so `mean(p) . n >= 0`, normalised. False when the system is
/// singular, `|det| <= 1e-12 * trace^3`.
bool planeFitNormal(const D3[] pts, out D3 n) pure nothrow @nogc @safe {
    double[3][3] m = 0;
    D3 s = 0;
    foreach (p; pts)
        foreach (i; 0 .. 3) {
            s[i] += p[i];
            foreach (j; 0 .. 3) m[i][j] += p[i] * p[j];
        }
    const det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
              - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
              + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    const tr = m[0][0] + m[1][1] + m[2][2];
    if (!(abs(det) > 1e-12 * tr * tr * tr)) return false;
    // Cramer's rule.
    foreach (c; 0 .. 3) {
        double[3][3] t = m;
        foreach (r; 0 .. 3) t[r][c] = s[r];
        n[c] = (t[0][0] * (t[1][1] * t[2][2] - t[1][2] * t[2][1])
              - t[0][1] * (t[1][0] * t[2][2] - t[1][2] * t[2][0])
              + t[0][2] * (t[1][0] * t[2][1] - t[1][1] * t[2][0])) / det;
    }
    if (s[0] * n[0] + s[1] * n[1] + s[2] * n[2] < 0) n[] = -n[];
    const l = sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    n[] /= l;
    return true;
}

private double cross2(D2 o, D2 a, D2 b) pure nothrow @nogc @safe {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
}

/// Convex hull of `pts` in the list order the reference traverses: Graham
/// scan from the lowest `v` (ties: highest `u`), counter-clockwise, nearer
/// collinear points dropped, strict left turns — then REVERSED (the scan
/// stack is read from its last pushed point).
D2[] hullReferenceOrder(const D2[] pts) pure @safe {
    import std.algorithm : sort;
    if (pts.length == 0) return null;
    size_t best = 0;
    foreach (c; 1 .. pts.length)
        if (pts[best][1] > pts[c][1] || (pts[best][1] == pts[c][1] && pts[c][0] > pts[best][0]))
            best = c;
    const D2 p0 = pts[best];
    D2[] rest;
    foreach (i, p; pts) if (i != best) rest ~= p;
    double d2(D2 p) { return (p[0] - p0[0]) ^^ 2 + (p[1] - p0[1]) ^^ 2; }
    // Angles around p0 lie in (0, pi], so the cross sign is a strict order.
    rest.sort!((a, b) {
        const c = cross2(p0, a, b);
        return c > 0 || (c == 0 && d2(a) < d2(b));
    });
    // Collinear with p0: keep only the farthest of each run.
    D2[] order = [p0];
    foreach (i, p; rest) {
        if (i + 1 < rest.length && cross2(p0, p, rest[i + 1]) == 0) continue;
        order ~= p;
    }
    if (order.length < 2) return order.dup;
    D2[] st = order[0 .. 2].dup;
    size_t i = 2;
    while (i < order.length) {
        if (st.length < 2) break;
        if (cross2(st[$ - 2], st[$ - 1], order[i]) > 0) { st ~= order[i]; ++i; }
        else st = st[0 .. $ - 1];
    }
    D2[] rev;
    foreach_reverse (p; st) rev ~= p;
    return rev;
}

/// Bounding rectangle aligned to hull edge (f, s): its area, and its
/// direction along the LONGER side flipped so `v >= 0`.
private double rectForEdge(const D2[] h, size_t f, size_t s, out D2 dir,
                           out double len, out double wid) pure nothrow @nogc @safe {
    D2 e = [h[s][0] - h[f][0], h[s][1] - h[f][1]];
    const l = sqrt(e[0] * e[0] + e[1] * e[1]);
    if (l == 0) return double.infinity;
    D2 d = [e[0] / l, e[1] / l];
    D2 perp = [-d[1], d[0]];
    double amin = double.infinity, amax = -double.infinity;
    double bmin = double.infinity, bmax = -double.infinity;
    foreach (q; h) {
        D2 r = [q[0] - h[f][0], q[1] - h[f][1]];
        const a = r[0] * d[0] + r[1] * d[1];
        const b = r[0] * perp[0] + r[1] * perp[1];
        if (a < amin) amin = a;
        if (a > amax) amax = a;
        if (b < bmin) bmin = b;
        if (b > bmax) bmax = b;
    }
    const w = amax - amin, ht = bmax - bmin;
    if (ht > w) { dir = [-d[1], d[0]]; len = ht; wid = w; }
    else        { dir = d;             len = w;  wid = ht; }
    if (dir[1] < 0) dir[] = -dir[];
    return len * wid;
}

/// Major axis of the hull (list order from `hullReferenceOrder`): the first
/// strictly farthest pair, then the four hull edges adjacent to it, each
/// replacing the current only on a STRICTLY smaller area; tie branch last.
D2 hullMajorAxis(const D2[] h) pure nothrow @nogc @safe {
    const n = h.length;
    if (n < 2) return [0.0, 1.0];
    double best = 0;
    size_t bi = 0, bj = 0;
    foreach (i; 0 .. n)
        foreach (j; i + 1 .. n) {
            const d2 = (h[i][0] - h[j][0]) ^^ 2 + (h[i][1] - h[j][1]) ^^ 2;
            if (d2 > best) { best = d2; bi = i; bj = j; }
        }
    const L = sqrt(best);
    if (L == 0) return [0.0, 1.0];
    D2 dir = [(h[bj][0] - h[bi][0]) / L, (h[bj][1] - h[bi][1]) / L];
    if (dir[1] < 0) dir[] = -dir[];
    D2 c = [(h[bi][0] + h[bj][0]) / 2, (h[bi][1] + h[bj][1]) / 2];
    double smin = 0, smax = 0;
    foreach (q; h) {
        const s = (q[0] - c[0]) * dir[1] - (q[1] - c[1]) * dir[0];
        if (s < smin) smin = s;
        if (s > smax) smax = s;
    }
    double len = L, wid = smax - smin;
    double area = len * wid;
    size_t[2][4] cands = [[bi, (bi + 1) % n], [bi, (bi + n - 1) % n],
                          [bj, (bj + 1) % n], [bj, (bj + n - 1) % n]];
    foreach (cd; cands) {
        D2 d; double l, w;
        const a2 = rectForEdge(h, cd[0], cd[1], d, l, w);
        if (area > a2) { area = a2; dir = d; len = l; wid = w; }
    }
    // Tie branch (length == width) — static decode, not driven.
    const m = len > wid ? len : wid;
    if (abs(len - wid) <= 1e-9 * m) {
        double umin = double.infinity, umax = -double.infinity;
        double vmin = double.infinity, vmax = -double.infinity;
        foreach (q; h) {
            if (q[0] < umin) umin = q[0];
            if (q[0] > umax) umax = q[0];
            if (q[1] < vmin) vmin = q[1];
            if (q[1] > vmax) vmax = q[1];
        }
        const bw = umax - umin, bh = vmax - vmin;
        if (abs(bw - bh) <= 1e-9 * m && abs(bw - len) <= 1e-9 * m)
            return [0.0, 1.0];
        if (abs(dir[0]) > abs(dir[1])) return [dir[1], dir[0]];
    }
    return dir;
}

/// Orientation of the plane through two skew edges' endpoints (`pts`,
/// exact duplicates already merged by the caller or not — they are merged
/// here). Writes Y = normal, X = normalize(Y x d), Z = X x Y (= d).
SkewFit skewEdgePairFrame(const Vec3[] pts, out Vec3 axisX, out Vec3 normal,
                          out Vec3 axisZ) pure @safe {
    D3[] p;
    foreach (v; pts) {
        D3 q = [v.x, v.y, v.z];
        bool dup = false;
        foreach (o; p) if (o == q) dup = true;
        if (!dup) p ~= q;
    }
    D3 n;
    if (!planeFitNormal(p, n)) return SkewFit.singular;
    const k = axisMaxExtent(n);
    // M: the shortest-arc rotation taking n onto e_k (M = R^T, R e_k = n).
    double[3][3] M = [[1.0, 0, 0], [0.0, 1, 0], [0.0, 0, 1]];
    D3 e = 0; e[k] = 1;
    bool same = true;
    foreach (i; 0 .. 3) if (abs(n[i] - e[i]) > 1e-12) same = false;
    if (!same) {
        D3 ax = [e[1] * n[2] - e[2] * n[1], e[2] * n[0] - e[0] * n[2], e[0] * n[1] - e[1] * n[0]];
        const s = sqrt(ax[0] * ax[0] + ax[1] * ax[1] + ax[2] * ax[2]);
        const cth = e[0] * n[0] + e[1] * n[1] + e[2] * n[2];
        if (s < 1e-12) return SkewFit.antiparallel;
        const ang = atan2(s, cth);
        ax[] /= s;
        double[3][3] K = [[0.0, -ax[2], ax[1]], [ax[2], 0.0, -ax[0]], [-ax[1], ax[0], 0.0]];
        double[3][3] R;
        foreach (i; 0 .. 3)
            foreach (j; 0 .. 3) {
                double kk = 0;
                foreach (t; 0 .. 3) kk += K[i][t] * K[t][j];
                R[i][j] = (i == j ? 1.0 : 0.0) + sin(ang) * K[i][j] + (1 - cos(ang)) * kk;
            }
        foreach (i; 0 .. 3) foreach (j; 0 .. 3) M[i][j] = R[j][i];
    }
    static immutable int[3] A1 = [1, 2, 0], A2 = [2, 0, 1];
    const a1 = A1[k], a2 = A2[k];
    D2[] pts2;
    foreach (q; p) {
        D3 r;
        foreach (i; 0 .. 3) r[i] = M[i][0] * q[0] + M[i][1] * q[1] + M[i][2] * q[2];
        pts2 ~= [r[a1], r[a2]];
    }
    auto hull = hullReferenceOrder(pts2);
    if (hull.length < 2) return SkewFit.degenerate;
    const D2 dr = hullMajorAxis(hull);
    // dir3 = M^T (du e_a1 + dv e_a2); Y = M^T e_k.
    D3 local = 0; local[a1] = dr[0]; local[a2] = dr[1];
    D3 d3, y;
    foreach (i; 0 .. 3) {
        d3[i] = M[0][i] * local[0] + M[1][i] * local[1] + M[2][i] * local[2];
        y[i]  = M[k][i];
    }
    if (y[axisMaxExtent(y)] < 0) y[] = -y[];
    D3 x = [y[1] * d3[2] - y[2] * d3[1], y[2] * d3[0] - y[0] * d3[2], y[0] * d3[1] - y[1] * d3[0]];
    const xl = sqrt(x[0] * x[0] + x[1] * x[1] + x[2] * x[2]);
    if (!(xl > 1e-12)) return SkewFit.degenerate;
    x[] /= xl;
    D3 z = [x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0]];
    axisX  = Vec3(cast(float)x[0], cast(float)x[1], cast(float)x[2]);
    normal = Vec3(cast(float)y[0], cast(float)y[1], cast(float)y[2]);
    axisZ  = Vec3(cast(float)z[0], cast(float)z[1], cast(float)z[2]);
    return SkewFit.ok;
}
