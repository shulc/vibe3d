// THE FIRST INTERACTIVE COVERAGE OF `tool.strokeExtrude` (task 2900).
//
// Before this file the suite had never driven this tool at all. Its only named
// test, `tests/test_stroke_extrude.d`, contains ZERO `play-events` — it drives
// the ONE-SHOT COMMAND `mesh.strokeExtrude`, which takes an explicit
// path-point list and records through the command funnel. That is a different
// record site from `StrokeExtrudeTool.commitEdit`.
//
// AND THE MOUSE IS THE ONLY ENTRY TO THIS TOOL'S RECORD SITE. `applyHeadless()`
// returns false unconditionally and faithfully — the tool's own header records
// that the reference exposes no path-point attributes and that arming the tool
// plus a headless apply is a bit-exact no-op there. So `tool.doApply` cannot
// reach `commitEdit` either, and there was no path by which any shipped test
// could have observed this tool building or recording. That is asserted below
// rather than trusted: if `applyHeadless` ever started answering true, the
// gesture would stop being the only door and this file's claim about its own
// necessity would be false.
//
// `built` IS NOT ON THE WIRE HERE, measured rather than assumed: `/api/tool/
// state` answers `{}` for this tool and `/api/tool/handles` answers
// `{"handles":null}` — it draws no gizmo at all, the extruded bands ARE the
// preview. It is published for exactly six tools tree-wide (poly_bevel,
// edge_bevel, edge_extend, edge_extrude, edge_slice, loop_slice —
// `grep -rn '"built"' source/`). GROWN VERTEX AND FACE COUNTS stand in and are
// strictly stronger: `built_ = (n != 0)` is the tool's own claim about
// `extrudeAlongPath`'s return, and the counts are that claim read off the mesh.
//
// WHY THE COUNTS ARE A DIRECTION AND NOT A NUMBER. A span commits every `prec`
// pixels of accumulated screen travel (captured attr, default 30 px), so the
// span count follows the drag length in PIXELS and therefore the viewport.
// Measured on this stand at three lengths: 80 px -> 20 vertices / 18 faces,
// 150 px -> 28 / 26, 260 px -> 36 / 34. Pinning any one of those would pin the
// harness's window size, not the tool.
//
// A MEASURED SURPRISE, recorded and deliberately NOT asserted: a stroke with
// ZERO motion still builds one span (8 -> 12 vertices) and records, because
// `onMouseButtonUp` appends the live tip and `applyPath` accepts a two-point
// path. So "no motion" is NOT this tool's empty gesture. Its real refusal is
// the reference precondition — no polygon selected — and that is the one the
// second block below drives.

import std.algorithm : canFind, sort;
import std.conv : to;
import std.json;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "tool.strokeExtrude";

string getRaw(string path) { return cast(string) get(BASE ~ path); }
JSONValue getJson(string path) { return parseJSON(getRaw(path)); }
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

/// The PLANE-COMPLETE readback. `/api/model` is not a substitute: it carries no
/// marks, no set masks and no per-face material/part.
string planes() { return getRaw("/api/mesh/planes"); }
long undoLen() { return cast(long) getJson("/api/history")["undo"].array.length; }
size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }
size_t faceCount() { return getJson("/api/model")["faces"].array.length; }

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

/// Arm the stand. `select` chooses whether face 4 (the cube's +Y face) is the
/// operand — the tool's own precondition is that at least one polygon is
/// already selected, and a press without one is a plain unconsumed no-op.
///
/// DISARM FIRST, and it is not defensive decoration (task 2900). `/api/reset`
/// does NOT drop the active tool, and `toolHost.activate()` deactivates the
/// outgoing one — which for a session tool means COMMITTING it. A previous
/// test, or a previous RED run of this one, that left a tool armed would
/// otherwise push a stray commit into the freshly reset mesh and shift every
/// count read after it.
void armStand(bool select) {
    cmd("tool.set " ~ TOOL ~ " off");
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    if (select) {
        r = postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
        assert(r["status"].str == "ok", "select failed: " ~ r.toString);
    }
    cmd("history.clear");
    // The framing is PART OF THE GESTURE: each path point is a ray-cast of the
    // cursor onto a camera-facing plane through the previous point, so where
    // the stroke goes in the world depends on the camera. Pinned, never
    // inherited.
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    cmd("tool.set " ~ TOOL ~ " on");
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(300));
}

/// The stroke: straight up the screen from the viewport centre, 150 px over 20
/// motion events. The press pixel does not matter — the path anchors at the
/// selection's average face centroid, not at the cursor.
void stroke() {
    auto cam = fetchCamera(BASE);
    immutable int cx = cam.vpX + cam.width / 2;
    immutable int cy = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy, cx, cy - 150, 20), BASE);
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));
}

/// Drop the tool and let `deactivate()`'s commit land.
void dropTool() {
    cmd("tool.set " ~ TOOL ~ " off");
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(300));
}

