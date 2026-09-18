// Regression test for the observable file.new outcome with an armed Loop
// Slice: a cleanly emptied scene and exactly one SceneReset undo entry, never
// a bogus mesh.loop_slice_edit entry. The first-layer production-drop witness
// is test_reset_disarms_tool; this cell reads the shared disarm observation
// only to attribute its final-state contract to the cancel-and-drop route.
//
// `dub build`/`dub test --config=tests` do NOT exercise app.d's installed
// seam body with the real active tool; the two named suite cells do.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import std.math : sqrt;

import drag_helpers;

void main() {}

alias baseUrl = testBaseUrl;

void resetCube() {
    auto r = parseJSON(cast(string) post(baseUrl ~ "/api/command", commandBody("scene.reset")));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

void cmd(string s) {
    auto resp = post(baseUrl ~ "/api/script", s);
    assert(parseJSON(cast(string) resp)["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ cast(string) resp);
}


JSONValue getModel()     { return getJson("/api/model"); }
JSONValue getToolState() { return getJson("/api/tool/state"); }
JSONValue getHistory()   { return getJson("/api/history"); }

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int) e.array[0].integer;
        int y = cast(int) e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int) i;
    }
    return -1;
}

int vertAt(JSONValue m, V3 p) {
    foreach (i; 0 .. m["vertices"].array.length) {
        auto v = vert(m, i);
        auto dx = v.x - p.x, dy = v.y - p.y, dz = v.z - p.z;
        if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-4) return cast(int) i;
    }
    return -1;
}

unittest { // file.new with an ARMED Loop Slice preview: clean scene, one undo entry
    resetCube();
    auto model = getModel();
    int va = vertAt(model, V3(0.5, -0.5, 0.5));
    int vb = vertAt(model, V3(0.5,  0.5, 0.5));
    assert(va >= 0 && vb >= 0, "setup: cube seed verts not found");
    int ei = edgeIndex(model, va, vb);
    assert(ei >= 0, "setup: cube seed edge not found");

    // Arming only happens in Edges/Polygons mode (see LoopSliceTool /
    // test_loop_slice_hover_state.d).
    cmd("select.typeFrom edge");
    cmd("tool.set mesh.loopSliceTool on");
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 mid = Vec3(0.5f, 0.0f, 0.5f);   // seed edge midpoint
    float sx, sy;
    assert(projectToWindow(mid, vp, sx, sy), "setup: seed midpoint should be on-camera");

    // Hover the seed edge, then a short click-drag arms the standing
    // preview (same recipe as test_loop_slice_hover_state.d's "ARMED
    // state" case -- 5 stationary motion events, the same hover-injection
    // pattern as test_loop_slice_hover_state.d's own hoverLog() /
    // test_element_pick_stays.d's, needed since SDL's X11 backend can
    // coalesce a single motion event away).
    import std.string : format;
    string hoverLog = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height);
    foreach (i; 0 .. 5)
        hoverLog ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 20.0, cast(int) sx, cast(int) sy);
    playAndWait(hoverLog);
    settle();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cast(int) sx, cast(int) sy,
                             cast(int) sx + 8, cast(int) sy, 6));
    settle();

    auto armed = getToolState();
    assert(armed["armed"].type == JSONType.true_,
        "setup: a click-drag on the seed edge should arm the standing " ~
        "preview, got tool/state: " ~ armed.toString);

    // Baseline: undo-stack depth right before file.new (after reset +
    // typeFrom + tool.set + the arming drag -- none of which are expected
    // to add a MODEL-undo entry of their own; the point is the DELTA
    // across file.new, not this absolute count).
    auto histBefore = getHistory();
    auto undoCountBefore = histBefore["undo"].array.length;

    // file.new fires while the Loop Slice preview is still armed.
    auto r = parseJSON(cast(string) post(baseUrl ~ "/api/command", `{"id":"file.new"}`));
    assert(r["status"].str == "ok", "file.new failed: " ~ r.toString);
    settle();

    auto disarm = getJson("/api/tool/disarm");
    assert(disarm["hadTool"].boolean
            && disarm["mode"].str == "cancelAndDrop"
            && !disarm["stillArmed"].boolean,
        "file.new with an armed Loop Slice must cross the production "
        ~ "cancel-and-drop seam before reset effects; got " ~ disarm.toString);

    // (a) Clean, fully-emptied scene -- the documented file.new contract
    // (test_commands_file_misc.d), unaffected by the armed tool.
    auto afterModel = getModel();
    assert(afterModel["vertices"].array.length == 0,
        "file.new should empty the scene even with an armed Loop Slice " ~
        "preview; got " ~ afterModel["vertices"].array.length.to!string ~
        " verts (a stray commitEdit()/cancelLiveEdit() against the " ~
        "already-reset mesh would show up here as leftover geometry)");

    // (b) Exactly one new undo entry -- the SceneReset itself, never a
    // second bogus "mesh.loop_slice_edit" commit ahead of it.
    auto histAfter = getHistory();
    auto undoArr = histAfter["undo"].array;
    assert(undoArr.length == undoCountBefore + 1,
        "file.new with an armed Loop Slice preview should add exactly ONE " ~
        "undo entry; undo stack went from " ~ undoCountBefore.to!string ~
        " to " ~ undoArr.length.to!string ~
        " entries (an extra entry means the document-replace seam did not " ~
        "drop the tool before geometry was recorded)");
    auto lastCommand = undoArr[$ - 1]["command"].str;
    assert(lastCommand == "scene.reset",
        "the new undo entry should be the scene.reset command (file.new's " ~
        "underlying factory), got \"" ~ lastCommand ~ "\" -- if this is " ~
        "\"mesh.loop_slice_edit\", the armed preview was wrongly committed");

    // Loop Slice tool itself must be fully dropped, not left dangling armed
    // against the now-empty scene. /api/tool/state returns bare `{}` when
    // activeTool is null (see app.d's setToolStateDataProvider).
    auto afterToolState = getToolState();
    assert(afterToolState.object.length == 0,
        "no tool should be active after file.new -- expected empty {} " ~
        "from /api/tool/state, got: " ~ afterToolState.toString);

    resetCube();
}
