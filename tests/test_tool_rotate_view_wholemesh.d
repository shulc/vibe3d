// Whole-mesh view-ring rotate drag test.
//
// Companion to test_tool_rotate_drag.d (which drags the view ring on a
// PARTIAL selection — the top face). This one drags the view ring with NO
// selection, so the moving set is the whole mesh (empty selection ⇒ whole
// mesh, per the universal transform rule). That exercises the wrapper-owned
// view-ring FAST PATH: XfrmTransformTool.beginRotateDragSession sets
// rotDragFastPath=true, onMouseMotion drains the producer's view axis+angle
// into applyTRS's transient view-axis/angle params, runs applyTRS(dragBaseline), and bridges
// the GPU with pivotRotationMatrix. The arbitrary view axis is applied through
// the SAME applyRotateIncremental kernel (dragAxisIdx == -1) the principal
// rings use — single source of truth for ui/handle/headless.
//
// What this pins down:
//   • no selection → ALL cube verts rotate (whole-mesh path)
//   • the rotation is RIGID — every pairwise vertex distance is preserved
//   • the centroid stays at the origin (rotation pivots at ACEN.Auto = (0,0,0)
//     for the whole default cube), i.e. no translation leaks in

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, cos, sin, PI;
import std.conv : to;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

double dist(double[3] a, double[3] b) {
    double dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
    return sqrt(dx*dx + dy*dy + dz*dz);
}

double distPointSegment(double px, double py,
                        double ax, double ay, double bx, double by)
{
    double vx = bx - ax, vy = by - ay;
    double wx = px - ax, wy = py - ay;
    double len2 = vx*vx + vy*vy;
    double t = len2 > 1e-9 ? (wx*vx + wy*vy) / len2 : 0.0;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    double qx = ax + t * vx, qy = ay + t * vy;
    double dx = px - qx, dy = py - qy;
    return sqrt(dx*dx + dy*dy);
}

void viewRingGrab(Vec3 pivot, Viewport vp,
                  out int x0, out int y0, out int x1, out int y1)
{
    float cx, cy;
    assert(projectToWindow(pivot, vp, cx, cy),
        "gizmo center projects off-camera (camera changed?)");

    float size = gizmoSize(pivot, vp);
    Vec3[3] axisEnds = [
        Vec3(pivot.x + size * 1.18f, pivot.y, pivot.z),
        Vec3(pivot.x, pivot.y + size * 1.18f, pivot.z),
        Vec3(pivot.x, pivot.y, pivot.z + size * 1.18f),
    ];
    float[2][3] axisPx;
    foreach (i; 0 .. 3) {
        assert(projectToWindow(axisEnds[i], vp, axisPx[i][0], axisPx[i][1]),
            "axis endpoint projects off-camera");
    }

    // Pick a point on the view ring that is far from projected axis handles.
    // In compact Transform, move/scale handles are registered too; this keeps
    // the click owned by arcView rather than an overlapping axis handle.
    double bestScore = -1.0;
    double bestA = 0.0;
    foreach (deg; [20.0, 50.0, 80.0, 110.0, 140.0, 170.0,
                   200.0, 230.0, 260.0, 290.0, 320.0]) {
        double a = deg * PI / 180.0;
        double px = cx + 95.0 * cos(a);
        double py = cy + 95.0 * sin(a);
        double score = double.max;
        foreach (i; 0 .. 3) {
            double d = distPointSegment(px, py, cx, cy,
                                        axisPx[i][0], axisPx[i][1]);
            if (d < score) score = d;
        }
        if (score > bestScore) { bestScore = score; bestA = a; }
    }
    assert(bestScore > 12.0,
        "could not find view-ring grab away from axis handles");

    x0 = cast(int)(cx + 95.0 * cos(bestA));
    y0 = cast(int)(cy + 95.0 * sin(bestA));
    // Tangential drag along the screen-space ring.
    x1 = x0 + cast(int)(70.0 * -sin(bestA));
    y1 = y0 + cast(int)(70.0 *  cos(bestA));
}

