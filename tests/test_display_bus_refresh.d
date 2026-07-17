// Bus-driven display refresh (task 0427, campaign 0407 §D4-в).
//
// Commands no longer refresh the display themselves — they mutate + publish
// change-bus flags; the main loop's flush site uploads the GPU buffers, and
// `ensureDisplayCurrent` pull-guards service VBO readers that run BEFORE the
// frame's flush (pickers inside event dispatch, the HTTP providers). These
// tests pin both halves:
//
//   1. same-batch undo→pick — the scenario ONLY the phase-2 guard covers:
//      a Ctrl+Z and a select-click delivered in the SAME event-player tick
//      dispatch inside one frame, with no flush (and therefore no bus-driven
//      upload) between them. The click's GPU pick must read the POST-undo
//      VBO, which only happens if the picker's pull-guard refreshes it
//      mid-batch.
//
//      ANTI-VACUITY (review amendment A4): the discriminating power of this
//      test lives ENTIRELY in the event timestamps. The Ctrl+Z keyup and the
//      pick mousedown are authored with IDENTICAL timestamps so the event
//      player posts them in one tick and the app dispatches them in one
//      frame. If the timestamps were spread out instead, the events would
//      land in different frames, the flush between them would upload the
//      post-undo VBO anyway, and the test would pass even with the guard
//      deleted — i.e. it would assert nothing. Do not "clean up" the
//      timestamps into a spaced sequence.
//
//   2. flush-refresh without any command-side display call — mesh.subdivide
//      over HTTP, one settle (several --test frames), then the
//      /api/gpu/face-vbo dump must match the post-subdivide mesh. After the
//      settle the pending flags have long been drained (the dump provider's
//      own pull-guard sees zero pending bits and no-ops), so the upload the
//      dump observes can only have come from the flush site.
//
// Runner: ./run_test.d test_display_bus_refresh   (HTTP suite; needs a
// running `vibe3d --test`, which run_test.d manages).

import std.net.curl : get, post;
import std.json;
import std.format : format;
import std.conv : to;
import core.thread : Thread;
import core.time : dur;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      playAndWait, Vec3;

void main() {}

enum baseUrl = "http://localhost:8080";

void postJson(string path, string body_) {
    auto resp = cast(string)post(baseUrl ~ path, body_);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok" || j["status"].str == "success",
        path ~ " failed: " ~ resp);
}

void cmd(string id) {
    postJson("/api/command", format(`{"id":"%s"}`, id));
}

// Post-playback / post-command settle. /api/play-events/status flips to
// `finished` once events are POSTED to the SDL queue, not processed, and an
// HTTP command's response returns before the frame's flush runs — give the
// main loop a few --test frames to dispatch + flush before reading state.
void settle(int ms = 200) {
    Thread.sleep(dur!"msecs"(ms));
}

JSONValue model() {
    return parseJSON(cast(string)get(baseUrl ~ "/api/model"));
}

// The face VBO holds fan-triangulated faces at stride 6: every face with
// n >= 3 corners contributes (n - 2) * 3 vertices. Deriving the expectation
// from /api/model (instead of hardcoding 36/144 for the cube) keeps the
// assert valid if the default scene ever changes.
long expectedFaceVertCount(JSONValue m) {
    long n = 0;
    foreach (f; m["faces"].array)
        if (f.array.length >= 3)
            n += (cast(long)f.array.length - 2) * 3;
    return n;
}

long gpuFaceVertCount() {
    auto j = parseJSON(cast(string)get(baseUrl ~ "/api/gpu/face-vbo"));
    return j["faceVertCount"].integer;
}

unittest { // 1. same-batch undo→pick: the pull-guard scenario
    postJson("/api/reset", "");
    cmd("history.clear");
    settle();

    // Base-cube geometry + the pixel of its camera-nearest vertex (nearest
    // vertex of a convex body is never occluded → always pickable). Captured
    // BEFORE the subdivide: this is where the vertex will be again AFTER the
    // undo, which is the state the click must pick against.
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    auto baseModel = model();
    auto baseVerts = baseModel["vertices"].array;
    const size_t baseVertCount = baseVerts.length;

    int   vid = -1;
    float bestD2 = float.max;
    float px = 0, py = 0;
    foreach (i, v; baseVerts) {
        auto a = v.array;
        Vec3 w = Vec3(cast(float)a[0].floating,
                      cast(float)a[1].floating,
                      cast(float)a[2].floating);
        Vec3 d = w - cam.eye;
        float d2 = d.x*d.x + d.y*d.y + d.z*d.z;
        if (d2 >= bestD2) continue;
        float sx, sy;
        if (!projectToWindow(w, vp, sx, sy)) continue;
        bestD2 = d2; vid = cast(int)i; px = sx; py = sy;
    }
    assert(vid >= 0, "no projectable base-cube vertex found");

    // Mutate: subdivide over HTTP (publishes Geometry; the flush uploads the
    // subdivided mesh, so the VBO now holds the WRONG geometry for a
    // post-undo pick).
    cmd("mesh.subdivide");
    settle();
    assert(model()["vertices"].array.length > baseVertCount,
        "mesh.subdivide did not add vertices — test setup broken");

    // One event batch, ALL discriminating events at the SAME timestamp (see
    // the header comment): Ctrl+Z (undo the subdivide), then click the
    // base-cube vertex. Dispatched in one frame → no flush between the undo
    // and the pick → only the picker's ensureDisplayCurrent can refresh the
    // VBO the pick reads.
    enum double t = 50.0;
    string log =
        format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
               cam.vpX, cam.vpY, cam.width, cam.height)
      ~ format(`{"t":%.3f,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n", t)
      ~ format(`{"t":%.3f,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n", t)
      ~ format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
               t, cast(int)px, cast(int)py)
      ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
               t, cast(int)px, cast(int)py)
      ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
               t, cast(int)px, cast(int)py);
    playAndWait(log);
    settle();

    // The undo itself must have landed (base topology restored) …
    assert(model()["vertices"].array.length == baseVertCount,
        "Ctrl+Z did not restore the base cube — undo path broken, "
        ~ "selection assert below would be meaningless");

    // … and the same-batch click must have picked the BASE-cube vertex. With
    // a stale (still-subdivided) VBO the pick lands elsewhere or nowhere.
    auto sel = parseJSON(cast(string)get(baseUrl ~ "/api/selection"));
    assert(sel["mode"].str == "vertices",
        "expected vertices mode, got: " ~ sel["mode"].str);
    auto picked = sel["selectedVertices"].array;
    assert(picked.length == 1 && picked[0].integer == vid,
        format("same-batch undo→pick selected %s, expected [%d] — the "
               ~ "mid-batch pull-guard did not refresh the VBO before the pick",
               picked.to!string, vid));

    postJson("/api/reset", "");
    cmd("history.clear");
}

unittest { // 2. flush-site upload with no command-side display call
    postJson("/api/reset", "");
    settle();

    auto m0 = model();
    assert(gpuFaceVertCount() == expectedFaceVertCount(m0),
        "baseline face VBO does not match the base mesh");

    cmd("mesh.subdivide");
    settle(); // several --test frames: dispatch + flush + upload have run

    auto m1 = model();
    const long want = expectedFaceVertCount(m1);
    const long got  = gpuFaceVertCount();
    assert(want > expectedFaceVertCount(m0),
        "mesh.subdivide did not grow the face count — test setup broken");
    assert(got == want,
        format("face VBO holds %d verts, mesh needs %d — the flush-site "
               ~ "bus-driven upload did not run after mesh.subdivide",
               got, want));

    postJson("/api/reset", "");
    cmd("history.clear");
}
