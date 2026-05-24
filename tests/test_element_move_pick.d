// xfrm.elementMove behaviour tests:
//   - click sets ACEN.userPlaced (the gizmo pivot AND the falloff
//     sphere anchor — ACEN is the single source of truth for both;
//     FalloffStage.evaluate reads state.actionCenter.center)
//   - moving set = prior selection (empty ⇒ whole mesh, per the
//     universal "empty selection = all" rule)
//   - falloff.element attenuates per-vert displacement around the
//     sphere — same shape as Linear/Radial
//   - the interactive click-pick path lives on the unified
//     xfrm.transform tool (gated on FalloffStage.type == Element);
//     it relies on GPU-resolved hover state and is not reliably
//     reproducible through play-events in --test, so the tests
//     here drive ACEN.userPlaced directly via
//     `tool.pipe.attr actionCenter userPlacedCenter "x,y,z"`.

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
void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

string acenAttr(string name) {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "ACEN")
            return st["attrs"][name].str;
    assert(false, "ACEN stage missing");
}

double[3] pivotAttr() {
    // ACEN's cenX/cenY/cenZ are the LIVE evaluated center —
    // same value queryActionCenter / FalloffStage.evaluate read.
    return [acenAttr("cenX").to!double,
            acenAttr("cenY").to!double,
            acenAttr("cenZ").to!double];
}

double[3] vertexPos(int i) {
    auto verts = getJson("/api/model")["vertices"].array;
    auto a = verts[i].array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

bool approxEq(double a, double b, double eps = 1e-3) {
    return fabs(a - b) < eps;
}

unittest { // /api/toolpipe round-trip: pickedCenter set via
           // tool.pipe.attr surfaces back through the WGHT stage.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0.25,-0.3,0.7\"");
    auto pc = pivotAttr();
    assert(approxEq(pc[0],  0.25, 1e-4));
    assert(approxEq(pc[1], -0.30, 1e-4));
    assert(approxEq(pc[2],  0.70, 1e-4));
}

unittest { // Empty selection + default pickedCenter (0,0,0) + auto
           // dist=0.5: cube corners are √3·0.5 ≈ 0.87 from origin,
           // OUTSIDE the falloff sphere → weight=0 → no motion even
           // though the moving set covers the whole mesh.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.attr xfrm.elementMove TX 0.3");
    cmd("tool.doApply");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts)
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c].floating), 0.5, 1e-4),
                "default pickedCenter at origin shouldn't move corners");
}

unittest { // pickedCenter is just the falloff anchor, NOT a
           // moving-set short-circuit. Pre-select
           // -Z face, set pickedCenter to +Z face centroid with a
           // sphere large enough to enclose every vert (dist=2).
           // Apply TX=0.3 → only the -Z face moves (= the prior
           // selection); the +Z face stays put.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0,0,0.5\"");
    cmd("tool.pipe.attr falloff dist 2");
    cmd("tool.attr xfrm.elementMove TX 0.3");
    cmd("tool.doApply");

    foreach (i; 0 .. 4) {
        auto v = vertexPos(i);
        // -Z face = selected = moves with the falloff sphere weight.
        // At pickedCenter (0,0,0.5), dist=2: corner v0 = (±0.5,±0.5,-0.5),
        // distance from pickedCenter = √(0.25+0.25+1) = √1.5 ≈ 1.225,
        // t = 1.225/2 ≈ 0.612. We don't pin the exact shape curve here;
        // just assert SOME positive x motion (weight > 0).
        assert(v[0] > -0.499,
            "selected -Z v" ~ i.to!string ~ " must move in +X; got x="
            ~ v[0].to!string);
    }
    // +Z face NOT in selection → MUST stay put.
    foreach (i; 4 .. 8) {
        auto v = vertexPos(i);
        double expectX = [-0.5, 0.5, 0.5, -0.5][i-4];
        assert(approxEq(v[0], expectX, 1e-4),
            "non-selected +Z v" ~ i.to!string ~ " must stay; got x="
            ~ v[0].to!string);
    }
}

