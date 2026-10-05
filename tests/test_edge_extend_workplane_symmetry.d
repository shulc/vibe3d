// Edge Extend under WORK-PLANE symmetry (task 9452; capture K-D cell D4,
// `edge-extend-symmetry-wp`: fits to 1e-5): the offset is mirrored, not
// refused, and the mirror plane is the symmetry plane mapped by the work
// plane TWICE — normal R²·eₓ through W(W(0)) — like the pen, while Move maps
// it once.
//
// The capture's rig: two quads mirrored about the work plane's local x = 0
// (W: centre (0.2, 0, 0.1), rotY 30), the outer edge of each selected, the
// press right of the plane. Our pixels are not the capture's, so the cell
// pins the LAW against our own right-ridge displacement d: the left ridge
// moves by d reflected about R²·eₓ = (0.5, 0, -0.866). The two candidates it
// rules out — no mirror (left = d) and the once-mapped plane R·eₓ — are
// computed beside it, and the cell first pins that both stand apart.

import edge_extend_gesture_helpers;
import http_client : getJson, postJson;
import drag_helpers : viewportFromCameraMatrices, projectToWindow, DV = Vec3;
import std.format : format;
import std.json;
import std.math : abs, cos, sin, PI;

void main() {}

alias V3 = double[3];
V3 sub(V3 a, V3 b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
double dot(V3 a, V3 b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
V3 reflect(V3 d, V3 n) { immutable k = 2 * dot(d, n); return [d[0] - k * n[0], d[1] - k * n[1], d[2] - k * n[2]]; }
double apart(V3 a, V3 b) {
    double m = 0;
    foreach (k; 0 .. 3) if (abs(a[k] - b[k]) > m) m = abs(a[k] - b[k]);
    return m;
}

enum string kVerts = "[[0.186603,0,-0.123205],[0.386603,0,0.223205],[0.733013,0,0.023205],"
    ~ "[0.533013,0,-0.323205],[0.013397,0,-0.023205],[0.213397,0,0.323205],"
    ~ "[-0.133013,0,0.523205],[-0.333013,0,0.176795]]";

unittest { // D4: both outer edges, work-plane symmetry X, press right of the plane
    auto r = postJson("/api/command", `{"id":"scene.reset"}`);
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmdId("scene.loadMesh", `{"vertices":` ~ kVerts ~ `,"faces":[[0,1,2,3],[4,7,6,5]]}`);
    assert(vertexCount() == 8 && faceCount() == 2, "rig did not load as 8 v / 2 f");
    setSymmetryX(false);
    selectEdges(edgesOf([[2, 3], [6, 7]]));
    cmd("workplane.edit cenX:0.2 cenY:0 cenZ:0.1 rotX:0 rotY:30 rotZ:0");
    cmd("tool.pipe.attr symmetry useWorkplane true");
    setSymmetryX(true);
    cmd("viewport.view Top");
    r = postJson("/api/camera", `{"focus":{"x":0.2,"y":0,"z":0.1},"distance":2.0}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    cmd("tool.set edge.extend on");
    cmd("history.clear");
    settle(250);

    auto vp = viewportFromCameraMatrices();
    float px, py;
    assert(projectToWindow(DV(0.9f, 0.0f, 0.0f), vp, px, py), "rig: press point off camera");
    immutable Px p = Px(cast(int) px, cast(int) py);
    press(p);
    assert(moveOffGizmo() && toolState()["dragBank"].str == "move",
        "rig: the press did not begin an off-handle haul: " ~ toolState().toString);
    Px end;
    increments(p, 10, 5, 2, end);
    release(end);
    assert(undoLen() == 0, format("a haul is a live session step, no history row: %d", undoLen()));

    auto m = model();
    assert(m["vertices"].array.length == 12, format("expected 12 vertices (4 new), got %d", m["vertices"].array.length));
    V3 disp(size_t src) {   // the new vertex nearest the source, minus the source
        immutable V3 s = vtx(m, src);
        double best = double.max;
        V3 d;
        foreach (i; 8 .. 12) {
            immutable V3 q = sub(vtx(m, i), s);
            if (dot(q, q) < best) { best = dot(q, q); d = q; }
        }
        return d;
    }
    immutable Offset o = offset();
    immutable V3 off = [o.x, o.y, o.z];
    immutable V3 d2 = disp(2), d3 = disp(3), d6 = disp(6), d7 = disp(7);
    assert(apart(d2, off) <= 1e-4 && apart(d3, off) <= 1e-4,
        format("the right (press-side) ridge does not take the offset as is: %s %s, offset %s", d2, d3, off));
    immutable double a = 30.0 * PI / 180.0;
    immutable V3 twice = reflect(off, [cos(2 * a), 0, -sin(2 * a)]);
    immutable V3 once = reflect(off, [cos(a), 0, -sin(a)]);
    assert(apart(twice, once) > 0.01 && apart(twice, off) > 0.01,
        format("rig cannot discriminate: twice %s, once %s, none %s", twice, once, off));
    assert(apart(d6, twice) <= 1e-4 && apart(d7, twice) <= 1e-4,
        format("the left ridge is not the offset reflected about R²·eₓ (W twice): %s %s; "
            ~ "twice %s, once %s, unmirrored %s", d6, d7, twice, once, off));
    cmd("tool.set edge.extend off");
}
