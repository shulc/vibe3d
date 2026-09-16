// Tab-key subpatch-toggle test (Stage E2 of doc/test_coverage_plan.md).
//
// Tab reaches mesh.subpatch_toggle through the same command funnel as scripts.
// Existing test_subpatch.d drives the command directly; this test exercises
// the keyboard binding through the live SDL event pipeline.
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

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.string : format;
import std.conv : to;
import std.math : fabs;
import core.thread : Thread;
import core.time : msecs;
import drag_helpers;

void main() {}

enum SDLK_TAB = 9;

alias baseUrl = testBaseUrl;


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

struct GpuSurface {
    int faceVertCount;
    double[3][] positions;
}

GpuSurface gpuSurface() {
    auto j = getJson("/api/gpu/face-vbo");
    GpuSurface s;
    s.faceVertCount = cast(int)j["faceVertCount"].integer;
    foreach (p; j["positions"].array) {
        auto a = p.array;
        s.positions ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return s;
}

double maxDelta(in double[3][] a, in double[3][] b) {
    assert(a.length == b.length, "surface population changed across a position-only edit");
    double result;
    foreach (i; 0 .. a.length)
        foreach (axis; 0 .. 3)
            result = result > fabs(a[i][axis] - b[i][axis])
                ? result : fabs(a[i][axis] - b[i][axis]);
    return result;
}

struct PreviewState {
    bool pending;
    long builds;
    long topologiesCreated;
}

PreviewState previewState() {
    auto j = getJson("/api/subpatch/preview");
    return PreviewState(j["pending"].type == JSONType.TRUE,
                        j["builds"].integer,
                        j["topologiesCreated"].integer);
}

void waitPreviewSettled(long buildsBefore) {
    foreach (_; 0 .. 1_500) {
        const p = previewState();
        if (p.builds > buildsBefore && !p.pending) return;
        Thread.sleep(20.msecs);
    }
    assert(false, "subpatch preview build did not settle within 30s");
}

void waitPreviewIdleAfterDispatchGrace() {
    // `pending:false` is also the PRE-dispatch state. Playback completion says
    // the event was posted, not that the frame consumed it, so give dispatch
    // its measured 60 ms window before an idle read is allowed to finish.
    Thread.sleep(60.msecs);
    foreach (_; 0 .. 1_500) {
        if (!previewState().pending) return;
        Thread.sleep(20.msecs);
    }
    assert(false, "subpatch preview did not become idle within 30s");
}

unittest { // Tab with no selection flips every face's subpatch flag
    postJson("/api/command", commandBody("scene.reset"));
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
    postJson("/api/command", commandBody("scene.reset"));
    // Switch to Polygons mode + select face 0 via the command channel —
    // the Tab handler reads mesh.selectedFaces, which /api/select
    // populates.
    postJson("/api/command", "select.typeFrom polygon");
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`));

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
    postJson("/api/command", commandBody("scene.reset"));
    // Select 2 of 6 faces in polygon mode …
    postJson("/api/command", "select.typeFrom polygon");
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0,1]}`));
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

unittest { // no-edit Tab off/on must take the reusable-preview short circuit
    postJson("/api/command", commandBody("scene.reset"));
    postJson("/api/command", "select.typeFrom polygon");

    const cold = previewState();
    auto tab = postJson("/api/play-events", LOG_HEADER ~ "\n" ~ tabKey(50));
    assert(tab["status"].str == "success", "initial Tab playback failed: " ~ tab.toString);
    waitPlaybackFinish();
    waitPreviewSettled(cold.builds);
    const warm = previewState();
    assert(warm.builds >= 1,
        "population floor: no subpatch preview build completed before the reuse check");
    assert(warm.topologiesCreated >= 1,
        "population floor: no OSD topology existed before the reuse check");

    tab = postJson("/api/play-events", LOG_HEADER ~ "\n" ~ tabKey(50));
    assert(tab["status"].str == "success", "Tab-off playback failed: " ~ tab.toString);
    waitPlaybackFinish();
    tab = postJson("/api/play-events", LOG_HEADER ~ "\n" ~ tabKey(50));
    assert(tab["status"].str == "success", "Tab-on playback failed: " ~ tab.toString);
    waitPlaybackFinish();
    waitPreviewIdleAfterDispatchGrace();

    const reused = previewState();
    assert(reused.topologiesCreated == warm.topologiesCreated,
        format("no-edit Tab-on created an OSD topology: %d -> %d",
               warm.topologiesCreated, reused.topologiesCreated));
    assert(reused.builds == warm.builds,
        format("no-edit Tab-on rebuilt instead of reusing: builds %d -> %d",
               warm.builds, reused.builds));
}

