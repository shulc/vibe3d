// XfrmTransformTool headless + interactive drag tests (Steps 2-3
// of doc/unified_transform_plan.md). Pins the T → R → S chain
// through `tool.attr xfrm.transform TX/RX/SX ... / tool.doApply`
// AND the interactive composition path that dispatches a click on
// any handler bank to its matching sub-tool.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt, cos, sin, PI;

import drag_helpers;

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

JSONValue queryCmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "query `" ~ s ~ "` failed: " ~ j.toString);
    assert("value" in j, "query `" ~ s ~ "` returned no value: " ~ j.toString);
    return j["value"];
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

int findTopFace() {
    auto m = getJson("/api/model");
    auto verts = m["vertices"].array;
    foreach (fi, f; m["faces"].array) {
        bool top = true;
        foreach (vi; f.array) {
            double vy = verts[vi.integer].array[1].floating;
            if (fabs(vy - 0.5) > 1e-4) { top = false; break; }
        }
        if (top) return cast(int)fi;
    }
    assert(false, "no top face found in default cube");
}

double[3] actionCenter() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return [c[0].floating, c[1].floating, c[2].floating];
}

unittest { // tool.set xfrm.transform activates without error; attrs
           // round-trip through /api/command.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform TX 0.25");
    // doApply with no selection — applyHeadless returns false (no
    // verts to process), which surfaces as a command-status `ok`
    // with no mutation. The /api/model below verifies the cube is
    // untouched in that case.
    cmd("select.typeFrom vertex");
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    cmd("tool.doApply");
    auto verts = dumpVerts();
    // v6 = (+0.5, +0.5, +0.5) translated by TX=0.25 → x=0.75.
    assert(approxEq(verts[6][0], 0.75, 1e-4),
        "TX=0.25 should shift v6.x to 0.75; got " ~ verts[6][0].to!string);
    assert(approxEq(verts[6][1], 0.5, 1e-4));
    assert(approxEq(verts[6][2], 0.5, 1e-4));
}

unittest { // T flag off skips the translate step even with TX set.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform T false");
    cmd("tool.attr xfrm.transform TX 0.5");
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    cmd("tool.doApply");
    auto verts = dumpVerts();
    assert(approxEq(verts[6][0], 0.5, 1e-4),
        "T=false should leave v6 untouched even with TX=0.5; got "
        ~ verts[6][0].to!string);
}

unittest { // Pure RY=90° around ACEN.Auto pivot (= selection bbox
           // centre = v6 itself, since only v6 is selected). Rotating
           // a point about itself is a no-op — v6 stays put.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform T false");
    cmd("tool.attr xfrm.transform S false");
    cmd("tool.attr xfrm.transform RY 90");
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    cmd("tool.doApply");
    auto verts = dumpVerts();
    foreach (c; 0 .. 3)
        assert(approxEq(fabs(verts[6][c]), 0.5, 1e-4),
            "rotate-around-self should leave v6 on ±0.5 box; got "
            ~ verts[6][c].to!string);
}

unittest { // SY=2 with multi-vertex selection. ACEN.Auto pivot is the
           // selection bbox centre. Scale stretches the verts along Y
           // about that centre. With v2=(+0.5,+0.5,-0.5) and
           // v6=(+0.5,+0.5,+0.5) selected, bbox-centre Y = +0.5 →
           // scaling about (·, +0.5, ·) by SY=2 leaves both verts'
           // Y exactly where they were (point on the pivot plane).
           // Verify they stay put.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform T false");
    cmd("tool.attr xfrm.transform R false");
    cmd("tool.attr xfrm.transform SY 2.0");
    postJson("/api/select", `{"mode":"vertices","indices":[2,6]}`);
    cmd("tool.doApply");
    auto verts = dumpVerts();
    foreach (vi; [2, 6]) {
        assert(approxEq(verts[vi][1], 0.5, 1e-4),
            "v" ~ vi.to!string ~ ".y on pivot plane should stay 0.5; "
            ~ "got " ~ verts[vi][1].to!string);
    }
}

