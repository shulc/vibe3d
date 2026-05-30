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
import std.math : fabs, sqrt;
import std.conv : to;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

double dist(double[3] a, double[3] b) {
    double dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
    return sqrt(dx*dx + dy*dy + dz*dz);
}

unittest { // dragging the view ring with no selection rotates the whole cube rigidly
    post("http://localhost:8080/api/reset", "");

    // No selection: the moving set is the whole mesh.
    auto setResp = post("http://localhost:8080/api/script", "tool.set rotate");
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set rotate failed: " ~ cast(string)setResp);

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
    float cx, cy;
    assert(projectToWindow(pivot, vp, cx, cy),
        "gizmo center projects off-camera (camera changed?)");

    // arcView ring ≈ 99 px around the gizmo center; click at +95 px lands
    // inside the 8 px hit-test band. A 70 px tangent drag traces a large
    // view-axis angle. Same geometry as test_tool_rotate_drag.
    int x0 = cast(int)(cx + 95);
    int y0 = cast(int)cy;
    int x1 = x0;
    int y1 = y0 - 70;

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
