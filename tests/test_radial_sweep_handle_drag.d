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
//
// WHAT THIS FILE WAS MISSING (task 2900). The drive here is REAL — measured on
// this stand, the drop takes the cube from 8 vertices to 108 and pushes one
// `mesh.bevel_edit` labelled "Radial Sweep". Two things were asserted and
// neither could see that: `startAngle`, a gizmo ATTRIBUTE the motion handler
// moves whether or not `revolveProfileEx` ever inserted a vertex, and an
// op-log counter pinned at ZERO, which an empty gesture satisfies for free
// (a drag that rebuilt no preview records no op-log entries either — that half
// has its own positive control below and is sound, but it is not evidence that
// the tool built).
//
// So a RadialSweepTool whose `deactivate()` reached `inserted == 0` — no
// geometry, no `commitSweepEdit`, nothing on the undo stack — left this file
// green. Before task 2900 no shipped test in this repository asserted that any
// tool of this family records anything on a real gesture.
//
// `built` IS NOT ON THE WIRE HERE, measured rather than assumed: it is
// published for exactly six tools tree-wide (`grep -rn '"built"' source/`) and
// `/api/tool/state` answers `{}` for `mesh.radialSweepTool`. A GROWN VERTEX
// COUNT stands in and is strictly stronger — `built` is the tool's claim about
// its kernel's return; the count is that claim read off the mesh. The bound is
// `> 8` rather than an exact number because the revolve's segment count follows
// the swept angle, which follows the drag, which follows the viewport.

import std.algorithm : canFind, sort;
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

// --- the acceptance witness -------------------------------------------------
//
// EVERY CHANNEL BELOW FAILS CLOSED — each assertion is "something MOVED", so a
// stale `/api/mesh/planes`, a frozen `/api/model` or an `/api/history` that
// stopped tracking all go RED rather than green. That is why these three need
// no positive control of their own, while the op-log ZERO further down does
// (and has one).

string getRaw(string path) { return cast(string) get(BASE ~ path); }
JSONValue getJson(string path) { return parseJSON(getRaw(path)); }

/// The PLANE-COMPLETE readback. `/api/model` is not a substitute: it carries no
/// marks, no set masks and no per-face material/part.
string planes() { return getRaw("/api/mesh/planes"); }
long undoLen() { return cast(long) getJson("/api/history")["undo"].array.length; }
size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }

string[] planeDiff(string aText, string bText) {
    auto a = parseJSON(aText);
    auto b = parseJSON(bText);
    bool[string] keys;
    foreach (k, _; a.objectNoRef) keys[k] = true;
    foreach (k, _; b.objectNoRef) keys[k] = true;
    string[] names;
    foreach (k, _; keys) if (k != "provenance") names ~= k;
    names.sort();
    string[] diff;
    foreach (k; names) {
        auto pa = k in a.objectNoRef;
        auto pb = k in b.objectNoRef;
        if (pa is null || pb is null) { diff ~= k; continue; }
        if (pa.toString() != pb.toString()) diff ~= k;
    }
    return diff;
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
    // DISARM FIRST, and it is not defensive decoration (task 2900). `/api/reset`
    // does NOT drop the active tool, and `toolHost.activate()` deactivates the
    // outgoing one — which for a session tool means COMMITTING it. So a
    // previous test (or a previous, RED run of this one) that left a tool armed
    // makes `tool.set ... on` push a stray commit into the freshly reset mesh,
    // and every count read after it is off by that tool's edit. Measured here:
    // a run following a red one started this block at 16 vertices instead of 8.
    cmd("tool.set " ~ TOOL ~ " off");
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    r = postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));

    // The three channels the acceptance criterion names, read BEFORE the
    // gesture rather than assumed: `history.clear` above makes `u0` 0 today,
    // and reading it keeps the delta from degenerating into a comparison
    // against a constant if the stand ever changes.
    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();

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

    // The drop is where RadialSweepTool runs its kernel and records: the whole
    // 8 -> 108 appears here, not during the drag.
    cmd("tool.set " ~ TOOL ~ " off");
    Thread.sleep(dur!"msecs"(300));

    // THE CHECKS THIS FILE DID NOT HAVE, half one: the kernel emitted
    // geometry. This stands in for `built`, which this tool does not publish.
    immutable size_t v1 = vertexCount();
    assert(v1 > v0,
        "the drop left " ~ v1.to!string ~ " vertices (started at "
      ~ v0.to!string ~ ") while startAngle reads " ~ after.to!string
      ~ ". `deactivate()` revolves the captured profile and commits only when "
      ~ "`inserted > 0`, so no growth means the kernel inserted nothing and "
      ~ "the record was never pushed — exactly the state in which the "
      ~ "startAngle assertion above, and the op-log zero, are both still true");

    // ...half two: a PLANE actually moved, and the drop recorded it.
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        "the gesture and its drop moved planes " ~ moved.to!string
      ~ " — `vertices` and `counts` are not both among them, so the mesh is "
      ~ "byte-identical to what it was before the drag. A tool attribute can "
      ~ "hold any value over that");
    immutable long undoDelta = undoLen() - u0;
    assert(undoDelta == 1,
        "the drop recorded " ~ undoDelta.to!string ~ " undo entr(ies), expected "
      ~ "exactly 1 (`mesh.bevel_edit`, label \"Radial Sweep\") — 0 means the "
      ~ "whole gesture was a no-op no attribute on this tool could see");

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