unittest { // TransformMove preset flips T=1 / R=0 / S=0 on the base
           // xfrm.transform tool. Activating it via tool.set runs the
           // preset's `attrs:` block; subsequent doApply with TX=0.5
           // and a non-zero RY/SX confirms only translate fired (no
           // rotation / scale leak through disabled flags).
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    cmd("tool.set TransformMove on");
    cmd("tool.attr TransformMove TX 0.25");
    cmd("tool.attr TransformMove RY 90");   // ignored — R is off
    cmd("tool.attr TransformMove SX 2.0");  // ignored — S is off
    cmd("tool.doApply");
    auto verts = dumpVerts();
    // v6 only translates by +0.25 in X; rotate/scale skipped.
    assert(approxEq(verts[6][0], 0.75, 1e-4)
        && approxEq(verts[6][1], 0.5, 1e-4)
        && approxEq(verts[6][2], 0.5, 1e-4),
        "TransformMove with TX=0.25 should shift v6.x by 0.25 ONLY; "
        ~ "got " ~ verts[6][0].to!string ~ "," ~ verts[6][1].to!string
        ~ "," ~ verts[6][2].to!string);
}

unittest { // TransformScale preset: T=0/R=0/S=1. Pure SY=2 around
           // the bbox-centre of multi-vertex selection.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[0,1,4,5]}`);
    cmd("tool.set TransformScale on");
    cmd("tool.attr TransformScale TX 100");   // ignored — T off
    cmd("tool.attr TransformScale SY 2.0");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    // Selection bbox = corners with y=-0.5: bbox centre y = -0.5.
    // SY=2 about that plane → y stays at -0.5 (verts ON the pivot).
    foreach (vi; [0, 1, 4, 5])
        assert(approxEq(verts[vi][1], -0.5, 1e-4),
            "v" ~ vi.to!string ~ " on pivot plane stays at y=-0.5; got "
            ~ verts[vi][1].to!string);
}

unittest { // MODO-style transform presets publish both operation flags
           // (T/R/S) and handle presentation metadata (H/presentation).
    postJson("/api/reset", "");

    cmd("tool.set Transform on");
    assert(queryCmd("tool.attr Transform H ?").integer == 0);
    assert(queryCmd("tool.attr Transform presentation ?").str == "compact");
    assert(queryCmd("tool.attr Transform T ?").type == JSON_TYPE.TRUE);
    assert(queryCmd("tool.attr Transform R ?").type == JSON_TYPE.TRUE);
    assert(queryCmd("tool.attr Transform S ?").type == JSON_TYPE.TRUE);

    cmd("tool.set TransformMove on");
    assert(queryCmd("tool.attr TransformMove H ?").integer == 0);
    assert(queryCmd("tool.attr TransformMove presentation ?").str == "full");
    assert(queryCmd("tool.attr TransformMove T ?").type == JSON_TYPE.TRUE);
    assert(queryCmd("tool.attr TransformMove R ?").type == JSON_TYPE.FALSE);
    assert(queryCmd("tool.attr TransformMove S ?").type == JSON_TYPE.FALSE);

    cmd("tool.set TransformRotate on");
    assert(queryCmd("tool.attr TransformRotate H ?").integer == 1);
    assert(queryCmd("tool.attr TransformRotate presentation ?").str == "full");
    assert(queryCmd("tool.attr TransformRotate T ?").type == JSON_TYPE.FALSE);
    assert(queryCmd("tool.attr TransformRotate R ?").type == JSON_TYPE.TRUE);
    assert(queryCmd("tool.attr TransformRotate S ?").type == JSON_TYPE.FALSE);

    cmd("tool.set TransformScale on");
    assert(queryCmd("tool.attr TransformScale H ?").integer == 2);
    assert(queryCmd("tool.attr TransformScale presentation ?").str == "full");
    assert(queryCmd("tool.attr TransformScale T ?").type == JSON_TYPE.FALSE);
    assert(queryCmd("tool.attr TransformScale R ?").type == JSON_TYPE.FALSE);
    assert(queryCmd("tool.attr TransformScale S ?").type == JSON_TYPE.TRUE);
}

