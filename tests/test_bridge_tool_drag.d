// Interactive drag coverage for the Bridge tool — the FIRST it has ever had.
//
// WHY THIS FILE EXISTS (task 2690). Three files in `tests/` carry the word
// bridge — `test_bridge.d`, `test_fixture_bridge.d`,
// `test_fixture_bridge_open_rows.d` — and all three drive the ONE-SHOT COMMAND
// `mesh.bridge`. `tool.set mesh.bridgeTool` followed by an event replay appears
// nowhere in the suite. So `BridgeTool` — its mouse handlers, its per-event
// segment increment, and `commitBridgeEdit` firing out of `deactivate()` — had
// no interactive witness at all: an override landing on any of them would have
// sat there with the command tests still green.
//
// THE STAND. Two coaxial unit squares (the operand `test_bridge.d` calls
// `loadCaps`), both selected. The tool draws NO handle — `/api/tool/handles`
// answers `{"handles":null}` for it — so the gesture is a bare horizontal LMB
// drag anywhere in the viewport, read at 20 px per segment.
//
// WHAT IT ASSERTS, and why not an attribute. The acceptance criterion for an
// interactive test in this family is that the tool BUILT and that a PLANE
// ACTUALLY MOVED; an attribute value proves only that a drag began, which is
// how three shipped drag tests in this tree stayed green over gestures that
// built nothing. `built` IS NOT AVAILABLE HERE, and that is measured rather
// than assumed: `/api/tool/state` publishes it for exactly six tools tree-wide
// (edge_extend, edge_extrude, edge_bevel, poly_bevel, edge_slice, loop_slice —
// `grep -rn '"built"' source/`), and `mesh.bridgeTool` is not one of them. What
// stands in for it is the tool's own pair of engagement claims, `valid` and
// `engaged` — `commitBridgeEdit` runs out of `deactivate()` and stays SILENT
// when either is false — backed by the plane and the count read after the drop.
//
// ONE MEASURED PROPERTY SHAPES THE ORDER OF THE READS: this tool builds NO
// LIVE PREVIEW. Measured on this stand, a full 60 px drag moves ZERO planes
// while it is under way; every plane moves at the DROP. So the plane comparison
// below brackets the gesture AND the drop, never the gesture alone — bracketing
// the gesture alone would go red on entirely correct code.

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
enum string TOOL = "mesh.bridgeTool";

/// Two coaxial unit squares — the bridge operand.
enum string kTwoCaps = `{
    "vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0],[0,0,1],[1,0,1],[1,1,1],[0,1,1]],
    "faces":[[0,1,2,3],[4,5,6,7]]
}`;

string getRaw(string path) { return cast(string) get(BASE ~ path); }


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

// --- the acceptance witness -------------------------------------------------
//
// EVERY CHANNEL BELOW FAILS CLOSED, which is why this file needs no separate
// positive control: each assertion is "something MOVED", so a `/api/mesh/planes`
// serving a stale copy leaves `moved` empty and goes RED, and an `/api/history`
// that stopped tracking leaves the delta at 0 and goes RED. (The frozen fixtures
// in tests/test_tool_gesture_g*.d assert "EQUAL" and "EMPTY", which a dead
// channel satisfies for free — that is why THEY open with a control.)

/// The PLANE-COMPLETE readback. `/api/model` is not a substitute: it carries no
/// marks, no set masks and no per-face material/part.
string planes() { return getRaw("/api/mesh/planes"); }
long undoLen() { return cast(long) getJson("/api/history")["undo"].array.length; }
size_t faceCount() { return getJson("/api/model")["faces"].array.length; }

unittest { // a bare horizontal haul bridges the two caps, and the drop records it
    import core.thread : Thread;
    import core.time   : dur;

    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset(empty) failed: " ~ r.toString);

    r = postJson("/api/command", commandBody("scene.loadMesh", kTwoCaps));
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);

    // `/api/load-mesh` RESETS THE CAMERA, so the framing is set AFTER the load,
    // never before.
    r = postJson("/api/camera",
        `{"azimuth":0.6,"elevation":0.5,"distance":5.0,`
        ~ `"focus":{"x":0.5,"y":0.5,"z":0.5}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);

    r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0,1]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("history.clear");
    cmd("tool.set " ~ TOOL ~ " on");
    Thread.sleep(dur!"msecs"(250));

    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t f0           = faceCount();

    auto st0 = getJson("/api/tool/state");
    assert(st0["engaged"].type == JSONType.false_,
        "the tool reports itself ENGAGED before any button went down: "
        ~ st0.toString ~ ". `engaged` would then say nothing about the haul, "
        ~ "and the check below would be satisfied by a gesture that never ran");
    immutable long seg0 = st0["segments"].integer;

    // The whole gesture: 60 px horizontal, read at 20 px per segment.
    auto cam = fetchCamera(BASE);
    immutable int cx = cam.vpX + cam.width  / 2;
    immutable int cy = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy, cx + 60, cy, 12), BASE);
    Thread.sleep(dur!"msecs"(120));

    // READ, THEN DROP, THEN ASSERT — and that order is load-bearing, not
    // style. An assert raised while this tool is still ON leaves it ENGAGED
    // with its loop cache pointing at this document, and the runner reuses one
    // `vibe3d --test` per worker across tests: the NEXT test's `/api/reset`
    // then deactivates an engaged bridge against a replaced document and the
    // process dies (`core.exception.ArrayIndexError@source/mesh_ops/bridge.d
    // (204): index [0] is out of bounds for array of length 0` — measured,
    // reported as a separate finding). A local red must stay local.
    //
    // The `built` substitute has to be READ before the drop, because the drop
    // is what consumes it: `commitBridgeEdit` fires out of `deactivate()` and
    // returns in silence when either of these is false.
    auto st = getJson("/api/tool/state");

    cmd("tool.set " ~ TOOL ~ " off");
    Thread.sleep(dur!"msecs"(250));

    assert(st["valid"].type == JSONType.true_ && st["engaged"].type == JSONType.true_,
        "the 60 px haul left the tool unengaged or the selection invalid: "
        ~ st.toString ~ ". `deactivate()` will then record nothing, and every "
        ~ "attribute on that object can still hold whatever it likes — which "
        ~ "is exactly how the other drag tests in this family shipped green "
        ~ "over an empty gesture");
    assert(st["segments"].integer > seg0,
        "the haul left `segments` at " ~ st["segments"].integer.to!string
        ~ ", where it already stood before the button went down: the per-event "
        ~ "segment increment never ran");

    // A PLANE actually moved, and the drop recorded it. NOTE THE BRACKET: this
    // tool builds no live preview, so the comparison spans the gesture AND the
    // drop. A comparison that stopped at the drop's near side would read zero
    // moved planes on a perfectly correct bridge.
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        "the haul and its drop moved planes " ~ moved.to!string
        ~ " — `vertices` and `counts` are not both among them, so the mesh is "
        ~ "byte-identical to the two loose caps it started as");
    immutable size_t f1 = faceCount();
    assert(f1 > f0,
        "the bridge added no face (still " ~ f0.to!string ~ ")");
    assert(undoLen() - u0 == 1,
        "the drop recorded " ~ (undoLen() - u0).to!string ~ " undo entr(ies), "
        ~ "expected exactly 1 — `commitBridgeEdit` runs from `deactivate()` "
        ~ "and stays silent unless the haul engaged");
}
