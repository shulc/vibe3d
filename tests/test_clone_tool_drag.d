// THE FIRST INTERACTIVE COVERAGE OF `mesh.clone` (task 2900).
//
// Before this file, `tool.set mesh.clone` did not appear in one test in the
// tree. `tests/test_mesh_clone.d`, `tests/test_l6_undo_depth.d` and
// `tests/test_hide_geometry_ops.d` all drive the ONE-SHOT COMMAND of the same
// name, which is a different record site: a `Command` fired through the command
// funnel, not `CloneTool.commitEdit` reached from `onMouseButtonUp`. A tool
// whose gesture path stopped building would have left every one of those green.
//
// WHAT THIS TOOL IS. CloneTool places ONE offset copy of the selected faces at
// the drag delta, non-cumulatively: every frame recomputes off the pristine
// `before` snapshot, and `weld = 0` is pinned so the copy never merges into its
// original. A zero delta takes an early exit that leaves `built` false, which
// is why the haul below is a real 70x40 px move and not a click.
//
// WHERE IT RECORDS, and why that changes the shape of this file. Unlike Mirror
// and Radial Sweep — which commit from `deactivate()` — CloneTool records
// INSIDE the gesture, at `onMouseButtonUp`. So the undo entry and the whole
// geometry delta are already there before the tool is dropped, and this file
// asserts them at that point. Dropping the tool afterwards must add NOTHING,
// and that is asserted too: `deactivate()`'s `if (active && built) commitEdit()`
// would otherwise push a second, duplicate entry for one gesture.
//
// `built` IS NOT ON THE WIRE HERE, measured rather than assumed: `/api/tool/
// state` publishes it for exactly six tools tree-wide (poly_bevel, edge_bevel,
// edge_extend, edge_extrude, edge_slice, loop_slice — `grep -rn '"built"'
// source/`) and answers `{}` for `mesh.clone`. A NAMED VERTEX COUNT stands in
// and is strictly stronger: `built = (n != 0)` is the tool's own claim about
// `arrayFaces`' return, and 12 is that claim's consequence read off the mesh —
// the cube's 8 plus one 4-corner copy of face 4, with no weld.
//
// EVERY CHANNEL HERE FAILS CLOSED, so this file needs no positive control:
// every assertion is "something MOVED", and a `/api/mesh/planes` serving a
// stale copy, an `/api/model` that froze or an `/api/history` that stopped
// tracking each leave their assertion RED. (The frozen fixtures in
// `tests/test_tool_gesture_g*.d` assert "EQUAL" and "EMPTY", which a dead
// channel satisfies for free — that is why THEY open with a control.)

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.json;
import std.net.curl : get, post;

import plane_diff_helpers;
import drag_helpers;

void main() {}

alias BASE = testBaseUrl;
enum string TOOL = "mesh.clone";

string getRaw(string path) { return cast(string) get(BASE ~ path); }


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

unittest { // a free centre haul clones face 4 and records exactly one entry
    // NO PRE-DISARM, DELIBERATELY (task 3130). `/api/reset` cancels and DROPS the
    // active tool BEFORE it replaces the geometry, so a gesture left standing by
    // an earlier stand — or by an earlier RED run of this one — cannot commit
    // into the scene this stand is about to read. The explicit
    // `tool.set <tool> off` that used to stand here (task 2900) was a workaround
    // for the opposite order. Removing it is not tidying: it makes this stand a
    // WITNESS for that guarantee instead of a file that hides its loss.
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);

    // CloneTool is gated to Polygons mode and builds its mask from the
    // RESTORED face selection, so the operand has to be a face selection.
    r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
    cmd("history.clear");

    // The framing is PART OF THE GESTURE: the haul is a free screen-plane drag
    // measured from the press pixel and converted through the drag space, so
    // how far the copy travels depends on the camera. Pinned, never inherited.
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(300));

    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();
    assert(v0 == 8,
        "the stand is not the 8-vertex cube this test's counts are named "
        ~ "against — got " ~ v0.to!string ~ " vertices after /api/reset");

    // No handle at all: the haul is anchored wherever the press lands and
    // feeds `planeDragDelta`, so the press is the viewport centre by
    // construction. 70x40 px, because a ZERO delta takes `rebuildPreview`'s
    // early exit, leaves `built` false and records nothing.
    auto cam = fetchCamera(BASE);
    immutable int cx = cam.vpX + cam.width / 2;
    immutable int cy = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy, cx + 70, cy - 40, 12), BASE);
    Thread.sleep(dur!"msecs"(200));

    // Half one: the kernel emitted geometry. This stands in for `built`.
    immutable size_t v1 = vertexCount();
    assert(v1 == 12,
        "the haul left " ~ v1.to!string ~ " vertices, expected 12 (the cube's 8 "
        ~ "plus one 4-corner copy of face 4). Zero growth means "
        ~ "`rebuildPreview` took its zero-delta or empty-mask early exit, "
        ~ "`built` stayed false and the mouse-up recorded nothing — a state no "
        ~ "tool attribute on this tool can tell apart from a real clone");

    // Half two: a PLANE actually moved.
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        "the haul moved planes " ~ moved.to!string ~ " — `vertices` and "
        ~ "`counts` are not both among them, so the mesh is byte-identical to "
        ~ "the cube it started as");

    // Half three: the record went on the stack AT THE MOUSE-UP, not at the
    // drop. CloneTool commits from `onMouseButtonUp`, so this reads 1 while
    // the tool is still armed.
    immutable long afterHaul = undoLen() - u0;
    assert(afterHaul == 1,
        "the haul recorded " ~ afterHaul.to!string ~ " undo entr(ies), expected "
        ~ "exactly 1 (`mesh.clone_edit`, label \"Clone\") — CloneTool records at "
        ~ "`onMouseButtonUp`, so 0 here means the gesture left nothing undoable");

    // And the drop adds NOTHING. `deactivate()`'s
    // `if (active && built) commitEdit()` would push a second entry for one
    // gesture; this is the assertion that would catch it.
    cmd("tool.set " ~ TOOL ~ " off");
    Thread.sleep(dur!"msecs"(300));
    immutable long afterDrop = undoLen() - u0;
    assert(afterDrop == 1,
        "dropping the tool took the gesture's undo delta from "
        ~ afterHaul.to!string ~ " to " ~ afterDrop.to!string ~ " — one gesture "
        ~ "must leave exactly one entry, and a second one here means the "
        ~ "mouse-up commit and the deactivate commit both fired");

    // The undo takes the clone back off, which is what makes the entry above a
    // real edit record rather than a bookmark.
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    Thread.sleep(dur!"msecs"(150));
    assert(vertexCount() == v0,
        "after one undo the mesh has " ~ vertexCount().to!string ~ " vertices, "
        ~ "expected the pre-gesture " ~ v0.to!string ~ " — the recorded entry "
        ~ "does not invert the clone it claims to own");
}
