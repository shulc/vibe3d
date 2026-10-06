// The transform tools under the constraint's Screen geometry (capture K-SC2,
// cells T_hi, T_lo, T_g0, R_hi, R_lo): after the transform each moved vertex
// is re-cast along the VIEW LINE through its transformed position to the
// NEAREST background hit in either direction — the shared `constrainPoint`
// rule the topology pen runs (K-SC). The hi rig (overhang 0.48 above the
// moved point, sphere 0.22 below) refutes the first hit from the eye; the lo
// rig (overhang 0.05 above, sphere 0.26 below) refutes a forward-only cast.
// Rig: sphere 64x32, r 1, centre (0,1,0) and the overhang quad on background
// layers, one loose vertex on the Edit layer (vertex mode, nothing selected);
// top ortho, focus (0.07,1,0), 439.52 px/m. The capture's transforms are
// applied numerically through the transform apply: Move TX 0.275 (the
// measured x travel); Rotate -6.891 degrees about the z line through
// (0.7, 1) (both rotate cells fit that angle). VIBE3D_CELL=<name>[,...]
// runs only those blocks.

import drag_helpers : Vec3;
import pen_rig_helpers : penCameraAt, penCommand, penSceneEmpty, readVerts;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.format : format;
import std.algorithm : canFind;
import std.array : split;
import std.math : abs, sqrt;
import std.process : environment;

void main() {}

private bool runs(string cell) {
    const f = environment.get("VIBE3D_CELL", "");
    return f.length == 0 || f.split(",").canFind(cell);
}

private void loadMesh(string json) {
    auto r = postJson("/api/command", commandBody("scene.loadMesh", json));
    assert(r["status"].str == "ok", "rig: mesh load failed: " ~ r.toString);
}

/// The K-SC2 T/R rig with the overhang at height `ovhY`, the vertex at
/// (0.35, `vy`, 0.2), `tool` armed under constraint geometry `geometry`.
private void rig(string tool, string geometry, double ovhY, double vy) {
    penSceneEmpty("Top");
    penCommand("prim.sphere cenX:0 cenY:1 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 sides:64 segments:32");
    penCommand("layer.add name:Over");
    loadMesh(format(`{"vertices":[[1.15,%s,-0.2],[1.15,%s,0.85],[0.15,%s,0.85],[0.15,%s,-0.2]],`
                    ~ `"faces":[[0,1,2,3]]}`, ovhY, ovhY, ovhY, ovhY));
    penCommand("layer.add name:Edit");
    loadMesh(format(`{"vertices":[[0.35,%s,0.2]],"faces":[]}`, vy));
    penCommand("viewport.view Top");   // a load leaves the view perspective
    penCameraAt(Vec3(0.07f, 1, 0), 439.52);
    assert(getJson("/api/camera")["projKind"].str == "Ortho", "rig premise: the top view is orthographic");
    penCommand("select.typeFrom vertex");
    penCommand("tool.pipe.attr constrain enabled true");
    penCommand("tool.pipe.attr constrain handle false");
    penCommand("tool.pipe.attr constrain dblSided true");
    penCommand("tool.pipe.attr constrain geometry " ~ geometry);
    penCommand("tool.pipe.attr constrain offset 0");
    penCommand(`tool.pipe.attr snap types ""`);
    penCommand("tool.set " ~ tool);
}

private Vec3 applied() {
    penCommand("tool.doApply");
    auto vs = readVerts();
    assert(vs.length == 1, format("the rig holds one vertex; got %s", vs.length));
    return vs[0];
}

private Vec3 moveCell(string geometry, double ovhY, double vy) {
    rig("move", geometry, ovhY, vy);
    penCommand("tool.attr move TX 0.275");
    return applied();
}

private Vec3 rotateCell(double ovhY, double vy) {
    rig("rotate", "screen", ovhY, vy);
    penCommand("tool.pipe.attr actionCenter userPlacedX 0.7");
    penCommand("tool.pipe.attr actionCenter userPlacedY 1");
    penCommand("tool.pipe.attr actionCenter userPlacedZ 0");
    penCommand("tool.attr rotate RZ -6.891");
    return applied();
}

private void near(string cell, Vec3 p, double[3] want, double xzTol, double yTol, string rival) {
    const double dxz = sqrt((p.x - want[0]) ^^ 2 + (p.z - want[2]) ^^ 2);
    assert(dxz <= xzTol && abs(p.y - want[1]) <= yTol,
           format("%s: (%.6f, %.6f, %.6f), captured (%(%.6f, %)) — xz %.6f (tol %g), y %.6f (tol %g); "
                  ~ "the rival: %s", cell, p.x, p.y, p.z, want[], dxz, xzTol, abs(p.y - want[1]), yTol,
                  rival));
}

unittest { // T_g0 — the control: geometry off runs no pass, the vertex keeps its height
    if (!runs("T_g0")) return;
    near("T_g0", moveCell("off", 2.06, 2.01), [0.625, 2.01, 0.2], 1e-5, 1e-5, "any re-cast");
}

unittest { // T_hi — overhang 0.48 above, sphere 0.22 below: the sphere
    if (!runs("T_hi")) return;
    near("T_hi", moveCell("screen", 2.45, 1.97), [0.625, 1.751013, 0.2], 1e-5, 5e-3,
         "the first hit from the eye, the overhang (y 2.45)");
}

unittest { // T_lo — overhang 0.05 above, sphere 0.26 below: the overhang
    if (!runs("T_lo")) return;
    near("T_lo", moveCell("screen", 2.06, 2.01), [0.625, 2.06, 0.2], 1e-5, 1e-4,
         "a forward-only cast, the sphere (y 1.75)");
}

unittest { // R_hi / R_lo — Rotate, the same two rigs
    if (!runs("R")) return;
    near("R_hi", rotateCell(2.45, 1.97), [0.46891, 1.857589, 0.20004], 1e-3, 5e-3,
         "the first hit from the eye, the overhang (y 2.45)");
    near("R_lo", rotateCell(2.06, 2.01), [0.47371, 2.06, 0.20004], 1e-3, 1e-4,
         "a forward-only cast, the sphere (y 1.86)");
}
