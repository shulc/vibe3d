// The topology pen over a background sphere under each constraint geometry
// (task 9477, capture K-C4 of task 9474; the numbers below are its cells).
// Laws: the constraint is a pass AFTER the pen's own placement —
//   * Screen re-casts the pen's already-offset point along the view onto the
//     surface and offsets it AGAIN (the double offset; cells scr, scr2);
//   * Point leaves a click at the pen's single offset (cell pt_off, the
//     control that must not move);
//   * a Ctrl+LMB vertex slide follows the surface only through that pass:
//     geometry Point lands on the sphere (h0d), geometry off moves the vertex
//     along the world axis alone (h0d_g0).
// Rig: sphere 64x32, r 1, centre (0,1,0) on a background layer; top ortho,
// focus (0.07,1,0), 439.52 px/m. Our click casts the pixel ray, the capture's
// the ray through the q-snapped plane point (2.9e-3 apart in xz, open K-C4
// PLAN-FINDING 1), so a Screen cell's tolerance is set by the candidates'
// separation, never by our own reading.

import drag_helpers : Vec3, buildDragLog, fetchCamera, playAndWait;
import pen_rig_helpers : clickPixels, penCameraAt, penCommand, penSceneEmpty, readVerts,
    worldPixel;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.format : format;
import std.math : abs, round, sqrt;

void main() {}

private enum double kPpm = 439.52;
private enum uint kLCtrl = 0x0040;
private immutable Vec3 kCentre = Vec3(0, 1, 0);

/// Background sphere in layer 0, an Edit layer on top (optionally holding the
/// capture's quad), the camera, the topology pen (mode point for a click, move
/// for a slide, as in the capture), then the constraint values.
private void rig(string geometry, double offset, bool quad = false) {
    penSceneEmpty("Top");
    penCommand("prim.sphere cenX:0 cenY:1 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 sides:64 segments:32");
    penCommand("layer.add name:Edit");
    if (quad) {
        auto r = postJson("/api/command", commandBody("scene.loadMesh",
            `{"vertices":[[0.3,1.948683,0.1],[0.3,1.905539,0.3],[0.1,1.948683,0.3],`
            ~ `[0.1,1.989949,0.1]],"faces":[[0,1,2,3]]}`));
        assert(r["status"].str == "ok", "rig: quad load failed: " ~ r.toString);
        penCommand("viewport.view Top");   // the load leaves the view perspective
    }
    penCameraAt(Vec3(0.07f, 1, 0), kPpm);
    assert(getJson("/api/camera")["projKind"].str == "Ortho", "rig premise: the top view is orthographic");
    penCommand("tool.set mesh.topoPen on");
    penCommand("tool.attr mesh.topoPen mode " ~ (quad ? "move" : "point"));
    penCommand("tool.pipe.attr constrain enabled true");
    penCommand("tool.pipe.attr constrain handle false");
    penCommand("tool.pipe.attr constrain geometry " ~ geometry);
    penCommand(format("tool.pipe.attr constrain offset %.9f", offset));
}

private double dxz(Vec3 a, double[3] b) {
    return sqrt((a.x - b[0]) ^^ 2 + (a.z - b[2]) ^^ 2);
}

private double sphereDist(Vec3 p) {
    const d = p - kCentre;
    return sqrt(cast(double)(d.x * d.x + d.y * d.y + d.z * d.z)) - 1.0;
}

/// One click at the capture's plane point; the one placed vertex.
private Vec3 clickCell(string cell, string geometry, double offset, double[3] planeHit) {
    rig(geometry, offset);
    clickPixels(worldPixel(Vec3(cast(float)planeHit[0], 1, cast(float)planeHit[2])));
    auto vs = readVerts();
    assert(vs.length == 1, format("%s: one click places one vertex; got %s", cell, vs.length));
    return vs[0];
}

private void clickWitness(string cell, string geometry, double offset, double[3] planeHit,
                          double[3] measured, double[3] rival, double tol) {
    // The rival candidate must be farther than 2 tol from the capture, or the
    // cell cannot choose between them.
    assert(dxz(Vec3(cast(float)rival[0], 0, cast(float)rival[2]), measured) > 2 * tol,
           cell ~ ": rig premise, the rival candidate is within 2 tol of the capture");
    const p = clickCell(cell, geometry, offset, planeHit);
    assert(dxz(p, measured) <= tol && abs(p.y - measured[1]) <= 5e-3,
           format("%s: placed (%.6f, %.6f, %.6f), captured (%(%.6f, %)) — xz %.6f, tol %g "
                  ~ "(rival candidate (%(%.6f, %)) at xz %.6f)", cell, p.x, p.y, p.z,
                  measured[], dxz(p, measured), tol, rival[], dxz(p, rival)));
}

unittest { // pt_off — Point, offset 0.1: ONE offset (control: stays as it was;
           // rival = the raw hit)
    clickWitness("pt_off", "point", 0.1, [0.3020675, 1, 0.19794],
                 [0.331134, 2.023368, 0.220255], [0.3020675, 1.930664, 0.19794], 0.01);
}

unittest { // scr — Screen, offset 0.1: the re-cast offset point offset again
           // (rival = the single offset)
    clickWitness("scr", "screen", 0.1, [0.3020675, 1, 0.19794],
                 [0.364253, 2.007031, 0.241801], [0.3289263, 2.0259329, 0.2173373], 0.01);
}

unittest { // scr2 — Screen, offset 0.2: double, not single
    clickWitness("scr2", "screen", 0.2, [0.3521213, 1, -0.1296848],
                 [0.502074, 2.071383, -0.186527], [0.4135059, 2.1153468, -0.1527227], 0.015);
}

/// A Ctrl+LMB slide of the quad's vertex u0 by +0.18 m along screen x; the
/// slid vertex, after asserting the other three stayed put.
private Vec3 slideCell(string cell, string geometry) {
    rig(geometry, 0, true);
    auto before = readVerts();
    assert(before.length == 4, format("%s: rig quad has 4 vertices; got %s", cell, before.length));
    const p = worldPixel(before[0]);
    const cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, p[0], p[1],
                             p[0] + cast(int)round(0.18 * kPpm), p[1], 20, kLCtrl, 1));
    auto after = readVerts();
    assert(after.length == 4, format("%s: the slide keeps 4 vertices; got %s", cell, after.length));
    foreach (i; 1 .. 4)
        assert(after[i] == before[i], format("%s: vertex %s moved (%s -> %s)", cell, i, before[i], after[i]));
    return after[0];
}

unittest { // h0d — geometry Point: the slid vertex lands on the sphere
    const v = slideCell("h0d", "point");
    assert(abs(sphereDist(v)) <= 4e-3 && dxz(v, [0.448337, 1.886422, 0.093297]) <= 5e-3,
           format("h0d: slid vertex (%.6f, %.6f, %.6f) — sphere distance %.6f, xz from the capture "
                  ~ "%.6f", v.x, v.y, v.z, sphereDist(v), dxz(v, [0.448337, 1.886422, 0.093297])));
}

unittest { // h0d_g0 — geometry off: a raw world-X move, off the surface
    const v = slideCell("h0d_g0", "off");
    assert(abs(v.y - 1.948683f) <= 1e-5 && abs(v.z - 0.1f) <= 1e-5 && abs(v.x - 0.48) <= 3e-3
           && sphereDist(v) > 0.05,
           format("h0d_g0: slid vertex (%.6f, %.6f, %.6f), expected (0.48, 1.948683, 0.1) "
                  ~ "(x tol 3e-3), sphere distance %.6f (captured 0.0685)", v.x, v.y, v.z,
                  sphereDist(v)));
}
