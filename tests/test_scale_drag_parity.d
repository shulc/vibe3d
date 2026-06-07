// Scale "drag == numeric" contract-pin (scale single-source refactor).
//
// Mirrors test_rotate_drag_parity.d for the scale arm. Its job is to LOCK
// the contract that an interactive single-axis scale-arrow drag produces the
// SAME geometry as the numeric `tool.attr xfrm.transform SX <factor>` +
// `tool.doApply` path. After the scale single-source refactor (ScaleTool's
// drag branches became gesture-scalar producers; the unified wrapper drains
// the within-drag factor into headlessScale and runs the one applyTRS
// evaluate), both arms share that single geometry-apply entry point — this
// test guards them against silently re-diverging.
//
// Setup: default cube → all 8 verts selected → xfrm.transform with ONLY the
// S flag (so the click can't land on a move arrow / rotate ring) → ACEN.Auto
// (pivot = whole-cube centroid = origin), so an X-arrow drag is a clean
// uniform-about-origin scale of the X component only and the factor recovery
// (post.x / pre.x) is unambiguous.

import std.net.curl;
import std.json;
import std.math   : fabs, sqrt;
import std.conv   : to;
import std.format : format;

import drag_helpers : Vec3, gizmoSize,
                      fetchCamera, viewportFromCamera,
                      projectToWindow, buildDragLog, playAndWait;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

Vec3[] dumpVerts() {
    auto verts = getJson("/api/model")["vertices"].array;
    Vec3[] out_;
    out_.length = verts.length;
    foreach (i, v; verts) {
        auto a = v.array;
        out_[i] = Vec3(cast(float)a[0].floating,
                       cast(float)a[1].floating,
                       cast(float)a[2].floating);
    }
    return out_;
}

void lockCamera() {
    auto r = postJson("/api/camera",
        `{"azimuth":0.5,"elevation":0.4,"distance":3.0,`
      ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`);
    assert(r["status"].str == "ok", "camera lock failed: " ~ r.toString);
}

// default cube → select all 8 verts → xfrm.transform with ONLY the S flag.
void setupScene() {
    postJson("/api/reset", "");
    lockCamera();
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform T false");
    cmd("tool.attr xfrm.transform R false");
    cmd("tool.attr xfrm.transform S true");
}

// Average post.x / pre.x over verts off the pivot's X axis — the uniform
// single-axis scale factor the drag produced.
float recoverXFactor(Vec3[] pre, Vec3[] post_) {
    float acc = 0;
    int   n   = 0;
    foreach (vi; 0 .. pre.length) {
        if (fabs(pre[vi].x) < 1e-4f) continue;
        acc += post_[vi].x / pre[vi].x;
        n++;
    }
    assert(n > 0, "no off-axis verts to recover the scale factor from");
    return acc / n;
}

unittest { // single-axis (X) scale-arrow drag == numeric SX, per vertex
    setupScene();
    auto pre = dumpVerts();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    Vec3 pivot = Vec3(0, 0, 0);            // ACEN.Auto centroid for full cube
    float size = gizmoSize(pivot, vp);
    // ScaleHandler X-arrow shaft: center + axis*(size/7) → center + axis*(size*1.18).
    Vec3 arrowStart = Vec3(pivot.x + size / 7.0f, pivot.y, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x + size * 1.18f, pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1),
        "X-arrow start projects off-camera");
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2),
        "X-arrow end projects off-camera");

    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));

    double sdx = cast(double)(sx2 - sx1);
    double sdy = cast(double)(sy2 - sy1);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    assert(sLen > 1.0, "X-arrow projects too short for a reliable scale drag");
    int x1 = x0 + cast(int)(80.0 * sdx / sLen);
    int y1 = y0 + cast(int)(80.0 * sdy / sLen);

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    auto postDrag = dumpVerts();

    // Sanity: the drag must actually have scaled the X component out.
    float maxMove = 0;
    foreach (vi; 0 .. pre.length) {
        float m = fabs(postDrag[vi].x - pre[vi].x);
        if (m > maxMove) maxMove = m;
    }
    assert(maxMove > 0.05f,
        "drag produced no measurable scale (|max Δx|=" ~ maxMove.to!string
        ~ ") — the synthetic click pixels likely missed the X arrow");

    // Recover the factor the drag produced, then reproduce it numerically.
    float fX = recoverXFactor(pre, postDrag);

    setupScene();
    auto preNum = dumpVerts();
    cmd(format("tool.attr xfrm.transform SX %.6f", fX));
    cmd("tool.attr xfrm.transform SY 1");
    cmd("tool.attr xfrm.transform SZ 1");
    cmd("tool.doApply");
    auto postNum = dumpVerts();

    assert(postDrag.length == postNum.length && pre.length == preNum.length,
        "vertex count changed between drag and numeric arms");

    // Per-vertex: drag-applied geometry == numeric-applied geometry.
    float maxDiff = 0;
    int   worst = -1;
    foreach (vi; 0 .. pre.length) {
        Vec3 diff = Vec3(postDrag[vi].x - postNum[vi].x,
                         postDrag[vi].y - postNum[vi].y,
                         postDrag[vi].z - postNum[vi].z);
        float m = sqrt(diff.x*diff.x + diff.y*diff.y + diff.z*diff.z);
        if (m > maxDiff) { maxDiff = m; worst = cast(int)vi; }
    }
    assert(maxDiff < 0.01f,
        "scale drag != numeric (contract broken): max per-vert drift = "
        ~ maxDiff.to!string ~ " at vertex " ~ worst.to!string
        ~ " (recovered SX = " ~ fX.to!string ~ ")");
}
