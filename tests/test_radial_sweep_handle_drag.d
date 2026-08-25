// Interactive drag coverage for the Radial Sweep tool's Start Angle handle.
//
// tests/test_fixture_radial_sweep.d drives this tool through parameters only;
// nothing in the suite had ever entered its MOTION path, which is where the
// per-event pixel increment lives. That increment now takes its previous pixel
// from the cooked gesture and cross-checks it against the tool's own, so it
// needs a test that reaches it.
//
// This tool consumes nothing when the press misses every handle, so
// `startAngle` moving off zero is by itself evidence that the press hit and
// the increment branch ran.
//
// Handle geometry, at the defaults (axis +Y, centre at the origin, start angle
// 0): the reference direction is -Z and the arm is 0.7 * gizmoSize, so the
// Start Angle handle sits at (0,0,-arm) and the direction it travels in as the
// angle grows — the live rotational tangent, axis x (pos - centre) — is -X.
// The End Angle handle defaults to 360 degrees, which lands it on the same
// point; the hit test tries Start first, so that is the one this drag grabs.

import std.conv : to;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.radialSweepTool";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

long busCounter(string key) {
    auto j = parseJSON(cast(string) get(BASE ~ "/api/changes"));
    return j[key].integer;
}

double queryStartAngle() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " startAngle ?");
    assert(r["status"].str == "ok", "query startAngle failed: " ~ r.toString);
    return r["value"].floating;
}

unittest { // dragging the Start Angle handle moves `startAngle` off zero
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    r = postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 centre  = Vec3(0.0f, 0.0f, 0.0f);
    float arm    = gizmoSize(centre, vp) * 0.7f;
    Vec3 handle  = Vec3(0.0f, 0.0f, -arm);      // centre + refDir * arm
    Vec3 tangent = Vec3(-1.0f, 0.0f, 0.0f);     // live rotational tangent there

    float hx, hy, tx, ty;
    assert(projectToWindow(handle, vp, hx, hy), "handle projects behind camera");
    assert(projectToWindow(handle + tangent, vp, tx, ty),
        "handle + tangent projects behind camera");
    double dx = tx - hx, dy = ty - hy;
    double len = (dx * dx + dy * dy) ^^ 0.5;
    assert(len > 1e-6, "the handle tangent projects to a point");

    int x0 = cast(int) hx, y0 = cast(int) hy;
    int x1 = cast(int)(hx + dx / len * 80.0);
    int y1 = cast(int)(hy + dy / len * 80.0);
    // TASK 1903 Stage E2, plan §9 — THE PREVIEW PATH MUST STAY UNRECORDED.
    // `rebuildRadialSweepPreview` re-runs `revolveProfileEx` once per drag
    // frame, and since E2 the kernel takes a `ref MeshEditBatch`. The batch it
    // gets is `MeshEditBatch.unrecorded(...)`; a RECORDING one would build and
    // throw away a full op-log at 60 Hz. This 16-step drag is the only place in
    // the suite that enters this tool's motion path, so it is where that gets
    // measured.
    //
    // THE COUNTER IS changeBus.opLogEntriesRecorded, read across the drag —
    // NOT a field on the per-batch tracker (which dies at each close()) and NOT
    // a field on Mesh (which the wholesale `*mesh = …` sites zero) (plan §5.8).
    //
    // M-P: switch `rebuildRadialSweepPreview`'s batch to the recording
    // constructor (`MeshEditBatch(previewMesh, kRevolveEditScope)`) and this
    // reddens with the per-frame entry count.
    immutable long opLogBefore = busCounter("opLogEntriesRecorded");
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 16), BASE);
    Thread.sleep(dur!"msecs"(120));
    immutable long opLogDuringDrag = busCounter("opLogEntriesRecorded") - opLogBefore;

    double after = queryStartAngle();
    assert(abs(after) > 0.5,
        "dragging the Start Angle handle should have moved startAngle off "
        ~ "zero — this tool consumes nothing when the press misses every "
        ~ "handle, so a zero here means the drag never began. Got "
        ~ after.to!string);

    // Asserted AFTER the drag-happened check above, deliberately: a delta of 0
    // measured across a drag that never began is the vacuous green this whole
    // block is built to avoid.
    assert(opLogDuringDrag == 0,
        "the Radial Sweep drag recorded " ~ opLogDuringDrag.to!string
      ~ " op-log entr(ies) across its frames, expected 0. The interactive "
      ~ "preview re-runs `revolveProfileEx` once per frame and must do it "
      ~ "inside an UNRECORDED MeshEditBatch — a recording one builds a full "
      ~ "op-log at 60 Hz for an edit the user has not committed "
      ~ "(task 1903 Stage E2, plan §9).");

    cmd("tool.set " ~ TOOL ~ " off");

    // POSITIVE CONTROL for the counter above, and it is not decoration: a
    // counter that never moves satisfies `== 0` for free. `mesh.delete` is one
    // of the four ops already on the per-mutation tracker (default-on), so it
    // records into an op-log and ticks the same counter.
    auto sel = postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    assert(sel["status"].str == "ok", "control select failed: " ~ sel.toString);
    immutable long ctlBefore = busCounter("opLogEntriesRecorded");
    cmd("mesh.delete");
    immutable long ctl = busCounter("opLogEntriesRecorded") - ctlBefore;
    assert(ctl > 0,
        "positive control: mesh.delete records into an op-log and must tick "
      ~ "changeBus.opLogEntriesRecorded, and it ticked " ~ ctl.to!string
      ~ ". A dead counter passes the drag assertion above for free "
      ~ "(task 1903 §5.8).");
}