unittest { // the stroke builds bands and the drop records exactly one entry
    armStand(true);

    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();
    immutable size_t f0           = faceCount();
    assert(v0 == 8 && f0 == 6,
        "the stand is not the 8-vertex / 6-face cube this test is named "
        ~ "against — got " ~ v0.to!string ~ " / " ~ f0.to!string);

    // THE GESTURE IS THE ONLY DOOR, asserted rather than trusted: this tool's
    // `applyHeadless()` returns false unconditionally, so the command funnel
    // must refuse a headless apply. If this ever answers ok, the claim that no
    // shipped test could have reached the record site stops being true.
    auto ha = postJson("/api/command", "tool.doApply " ~ TOOL);
    assert(ha["status"].str != "ok" && ha["status"].str != "success",
        "`tool.doApply " ~ TOOL ~ "` answered " ~ ha["status"].str
        ~ " — this tool's `applyHeadless()` returns false unconditionally "
        ~ "(faithfully: the reference exposes no path-point attributes), so a "
        ~ "headless apply must be refused. If it now succeeds, the mouse is no "
        ~ "longer the only entry to `commitEdit` and this file's design "
        ~ "premise is stale: " ~ ha.toString);

    stroke();

    // Half one: the kernel emitted geometry, DURING the gesture — this tool
    // previews by mutating the document mesh directly, so the bands are
    // already there before the drop. This stands in for `built`.
    immutable size_t v1 = vertexCount();
    immutable size_t f1 = faceCount();
    assert(v1 > v0 && f1 > f0,
        "the stroke left " ~ v1.to!string ~ " vertices / " ~ f1.to!string
        ~ " faces (started at " ~ v0.to!string ~ " / " ~ f0.to!string
        ~ ", measured 28 / 26 for this 150 px stroke on this stand). "
        ~ "`applyPath` sets `built_` from `extrudeAlongPath`'s return and "
        ~ "`deactivate()` commits only when built, so no growth means the "
        ~ "whole gesture was a no-op — and this tool publishes no attribute, "
        ~ "no handle and no `built` flag that could have said so");

    dropTool();

    // Half two: a PLANE actually moved, and the drop recorded it.
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        "the stroke and its drop moved planes " ~ moved.to!string
        ~ " — `vertices` and `counts` are not both among them, so the mesh is "
        ~ "byte-identical to the cube it started as");
    immutable long undoDelta = undoLen() - u0;
    assert(undoDelta == 1,
        "the drop recorded " ~ undoDelta.to!string ~ " undo entr(ies), expected "
        ~ "exactly 1 (`mesh.strokeExtrude_edit`, label \"Stroke Extrude\") — 0 "
        ~ "means `deactivate()` found nothing built and the gesture left "
        ~ "nothing undoable behind it");

    // The undo takes the bands back off, which is what makes the entry a real
    // edit record rather than a bookmark.
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(150));
    assert(vertexCount() == v0 && faceCount() == f0,
        "after one undo the mesh has " ~ vertexCount().to!string ~ " vertices / "
        ~ faceCount().to!string ~ " faces, expected the pre-gesture "
        ~ v0.to!string ~ " / " ~ f0.to!string ~ " — the recorded entry does not "
        ~ "invert the stroke it claims to own");
}

unittest { // the documented precondition: no polygon selected, no stroke
    // AND ITS POSITIVE CONTROL, IN THE SAME BLOCK, ON THE SAME CHANNELS. The
    // refusal below is an EMPTY plane diff and a ZERO undo delta, and a dead
    // `/api/mesh/planes` or a stopped `/api/history` satisfies both for free.
    // So the identical stroke is replayed afterwards WITH a selection and both
    // channels are required to move. Without that second half this block would
    // be the very defect this task exists to remove.
    armStand(false);

    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();

    stroke();
    dropTool();

    auto moved = planeDiff(planesBefore, planes());
    assert(moved.length == 0,
        "with no polygon selected the stroke moved planes " ~ moved.to!string
        ~ " — `onMouseButtonDown` returns false when `selectedFaceMask()` is "
        ~ "null, so the press must not be consumed and no path may be anchored");
    assert(undoLen() - u0 == 0,
        "with no polygon selected the stroke recorded "
        ~ (undoLen() - u0).to!string ~ " undo entr(ies), expected 0");
    assert(vertexCount() == v0,
        "with no polygon selected the mesh grew to " ~ vertexCount().to!string
        ~ " vertices from " ~ v0.to!string);

    // The control: the SAME stroke, with the operand selected, must move both
    // channels this block just required to stand still.
    armStand(true);
    immutable string ctlBefore = planes();
    immutable long   ctlU0     = undoLen();
    stroke();
    dropTool();
    auto ctlMoved = planeDiff(ctlBefore, planes());
    assert(ctlMoved.canFind("vertices") && ctlMoved.canFind("counts"),
        "positive control: the identical stroke WITH face 4 selected moved "
        ~ "planes " ~ ctlMoved.to!string ~ ", and `vertices`/`counts` are not "
        ~ "both there. The refusal asserted above is then satisfied by a dead "
        ~ "channel rather than by the tool refusing");
    assert(undoLen() - ctlU0 == 1,
        "positive control: the identical stroke WITH face 4 selected recorded "
        ~ (undoLen() - ctlU0).to!string ~ " undo entr(ies), expected 1. A "
        ~ "history that stopped tracking makes the zero above meaningless");
}
