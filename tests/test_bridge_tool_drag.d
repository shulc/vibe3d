// Registered Bridge gesture witnesses: a click engages its separate preview,
// later drags edit Segments, and explicit release saves one undoable mesh edit.

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

// Task 20261640: use production event replay, never a stand-in Tool callback.
void armCaps(bool select = true) {
    cmd(commandBody("scene.reset", `{"empty":true}`));
    cmd(commandBody("scene.loadMesh", kTwoCaps));
    cmd(commandBody("mesh.select", select
        ? `{"mode":"polygons","indices":[0,1]}`
        : `{"mode":"polygons","indices":[]}`));
    cmd("history.clear");
    cmd("tool.set " ~ TOOL ~ " on");
}

void gesture(int dx = 0, int dy = 0, int steps = 0, uint mod = 0, ubyte btn = 1) {
    auto cam = fetchCamera(BASE);
    auto x = cam.vpX + cam.width / 2;
    auto y = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x + dx, y + dy, steps, mod, btn), BASE);
}

JSONValue parameters(JSONValue state) {
    auto result = JSONValue.emptyObject;
    enum keys = ["segments", "twist", "mode", "tension", "connect", "remove",
            "flip", "orient", "uvs", "autoStep", "steps", "continuous"];
    assert(keys.length == 12, "click parameter population");
    foreach (key; keys)
        result[key] = state[key];
    return result;
}

ulong previewKey() {
    auto key = getJson("/api/viewport/display")["cells"].array[0]["toolPreviewKey"];
    return key.type == JSONType.uinteger ? key.uinteger : cast(ulong) key.integer;
}

unittest { // Default click is a live Bridge, then explicit release saves it.
    armCaps();
    scope(exit) cmd("tool.set " ~ TOOL ~ " off");
    auto before = planes();
    auto armed = getJson("/api/tool/state");
    auto preview = previewKey();
    auto u0 = undoLen();
    assert(u0 == 0, "click history headroom: measured arm depth " ~ u0.to!string);
    assert(armed["valid"].type == JSONType.true_ &&
        armed["engaged"].type == JSONType.false_, "click starts valid and unengaged");
    assert(armed["segments"].integer == 1 && preview > 0,
        "default click has one requested segment and an uploaded preview");

    gesture(); // down/up only: no motion and no property write can engage it.
    auto clicked = getJson("/api/tool/state");
    assert(clicked["tool"].str == TOOL, "click keeps Bridge active");
    assert(parameters(clicked) == parameters(armed), "click preserves every Bridge parameter");
    assert(clicked["effectiveSegments"] == armed["effectiveSegments"] && previewKey() == preview,
        "click preserves the positive standing preview");
    assert(planes() == before && undoLen() == u0, "click leaves source and history unchanged");
    assert(clicked["engaged"].type == JSONType.true_, "ordinary viewport click engages Bridge");

    cmd("tool.release");
    auto after = planes();
    assert(after != before && faceCount() == 4, "default click release saves four bridge faces");
    assert(undoLen() == u0 + 1, "click release records exactly one mesh edit");
    cmd("tool.release");
    assert(planes() == after && undoLen() == u0 + 1, "extra release cannot save click twice");
    cmd("history.undo");
    assert(planes() == before, "click release undo restores exact input planes");
    cmd("history.redo");
    assert(planes() == after, "click release redo restores exact saved planes");
}

unittest { // Later drags edit the same engaged operation; cancel discards it.
    armCaps();
    scope(exit) cmd("tool.set " ~ TOOL ~ " off");
    auto before = planes();
    auto armed = getJson("/api/tool/state");
    auto u0 = undoLen();
    auto preview = previewKey();
    gesture();
    enum deltas = [[0, 40], [19, 0], [0, 0]];
    assert(deltas.length == 3, "non-segment gesture population");
    foreach (delta; deltas) {
        gesture(delta[0], delta[1], 1);
        auto state = getJson("/api/tool/state");
        assert(state["tool"].str == TOOL && state["engaged"].type == JSONType.true_,
            "vertical/sub-step/zero-delta release keeps Bridge engaged");
        assert(parameters(state) == parameters(armed), "non-segment motion preserves parameters");
    }
    gesture(60, 0, 3);
    auto dragged = getJson("/api/tool/state");
    assert(dragged["tool"].str == TOOL && dragged["engaged"].type == JSONType.true_,
        "later horizontal drag keeps the same live Bridge");
    assert(dragged["segments"].integer == armed["segments"].integer + 3 &&
        previewKey() != preview,
        "later horizontal drag edits preview Segments");
    assert(planes() == before && undoLen() == u0, "later drag changes preview only");
    cmd("tool.release");
    auto after = planes();
    assert(after != before && faceCount() == 16 && undoLen() == u0 + 1,
        "click then drag release saves one four-segment Bridge edit");
    cmd("history.undo");
    assert(planes() == before, "click then drag undo restores frozen source");
    cmd("history.redo");
    assert(planes() == after, "click then drag redo restores saved preview");

    armCaps();
    before = planes(); u0 = undoLen();
    gesture();
    playAndWait(`{"t":0,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}`
        ~ "\n" ~ `{"t":50,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":0,"repeat":0}`
        ~ "\n", BASE); // UI navigation, unlike script history.undo, cancels live edits.
    cmd("tool.release");
    assert(planes() == before && undoLen() == u0, "cancel then release discards clicked preview");
}