unittest { // task 6249: Tab-off/on after a real drag must not resurrect stale limit positions
    // Every older subpatch regression uses the six-face cube. The old fold's
    // blindness is probabilistic and rises with the face-chain length; one
    // subdivision gives this cell 24 faces plus deterministic population and
    // motion guards, while the pure member matrix carries the general proof.
    postJson("/api/command", commandBody("scene.reset"));
    auto subdiv = postJson("/api/command", commandBody("mesh.subdivide"));
    assert(subdiv["status"].str == "ok", "fixture subdivision failed: " ~ subdiv.toString);

    auto cage = getJson("/api/model");
    assert(cage["vertexCount"].integer == 26,
        "population floor: the once-subdivided cube must have exactly 26 cage vertices");
    assert(cage["faceCount"].integer == 24,
        "fixture guard: the once-subdivided cube must have exactly 24 faces");

    postJson("/api/command", "select.typeFrom polygon");
    const cold = previewState();
    auto tab = postJson("/api/play-events", LOG_HEADER ~ "\n" ~ tabKey(50));
    assert(tab["status"].str == "success", "initial Tab playback failed: " ~ tab.toString);
    waitPlaybackFinish();
    waitPreviewSettled(cold.builds);

    auto before = gpuSurface();
    assert(before.faceVertCount == 9_216 && before.positions.length == 9_216,
        format("population floor: the 24-face depth-3 preview must expose exactly "
             ~ "9216 face vertices, got count=%d positions=%d",
               before.faceVertCount, before.positions.length));

    auto toolOn = postJson("/api/script", "tool.set xfrm.elementMove on");
    assert(toolOn["status"].str == "ok", "element Move activation failed: " ~ toolOn.toString);
    Thread.sleep(150.msecs);

    auto cam = fetchCamera();
    auto vp = viewportFromCamera(cam);
    auto vertices = getJson("/api/model")["vertices"].array;
    size_t picked;
    double nearest = double.max;
    foreach (i, value; vertices) {
        auto p = value.array;
        immutable double dx = p[0].floating - cam.eye.x;
        immutable double dy = p[1].floating - cam.eye.y;
        immutable double dz = p[2].floating - cam.eye.z;
        immutable double dist2 = dx * dx + dy * dy + dz * dz;
        if (dist2 < nearest) { nearest = dist2; picked = i; }
    }
    assert(picked == 19, format("fixture drift: nearest cage vertex must be 19, got %d", picked));
    auto pickedJson = vertices[picked].array;
    Vec3 pickedPos = Vec3(cast(float)pickedJson[0].floating,
                          cast(float)pickedJson[1].floating,
                          cast(float)pickedJson[2].floating);
    float sx, sy;
    assert(projectToWindow(pickedPos, vp, sx, sy),
        "fixture drift: cage vertex 19 must project into the viewport");

    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cast(int)sx, cast(int)sy,
                             cast(int)sx, cast(int)sy - 60, 8));
    Thread.sleep(150.msecs);
    waitPreviewIdleAfterDispatchGrace();
    auto live = gpuSurface();
    assert(live.faceVertCount == 9_216 && live.positions.length == 9_216,
        "the interactive position edit must preserve the 9216-vertex preview population");
    immutable double liveDelta = maxDelta(before.positions, live.positions);
    assert(fabs(liveDelta - 0.274082) < 1e-5,
        format("the fixed 60px gizmo drag must move the limit VBO by 0.274082, got %.9f",
               liveDelta));

    tab = postJson("/api/play-events", LOG_HEADER ~ "\n" ~ tabKey(50));
    assert(tab["status"].str == "success", "Tab-off playback failed: " ~ tab.toString);
    waitPlaybackFinish();
    const beforeRestore = previewState();
    tab = postJson("/api/play-events", LOG_HEADER ~ "\n" ~ tabKey(50));
    assert(tab["status"].str == "success", "Tab-on playback failed: " ~ tab.toString);
    waitPlaybackFinish();
    waitPreviewSettled(beforeRestore.builds);
    auto restored = gpuSurface();
    assert(restored.faceVertCount == 9_216 && restored.positions.length == 9_216,
        "Tab-on must restore the 9216-vertex preview population");

    postJson("/api/script", "tool.set xfrm.elementMove off");
    Thread.sleep(150.msecs);

    immutable double restoredDelta = maxDelta(before.positions, restored.positions);
    assert(fabs(restoredDelta - 0.274082) < 1e-5,
        format("Tab-on resurrected the pre-edit surface: expected VBO delta 0.274082, got %.9f",
               restoredDelta));
    immutable double continuityDelta = maxDelta(live.positions, restored.positions);
    assert(continuityDelta < 2e-5,
        format("Tab-on surface must match the live post-drag VBO, max delta %.9f",
               continuityDelta));
}