unittest { // Empty selection ⇒ whole mesh moves (universal rule).
           // pickedCenter at the cube centre, dist=2 covers every
           // corner. TX=0.5 shifts every vert by its sphere weight.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0,0,0\"");
    cmd("tool.pipe.attr falloff dist 2");
    cmd("tool.attr xfrm.elementMove TX 0.5");
    cmd("tool.doApply");
    auto verts = getJson("/api/model")["vertices"].array;
    int moved = 0;
    foreach (v; verts) {
        double x = v.array[0].floating;
        if (fabs(x + 0.5) > 1e-3 && fabs(x - 0.5) > 1e-3)
            ++moved;
    }
    assert(moved == 8,
        "empty selection ⇒ whole mesh moves; got " ~ moved.to!string
        ~ " of 8 verts displaced");
}

// NOTE: an interactive test for the click-pick → screen-plane drag
// path (XfrmTransformTool.onMouseButtonDown falling through to
// moveSub.beginScreenPlaneDragAt when falloff.element is active and
// no gizmo handler was hit) lives outside the headless suite — that
// path requires g_hoveredVertex/Edge/Face populated by the GPU ID-
// buffer hover pass BEFORE the synthetic MOUSEBUTTONDOWN fires, and
// EventPlayer.tick batches due events in one call, so no render
// frame intervenes between motion and click to refresh hover.
// Manual interactive testing covers it.

unittest { // anchorRing: picked element's verts always get weight=1
           // regardless of sphere radius. Simulate click-picking the
           // +Z face (verts 4,5,6,7) by setting ACEN.userPlaced AND
           // FalloffStage.anchorRing manually (the click path can't
           // be reliably driven headlessly). With dist=0.5 the face
           // corners sit at √2·0.5 ≈ 0.707 from the centre, well
           // outside the sphere — without the anchor-ring short-
           // circuit they'd get weight=0 and the picked face wouldn't
           // move. Verify: all 4 +Z verts shift by full TX; -Z face
           // stays put (outside sphere AND not in ring).
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0,0,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.pipe.attr falloff anchorRing \"4,5,6,7\"");
    cmd("tool.attr xfrm.elementMove TX 0.3");
    cmd("tool.doApply");

    foreach (i; 4 .. 8) {
        auto v = vertexPos(i);
        double baseX = [-0.5, 0.5, 0.5, -0.5][i - 4];
        assert(approxEq(v[0], baseX + 0.3, 1e-4),
            "anchor v" ~ i.to!string ~ " must shift by full TX=0.3 "
            ~ "(weight=1 short-circuit); got x=" ~ v[0].to!string);
    }
    foreach (i; 0 .. 4) {
        auto v = vertexPos(i);
        double baseX = [-0.5, 0.5, 0.5, -0.5][i];
        assert(approxEq(v[0], baseX, 1e-4),
            "-Z v" ~ i.to!string ~ " outside sphere + not in ring "
            ~ "must stay; got x=" ~ v[0].to!string);
    }
}

unittest { // anchorRing round-trip via setAttr / listAttrs.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff anchorRing \"0,3,7\"");
    auto j = getJson("/api/toolpipe");
    string ring;
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT")
            ring = st["attrs"]["anchorRing"].str;
    assert(ring == "0,3,7",
        "anchorRing round-trip failed: " ~ ring);
    // Empty string clears.
    cmd("tool.pipe.attr falloff anchorRing \"\"");
    foreach (st; j["stages"].array) {}
    j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT")
            ring = st["attrs"]["anchorRing"].str;
    assert(ring == "", "anchorRing should clear on empty; got " ~ ring);
}

unittest { // Type change AWAY from Element wipes anchorRing — no
           // stale ring carries into a subsequent re-activation.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff anchorRing \"1,2\"");
    cmd("tool.pipe.attr falloff type linear");
    cmd("tool.pipe.attr falloff type element");
    auto j = getJson("/api/toolpipe");
    string ring;
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT")
            ring = st["attrs"]["anchorRing"].str;
    assert(ring == "",
        "anchorRing should clear on type change away from Element; "
        ~ "got " ~ ring);
}

unittest { // queryActionCenter returns ACEN.userPlaced when Element
           // falloff is active — gizmo follows the click. Round-
           // trips ACEN.cenX/Y/Z (the live computed pivot) as the
           // observable proxy.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0,0,0.5\"");
    auto pc = pivotAttr();
    assert(approxEq(pc[0], 0,   1e-4)
        && approxEq(pc[1], 0,   1e-4)
        && approxEq(pc[2], 0.5, 1e-4));
}