void runViewRingWholeMesh(string toolId) {
    post("http://localhost:8080/api/reset", "");

    // No selection: the moving set is the whole mesh.
    auto setResp = post("http://localhost:8080/api/script", "tool.set " ~ toolId);
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set " ~ toolId ~ " failed: " ~ cast(string)setResp);

    // Snapshot all 8 verts of the default unit cube.
    int nVerts;
    {
        auto m = parseJSON(cast(string)get("http://localhost:8080/api/model"));
        nVerts = cast(int)m["vertices"].array.length;
    }
    assert(nVerts == 8, "default cube should have 8 verts, got " ~ nVerts.to!string);

    double[3][] pre = new double[3][](nVerts);
    foreach (i; 0 .. nVerts) pre[i] = vertexPos(i);

    // Centroid of the default cube is the origin; ACEN.Auto pivots there.
    double[3] preCentroid = [0.0, 0.0, 0.0];
    foreach (i; 0 .. nVerts)
        foreach (k; 0 .. 3) preCentroid[k] += pre[i][k] / nVerts;
    foreach (k; 0 .. 3)
        assert(approx(preCentroid[k], 0.0, 1e-4),
            "default cube centroid not at origin (k=" ~ k.to!string ~ ")");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    Vec3 pivot = Vec3(0, 0, 0);
    int x0, y0, x1, y1;
    viewRingGrab(pivot, vp, x0, y0, x1, y1);

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    double[3][] post = new double[3][](nVerts);
    foreach (i; 0 .. nVerts) post[i] = vertexPos(i);

    // Every vert moved — whole-mesh rotation, no idle verts.
    foreach (i; 0 .. nVerts) {
        double dx = post[i][0] - pre[i][0];
        double dy = post[i][1] - pre[i][1];
        double dz = post[i][2] - pre[i][2];
        double moved = sqrt(dx*dx + dy*dy + dz*dz);
        assert(moved > 0.05,
            "whole-mesh v" ~ i.to!string ~ " barely moved (|Δ|=" ~
            moved.to!string ~ ") — view-ring hit-test likely missed");
    }

    // Rigid: every pairwise distance preserved.
    foreach (i; 0 .. nVerts)
        foreach (j; i + 1 .. nVerts) {
            double dPre  = dist(pre[i],  pre[j]);
            double dPost = dist(post[i], post[j]);
            assert(fabs(dPre - dPost) < 1e-3,
                "non-rigid rotation: |v" ~ i.to!string ~ "v" ~ j.to!string ~
                "| changed " ~ dPre.to!string ~ " → " ~ dPost.to!string);
        }

    // Centroid invariant: rotation pivots at the origin, so no translation
    // leaks in (the whole-mesh fast path must not drift the pivot).
    double[3] postCentroid = [0.0, 0.0, 0.0];
    foreach (i; 0 .. nVerts)
        foreach (k; 0 .. 3) postCentroid[k] += post[i][k] / nVerts;
    foreach (k; 0 .. 3)
        assert(approx(postCentroid[k], 0.0, 1e-3),
            "centroid drifted from origin during whole-mesh view rotation (k=" ~
            k.to!string ~ ", got " ~ postCentroid[k].to!string ~ ")");
}

unittest { // rotate full presentation: view ring rotates whole cube rigidly
    runViewRingWholeMesh("rotate");
}

unittest { // bare Transform compact presentation includes screen-space rotate
    runViewRingWholeMesh("Transform");
}

// Published cumulative rotate euler (deg) off /api/toolpipe/eval.
double publishedRotateAxis(int axis) {
    auto j = parseJSON(cast(string)get("http://localhost:8080/api/toolpipe/eval"));
    auto t = "transform" in j.object;
    assert(t !is null,
        "eval has no transform block (no transform tool active?): " ~ j.toString);
    return (*t)["rotate"].array[axis].floating;
}

// MATRIX-AS-TRUTH — a view-ring drag now FOLDS its arbitrary-axis rotation onto
// runRotMatrix, so the DERIVED panel euler (transform.rotate) is the cumulative
// orientation and reads NON-ZERO after the drag. Under the prior euler-as-truth
// model the view-ring was a transient axis-angle param never stored in the Euler
// field, so the panel showed (0,0,0) after a pure view-ring drag — the gap this
// fixes. (The tool is left ACTIVE — no `tool.set off` — so the live run's published
// rotate is still observable on the eval seam.)
unittest { // view-ring drag → panel cumulative euler is non-zero
    post("http://localhost:8080/api/reset", "");
    auto setResp = post("http://localhost:8080/api/script", "tool.set rotate");
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set rotate failed: " ~ cast(string)setResp);

    // Pristine: no rotation applied yet ⇒ published euler is identity.
    foreach (k; 0 .. 3)
        assert(approx(publishedRotateAxis(k), 0.0, 1e-4),
            "pre-drag published rotate axis " ~ k.to!string ~ " should be 0");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 pivot = Vec3(0, 0, 0);
    int x0, y0, x1, y1;
    viewRingGrab(pivot, vp, x0, y0, x1, y1);
    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    // The view-ring rotation folded onto runRotMatrix ⇒ at least one euler
    // component is materially non-zero (a real arc was dragged).
    double mag = 0.0;
    foreach (k; 0 .. 3) {
        double v = publishedRotateAxis(k);
        if (fabs(v) > mag) mag = fabs(v);
    }
    assert(mag > 1.0,
        "view-ring drag should publish a non-zero cumulative euler (matrix-truth "
        ~ "folds the view rotation into the panel value); max |component| = "
        ~ mag.to!string);
}
