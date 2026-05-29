// MS-1 of doc/rotate_single_source_plan.md — rotate "drag == numeric"
// contract-pin (live-drag arm).
//
// This is a GREEN contract-pin, NOT a RED-first test (round-3 S3 honesty
// note): unlike the translate refactor, rotate has no live per-cluster bug,
// so this drag already agrees with the numeric path. Its job is to LOCK the
// "an interactive principal-axis ring drag produces the same geometry as the
// numeric `tool.attr xfrm.transform R<axis>` + `tool.doApply`" contract so the
// single-source refactor (gesture-scalar producer → wrapper applyTRS, Phase 3+)
// cannot silently re-diverge them. From Phase 3 onward this test is the live
// exerciser of the new gesture→drag→applyTRS code path.
//
// Why ACEN.Auto + a clean-cube top face (not the ACEN.Local 3-poly fixture the
// plan's numeric arm uses): the principal-axis arcs reorient toward the camera
// every frame (RotateHandler.applyStart, handler.d), so a reliable synthetic
// click pixel requires replicating that arc geometry test-side. ACEN.Auto gives
// a single world-aligned pivot at (0, 0.5, 0), making the click + the angle
// recovery unambiguous. ACEN.Local per-cluster correctness is already pinned by
// the numeric invariants in test_acen_local_rotate_parity.d (centroid-fixed +
// radius-preserved). The display-readout / undo arm (B-survivor-1) lands with
// the B2 commit-hook work in MS-5 once a tool-attr read endpoint exists.
//
// Drag construction: replicate SemicircleHandler's arc geometry for the Y arc
//   right, up = localFrame(axisY)            (handler.d:89-94)
//   startAngle via applyStart(arcY, axisY)   (handler.d:731-742)
//   click the camera-facing midpoint (a = startAngle + PI/2) at world radius
//   gizmoSize(center); drag tangentially along the arc to a second param.

import std.net.curl;
import std.json;
import std.math   : fabs, sqrt, sin, cos, atan2, PI;
import std.conv   : to;
import std.format : format;

import drag_helpers : Vec3, dot, cross, normalize, gizmoSize,
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

// The default cube's top face = the polygon whose 4 verts all sit on y≈0.5.
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

int[] topFaceVerts(int topFace) {
    int[] out_;
    foreach (vi; getJson("/api/model")["faces"].array[topFace].array)
        out_ ~= cast(int)vi.integer;
    return out_;
}

