// Tests for the headless apply path on deform tools.
//
// MoveTool.applyHeadless() (called by `tool.doApply` after `tool.set
// xfrm.shear on; tool.attr xfrm.shear TX <v>`) reuses the same
// per-vertex weighting code path as interactive drag — the active
// FalloffStage's per-vertex weight × the explicit numeric translate.
// This file pins down the shear behaviour with a known cube+linear
// falloff configuration: the X offset must scale linearly with the
// vertex's Y position, matching the reference values reverse-derived
// against MODO 9 (see tools/modo_diff/probe_shear.py).
//
// If MoveTool.applyHeadless changes (or FalloffStage.shape's default
// flips, or the xfrm.shear preset stops pinning shape=linear), the
// per-row asserts below catch the regression before it reaches the
// cross-engine diff suite.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

unittest { // shear: linear X gradient by Y, weight 0 at y=-0.5, 1 at y=+0.5
    // Reset + polygon mode (xfrm.shear is selection-aware in Polygons mode;
    // empty selection falls back to the whole mesh in MoveTool, mirroring
    // MODO's behaviour).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");

    // Cube with segmentsY=4 — produces 5 vert rows along Y at
    // y ∈ {-0.5, -0.25, 0, 0.25, 0.5}, exactly the gradient the linear
    // falloff samples.
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:1 segmentsY:4 segmentsZ:1 radius:0");

    // Activate shear preset. config/tool_presets.yaml wires this as
    // base=move + falloff.type=linear + falloff.shape=linear (the
    // shape pin ships in commit f804e28 — without it the default
    // Smooth shape would skew the gradient).
    cmd("tool.set xfrm.shear on");

    // Pin falloff handles. weight=1 at start (y=+0.5), weight=0 at end
    // (y=-0.5). Comma-separated vec3 needs quoting because the
    // argstring parser only accepts barewords [a-zA-Z0-9_./-].
    cmd("tool.pipe.attr falloff start \"0,0.5,0\"");
    cmd("tool.pipe.attr falloff end \"0,-0.5,0\"");
    cmd("tool.pipe.attr falloff shape linear");

    // TX=0.5: top row should shift +0.5, bottom row stays.
    cmd("tool.attr xfrm.shear TX 0.5");

    cmd("tool.doApply");

    // Group verts by their Y row and check each row's X span. vibe3d's
    // prim.cube duplicates the four corners on the y=±0.5 caps (top /
    // bottom faces own them, side faces also own them), so the same
    // (X, Y, Z) appears twice for the extreme rows — that's a
    // primitive-tessellation quirk, not a deform-math one. The
    // per-(X,Y) sanity check below treats duplicates as the same row
    // entry.
    auto verts = getJson("/api/model")["vertices"].array;

    // (yRow, expectedXLeft, expectedXRight)
    double[3][5] expected = [
        [-0.5,  -0.5,    0.5],     // weight 0
        [-0.25, -0.375,  0.625],   // weight 0.25
        [ 0.0,  -0.25,   0.75],    // weight 0.5
        [ 0.25, -0.125,  0.875],   // weight 0.75
        [ 0.5,   0.0,    1.0],     // weight 1.0
    ];

    foreach (row; expected) {
        double y = row[0], xL = row[1], xR = row[2];
        bool sawLeft = false, sawRight = false;
        foreach (v; verts) {
            auto a = v.array;
            if (!approxEq(a[1].floating, y)) continue;
            if      (approxEq(a[0].floating, xL)) sawLeft = true;
            else if (approxEq(a[0].floating, xR)) sawRight = true;
            else assert(false,
                "y=" ~ y.to!string ~ " row has unexpected X="
                ~ a[0].floating.to!string
                ~ " (expected " ~ xL.to!string ~ " or " ~ xR.to!string ~ ")");
        }
        assert(sawLeft,
            "y=" ~ y.to!string ~ " row missing left X=" ~ xL.to!string);
        assert(sawRight,
            "y=" ~ y.to!string ~ " row missing right X=" ~ xR.to!string);
    }
}

unittest { // shear with TX=0 leaves the cube alone — nothing moves
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:1 segmentsY:4 segmentsZ:1 radius:0");
    cmd("tool.set xfrm.shear on");
    cmd("tool.pipe.attr falloff start \"0,0.5,0\"");
    cmd("tool.pipe.attr falloff end \"0,-0.5,0\"");
    cmd("tool.pipe.attr falloff shape linear");
    // TX=0 (default) — no-op apply. Falloff weight × 0 = 0 displacement.
    cmd("tool.doApply");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        // X must stay on the original cube boundary (±0.5).
        assert(approxEq(fabs(a[0].floating), 0.5),
            "TX=0 shear shouldn't shift X off ±0.5, got "
            ~ a[0].floating.to!string);
    }
}