unittest { // Interactive: T=1 only, click+drag the X-arrow with v6
           // selected. The composition path dispatches mouse-down to
           // the MoveTool sub-instance which handles the drag as it
           // does on its own. Mirrors test_tool_move_drag.d but via
           // xfrm.transform.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform R false");
    cmd("tool.attr xfrm.transform S false");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    drag_helpers.Vec3 pivot = drag_helpers.Vec3(0.5f, 0.5f, 0.5f);
    float size = gizmoSize(pivot, vp);
    auto arrowStart = drag_helpers.Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z);
    auto arrowEnd   = drag_helpers.Vec3(pivot.x + size,         pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1));
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2));
    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double sdx = cast(double)(sx2 - sx1), sdy = cast(double)(sy2 - sy1);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    int x1 = x0 + cast(int)(100.0 * sdx / sLen);
    int y1 = y0 + cast(int)(100.0 * sdy / sLen);
    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    auto verts = dumpVerts();
    double dx = verts[6][0] - 0.5;
    assert(dx > 0.1,
        "X-arrow drag via xfrm.transform should shift v6.x; dx="
        ~ dx.to!string);
    assert(fabs(verts[6][1] - 0.5) < 0.01
        && fabs(verts[6][2] - 0.5) < 0.01,
        "X-only drag should not touch v6.y/z");
    // Other corners untouched.
    foreach (k; 0 .. 3) {
        assert(fabs(verts[0][k] - [-0.5,-0.5,-0.5][k]) < 1e-4,
            "v0 moved on X-only drag of v6");
    }
}

unittest { // Bare Transform: rotate ring dispatches to Rotate, not Move.
    postJson("/api/reset", "");
    int topFace = findTopFace();
    postJson("/api/select", `{"mode":"polygons","indices":[` ~ topFace.to!string ~ `]}`);
    cmd("tool.set Transform on");

    int[] topVerts;
    {
        auto m = getJson("/api/model");
        foreach (vi; m["faces"].array[topFace].array)
            topVerts ~= cast(int)vi.integer;
    }
    double[3][] pre = new double[3][](topVerts.length);
    foreach (i, vi; topVerts) pre[i] = vertexPos(vi);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    drag_helpers.Vec3 pivot = drag_helpers.Vec3(0, 0.5f, 0);
    float cx, cy;
    assert(projectToWindow(pivot, vp, cx, cy));

    int x0 = cast(int)(cx + 95);
    int y0 = cast(int)cy;
    int x1 = x0;
    int y1 = y0 - 70;
    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    double[3] centroid = [0, 0, 0];
    foreach (vi; topVerts) {
        auto p = vertexPos(vi);
        centroid[0] += p[0];
        centroid[1] += p[1];
        centroid[2] += p[2];
    }
    foreach (k; 0 .. 3) centroid[k] /= topVerts.length;
    assert(fabs(centroid[0]) < 0.02 && fabs(centroid[1] - 0.5) < 0.02
        && fabs(centroid[2]) < 0.02,
        "Transform rotate ring should rotate around the top-face centroid, not move it; centroid="
        ~ centroid[0].to!string ~ "," ~ centroid[1].to!string ~ "," ~ centroid[2].to!string);

    double movedMax = 0;
    foreach (i, vi; topVerts) {
        auto p = vertexPos(vi);
        double dx = p[0] - pre[i][0];
        double dy = p[1] - pre[i][1];
        double dz = p[2] - pre[i][2];
        movedMax = movedMax > sqrt(dx*dx + dy*dy + dz*dz)
            ? movedMax : sqrt(dx*dx + dy*dy + dz*dz);
    }
    assert(movedMax > 0.05,
        "Transform rotate ring did not rotate the selected face; max movement="
        ~ movedMax.to!string);
}

unittest { // Bare Transform: scale axis head dispatches to Scale, not Move.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    cmd("tool.set Transform on");

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    drag_helpers.Vec3 pivot = drag_helpers.Vec3(0, 0, 0);
    float size = gizmoSize(pivot, vp);
    auto arrowEnd = drag_helpers.Vec3(pivot.x + size, pivot.y, pivot.z);
    float sx, sy;
    assert(projectToWindow(arrowEnd, vp, sx, sy));

    int x0 = cast(int)sx;
    int y0 = cast(int)sy;
    int x1 = x0 + 80;
    int y1 = y0;
    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    foreach (i; 0 .. 8) {
        auto p = vertexPos(i);
        assert(fabs(p[1] - pre[i][1]) < 1e-4,
            "Transform X-scale should not change y for v" ~ i.to!string);
        assert(fabs(p[2] - pre[i][2]) < 1e-4,
            "Transform X-scale should not change z for v" ~ i.to!string);
        assert(fabs(p[0]) > 0.6,
            "Transform X-scale head did not scale x for v" ~ i.to!string
            ~ "; x=" ~ p[0].to!string);
        assert((p[0] > 0) == (pre[i][0] > 0),
            "Transform X-scale should preserve x sign for v" ~ i.to!string);
    }
}