void lockCamera() {
    auto r = postJson("/api/camera",
        `{"azimuth":0.5,"elevation":0.4,"distance":3.0,`
      ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`);
    assert(r["status"].str == "ok", "camera lock failed: " ~ r.toString);
}

// Establish: default cube → top-face selection → xfrm.transform with ONLY
// the R flag (so the click can't accidentally land on a move arrow / scale
// box) → ACEN.Auto (default). Returns the top-face vert indices.
int[] setupScene() {
    postJson("/api/reset", "");
    lockCamera();
    int topFace = findTopFace();
    auto sel = postJson("/api/select",
        `{"mode":"polygons","indices":[` ~ topFace.to!string ~ `]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform T false");
    cmd("tool.attr xfrm.transform S false");
    cmd("tool.attr xfrm.transform R true");
    return topFaceVerts(topFace);
}

// Replica of source/handler.d:localFrame (89-94).
void localFrame(Vec3 normal, out Vec3 right, out Vec3 up) {
    Vec3 fwd = normalize(normal);
    Vec3 tmp = fabs(fwd.x) < 0.9f ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
    right = normalize(cross(fwd, tmp));
    up    = cross(right, fwd);
}

// Replica of RotateHandler.applyStart's start direction (handler.d:731-742),
// returning the chosen startAngle in the arc's (right, up) frame.
float arcStartAngle(Vec3 n, Vec3 camFwd, Vec3 right, Vec3 up) {
    Vec3 dir = cross(n, camFwd);
    float len = sqrt(dot(dir, dir));
    if (len <= 1e-4f) return 0.0f;     // degenerate: SemicircleHandler default
    dir = dir / len;
    Vec3 mid = cross(n, dir);
    if (dot(mid, camFwd) < 0.0f) dir = dir * (-1.0f);
    return atan2(dot(dir, up), dot(dir, right));
}

// Signed rotation angle (radians) about +Y that maps the XZ projection of
// (pre - center) onto (post - center), in the engine's Rodrigues convention
// (rotateVec around +Y: x' = x·c + z·s, z' = z·c − x·s).
float recoverYAngle(Vec3[] pre, Vec3[] post_, int[] verts, Vec3 center) {
    float accC = 0, accS = 0;
    foreach (vi; verts) {
        float ax = pre[vi].x - center.x, az = pre[vi].z - center.z;
        float bx = post_[vi].x - center.x, bz = post_[vi].z - center.z;
        float r2 = ax*ax + az*az;
        if (r2 < 1e-6f) continue;            // vert on the Y axis
        accC += (ax*bx + az*bz);             // ∝ cosθ
        accS += (az*bx - ax*bz);             // ∝ sinθ
    }
    return atan2(accS, accC);
}

unittest { // principal-axis (Y) ring drag == numeric RY, per vertex
    int[] topVerts = setupScene();
    auto pre = dumpVerts();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    Vec3 center = Vec3(0, 0.5f, 0);          // ACEN.Auto top-face centroid
    Vec3 axisY  = Vec3(0, 1, 0);
    float radius = gizmoSize(center, vp);

    Vec3 right, up;
    localFrame(axisY, right, up);
    Vec3 camFwd = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
    float startAngle = arcStartAngle(axisY, camFwd, right, up);

    // Camera-facing midpoint of the arc, then a second point further along
    // the arc — the drag traces a tangential pull producing a ~0.45 rad turn.
    float a0 = startAngle + cast(float)(PI / 2.0);
    float a1 = a0 + 0.45f;
    Vec3 w0 = center + right * (cos(a0) * radius) + up * (sin(a0) * radius);
    Vec3 w1 = center + right * (cos(a1) * radius) + up * (sin(a1) * radius);

    float x0f, y0f, x1f, y1f;
    assert(projectToWindow(w0, vp, x0f, y0f),
        "arc start projects off-camera");
    assert(projectToWindow(w1, vp, x1f, y1f),
        "arc end projects off-camera");

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              cast(int)x0f, cast(int)y0f,
                              cast(int)x1f, cast(int)y1f, 20);
    playAndWait(log);

    auto postDrag = dumpVerts();

    // Sanity: the drag must actually have rotated the top face.
    float maxMove = 0;
    foreach (vi; topVerts) {
        Vec3 d = postDrag[vi] - pre[vi];
        float m = sqrt(dot(d, d));
        if (m > maxMove) maxMove = m;
    }
    assert(maxMove > 0.05f,
        "drag produced no measurable rotation (|max Δ|=" ~ maxMove.to!string
        ~ ") — the synthetic click pixels likely missed the Y arc");

    // Recover the rotation angle the drag produced, then reproduce it through
    // the numeric path in a fresh scene.
    float thetaRad = recoverYAngle(pre, postDrag, topVerts, center);
    float thetaDeg = thetaRad * 180.0f / cast(float)PI;

    setupScene();
    auto preNum = dumpVerts();
    cmd(format("tool.attr xfrm.transform RX 0"));
    cmd(format("tool.attr xfrm.transform RY %.6f", thetaDeg));
    cmd(format("tool.attr xfrm.transform RZ 0"));
    cmd("tool.doApply");
    auto postNum = dumpVerts();

    assert(postDrag.length == postNum.length && pre.length == preNum.length,
        "vertex count changed between drag and numeric arms");

    // Per-vertex: drag-applied geometry == numeric-applied geometry.
    float maxDiff = 0;
    int   worst = -1;
    foreach (vi; 0 .. pre.length) {
        Vec3 diff = postDrag[vi] - postNum[vi];
        float m = sqrt(dot(diff, diff));
        if (m > maxDiff) { maxDiff = m; worst = cast(int)vi; }
    }
    assert(maxDiff < 0.01f,
        "rotate drag != numeric (contract broken): max per-vert drift = "
        ~ maxDiff.to!string ~ " at vertex " ~ worst.to!string
        ~ " (recovered RY = " ~ thetaDeg.to!string ~ "°)");
}
