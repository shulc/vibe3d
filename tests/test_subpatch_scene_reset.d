// Regression test for task 0415 (campaign 0407 §B.V1 step 1, Phase 2 step 0)
// silent-bug #1: `subpatchPreview` in the EditorApp ctx bag threaded through
// registration.d's registerCommands MUST be pointer-backed
// (`SubpatchPreview* subpatchPreviewPtr` + `@property ref`), never a plain
// by-value `SubpatchPreview subpatchPreview` field.
//
// `SubpatchPreview` is a STRUCT (mesh.d), not a class. `scene.reset`'s
// factory body (registerCommands, moved from former app.d Span B) calls
// `subpatchPreview.deactivate()` as part of its onResetTool callback. If the
// ctx field were by-value, that call would mutate a throwaway copy of the
// struct captured inside the `EditorApp app` value passed into
// registerCommands — the render loop's REAL `subpatchPreview` local in
// main() would never see the deactivation. `scene.reset` is what `/api/reset`
// dispatches, i.e. the reset every single HTTP test runs before its own
// assertions — a silent regression here is exactly the "cross-test state
// bleed" class documented in CLAUDE.md's flake note.
//
// This locks the observable CONTRACT: after toggling every face of a cube
// to subpatch (activating the live smoothed preview, verified via the
// higher `/api/gpu/face-vbo` face-vert count — same technique as
// test_subpatch_move.d) and then resetting, the rendered surface returns to
// the flat 36-face-vert cage. `dub build`/`dub test --config=modeling` do
// NOT exercise this: app.d's main() (where the ctx is actually assembled
// and registerCommands is actually invoked) is excluded from the
// `dub test` build, and a by-value regression here compiles cleanly with
// zero warnings — this HTTP round-trip is the only oracle.

import std.net.curl;
import std.json;
import std.conv : to;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void settle() { Thread.sleep(150.msecs); }

int gpuFaceVertCount() {
    return cast(int) getJson("/api/gpu/face-vbo")["faceVertCount"].integer;
}

long modelVertexCount() {
    return getJson("/api/model")["vertices"].array.length;
}

unittest { // subpatch preview correctly clears across /api/reset (scene.reset)
    // Fresh cube: flat cage renders 6 faces x 2 tris x 3 verts = 36 face-verts.
    postJson("/api/reset", "");
    settle();
    auto cageCount = gpuFaceVertCount();
    assert(cageCount == 36,
        "fresh cube should expose 36 face-verts, got " ~ cageCount.to!string);

    // Tab-equivalent: flip every face to subpatch (no selection = global
    // toggle, same as the Tab keyboard handler / test_subpatch_move.d).
    postJson("/api/command", "select.typeFrom polygon");
    postJson("/api/command", `{"id":"mesh.subpatch_toggle"}`);
    settle();

    auto activeCount = gpuFaceVertCount();
    assert(activeCount > cageCount,
        "subpatch preview should expose more face-verts than the flat cage " ~
        "after toggling every face (got " ~ activeCount.to!string ~
        " vs cage " ~ cageCount.to!string ~ ") — if not, subpatch preview " ~
        "never activated and this test can't exercise the reset path");

    // /api/reset dispatches scene.reset — the SAME command factory
    // registerCommands (Phase 2) now builds, whose onResetTool callback
    // calls subpatchPreview.deactivate(). Every HTTP test in the suite
    // starts this way.
    postJson("/api/reset", "");
    settle();

    auto afterResetCount = gpuFaceVertCount();
    assert(afterResetCount == 36,
        "subpatch preview should be fully deactivated after /api/reset -- " ~
        "fresh cube should be back to the flat 36-face-vert cage, got " ~
        afterResetCount.to!string ~
        " (if this is still elevated, subpatchPreview.deactivate() is " ~
        "mutating a throwaway EditorApp-ctx copy instead of the real " ~
        "render-loop struct -- see EditorApp.subpatchPreviewPtr)");

    // Cage geometry itself must also be the plain 8-vertex cube (not the
    // 6-face-selected leftovers from the toggle step).
    assert(modelVertexCount() == 8,
        "post-reset cage should be the default 8-vertex cube, got " ~
        modelVertexCount().to!string);
}