unittest { // Bare Transform: rotate then move must not re-apply the rotation.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[0,1,2]}`);
    cmd("tool.set Transform off");
    cmd("tool.set Transform on");
    cmd("tool.pipe.attr actionCenter mode auto");
    cmd("tool.pipe.attr axis mode auto");
    cmd("tool.pipe.attr falloff type none");
    cmd("tool.pipe.attr symmetry enabled false");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    auto center = actionCenter();
    drag_helpers.Vec3 pivot = drag_helpers.Vec3(cast(float)center[0],
                                                cast(float)center[1],
                                                cast(float)center[2]);
    float cx, cy;
    assert(projectToWindow(pivot, vp, cx, cy));

    string rotLog = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 cast(int)(cx + 95), cast(int)cy,
                                 cast(int)(cx + 95), cast(int)(cy - 70), 20);
    playAndWait(rotLog);

    double[3][3] afterRotate;
    foreach (slot, vi; [0, 1, 2])
        afterRotate[slot] = vertexPos(vi);

    center = actionCenter();
    pivot = drag_helpers.Vec3(cast(float)center[0],
                              cast(float)center[1],
                              cast(float)center[2]);
    float mx, my;
    assert(projectToWindow(pivot, vp, mx, my));
    int x0 = cast(int)mx;
    int y0 = cast(int)my;
    int x1 = x0 + 80;
    int y1 = y0;

    string moveLog = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  x0, y0, x1, y1, 20);
    playAndWait(moveLog);

    double[3] d0;
    auto p0 = vertexPos(0);
    foreach (k; 0 .. 3) d0[k] = p0[k] - afterRotate[0][k];
    double moved = sqrt(d0[0]*d0[0] + d0[1]*d0[1] + d0[2]*d0[2]);
    assert(moved > 0.05, "post-rotate move did not move v0 enough");

    foreach (vi; [1, 2]) {
        auto p = vertexPos(vi);
        foreach (k; 0 .. 3) {
            double dk = p[k] - afterRotate[vi][k];
            assert(fabs(dk - d0[k]) < 0.02,
                "post-rotate move should translate every selected vertex by the same delta; "
                ~ "v" ~ vi.to!string ~ " component " ~ k.to!string
                ~ " delta=" ~ dk.to!string ~ " expected " ~ d0[k].to!string);
        }
    }
}

unittest { // T→R→S chain order: TX=0.5 first translates v6 to
           // (1.0, 0.5, 0.5). Then RY=90° about ACEN.Auto bbox of the
           // post-T selection (the bbox now centres on v6's NEW
           // position — pivot snapshot is taken BEFORE the chain
           // starts, so pivot stays at the ORIGINAL bbox centre).
           // Verify the chain ordering by checking the final
           // position is what T-first-then-R-about-original-pivot
           // predicts.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform TX 0.5");
    cmd("tool.attr xfrm.transform RY 90");
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    cmd("tool.doApply");
    auto verts = dumpVerts();
    // Pivot = v6's ORIGINAL position = (0.5, 0.5, 0.5). After TX=0.5:
    // v6 → (1.0, 0.5, 0.5). Rotate 90° around Y about pivot
    // (0.5, 0.5, 0.5): relative pos = (0.5, 0, 0); Y-rotation 90°
    // sends +X → +Z and +Z → -X, so (0.5, 0, 0) → (0, 0, -0.5);
    // final = pivot + (0, 0, -0.5) = (0.5, 0.5, 0.0).
    assert(approxEq(verts[6][0], 0.5, 1e-4)
        && approxEq(verts[6][1], 0.5, 1e-4)
        && approxEq(verts[6][2], 0.0, 1e-4),
        "T→R chain: expected v6 at (0.5,0.5,0.0); got "
        ~ verts[6][0].to!string ~ "," ~ verts[6][1].to!string
        ~ "," ~ verts[6][2].to!string);
}
