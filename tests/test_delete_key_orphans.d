// Delete / Backspace / Shift+Backspace in polygon mode (task 7131, wave
// bugfix S11 item 3). Law (fixture `delete_makepoly_lasso_hide_keys.json`,
// section `delete_keys`): Backspace AND Delete run the deleting command,
// which also drops points left without a polygon; Shift+Backspace runs the
// removing command, which keeps them. One undo restores geometry + selection.
//
// Every key goes through /api/play-events (real SDL key events, the same
// InputRouter resolve the user hits), never through /api/command. The rig is
// an ISOLATED quad because a closed cube cannot tell delete from remove (no
// orphan points either way — 8/5 under both); the cube cell is the owner's
// scenario and a green control only.
//
// Order is load-bearing: the controls that must stay green (floors, cube via
// Delete, quad via Delete + undo) sit above the one red line per run.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.json;
import std.format : format;
import std.conv : to;
import core.thread : Thread;
import core.time : msecs;

void main() {}

enum string kFixture = import("fixtures/delete_makepoly_lasso_hide_keys.json");

// SDL keycodes / modifiers as SDL2 defines them.
enum SDLK_BACKSPACE = 8;
enum SDLK_DELETE    = 127;
enum SDLK_z         = 122;
enum KMOD_NONE      = 0;
enum KMOD_LSHIFT    = 1;
enum KMOD_LCTRL     = 64;

