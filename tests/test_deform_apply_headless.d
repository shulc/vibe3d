// Tests for the headless apply path on deform tools.
//
// MoveTool.applyHeadless() (called by `tool.doApply` after `tool.set
// xfrm.shear on; tool.attr xfrm.shear TX <v>`) reuses the same
// per-vertex weighting code path as interactive drag — the active
// FalloffStage's per-vertex weight × the explicit numeric translate.
// This file pins down the shear behaviour with a known cube+linear
// falloff configuration: the X offset must scale linearly with the
// vertex's Y position, matching the analytical reference values.
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
    // empty selection falls back to the whole mesh in MoveTool).
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

// ---------------------------------------------------------------------------
// twist (xfrm.twist preset = RotateTool + linear falloff). Verifies vibe3d
// against the analytical reference (per-vertex rotation by RY · weight(y)
// around the world Y axis).
// ---------------------------------------------------------------------------

import std.math : cos, sin, PI;

unittest { // twist: per-vertex Y-axis rotation via rotation-MATRIX lerp
    // vibe3d rotates with weight w as a linear blend of the rotation matrix:
    //   M(w) = (1-w)·I + w·R(axis, theta)        applied to p
    // This is NOT the arc model (R(theta*w)·p, radius-preserving) NOR a
    // quaternion lerp. M(w) blends two rotation matrices, so the component IN
    // the rotation plane pinches (radius < 1 mid-weight) while the component
    // ALONG the axis is preserved exactly. For a Y-axis rotation:
    //   xNew =  a·ox + b·oz
    //   yNew =  oy                          ← axis component preserved (no pinch)
    //   zNew =  a·oz - b·ox
    // where a = 1-w + w·cos(theta),  b = w·sin(theta).
    // At w=0: a=1,b=0 → identity. At w=1: a=cos,b=sin → pure rotation R(theta).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:1 segmentsY:4 segmentsZ:1 radius:0");

    // Snapshot BEFORE positions — we'll rotate each one analytically and
    // compare to the AFTER mesh. Avoids hardcoding the cube's vert
    // emission order.
    auto before = getJson("/api/model")["vertices"].array;
    double[3][] origs;
    foreach (v; before) {
        auto a = v.array;
        origs ~= [a[0].floating, a[1].floating, a[2].floating];
    }

    cmd("tool.set xfrm.twist on");
    cmd("tool.pipe.attr falloff start \"0,0.5,0\"");
    cmd("tool.pipe.attr falloff end \"0,-0.5,0\"");
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.attr xfrm.twist RY 30");
    cmd("tool.doApply");

    auto after = getJson("/api/model")["vertices"].array;
    assert(after.length == origs.length,
        "vert count changed: " ~ origs.length.to!string ~ " → "
        ~ after.length.to!string);

    enum START_Y =  0.5;
    enum END_Y   = -0.5;
    enum RY_DEG  = 30.0;

    foreach (i, v; after) {
        auto a = v.array;
        double ox = origs[i][0], oy = origs[i][1], oz = origs[i][2];
        // Linear weight: 1 at start_Y, 0 at end_Y, clamped outside [0,1].
        double w = (oy - END_Y) / (START_Y - END_Y);
        if (w < 0) w = 0;
        else if (w > 1) w = 1;
        // Full rotation angle (Y axis, pivot at origin).
        double theta = RY_DEG * (PI / 180.0);
        // Matrix lerp M(w) = (1-w)·I + w·R(Y,theta), R(Y,theta)·p =
        //   (ox·cos + oz·sin, oy, oz·cos - ox·sin):
        double ca = 1.0 - w + w * cos(theta);  // (1-w) + w·cos
        double sb = w * sin(theta);            //         w·sin
        double xExp = ca * ox + sb * oz;
        double yExp = oy;                      // axis component preserved
        double zExp = ca * oz - sb * ox;
        assert(approxEq(a[1].floating, yExp, 1e-4),
            "vert " ~ i.to!string ~ " Y mismatch: "
            ~ "got " ~ a[1].floating.to!string
            ~ ", expected " ~ yExp.to!string
            ~ " (orig=(" ~ ox.to!string ~ "," ~ oy.to!string ~ ","
            ~ oz.to!string ~ "), w=" ~ w.to!string ~ ")");
        assert(approxEq(a[0].floating, xExp, 1e-4),
            "vert " ~ i.to!string ~ " X mismatch: "
            ~ "got " ~ a[0].floating.to!string
            ~ ", expected " ~ xExp.to!string
            ~ " (orig=(" ~ ox.to!string ~ "," ~ oy.to!string ~ ","
            ~ oz.to!string ~ "), w=" ~ w.to!string ~ ")");
        assert(approxEq(a[2].floating, zExp, 1e-4),
            "vert " ~ i.to!string ~ " Z mismatch: "
            ~ "got " ~ a[2].floating.to!string
            ~ ", expected " ~ zExp.to!string);
    }
}

