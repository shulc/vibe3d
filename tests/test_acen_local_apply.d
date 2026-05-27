// ACEN.Local per-cluster apply — behavioural lock-in.
//
// Selects two DISJOINT face clusters (top -X half + bottom +X+Z corner of a
// segments-2 cube), enables actr.local, and asserts the transform apply treats
// each cluster in its OWN local frame about its OWN centre — matching the
// reference engine (verified vertex-exact by manual capture; see
// memory vibe3d_acen_divergences finding #3). This guards the per-cluster fix
// (vibe3d 71c8926 + c67c3de) against regression to single-pivot / world axes.
//
// We assert on vibe3d's OWN mesh (group moved verts by Y level), NOT per-vertex
// reference parity: the reference welds the cube (26 verts) while vibe3d leaves
// duplicated corners (34), so a partial-face-selection tears differently — a
// weld-topology difference orthogonal to ACEN. The per-cluster SEMANTICS are
// what we lock here.
//
// before[i]/after[i] are compared BY INDEX, which is valid: a transform op
// mutates mesh.vertices[i] in place WITHOUT reordering (verified — count stable
// and every untouched vert is byte-identical at its index; vibe3d's /api/model
// order is deterministic). This is unlike the reference's headless dump, which
// sorted by position and broke index correspondence once verts moved.

import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : abs, sqrt;

void main() {}

string baseUrl = "http://localhost:8080";
JSONValue getJson(string p)            { return parseJSON(cast(string) get(baseUrl ~ p)); }
JSONValue postJson(string p, string b) { return parseJSON(cast(string) post(baseUrl ~ p, b)); }
void cmd(string c)                     { postJson("/api/command", c); }

bool veq(double[3] a, double[3] b) {
    return abs(a[0]-b[0]) < 1e-4 && abs(a[1]-b[1]) < 1e-4 && abs(a[2]-b[2]) < 1e-4;
}

double[3][] verts() {
    double[3][] o;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        o ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return o;
}

// The two-cluster asymmetric selection: two adjacent top -X faces (cluster A,
// normal +Y) and one disjoint bottom +X+Z face (cluster B, normal -Y).
immutable double[3][4][3] FACES = [
    [[-0.5,0.5,-0.5],[0,0.5,-0.5],[0,0.5,0],[-0.5,0.5,0]],
    [[-0.5,0.5,0],[0,0.5,0],[0,0.5,0.5],[-0.5,0.5,0.5]],
    [[0,-0.5,0],[0.5,-0.5,0],[0.5,-0.5,0.5],[0,-0.5,0.5]],
];

void selectAsymmetric() {
    auto model = getJson("/api/model");
    auto V = model["vertices"].array;
    double[3] vp(long i) { auto a = V[cast(size_t)i].array; return [a[0].floating,a[1].floating,a[2].floating]; }
    int[] idx;
    foreach (want; FACES) {
        int hit = -1;
        foreach (fi, f; model["faces"].array) {
            auto fv = f.array;
            if (fv.length != want.length) continue;
            auto used = new bool[](fv.length);
            bool ok = true;
            foreach (wc; want) {
                double[3] t = wc;
                bool found = false;
                foreach (k, vi; fv)
                    if (!used[k] && veq(vp(vi.integer), t)) { used[k]=true; found=true; break; }
                if (!found) { ok = false; break; }
            }
            if (ok) { hit = cast(int)fi; break; }
        }
        assert(hit >= 0, "asymmetric face not found");
        idx ~= hit;
    }
    string s = "[";
    foreach (k, v; idx) { if (k) s ~= ","; s ~= v.to!string; }
    s ~= "]";
    auto r = postJson("/api/select", `{"mode":"polygons","indices":` ~ s ~ `}`);
    assert(r["status"].str == "ok", "select failed");
}

void setup() {
    postJson("/api/reset", "");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:2 segmentsY:2 segmentsZ:2 radius:0");
    cmd("select.typeFrom polygon");
    selectAsymmetric();
    cmd("actr.local");
}

// Mean displacement of selected (moved) verts whose ORIGINAL Y ~= yLevel.
double[3] clusterDisp(double[3][] before, double[3][] after, double yLevel) {
    double[3] sum = [0,0,0]; int n = 0;
    foreach (i; 0 .. before.length) {
        double d = sqrt((after[i][0]-before[i][0])^^2 + (after[i][1]-before[i][1])^^2
                      + (after[i][2]-before[i][2])^^2);
        if (d > 1e-5 && abs(before[i][1]-yLevel) < 1e-3) {
            foreach (c; 0..3) sum[c] += after[i][c]-before[i][c];
            n++;
        }
    }
    assert(n > 0, "no moved verts at y=" ~ yLevel.to!string);
    foreach (c; 0..3) sum[c] /= n;
    return sum;
}

double[3] clusterCentroidShift(double[3][] before, double[3][] after, double yLevel) {
    double[3] cb = [0,0,0], ca = [0,0,0]; int n = 0;
    foreach (i; 0 .. before.length) {
        double d = sqrt((after[i][0]-before[i][0])^^2 + (after[i][1]-before[i][1])^^2
                      + (after[i][2]-before[i][2])^^2);
        if (d > 1e-5 && abs(before[i][1]-yLevel) < 1e-3) {
            foreach (c; 0..3) { cb[c] += before[i][c]; ca[c] += after[i][c]; }
            n++;
        }
    }
    assert(n > 0, "no moved verts at y=" ~ yLevel.to!string);
    double[3] o;
    foreach (c; 0..3) o[c] = ca[c]/n - cb[c]/n;
    return o;
}

unittest { // move + actr.local: each cluster moves along its OWN local axis
    setup();
    auto before = verts();
    cmd("tool.set move on"); cmd("tool.attr move TY 0.3");
    cmd("tool.doApply"); cmd("tool.set move off");
    auto after = verts();
    auto top = clusterDisp(before, after, 0.5);   // normal +Y
    auto bot = clusterDisp(before, after, -0.5);   // normal -Y
    // local Y (up) of the two opposite-facing clusters is opposite ±Z, so a
    // single TY drag moves them in OPPOSITE world directions (NOT a shared +Y).
    assert(top[2] < -0.1, "top cluster should move -Z, got dz=" ~ top[2].to!string);
    assert(bot[2] >  0.1, "bottom cluster should move +Z, got dz=" ~ bot[2].to!string);
    assert(abs(top[1]) < 1e-3 && abs(bot[1]) < 1e-3,
        "local move must not shift world Y (would mean world-axis fallback)");
}

unittest { // rotate + actr.local: each cluster rotates about its OWN centre
    setup();
    auto before = verts();
    cmd("tool.set rotate on"); cmd("tool.attr rotate RY 40");
    cmd("tool.doApply"); cmd("tool.set rotate off");
    auto after = verts();
    // Per-cluster rotation about each cluster's own centroid keeps that
    // centroid fixed; a single shared pivot would move both centroids.
    auto topShift = clusterCentroidShift(before, after, 0.5);
    auto botShift = clusterCentroidShift(before, after, -0.5);
    double topMag = sqrt(topShift[0]^^2 + topShift[1]^^2 + topShift[2]^^2);
    double botMag = sqrt(botShift[0]^^2 + botShift[1]^^2 + botShift[2]^^2);
    assert(topMag < 0.02, "top cluster centroid moved " ~ topMag.to!string
        ~ " (should be ~0: rotated about own centre, not a shared pivot)");
    assert(botMag < 0.02, "bottom cluster centroid moved " ~ botMag.to!string
        ~ " (should be ~0: rotated about own centre, not a shared pivot)");
}
