// Interactive rotate-tool drag test (Stage A2 of doc/test_coverage_plan.md).
//
// The X/Y/Z semicircle arcs reorient themselves toward the camera every
// frame (RotateHandler.applyStart in handler.d), so picking a reliable
// click pixel on them requires replicating that camera-relative math
// test-side. The view-aligned ring (`arcView`) is much simpler — a full
// circle in the camera plane at world radius `size * 1.1` (≈ 99 px on
// screen at the default 90 px gizmo target), so we drive the drag
// through it instead.
//
// What this pins down:
//   • selecting the top face puts the gizmo at ACEN.Auto centroid
//     (0, 0.5, 0)
//   • dragging the view ring fires the dragAxis==3 path
//     (RotateTool.onMouseButtonDown → applyRotationVec via camFwd axis)
//   • the resulting rotation is RIGID — pairwise distances between
//     top-face verts stay the same to within float precision
//   • bottom-face verts are untouched (no selection bleed)

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

// Find the index of the face whose all four vertices sit on y ≈ 0.5 —
// that's the top face of the default cube regardless of which order
// the engine stores polygons in.
int findTopFace() {
    auto m = parseJSON(cast(string)get("http://localhost:8080/api/model"));
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

unittest { // dragging the view-axis ring rotates top face rigidly
    post("http://localhost:8080/api/reset", "");

    int topFace = findTopFace();
    auto selResp = post("http://localhost:8080/api/select",
                        `{"mode":"polygons","indices":[` ~ topFace.to!string ~ `]}`);
    assert(parseJSON(cast(string)selResp)["status"].str == "ok",
        "select failed: " ~ cast(string)selResp);

    auto setResp = post("http://localhost:8080/api/script", "tool.set rotate");
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set rotate failed: " ~ cast(string)setResp);

    // Fetch the 4 top-face vert indices so we can check displacement and
    // pairwise-distance invariants after the drag.
    int[] topVerts;
    {
        auto m = parseJSON(cast(string)get("http://localhost:8080/api/model"));
        foreach (vi; m["faces"].array[topFace].array)
            topVerts ~= cast(int)vi.integer;
    }
    double[3][] pre = new double[3][](topVerts.length);
    foreach (i, vi; topVerts) pre[i] = vertexPos(vi);
    auto preBottom0 = vertexPos(0);  // v0 is bottom — must not move

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // ACEN.Auto pivot = top-face centroid = (0, 0.5, 0).
    Vec3 pivot = Vec3(0, 0.5f, 0);
    float cx, cy;
    assert(projectToWindow(pivot, vp, cx, cy),
        "gizmo center projects off-camera (camera changed?)");

    // arcView (view-aligned ring) lives at world radius gizmoSize(pivot)*1.1,
    // which corresponds to ~99 px around the gizmo center on screen. The
    // ring's hit-test threshold is 8 px so a click at +95 px on the right
    // side lands solidly inside. The drag then traces a tangent — up by
    // ~70 px — which both passes the ≥ 25 px ctrl-constraint deadzone
    // (rotate has no such gate; harmless either way) and produces a
    // visibly large angle in the dragAxis==3 path.
    int x0 = cast(int)(cx + 95);
    int y0 = cast(int)cy;
    int x1 = x0;
    int y1 = y0 - 70;

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    auto postBottom0 = vertexPos(0);
    foreach (k; 0 .. 3) {
        assert(approx(postBottom0[k], preBottom0[k], 1e-4),
            "v0 (bottom) moved during top-face rotation — selection bled (k=" ~
            k.to!string ~ ")");
    }

    // Every top-face vertex should have moved (rotation around (0,0.5,0)
    // means each corner traces an arc — minimum displacement is at least
    // half the click-arc-angle × distance-from-pivot; with our 70 px drag
    // that's well over 0.05 in world units).
    double[3][] post = new double[3][](topVerts.length);
    foreach (i, vi; topVerts) post[i] = vertexPos(vi);
    foreach (i; 0 .. topVerts.length) {
        double dx = post[i][0] - pre[i][0];
        double dy = post[i][1] - pre[i][1];
        double dz = post[i][2] - pre[i][2];
        double moved = sqrt(dx*dx + dy*dy + dz*dz);
        assert(moved > 0.05,
            "top-face v" ~ topVerts[i].to!string ~ " barely moved (|Δ|=" ~
            moved.to!string ~ ") — view-ring hit-test likely missed");
    }

    // Rigid rotation: pairwise distances between top-face verts preserved.
    foreach (i; 0 .. topVerts.length) {
        foreach (j; i + 1 .. topVerts.length) {
            double dPre  = dist(pre[i],  pre[j]);
            double dPost = dist(post[i], post[j]);
            assert(fabs(dPre - dPost) < 1e-3,
                "non-rigid rotation: |v" ~ topVerts[i].to!string ~ "v" ~
                topVerts[j].to!string ~ "| changed " ~
                dPre.to!string ~ " → " ~ dPost.to!string);
        }
    }
}
