// Tests for subphase 6.8: prim.torus headless command.
//
// The schema uses conventional torus parameters: majorRadius,
// minorRadius, majorSegments, minorSegments, axis.
//
// Coverage: topology counts, manifold (every edge shared by exactly 2
// faces), all-quad output, axis variants, off-center, tube cross-section
// invariants, undo, JSON↔argstring parity.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt, isNaN;

void main() {}

string baseUrl = "http://localhost:8080";

string apiUrl(string path) { return baseUrl ~ path; }

JSONValue postJson(string path, string body_)
{
    return parseJSON(cast(string) post(apiUrl(path), body_));
}

JSONValue getModel()
{
    return parseJSON(cast(string) get(apiUrl("/api/model")));
}

void resetEmpty()
{
    auto resp = postJson("/api/reset?empty=true", "");
    assert(resp["status"].str == "ok", "reset(empty) failed: " ~ resp.toString);
}

JSONValue primTorusArg(string params)
{
    return postJson("/api/command", "prim.torus " ~ params);
}

JSONValue primTorusJson(string paramsJson)
{
    return postJson("/api/command",
        `{"id":"prim.torus","params":{` ~ paramsJson ~ `}}`);
}

// -------------------------------------------------------------------------
// 1. Default counts: V = M·N, F = M·N (all quads).
// -------------------------------------------------------------------------

unittest { // default counts
    resetEmpty();
    auto resp = primTorusArg(
        "majorRadius:1.0 minorRadius:0.25 majorSegments:24 minorSegments:12 axis:1 cenX:0 cenY:0 cenZ:0");
    assert(resp["status"].str == "ok", "default torus failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 24 * 12,
        "expected 288 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 24 * 12,
        "expected 288 faces, got " ~ m["faces"].array.length.to!string);
    foreach (f; m["faces"].array)
        assert(f.array.length == 4, "all torus faces must be quads");
}

// -------------------------------------------------------------------------
// 2. Topology formula across (M, N) grid: V = M·N, F = M·N.
// -------------------------------------------------------------------------

