// Interactive drag coverage for the Radial Array tool's Offset handle.
//
// tests/test_fixture_radial_array.d and tests/test_mesh_radial_array.d drive
// this tool through parameters only; nothing in the suite had ever entered its
// MOTION path, which is where the per-event pixel increment lives. That
// increment now takes its previous pixel from the cooked gesture and
// cross-checks it against the tool's own, so it needs a test that reaches it.
//
// A press that misses both handles is not ignored here — it REPOSITIONS the
// rotation centre — but it does not touch `offset`, so `offset` moving off
// zero is evidence that the press hit the offset arrow and the increment ran.
//
// The press point is reconstructed from the arrow's own geometry rather than
// read off /api/tool/handles: with the default Y axis and a centre at the
// origin, the shaft runs from centre + Y*(arm/6) to centre + Y*arm. (The tool
// does now override toolHandlesJson — task 0660 — so the registry is readable
// here too; this test's independent reconstruction is left as it was, since it
// is what makes a geometry change fail loudly instead of silently following.)
//
// WHAT THIS FILE WAS MISSING (task 2900). The drive is REAL — measured on this
// stand, the drag previews on the DOCUMENT mesh (8 -> 100 vertices while the
// button is down) and the drop pushes one `mesh.radial_array_edit` labelled
// "Radial Array". The defect was the ASSERTION: `offset` is a gizmo attribute
// the motion handler moves whether or not `arrayFacesRadial` copied one face,
// so a RadialArrayTool that built nothing left this file green.
//
// Its sibling `tests/test_radial_array_center_space.d` DOES assert geometry (12
// vertices after an off-handle click), so this tool's PREVIEW had a witness —
// but neither file touched `/api/undo` or `/api/history`, so the RECORD had
// none, and the record is where the gesture becomes undoable work.
//
// `built` IS NOT ON THE WIRE HERE, measured rather than assumed: it is
// published for exactly six tools tree-wide (`grep -rn '"built"' source/`) and
// `/api/tool/state` answers `{}` for `mesh.radialArrayTool`. A GROWN VERTEX
// COUNT stands in and is strictly stronger — `built` is the tool's claim about
// its kernel's return, the count is that claim read off the mesh. The bound is
// `> 8` rather than an exact number because the copy count follows the radial
// count parameter and the offset follows the drag, which follows the viewport.

import std.algorithm : canFind, sort;
import std.conv : to;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.radialArrayTool";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

// --- the acceptance witness -------------------------------------------------
//
// EVERY CHANNEL BELOW FAILS CLOSED: each new assertion is "something MOVED", so
// a stale `/api/mesh/planes`, a frozen `/api/model` or an `/api/history` that
// stopped tracking go RED rather than silently green. No positive control is
// needed for that kind, and adding one would be a seventh check that cannot
// come out differently.

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

double queryOffset() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " offset ?");
    assert(r["status"].str == "ok", "query offset failed: " ~ r.toString);
    return r["value"].floating;
}

unittest { // dragging the offset arrow moves `offset` off zero
    // NO PRE-DISARM, DELIBERATELY (task 3130). `/api/reset` cancels and DROPS the
    // active tool BEFORE it replaces the geometry, so a gesture left standing by
    // an earlier stand — or by an earlier RED run of this one — cannot commit
    // into the scene this stand is about to read. The explicit
    // `tool.set <tool> off` that used to stand here (task 2900) was a workaround
    // for the opposite order. Removing it is not tidying: it makes this stand a
    // WITNESS for that guarantee instead of a file that hides its loss.
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    r = postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    // Settle so a draw() frame has registered the handles the press
    // hit-tests against. 0.6*arm lands mid-shaft.
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));

    // Read the three channels BEFORE the gesture rather than assuming them.
    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 anchor = Vec3(0.0f, 0.0f, 0.0f);
    Vec3 axis   = Vec3(0.0f, 1.0f, 0.0f);
    float arm   = gizmoSize(anchor, vp);
    Vec3 press  = anchor + axis * (arm * 0.6f);

    float ax, ay, tx, ty, px, py;
    assert(projectToWindow(anchor, vp, ax, ay), "anchor projects behind camera");
    assert(projectToWindow(anchor + axis, vp, tx, ty),
        "centre + Y projects behind camera");
    assert(projectToWindow(press, vp, px, py), "shaft mid-point is off-camera");
    double dx = tx - ax, dy = ty - ay;
    double len = (dx * dx + dy * dy) ^^ 0.5;
    assert(len > 1e-6, "the offset axis projects to a point");

    int x0 = cast(int) px, y0 = cast(int) py;
    int x1 = cast(int)(px + dx / len * 80.0);
    int y1 = cast(int)(py + dy / len * 80.0);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 16), BASE);
    Thread.sleep(dur!"msecs"(120));

    double after = queryOffset();
    assert(abs(after) > 1e-3,
        "dragging the offset arrow should have moved offset off zero — a "
        ~ "press that missed the handles only repositions the centre and "
        ~ "leaves offset alone. Got " ~ after.to!string);

    // The drop is where RadialArrayTool records (`commitEdit` from
    // `deactivate()`); the preview it commits is already on the document mesh.
    cmd("tool.set " ~ TOOL ~ " off");
    Thread.sleep(dur!"msecs"(300));

    // THE CHECKS THIS FILE DID NOT HAVE, half one: the kernel emitted geometry.
    // This stands in for `built`, which this tool does not publish.
    immutable size_t v1 = vertexCount();
    assert(v1 > v0,
        "the drop left " ~ v1.to!string ~ " vertices (started at "
      ~ v0.to!string ~ ") while offset reads " ~ after.to!string
      ~ ". `rebuildPreview` sets `built` from its kernel's return and "
      ~ "`deactivate()` commits only when built, so no growth means the tool "
      ~ "copied nothing — and the offset attribute above reads exactly the "
      ~ "same in that state, which is where this test used to stop looking");

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
      ~ "exactly 1 (`mesh.radial_array_edit`, label \"Radial Array\") — 0 means "
      ~ "the gesture left nothing undoable behind it");
}
