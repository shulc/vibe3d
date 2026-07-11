// Tests for mesh.radial_align — task 0361: distributes the selection's
// chain at equal angular slots around a circle (center = mean position,
// radius = mean distance from center), replacing the prior 3D
// sphere-projection algorithm. CONFIRMED (private toolcard capture): the
// reference tool has NO cylinder/sphere mode — see
// source/tools/align_kernels.d's module doc comment for the full law.
//
// The circle's BASE ANCHOR (which point sits at angle 0) is an
// unverified implementation choice (see align_kernels.radialAlignTargets's
// doc comment) — these tests therefore assert only the anchor-INDEPENDENT
// structural properties that ARE bit-exact verified against the private
// capture (task 0361, cases "ra_circle" / "ra_circle_angle90" /
// "ra_nside4" / "ra_circle_weight05"): the auto-computed center/radius
// law, equal angular spacing, and the weight-blend law. No reference
// engine runs at test time.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt, atan2, PI;
import std.algorithm : sort;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

double[3][] dumpVerts() {
    double[3][] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return out_;
}

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

int findVert(double[3][] verts, double x, double y, double z) {
    foreach (i, v; verts)
        if (approxEq(v[0], x) && approxEq(v[1], y) && approxEq(v[2], z))
            return cast(int)i;
    return -1;
}

// Build the toolcard's closed 4-vertex y=-0.5 loop (A,B,C,E) with B
// pre-displaced within the same plane, and select it. Returns the 4
// vertex indices in a fixed (test-local, arbitrary) order.
int[4] buildAndSelectLoop() {
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    auto before = dumpVerts();
    int idxA = findVert(before, -0.5, -0.5, -0.5);
    int idxB = findVert(before,  0.5, -0.5, -0.5);
    int idxC = findVert(before,  0.5, -0.5,  0.5);
    int idxE = findVert(before, -0.5, -0.5,  0.5);
    assert(idxA >= 0 && idxB >= 0 && idxC >= 0 && idxE >= 0,
        "expected all 4 y=-0.5 face corners on the default cube");

    // Pre-displace B within the SAME plane (toolcard method — decouples
    // the natural equal-step geometry so center/radius aren't trivially
    // the untouched cube corner values).
    cmd("mesh.move_vertex from:{0.5,-0.5,-0.5} to:{0.7071,-0.5,0.0}");

    postJson("/api/select",
        `{"mode":"vertices","indices":[` ~ idxA.to!string ~ `,` ~ idxB.to!string
        ~ `,` ~ idxC.to!string ~ `,` ~ idxE.to!string ~ `]}`);
    return [idxA, idxB, idxC, idxE];
}

unittest { // center/radius auto-compute law, BIT-EXACT verified against
           // the "ra_circle" capture case (measured
           // center=(0.051777,-0.5,0.125), radius=0.688103) — computed
           // here from vibe3d's OWN pre-align positions (order/index-
           // agnostic) rather than hardcoded, so the test is robust to
           // vibe3d's internal vertex ordering.
    auto idx = buildAndSelectLoop();
    auto source = dumpVerts();
    double[3] cSrc = [0, 0, 0];
    foreach (i; idx) foreach (c; 0 .. 3) cSrc[c] += source[i][c];
    foreach (c; 0 .. 3) cSrc[c] /= 4.0;
    assert(approxEq(cSrc[0], 0.051777, 2e-3), "reconstructed center.x mismatch");
    assert(approxEq(cSrc[1], -0.5),           "reconstructed center.y mismatch");
    assert(approxEq(cSrc[2], 0.125),          "reconstructed center.z mismatch");

    cmd("mesh.radial_align");
    auto after = dumpVerts();

    // Every touched vertex sits at the measured mean radius from center.
    foreach (i; idx) {
        double dx = after[i][0]-cSrc[0], dy = after[i][1]-cSrc[1], dz = after[i][2]-cSrc[2];
        double r = sqrt(dx*dx + dy*dy + dz*dz);
        assert(approxEq(r, 0.688103, 2e-3), "radius mismatch, got " ~ r.to!string);
    }

    // Equal 90-degree angular spacing (order-independent: sort the 4
    // touched points by their angle around the center in the y=-0.5
    // plane and check consecutive gaps, wrapping — matches the measured
    // "regular inscribed square" fact regardless of which physical
    // vertex the (unverified) base anchor put at angle 0).
    double[] angles;
    foreach (i; idx) {
        double dx = after[i][0]-cSrc[0], dz = after[i][2]-cSrc[2];
        angles ~= atan2(dz, dx);
    }
    sort(angles);
    double[] gaps;
    foreach (k; 0 .. angles.length) {
        double a = angles[k];
        double b = (k + 1 < angles.length) ? angles[k+1] : angles[0] + 2*PI;
        gaps ~= (b - a) * (180.0 / PI);
    }
    foreach (g; gaps)
        assert(approxEq(g, 90.0, 1.0), "expected ~90 deg slot gaps, got " ~ gaps.to!string);

    auto model = getJson("/api/model");
    assert(model["vertexCount"].integer == 8);
    assert(model["faceCount"].integer == 6);
}

