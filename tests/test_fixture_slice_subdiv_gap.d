// Slice tool Split + Cap Sections + Gap on SUBDIVIDED (Catmull-Clark x2)
// geometry with an OBLIQUE cut plane (task 0291) — the reported bug and its
// fix, driven through the LIVE tool (not the kernel directly; see the
// source/mesh.d cutByPlaneSplitGap unittests for the kernel-level proof).
//
// A single-cut + fixed along-edge slide (the pre-0291 behaviour) grazes
// existing verts on dense/curved geometry (a "sliver"): the graze vertex sits
// almost exactly ON the cut plane, so sliding it a fixed distance along its
// own crossed edge overshoots past the edge's far endpoint, scattering the
// seam off the cut plane and producing a self-intersecting cap. This is RED
// on pre-fix HEAD (the cap self-intersects) and GREEN once Slice routes
// split+caps+gap through TWO REAL parallel plane cuts (Mesh.cutByPlaneSplitGap)
// + a band delete: every seam then sits on a REAL edge-plane intersection, so
// each remaining shell's cap is always planar and simple.
//
// This does NOT use fixture_helpers.runTopologyDiffSuite: that harness only
// supports a frozen expected-vertex SET compare, not the structural
// (planarity / self-intersection) predicates this regression needs. Mirrors
// the self-contained HTTP-driving style of test_slice_gap_rmb.d /
// test_fixture_item_transform.d instead.
//
// Reference ground truth: toolcards/poly.knife/capture/subdiv_gap/ANALYSIS.md
// (owner case: CC^2 cube, plane normal [0,-0.851,0.524], gap 0.415 center —
// TWO clean planar/simple caps, band between them removed).

import std.net.curl;
import std.json;
import std.math   : abs, sqrt;
import std.format : format;

void main() {}

enum string BASE = "http://localhost:8080";

// ---------------------------------------------------------------------------
// HTTP helpers (mirrors test_slice_gap_rmb.d / test_fixture_item_transform.d
// — each test file keeps its own minimal driver rather than reaching into
// fixture_helpers' private internals).
// ---------------------------------------------------------------------------

