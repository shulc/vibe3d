// Tab-key subpatch-toggle test (Stage E2 of doc/test_coverage_plan.md).
//
// app.d:1938 handles SDLK_TAB inline (not through mesh.subpatch_toggle
// command — the key path takes a different branch). Existing
// test_subpatch.d drives the command directly, so the keypress flow
// itself has zero coverage. This test exercises Tab through the live
// SDL event pipeline.
//
// What the key handler does (MODE-AWARE scope — parity task 0464):
//   • Polygons mode + a face selection ⇒ toggle isSubpatch on just the
//     selected faces; leave the rest alone.
//   • Polygons mode + nothing selected ⇒ invert isSubpatch on every face.
//   • edge / vertex / item mode         ⇒ a persisted face selection is
//     IGNORED; Tab toggles the WHOLE model (matches the reference editor,
//     which drops the polygon selection's authority outside polygon mode).
//
// All branches are pinned below — independent unittests so a failure
// localises cleanly.

import std.net.curl;
import std.json;
import std.string : format;
import std.conv : to;
import core.thread : Thread;
import core.time : msecs;

void main() {}

enum SDLK_TAB = 9;

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

void waitPlaybackFinish() {
    foreach (_; 0 .. 100) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "playback didn't finish within 5s");
}

string tabKey(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":0,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":0,"repeat":0}`,
        t,         SDLK_TAB,
        t + 10.0,  SDLK_TAB);
}

enum string LOG_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1.0,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2.0,"type":"SDL_WINDOWEVENT","sub":3}`;

bool[] subpatchFlags() {
    auto j = getJson("/api/model");
    bool[] r;
    foreach (b; j["isSubpatch"].array)
        r ~= (b.type == JSONType.TRUE);
    return r;
}

unittest { // Tab with no selection flips every face's subpatch flag
    postJson("/api/reset", "");
    auto before = subpatchFlags();
    assert(before.length == 6, "cube has 6 faces");
    foreach (i, b; before)
        assert(!b, "fresh cube: face " ~ i.to!string ~ " should not be subpatch");

    auto r = postJson("/api/play-events", LOG_HEADER ~ "\n" ~ tabKey(50));
    assert(r["status"].str == "success",
        "/api/play-events failed: " ~ r.toString);
    waitPlaybackFinish();

    auto after = subpatchFlags();
    foreach (i, b; after)
        assert(b,
            "after Tab w/ no selection, face " ~ i.to!string ~
            " should be subpatch=true");

    // Second Tab toggles them all back off.
    r = postJson("/api/play-events", LOG_HEADER ~ "\n" ~ tabKey(50));
    assert(r["status"].str == "success");
    waitPlaybackFinish();

    auto reverted = subpatchFlags();
    foreach (i, b; reverted)
        assert(!b,
            "after second Tab, face " ~ i.to!string ~
            " should toggle back to subpatch=false");
}

unittest { // Tab with a single face selected flips only that face
    postJson("/api/reset", "");
    // Switch to Polygons mode + select face 0 via the command channel —
    // the Tab handler reads mesh.selectedFaces, which /api/select
    // populates.
    postJson("/api/command", "select.typeFrom polygon");
    postJson("/api/select", `{"mode":"polygons","indices":[0]}`);

    auto r = postJson("/api/play-events", LOG_HEADER ~ "\n" ~ tabKey(50));
    assert(r["status"].str == "success",
        "/api/play-events failed: " ~ r.toString);
    waitPlaybackFinish();

    auto flags = subpatchFlags();
    assert(flags[0],
        "after Tab w/ face 0 selected, face 0 should be subpatch=true");
    foreach (i; 1 .. flags.length)
        assert(!flags[i],
            "face " ~ i.to!string ~ " unselected; should stay subpatch=false");
}

unittest { // MODE-AWARE (parity 0464): a face selection made in polygon mode
           // must NOT scope the toggle once the current selection type is
           // edge. Tab in edge mode toggles the WHOLE model — matching the
           // reference editor (re-confirmed headless: polygon-select 2 →
           // switch to edge → convert → all 6 become subpatch).
    postJson("/api/reset", "");
    // Select 2 of 6 faces in polygon mode …
    postJson("/api/command", "select.typeFrom polygon");
    postJson("/api/select", `{"mode":"polygons","indices":[0,1]}`);
    // … then switch to edge mode. The face selection persists in the mesh
    // (hasAnySelectedFaces() is still true), so the OLD, mode-blind handler
    // would have toggled only faces 0,1. The fix keys off currentSelType.
    postJson("/api/command", "select.typeFrom edge");

    auto r = postJson("/api/play-events", LOG_HEADER ~ "\n" ~ tabKey(50));
    assert(r["status"].str == "success",
        "/api/play-events failed: " ~ r.toString);
    waitPlaybackFinish();

    auto flags = subpatchFlags();
    assert(flags.length == 6, "cube has 6 faces");
    foreach (i, b; flags)
        assert(b,
            "edge-mode Tab must whole-model (parity): face " ~ i.to!string ~
            " should be subpatch=true, not just the 2 polygon-selected");
}