unittest { // Admission exclusions must not acquire the click engagement bit.
    enum chords = [[0, 3], [512, 1], [1, 1], [64, 1]];
    assert(chords.length == 4, "excluded click population");
    foreach (chord; chords) {
        armCaps();
        gesture(0, 0, 0, cast(uint)chord[0], cast(ubyte)chord[1]);
        auto state = getJson("/api/tool/state");
        cmd("tool.set " ~ TOOL ~ " off"); // Clean up before inspecting exclusions.
        assert(state["engaged"].type == JSONType.false_,
            "RMB/Alt/Shift/Ctrl click cannot engage Bridge");
    }
    armCaps(false);
    gesture();
    auto invalid = getJson("/api/tool/state");
    cmd("tool.set " ~ TOOL ~ " off");
    assert(invalid["valid"].type == JSONType.false_ && invalid["engaged"].type == JSONType.false_,
        "invalid click cannot engage Bridge");
}

unittest { // a bare horizontal haul bridges the two caps, and the drop records it
    import core.thread : Thread;
    import core.time   : dur;

    auto r = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
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
    // document mesh is unchanged during preview, so the comparison spans the gesture AND the
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

unittest { // Every consumed open-row parameter rebuilds the production preview.
    import std.file : readText;
    import std.path : buildPath, dirName;
    import core.thread : Thread;
    import core.time : msecs;
    auto fixture = parseJSON(readText(buildPath(__FILE_FULL_PATH__.dirName,
        "fixtures/bridge_auto_connection/frozen.json")));
    auto input = fixture["cases"].array[0]["input"];
    auto reset = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
    assert(reset["status"].str == "ok", "preview empty reset");
    auto scene = JSONValue.emptyObject;
    scene["vertices"] = input["vertices"]; scene["faces"] = input["faces"];
    auto response = postJson("/api/command", commandBody("scene.loadMesh", scene.toString));
    assert(response["status"].str == "ok", "preview fixture load");
    auto model = getJson("/api/model");
    JSONValue[] indices;
    foreach (pair; input["selection_packet_order"]["edges"].array) {
        bool found;
        foreach (i, e; model["edges"].array) {
            auto a = e.array;
            if ((a[0].integer == pair.array[0].integer && a[1].integer == pair.array[1].integer) ||
                (a[1].integer == pair.array[0].integer && a[0].integer == pair.array[1].integer)) {
                indices ~= JSONValue(i); found = true; break;
            }
        }
        assert(found, "preview selected edge exists");
    }
    assert(indices.length == 8, "preview selection population");
    auto select = JSONValue.emptyObject;
    select["mode"] = JSONValue("edges"); select["indices"] = JSONValue(indices);
    response = postJson("/api/command", commandBody("mesh.select", select.toString));
    assert(response["status"].str == "ok", "preview select");
    cmd("tool.set " ~ TOOL ~ " on");
    scope(exit) cmd("tool.set " ~ TOOL ~ " off");
    Thread.sleep(200.msecs);
    ulong key() {
        auto v = getJson("/api/viewport/display")["cells"].array[0]["toolPreviewKey"];
        return v.type == JSONType.uinteger ? v.uinteger : cast(ulong)v.integer;
    }
    void change(string name, string value) {
        auto before = key();
        cmd("tool.attr " ~ TOOL ~ " " ~ name ~ " " ~ value);
        foreach (_; 0 .. 60) {
            Thread.sleep(25.msecs);
            if (key() != before) return;
        }
        assert(false, "consumed bridge preview not rebuilt: " ~ name);
    }
    change("connect", "false");
    change("segments", "3");
    assert(getJson("/api/tool/state")["effectiveSegments"].integer == 3,
        "rails preview effective requested segments");
    change("mode", "smooth");
    change("tension", "0");
    change("autoStep", "false");
    change("connect", "true");
    assert(getJson("/api/tool/state")["effectiveSegments"].integer == 3,
        "static autoStep false preview requested segments");
    change("autoStep", "true");
    assert(getJson("/api/tool/state")["effectiveSegments"].integer == 5,
        "connected preview effective side segments");
    change("twist", "1");
    auto state = getJson("/api/tool/state");
    assert(state["twistRefused"].type == JSONType.true_ && state["effectiveSegments"].integer == 0,
        "open twist preview refusal and effective zero");
}