unittest { // formula
    static struct Case { int M; int N; }
    Case[] cases = [
        Case(3,  3), Case(4, 4), Case(5, 6), Case(8, 4),
        Case(12, 8), Case(16, 16),
    ];
    foreach (c; cases) {
        resetEmpty();
        auto resp = primTorusArg(
            "majorRadius:1.0 minorRadius:0.25 majorSegments:" ~ c.M.to!string
            ~ " minorSegments:" ~ c.N.to!string ~ " axis:1");
        assert(resp["status"].str == "ok",
            "M=" ~ c.M.to!string ~ " N=" ~ c.N.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        size_t expectedV = c.M * c.N;
        size_t expectedF = c.M * c.N;
        assert(m["vertices"].array.length == expectedV,
            "M=" ~ c.M.to!string ~ " N=" ~ c.N.to!string
            ~ ": expected " ~ expectedV.to!string ~ " verts, got "
            ~ m["vertices"].array.length.to!string);
        assert(m["faces"].array.length == expectedF,
            "M=" ~ c.M.to!string ~ " N=" ~ c.N.to!string
            ~ ": expected " ~ expectedF.to!string ~ " faces, got "
            ~ m["faces"].array.length.to!string);
    }
}

// -------------------------------------------------------------------------
// 3. Manifold: every edge shared by exactly two faces.
// -------------------------------------------------------------------------

unittest { // manifold
    resetEmpty();
    primTorusArg("majorRadius:1.0 minorRadius:0.25 majorSegments:8 minorSegments:6 axis:1");
    auto m = getModel();

    int[long] edgeCount;
    foreach (f; m["faces"].array) {
        auto verts = f.array;
        size_t n = verts.length;
        foreach (k; 0 .. n) {
            long a = verts[k].integer;
            long b = verts[(k + 1) % n].integer;
            long lo = a < b ? a : b;
            long hi = a < b ? b : a;
            long key = (lo << 32) | hi;
            edgeCount[key] = edgeCount.get(key, 0) + 1;
        }
    }
    int boundaryEdges = 0, manifoldEdges = 0, weirdEdges = 0;
    foreach (k, c; edgeCount) {
        if      (c == 1) ++boundaryEdges;
        else if (c == 2) ++manifoldEdges;
        else             ++weirdEdges;
    }
    assert(boundaryEdges == 0, "torus is closed — no boundary edges expected");
    assert(weirdEdges == 0,    "torus is 2-manifold — no >2-shared edges expected");
}

// -------------------------------------------------------------------------
// 4. Axis variants preserve topology and tube cross-section.
// -------------------------------------------------------------------------

unittest { // axis = X / Y / Z
    foreach (ax; [0, 1, 2]) {
        resetEmpty();
        auto resp = primTorusArg(
            "majorRadius:1.0 minorRadius:0.25 majorSegments:8 minorSegments:6 axis:"
            ~ ax.to!string);
        assert(resp["status"].str == "ok", "axis=" ~ ax.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        assert(m["vertices"].array.length == 48, "axis=" ~ ax.to!string ~ ": 48 verts");
        assert(m["faces"].array.length == 48,    "axis=" ~ ax.to!string ~ ": 48 faces");

        // Tube cross-section: every vertex's distance from the major axis
        // (the axis-line through the center) lies in [R-r, R+r] = [0.75, 1.25],
        // and the vertex's coord ALONG the axis lies in [-r, r] = [-0.25, 0.25].
        foreach (v; m["vertices"].array) {
            double[3] p = [v.array[0].floating, v.array[1].floating, v.array[2].floating];
            int b = (ax + 1) % 3;
            int c = (ax + 2) % 3;
            double radial = sqrt(p[b] * p[b] + p[c] * p[c]);
            assert(radial >= 0.75 - 1e-3 && radial <= 1.25 + 1e-3,
                "axis=" ~ ax.to!string ~ ": vert radial=" ~ radial.to!string ~ " out of [R-r, R+r]");
            assert(fabs(p[ax]) <= 0.25 + 1e-3,
                "axis=" ~ ax.to!string ~ ": vert axial=" ~ p[ax].to!string ~ " exceeds r=0.25");
        }
    }
}

// -------------------------------------------------------------------------
// 5. Off-center: centroid of all verts equals (cenX, cenY, cenZ).
// -------------------------------------------------------------------------

unittest { // off-center centroid
    resetEmpty();
    auto resp = primTorusArg(
        "majorRadius:1.0 minorRadius:0.25 majorSegments:24 minorSegments:12 axis:1 cenX:2.0 cenY:3.0 cenZ:-1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    double cx = 0, cy = 0, cz = 0;
    foreach (v; m["vertices"].array) {
        cx += v.array[0].floating;
        cy += v.array[1].floating;
        cz += v.array[2].floating;
    }
    auto n = m["vertices"].array.length;
    cx /= n; cy /= n; cz /= n;
    assert(fabs(cx - 2.0) < 1e-3 && fabs(cy - 3.0) < 1e-3 && fabs(cz - (-1.0)) < 1e-3,
        "off-center centroid expected (2,3,-1), got ("
        ~ cx.to!string ~ "," ~ cy.to!string ~ "," ~ cz.to!string ~ ")");
}

// -------------------------------------------------------------------------
// 6. Tube ring at fixed major-loop angle is a circle of radius minorRadius.
// -------------------------------------------------------------------------

unittest { // minor-circle invariant
    resetEmpty();
    primTorusArg("majorRadius:1.0 minorRadius:0.25 majorSegments:8 minorSegments:6 axis:1");
    auto m = getModel();
    // Vertices are emitted in (i, j) order with i = major (slow), j = minor (fast).
    // Verts 0..5 form the first minor circle (i=0).
    // The center of that circle is at distance R from the torus center along
    // the major-loop direction. For axis=Y, i=0, position[B]=-(R+r·cos(0))*cos(0)
    // = -1.25 (Z direction). Center expected at (0, 0, -1).
    double cx = 0, cy = 0, cz = 0;
    foreach (k; 0 .. 6) {
        cx += m["vertices"].array[k].array[0].floating;
        cy += m["vertices"].array[k].array[1].floating;
        cz += m["vertices"].array[k].array[2].floating;
    }
    cx /= 6; cy /= 6; cz /= 6;
    assert(fabs(cx) < 1e-3 && fabs(cy) < 1e-3 && fabs(cz - (-1.0)) < 1e-3,
        "minor-circle 0 centroid expected (0, 0, -1), got ("
        ~ cx.to!string ~ "," ~ cy.to!string ~ "," ~ cz.to!string ~ ")");
    // Each vert's distance to that center is the minor radius.
    foreach (k; 0 .. 6) {
        double dx = m["vertices"].array[k].array[0].floating - cx;
        double dy = m["vertices"].array[k].array[1].floating - cy;
        double dz = m["vertices"].array[k].array[2].floating - cz;
        double d  = sqrt(dx * dx + dy * dy + dz * dz);
        assert(fabs(d - 0.25) < 1e-3,
            "minor-circle vert distance expected 0.25, got " ~ d.to!string);
    }
}

// -------------------------------------------------------------------------
// 7. Undo restores empty scene
// -------------------------------------------------------------------------

unittest { // undo
    resetEmpty();
    auto r1 = primTorusArg(
        "majorRadius:1.0 minorRadius:0.25 majorSegments:8 minorSegments:6 axis:1");
    assert(r1["status"].str == "ok", r1.toString);
    auto m1 = getModel();
    assert(m1["vertices"].array.length == 48);

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", u.toString);
    auto m2 = getModel();
    assert(m2["vertices"].array.length == 0,
        "after undo: expected 0 verts, got " ~ m2["vertices"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 8. JSON path parity with argstring path
// -------------------------------------------------------------------------

unittest { // JSON ↔ argstring
    resetEmpty();
    primTorusArg("majorRadius:1.0 minorRadius:0.3 majorSegments:12 minorSegments:8 axis:0");
    auto ma = getModel();
    size_t vA = ma["vertices"].array.length;
    size_t fA = ma["faces"].array.length;

    resetEmpty();
    primTorusJson(`"majorRadius":1.0,"minorRadius":0.3,"majorSegments":12,"minorSegments":8,"axis":0`);
    auto mj = getModel();
    assert(vA == mj["vertices"].array.length, "JSON ↔ arg vert mismatch");
    assert(fA == mj["faces"].array.length,    "JSON ↔ arg face mismatch");
    assert(vA == 96, "expected 96 verts, got " ~ vA.to!string);
    assert(fA == 96, "expected 96 faces, got " ~ fA.to!string);
}

// -------------------------------------------------------------------------
// 8. Task 0315: torus degenerate-radii guards — minorRadius<=0,
// majorRadius<=0, and minorRadius>=majorRadius (previously unguarded and
// able to fold the tube through the central axis).
// -------------------------------------------------------------------------

bool hasCoincidentVerts(JSONValue verts, double eps = 1e-7)
{
    auto arr = verts.array;
    foreach (i; 0 .. arr.length)
        foreach (j; i + 1 .. arr.length) {
            double dx = arr[i].array[0].floating - arr[j].array[0].floating;
            double dy = arr[i].array[1].floating - arr[j].array[1].floating;
            double dz = arr[i].array[2].floating - arr[j].array[2].floating;
            if (dx * dx + dy * dy + dz * dz < eps * eps) return true;
        }
    return false;
}

unittest { // minorRadius=0 no longer collapses each minor-loop ring to a point
    resetEmpty();
    auto resp = primTorusArg("majorRadius:1.0 minorRadius:0.0 majorSegments:8 minorSegments:6 axis:1");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 48,
        "expected 48 verts (8*6), got " ~ m["vertices"].array.length.to!string);
    assert(!hasCoincidentVerts(m["vertices"]),
        "minorRadius=0: expected no coincident vertices after degenerate-radius guard");
}

unittest { // majorRadius=0 no longer produces NaN / unbounded output
    resetEmpty();
    auto resp = primTorusArg("majorRadius:0.0 minorRadius:0.25 majorSegments:8 minorSegments:6 axis:1");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 48,
        "expected 48 verts (8*6), got " ~ m["vertices"].array.length.to!string);
    foreach (v; m["vertices"].array)
        foreach (c; v.array)
            assert(!isNaN(c.floating), "majorRadius=0: found NaN vertex coordinate");
}

unittest { // minorRadius >= majorRadius no longer folds the tube through the axis
    resetEmpty();
    auto resp = primTorusArg("majorRadius:1.0 minorRadius:2.0 majorSegments:8 minorSegments:6 axis:1");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 48,
        "expected 48 verts (8*6), got " ~ m["vertices"].array.length.to!string);
    foreach (v; m["vertices"].array) {
        double x = v.array[0].floating;
        double z = v.array[2].floating;
        double radial = sqrt(x * x + z * z);
        assert(radial > 1e-6,
            "minorRadius>=majorRadius: expected radial distance to stay positive "
            ~ "(no self-intersection through the axis), got " ~ radial.to!string);
    }
}