unittest { // weight blend law, BIT-EXACT verified against the
           // "ra_circle_weight05" capture case:
           // result = lerp(source, aligned(weight=1), weight).
    auto idx = buildAndSelectLoop();
    auto source = dumpVerts();

    cmd("mesh.radial_align");
    auto aligned = dumpVerts();
    cmd("history.undo");

    buildAndSelectLoopReselect(idx);   // re-select after undo (see helper)
    cmd("mesh.radial_align weight:0.5");
    auto blended = dumpVerts();

    foreach (i; idx) {
        foreach (c; 0 .. 3) {
            double want = source[i][c] + (aligned[i][c] - source[i][c]) * 0.5;
            assert(approxEq(blended[i][c], want, 1e-3),
                "weight=0.5 mismatch at vert " ~ i.to!string ~ " axis " ~ c.to!string
                ~ ": want " ~ want.to!string ~ " got " ~ blended[i][c].to!string);
        }
    }
}

// history.undo may drop the live selection along with the geometry
// (T-SEP: selection is a separate undo timeline) — re-select the same 4
// indices so the second mesh.radial_align call operates on the same
// chain rather than falling back to whole-mesh.
void buildAndSelectLoopReselect(int[4] idx) {
    cmd("select.typeFrom vertex");
    postJson("/api/select",
        `{"mode":"vertices","indices":[` ~ idx[0].to!string ~ `,` ~ idx[1].to!string
        ~ `,` ~ idx[2].to!string ~ `,` ~ idx[3].to!string ~ `]}`);
}

unittest { // N-Sided(4) uses the SAME center + radius as Circle mode for
           // an identical input — bit-exact structural match measured in
           // ra_nside4.json vs ra_circle.json.
    auto idx = buildAndSelectLoop();
    auto source = dumpVerts();
    double[3] cSrc = [0, 0, 0];
    foreach (i; idx) foreach (c; 0 .. 3) cSrc[c] += source[i][c];
    foreach (c; 0 .. 3) cSrc[c] /= 4.0;

    cmd("mesh.radial_align mode:nside side:4");
    auto after = dumpVerts();
    foreach (i; idx) {
        double dx = after[i][0]-cSrc[0], dy = after[i][1]-cSrc[1], dz = after[i][2]-cSrc[2];
        double r = sqrt(dx*dx + dy*dy + dz*dz);
        assert(approxEq(r, 0.688103, 2e-3), "nside4 radius mismatch, got " ~ r.to!string);
    }
}

unittest { // undo restores — no selection (whole-mesh fallback).
    postJson("/api/reset", "");
    cmd("mesh.radial_align");
    cmd("history.undo");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "undo should restore ±0.5 corners");
    }
    auto model = getJson("/api/model");
    assert(model["vertexCount"].integer == 8);
    assert(model["edgeCount"].integer == 12);
    assert(model["faceCount"].integer == 6);
}