enum string LOG_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1.0,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2.0,"type":"SDL_WINDOWEVENT","sub":3}`;

JSONValue fixture() { return parseJSON(kFixture); }
JSONValue cell(string name) { return fixture()["delete_keys"]["cells"][name]; }

void ok(JSONValue r, string what) {
    assert(r["status"].str == "ok", what ~ " failed: " ~ r.toString);
}

void waitPlaybackFinish() {
    foreach (_; 0 .. 100) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "playback didn't finish within 5s");
}

void pressKey(int sym, int mod) {
    auto log = LOG_HEADER ~ "\n" ~ format(
        `{"t":50,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
      ~ `{"t":60,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
        sym, mod, sym, mod);
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", "/api/play-events failed: " ~ r.toString);
    waitPlaybackFinish();
}

/// Load a fixture rig, enter polygon mode, select the cell's polygons and
/// clear history, so a later Ctrl+Z can only undo the key under test.
void rig(JSONValue c) {
    auto rg = fixture()["rigs"][c["rig"].str];
    auto body = JSONValue.emptyObject;
    body["vertices"] = rg["vertices"];
    body["faces"] = rg["polygons"];
    ok(postJson("/api/command", commandBody("scene.reset")), "scene.reset");
    ok(postJson("/api/command", commandBody("scene.loadMesh", body.toString)), "scene.loadMesh");
    ok(postJson("/api/command", "select.typeFrom polygon"), "select.typeFrom polygon");
    ok(postJson("/api/command", commandBody("mesh.select",
        `{"mode":"polygons","indices":` ~ c["selected_polygons"].toString ~ `}`)), "mesh.select");
    ok(postJson("/api/command", `{"id":"history.clear"}`), "history.clear");
}

int[][] ints2(JSONValue a) {
    int[][] r;
    foreach (row; a.array) {
        int[] x;
        foreach (v; row.array) x ~= cast(int) v.integer;
        r ~= x;
    }
    return r;
}

int[] ints(JSONValue a) {
    int[] r;
    foreach (v; a.array) r ~= cast(int) v.integer;
    return r;
}

/// Compare live state to a fixture state block: counts, polygon list by
/// identity (corner order included) and the polygon selection.
void expectState(JSONValue want, string label) {
    auto m = getJson("/api/model");
    auto got = format("%d/%d", m["vertexCount"].integer, m["faceCount"].integer);
    auto exp = format("%d/%d", want["vertex_count"].integer, want["polygon_count"].integer);
    assert(got == exp, format("%s: vertex/polygon counts %s, fixture %s", label, got, exp));
    auto gotFaces = ints2(m["faces"]);
    auto expFaces = ints2(want["polygons"]);
    assert(gotFaces.length == want["polygon_count"].integer,
        label ~ ": population floor — face list length disagrees with the count");
    assert(gotFaces == expFaces,
        format("%s: polygons %s, fixture %s", label, gotFaces, expFaces));
    auto sel = getJson("/api/selection");
    auto selFaces = ints(sel["selectedFaces"]);
    auto expSel = ints(want["selected"]["polygons"]);
    assert(selFaces == expSel,
        format("%s: selected polygons %s, fixture %s", label, selFaces, expSel));
}

// 1. Floors: each rig loads to its fixture `before` state (4/1 quad, 8/6 cube).
unittest {
    foreach (name; ["d-iso-bs", "d-cube-bs"]) {
        auto c = cell(name);
        rig(c);
        auto m = getJson("/api/model");
        assert(m["vertexCount"].integer == c["before"]["vertex_count"].integer
            && m["faceCount"].integer == c["before"]["polygon_count"].integer,
            "rig: before counts differ from the fixture (" ~ name ~ ")");
        expectState(c["before"], "rig " ~ name);
    }
}

// 2. Owner's scenario, via Delete (green on HEAD by construction: a closed
// cube leaves no orphans, so this cannot tell delete from remove — it is a
// control, not the witness). The expected state is the Backspace cell's,
// whose law says the two keys are one command.
unittest {
    auto c = cell("d-cube-bs");
    rig(c);
    pressKey(SDLK_DELETE, KMOD_NONE);
    auto m = getJson("/api/model");
    assert(m["vertexCount"].integer == 8 && m["faceCount"].integer == 5, "cube face delete");
    expectState(c["after"], "cube face delete");
    pressKey(SDLK_z, KMOD_LCTRL);
    expectState(c["after_undo"], "cube face delete undo");
}

// 3. d-iso-del: Delete removes the quad AND its four orphan points; Ctrl+Z
// restores geometry and the selection.
unittest {
    auto c = cell("d-iso-del");
    rig(c);
    pressKey(SDLK_DELETE, KMOD_NONE);
    auto m = getJson("/api/model");
    assert(m["vertexCount"].integer == 0 && m["faceCount"].integer == 0,
        "delete left orphan points");
    expectState(c["after"], "d-iso-del");
    pressKey(SDLK_z, KMOD_LCTRL);
    expectState(c["after_undo"], "d-iso-del undo");
}

// 4. d-iso-bs: Backspace in component mode is the SAME deleting command.
// RED on HEAD 9f434948: Backspace is bound to the removing command → 4/0.
unittest {
    auto c = cell("d-iso-bs");
    rig(c);
    pressKey(SDLK_BACKSPACE, KMOD_NONE);
    auto m = getJson("/api/model");
    assert(m["vertexCount"].integer == 0 && m["faceCount"].integer == 0,
        format("backspace in component mode is not delete (got %d/%d, want 0/0)",
               m["vertexCount"].integer, m["faceCount"].integer));
    expectState(c["after"], "d-iso-bs");
    pressKey(SDLK_z, KMOD_LCTRL);
    expectState(c["after_undo"], "d-iso-bs undo");
}

// 5. d-iso-sbs: Shift+Backspace removes the polygon and KEEPS the points.
// RED on HEAD 9f434948 (shown by isolation — block 4 stops the module
// first): the chord is unbound, nothing happens → 4/1.
unittest {
    auto c = cell("d-iso-sbs");
    rig(c);
    pressKey(SDLK_BACKSPACE, KMOD_LSHIFT);
    auto m = getJson("/api/model");
    assert(m["vertexCount"].integer == 4 && m["faceCount"].integer == 0,
        format("shift+backspace did not remove (keep points) (got %d/%d, want 4/0)",
               m["vertexCount"].integer, m["faceCount"].integer));
    expectState(c["after"], "d-iso-sbs");
    pressKey(SDLK_z, KMOD_LCTRL);
    expectState(c["after_undo"], "d-iso-sbs undo");
}