unittest { // twist with RY=0 leaves the cube alone
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:1 segmentsY:4 segmentsZ:1 radius:0");
    cmd("tool.set xfrm.twist on");
    cmd("tool.pipe.attr falloff start \"0,0.5,0\"");
    cmd("tool.pipe.attr falloff end \"0,-0.5,0\"");
    cmd("tool.pipe.attr falloff shape linear");
    // Default RX/RY/RZ = 0 → no rotation. applyHeadless skips the loop
    // entirely (each axis-rotation is gated `if (R{X,Y,Z} != 0)`).
    cmd("tool.doApply");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        // Cube corners stay on the ±0.5 box.
        bool onBox = approxEq(fabs(a[0].floating), 0.5)
                  || approxEq(fabs(a[1].floating), 0.5)
                  || approxEq(fabs(a[2].floating), 0.5);
        assert(onBox, "RY=0 twist shouldn't move verts off the cube box");
    }
}

// ---------------------------------------------------------------------------
// taper (xfrm.taper preset = ScaleTool + linear falloff). SX=2.0
// gives the expected per-row X-scale ramp; this test asserts it.
// ---------------------------------------------------------------------------

unittest { // taper: per-row X-scale by SX · weight(y) about the ACEN center
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:1 segmentsY:4 segmentsZ:1 radius:0");

    cmd("tool.set xfrm.taper on");
    cmd("tool.pipe.attr falloff start \"0,0.5,0\"");
    cmd("tool.pipe.attr falloff end \"0,-0.5,0\"");
    cmd("tool.pipe.attr falloff shape linear");
    // SX=2.0 — top row scales 2× along X about origin (ACEN.Auto on a
    // centered cube ⇒ origin), bottom stays. Y and Z stay unchanged
    // because SY/SZ default to 1.0 and applyHeadless short-circuits
    // identity-scale axes out via the `headlessScale == (1,1,1)` guard
    // (tested separately in the no-op test below).
    cmd("tool.attr xfrm.taper SX 2.0");
    cmd("tool.doApply");

    auto verts = getJson("/api/model")["vertices"].array;

    // (yRow, weight, expectedXLeft, expectedXRight) — X = ±(0.5 · (1 + (SX-1)·w))
    double[3][5] expected = [
        [-0.5,  -0.5,    0.5],     // weight 0,    1.0×
        [-0.25, -0.625,  0.625],   // weight 0.25, 1.25×
        [ 0.0,  -0.75,   0.75],    // weight 0.5,  1.5×
        [ 0.25, -0.875,  0.875],   // weight 0.75, 1.75×
        [ 0.5,  -1.0,    1.0],     // weight 1.0,  2.0×
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

unittest { // taper at identity (SX=SY=SZ=1) is a no-op
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:1 segmentsY:4 segmentsZ:1 radius:0");
    cmd("tool.set xfrm.taper on");
    cmd("tool.pipe.attr falloff start \"0,0.5,0\"");
    cmd("tool.pipe.attr falloff end \"0,-0.5,0\"");
    cmd("tool.pipe.attr falloff shape linear");
    // Default SX=SY=SZ=1.0 — applyHeadless's identity-scale guard
    // returns early. No verts should move; cube stays on ±0.5 box.
    cmd("tool.doApply");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        bool onBox = approxEq(fabs(a[0].floating), 0.5)
                  || approxEq(fabs(a[1].floating), 0.5)
                  || approxEq(fabs(a[2].floating), 0.5);
        assert(onBox,
            "identity taper shouldn't move verts off the cube box, got ("
            ~ a[0].floating.to!string ~ ", " ~ a[1].floating.to!string
            ~ ", " ~ a[2].floating.to!string ~ ")");
    }
}
