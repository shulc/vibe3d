// THE FIRST RECORD COVERAGE OF `mesh.arrayTool`'s gesture (task 2900).
//
// The tool was not uncovered — `tests/test_tool_overlay_item_space.d` block 5
// drives this exact haul on two item-space stands and asserts the offset DELTA
// against the layer-to-world linear inverse, with its own anti-vacuity. That
// block is SOUND FOR THE LAW IT MEASURES and is deliberately left alone: it is
// a conversion test, and bolting a record assertion onto a body that runs twice
// on two different stands would blur what it means. What no file had was the
// other half — that the gesture BUILDS and RECORDS. `offX/offY/offZ` are tool
// attributes; the motion handler moves them whether or not `arrayFaces` ever
// copied a face, so an ArrayTool that built nothing left every shipped
// assertion about it green.
//
// `tests/test_fixture_array.d` does not close that either: it drives
// `tool.doApply`, which records a `ToolDoApplyCommand` — a different entry from
// a different site than `ArrayTool.commitEdit`.
//
// WHERE IT RECORDS. Like CloneTool and unlike Mirror / Radial Sweep, ArrayTool
// commits INSIDE the gesture, at `onMouseButtonUp`. So the entry is on the
// stack before the tool is dropped, and the drop must add NOTHING — asserted
// below, because `deactivate()`'s `if (active && built) commitEdit()` would
// otherwise push a duplicate for one gesture.
//
// `built` IS NOT ON THE WIRE HERE, measured rather than assumed: it is
// published for exactly six tools tree-wide (`grep -rn '"built"' source/`) and
// `/api/tool/state` answers `{}` for `mesh.arrayTool`. A GROWN VERTEX COUNT
// stands in and is strictly stronger — `built = (n != 0)` is the tool's own
// claim about its kernel's return, the count is that claim read off the mesh.
// The bound is `> 8` in a NAMED DIRECTION rather than an exact number because
// the copy count follows the `count` parameter; on this stand it measured 20
// (the cube's 8 plus three 4-corner copies of face 4).
//
// EVERY CHANNEL HERE FAILS CLOSED, so this file needs no positive control:
// every assertion is "something MOVED", and a stale `/api/mesh/planes`, a
// frozen `/api/model` or an `/api/history` that stopped tracking each leave
// their assertion RED rather than green.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import plane_diff_helpers;
import drag_helpers;

void main() {}

alias BASE = testBaseUrl;
enum string TOOL = "mesh.arrayTool";

string getRaw(string path) { return cast(string) get(BASE ~ path); }


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double attrOf(string name) {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " " ~ name ~ " ?");
    assert(r["status"].str == "ok", "query " ~ name ~ " failed: " ~ r.toString);
    return r["value"].floating;
}

/// The PLANE-COMPLETE readback. `/api/model` is not a substitute: it carries no
/// marks, no set masks and no per-face material/part.
string planes() { return getRaw("/api/mesh/planes"); }
long undoLen() { return cast(long) getJson("/api/history")["undo"].array.length; }
size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }

unittest { // a free centre haul arrays face 4 and records exactly one entry
    // NO PRE-DISARM, DELIBERATELY (task 3130). `/api/reset` cancels and DROPS the
    // active tool BEFORE it replaces the geometry, so a gesture left standing by
    // an earlier stand — or by an earlier RED run of this one — cannot commit
    // into the scene this stand is about to read. The explicit
    // `tool.set <tool> off` that used to stand here (task 2900) was a workaround
    // for the opposite order. Removing it is not tidying: it makes this stand a
    // WITNESS for that guarantee instead of a file that hides its loss.
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);

    r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
    cmd("history.clear");

    // The framing is PART OF THE GESTURE: the haul is a free screen-plane drag
    // converted through the drag space, so how far the copies travel depends on
    // the camera. Pinned, never inherited.
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
    // `offX/offY/offZ` default to (1,1,1), a layer-space baseline the drag
    // never touches, so the branch check below is on the DELTA.
    immutable double preOffX = attrOf("offX");

    // No handle: the haul is anchored wherever the press lands and feeds
    // `planeDragDelta`, so the press is the viewport centre by construction —
    // the same drive `tests/test_tool_overlay_item_space.d` block 5 uses.
    auto cam = fetchCamera(BASE);
    immutable int cx = cam.vpX + cam.width / 2;
    immutable int cy = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy, cx + 70, cy - 40, 12), BASE);
    Thread.sleep(dur!"msecs"(200));

    // The branch check, kept from the shipped coverage's shape: a press that
    // engaged nothing leaves the offset baseline exactly where it stood.
    immutable double dOffX = attrOf("offX") - preOffX;
    assert(abs(dOffX) > 1e-3,
        "the centre haul left offX at its (1,1,1) baseline — the press engaged "
        ~ "no drag space, so nothing downstream of it ran. Got a delta of "
        ~ dOffX.to!string);

    // Half one: the kernel emitted geometry. This stands in for `built`, which
    // this tool does not publish, and it is the check no shipped file made.
    immutable size_t v1 = vertexCount();
    assert(v1 > v0,
        "the haul left " ~ v1.to!string ~ " vertices, expected MORE than the "
        ~ "cube's " ~ v0.to!string ~ " (20 on this stand: 8 plus three "
        ~ "4-corner copies of face 4) while offX moved by "
        ~ dOffX.to!string ~ ". `rebuildPreview` sets `built` from its kernel's "
        ~ "return and the mouse-up commits only when built, so no growth means "
        ~ "the grid copied nothing — and the offset attribute reads exactly the "
        ~ "same in that state");

    // Half two: a PLANE actually moved.
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        "the haul moved planes " ~ moved.to!string ~ " — `vertices` and "
        ~ "`counts` are not both among them, so the mesh is byte-identical to "
        ~ "the cube it started as");

    // Half three: the record went on the stack AT THE MOUSE-UP.
    immutable long afterHaul = undoLen() - u0;
    assert(afterHaul == 1,
        "the haul recorded " ~ afterHaul.to!string ~ " undo entr(ies), expected "
        ~ "exactly 1 (`mesh.array_edit`, label \"Array\") — ArrayTool records at "
        ~ "`onMouseButtonUp`, so 0 here means the gesture left nothing undoable");

    // And the drop adds NOTHING.
    cmd("tool.set " ~ TOOL ~ " off");
    Thread.sleep(dur!"msecs"(300));
    immutable long afterDrop = undoLen() - u0;
    assert(afterDrop == 1,
        "dropping the tool took the gesture's undo delta from "
        ~ afterHaul.to!string ~ " to " ~ afterDrop.to!string ~ " — one gesture "
        ~ "must leave exactly one entry, and a second one here means the "
        ~ "mouse-up commit and the deactivate commit both fired");

    // The undo takes the copies back off, which is what makes the entry above a
    // real edit record rather than a bookmark.
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    Thread.sleep(dur!"msecs"(150));
    assert(vertexCount() == v0,
        "after one undo the mesh has " ~ vertexCount().to!string ~ " vertices, "
        ~ "expected the pre-gesture " ~ v0.to!string ~ " — the recorded entry "
        ~ "does not invert the array it claims to own");
}