void cmd(string s) {
    auto resp = cast(string) post(BASE ~ "/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}
void resetCube() {
    auto resp = cast(string) post(BASE ~ "/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}
JSONValue getModel() { return parseJSON(cast(string) get(BASE ~ "/api/model")); }

double num(JSONValue v) {
    if (v.type == JSONType.float_)   return v.floating;
    if (v.type == JSONType.integer)  return cast(double) v.integer;
    if (v.type == JSONType.uinteger) return cast(double) v.uinteger;
    assert(false, "expected a number, got " ~ v.toString);
}

// ---------------------------------------------------------------------------
// Minimal local Vec3 + geometry predicates (duplicated rather than importing
// source/math.d / source/mesh.d into this test binary's compile unit — see
// tests/drag_helpers.d's doc comment for why: these test binaries compile
// standalone against the HTTP surface, not the modeling source tree).
// ---------------------------------------------------------------------------

struct V3 { double x = 0, y = 0, z = 0; }
V3 vsub(V3 a, V3 b) { return V3(a.x - b.x, a.y - b.y, a.z - b.z); }
V3 vadd(V3 a, V3 b) { return V3(a.x + b.x, a.y + b.y, a.z + b.z); }
V3 vscale(V3 a, double s) { return V3(a.x * s, a.y * s, a.z * s); }
double vdot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
V3 vcross(V3 a, V3 b) {
    return V3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}
double vlen(V3 a) { return sqrt(a.x * a.x + a.y * a.y + a.z * a.z); }
V3 vnorm(V3 a) { double l = vlen(a); return V3(a.x / l, a.y / l, a.z / l); }

V3[] readVerts(JSONValue m) {
    V3[] r;
    foreach (v; m["vertices"].array) {
        auto c = v.array;
        r ~= V3(num(c[0]), num(c[1]), num(c[2]));
    }
    return r;
}
uint[][] readFaces(JSONValue m) {
    uint[][] r;
    foreach (f; m["faces"].array) {
        uint[] face;
        foreach (c; f.array) face ~= cast(uint) c.integer;
        r ~= face;
    }
    return r;
}

// Component count via union-find over faces sharing a vertex (mirrors the
// `componentCount` idiom in source/mesh.d's cutByPlaneEx unittests).
size_t componentCount(uint[][] faces) {
    if (faces.length == 0) return 0;
    auto parent = new size_t[](faces.length);
    foreach (i; 0 .. faces.length) parent[i] = i;
    size_t find(size_t x) {
        while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
        return x;
    }
    void uni(size_t a, size_t b) { parent[find(a)] = find(b); }
    uint[][uint] vFaces;
    foreach (fi, f; faces) foreach (v; f) vFaces[v] ~= cast(uint) fi;
    foreach (v, fs; vFaces) foreach (k; 1 .. fs.length) uni(fs[0], fs[k]);
    bool[size_t] roots;
    foreach (i; 0 .. faces.length) roots[find(i)] = true;
    return roots.length;
}

// A "cap" face: every corner lies on ONE of the two offset planes (p+n*loAmt
// or p-n*hiAmt), within `tol`. Precise by construction — capShellCycles seals
// exactly the crossing verts of one plane cut.
uint[] capFaces(V3[] verts, uint[][] faces, V3 p, V3 n, double loAmt, double hiAmt,
               double tol) {
    uint[] caps;
    foreach (fi, f; faces) {
        if (f.length == 0) continue;
        bool onLo = true, onHi = true;
        foreach (vi; f) {
            double dv = vdot(n, vsub(verts[vi], p));
            if (abs(dv - loAmt) >= tol) onLo = false;
            if (abs(dv - (-hiAmt)) >= tol) onHi = false;
        }
        if (onLo || onHi) caps ~= cast(uint) fi;
    }
    return caps;
}

V3 newellNormal(V3[] verts, uint[] f) {
    V3 n = V3(0, 0, 0);
    foreach (i; 0 .. f.length) {
        V3 a = verts[f[i]];
        V3 b = verts[f[(i + 1) % f.length]];
        n.x += (a.y - b.y) * (a.z + b.z);
        n.y += (a.z - b.z) * (a.x + b.x);
        n.z += (a.x - b.x) * (a.y + b.y);
    }
    return vnorm(n);
}
V3 centroidOf(V3[] verts, uint[] f) {
    V3 c = V3(0, 0, 0);
    foreach (vi; f) c = vadd(c, verts[vi]);
    return vscale(c, 1.0 / f.length);
}
double planarityDev(V3[] verts, uint[] f) {
    V3 n = newellNormal(verts, f);
    V3 c = centroidOf(verts, f);
    double dev = 0.0;
    foreach (vi; f) {
        double d = abs(vdot(n, vsub(verts[vi], c)));
        if (d > dev) dev = d;
    }
    return dev;
}
// O(k^2) count of non-adjacent edge-pair crossings of the polygon projected
// onto its own best-fit plane — a self-intersecting ("bowtie") n-gon has >=1.
size_t selfX(V3[] verts, uint[] f) {
    size_t k = f.length;
    if (k < 4) return 0;
    V3 n = newellNormal(verts, f);
    V3 arb = (abs(n.x) < 0.9) ? V3(1, 0, 0) : V3(0, 1, 0);
    V3 u = vnorm(vcross(n, arb));
    V3 v = vcross(n, u);
    auto pts = new double[2][](k);
    foreach (i; 0 .. k) {
        V3 p = verts[f[i]];
        pts[i] = [vdot(p, u), vdot(p, v)];
    }
    static bool segCross(double[2] a, double[2] b, double[2] c, double[2] d) {
        double d1 = (b[0]-a[0])*(c[1]-a[1]) - (b[1]-a[1])*(c[0]-a[0]);
        double d2 = (b[0]-a[0])*(d[1]-a[1]) - (b[1]-a[1])*(d[0]-a[0]);
        double d3 = (d[0]-c[0])*(a[1]-c[1]) - (d[1]-c[1])*(a[0]-c[0]);
        double d4 = (d[0]-c[0])*(b[1]-c[1]) - (d[1]-c[1])*(b[0]-c[0]);
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0));
    }
    size_t crossings = 0;
    foreach (i; 0 .. k) {
        size_t i2 = (i + 1) % k;
        foreach (j; i + 1 .. k) {
            size_t j2 = (j + 1) % k;
            if (j == i || j2 == i || j == i2) continue;
            if (segCross(pts[i], pts[i2], pts[j], pts[j2])) ++crossings;
        }
    }
    return crossings;
}

// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("mesh.subdivide");
    cmd("mesh.subdivide");

    auto before = getModel();
    assert(before["faces"].array.length == 96,
           format("expected 96 faces after subdivide x2, got %d",
                  before["faces"].array.length));

    // The owner's exact live-case plane: axis=x extrudes the drawn Y-Z line
    // along world X (planeForSlice: n = normalize(cross(end-start, X)),
    // p = start) — reproduces the reference capture's oblique normal
    // [0,-0.851,0.524] exactly (see doc/slice_gap_two_cut_plan.md Phase 0).
    cmd("tool.set mesh.sliceTool on");
    cmd("tool.attr mesh.sliceTool infinite 1");
    cmd("tool.attr mesh.sliceTool split 1");
    cmd("tool.attr mesh.sliceTool caps 1");
    cmd("tool.attr mesh.sliceTool gap 0.415");
    cmd("tool.attr mesh.sliceTool gapSide center");
    cmd("tool.attr mesh.sliceTool startX 0");
    cmd("tool.attr mesh.sliceTool startY 0.4");
    cmd("tool.attr mesh.sliceTool startZ 0.61");
    cmd("tool.attr mesh.sliceTool endX 0");
    cmd("tool.attr mesh.sliceTool endY -1.14");
    cmd("tool.attr mesh.sliceTool endZ -1.89");
    cmd("tool.attr mesh.sliceTool axis x");
    cmd("tool.doApply");
    cmd("tool.set mesh.sliceTool off");

    auto after   = getModel();
    V3[] verts   = readVerts(after);
    uint[][] faces = readFaces(after);
    assert(faces.length > 0, "slice must produce geometry");

    V3 P = V3(0.0, 0.4, 0.61);
    V3 N = vnorm(vcross(vsub(V3(0.0, -1.14, -1.89), P), V3(1, 0, 0)));
    enum double G   = 0.415;
    enum double OFF = G * 0.5;   // 0.2075

    assert(componentCount(faces) == 2,
           format("expected the band removed (2 shells), got %d components",
                  componentCount(faces)));

    auto caps = capFaces(verts, faces, P, N, OFF, OFF, 1e-3);
    assert(caps.length == 2,
           format("expected exactly 2 cap faces, got %d", caps.length));
    foreach (fi; caps) {
        double dev = planarityDev(verts, faces[fi]);
        size_t sx  = selfX(verts, faces[fi]);
        assert(dev < 1e-3,
               format("cap face %d not planar (planarityDev=%.6f) — the fixed "
                      ~ "two-cut model must place every corner on a real "
                      ~ "edge-plane intersection", fi, dev));
        assert(sx == 0,
               format("cap face %d self-intersects (selfX=%d) — this is "
                      ~ "exactly the reported sliver-cap bug", fi, sx));
    }

    // SECONDARY: the slab is empty (eps margin around the two seam planes).
    enum double EPS_S = 1e-3;
    foreach (v; verts) {
        double dv = vdot(N, vsub(v, P));
        assert(!(dv > -OFF + EPS_S && dv < OFF - EPS_S),
               format("vertex left inside the removed slab: dv=%.6f", dv));
    }
}
