// Task 1906 stage 2a — THE MID-BATCH DISPLAY PULL GUARD AFTER A COMMAND THAT
// PUBLISHES WITHOUT DELIVERING.
//
// ===========================================================================
// WHAT THIS PINS
// ===========================================================================
// Since stage 2a `ensureDisplayCurrent` — the pull guard in front of every VBO
// reader that can run BEFORE a frame's flush — no longer pulls
// a per-frame pending word. It compares a `(mesh address, display-class bus
// epoch)` stamp. Since stage 3 the epoch is advanced by exactly ONE thing: a
// SYNCHRONOUS bus delivery, which always names its subject. (Stage 2a had a
// second advancer — a per-layer feed at the top of the flush block, re-supplying
// `Mesh.pendingChanges_` where the address was known; stage 3 deleted the drain
// and the feed together.) Every pull-guard call site runs BEFORE the flush
// block, which is why the second advancer never rescued this cell anyway.
//
// So a command that MUTATES the mesh and only `noteChange`s — accumulate, no
// delivery — leaves the guard with nothing to react to for the rest of the
// frame, and a VBO reader in the same event batch renders the PREVIOUS
// geometry. `file.load` was such a command: measured at review time it produced
// ZERO subject-carrying deliveries, only the subject-less per-frame aggregate
// that `mesh_dirty` deliberately ignores. `source/commands/file/load.d`'s two
// tails are `publishChange` now; this file is the witness for the apply tail.
//
// ===========================================================================
// WHY THE RIG LOOKS LIKE THIS — three ways it could have been born inert
// ===========================================================================
//   * THE MUTATION MUST BE DELIVERED BY AN EVENT, NOT BY HTTP. The frame runs
//     `tickEventPlayer()` (which dispatches recorded events, pull guards and
//     all) BEFORE `httpServer.tickAll()` (which services command bridges), and
//     the HTTP accept loop is SINGLE-THREADED with `handleClient` inline — so
//     two bridge requests can never be pending in the same tick, and an HTTP
//     command can never be followed by an HTTP VBO read inside its own frame.
//     `Ctrl+Shift+Z` (history.redo) re-applies `file.load` from inside the
//     event batch, which is the only way to get a reader after it in the same
//     frame.
//   * THE MESH ADDRESS MUST NOT CHANGE. The guard's stamp carries the mesh
//     address, so any change of the primary layer mismatches it and re-services
//     — which is why a document-replacing `.v3d` load is NOT the
//     discriminating cell even though
//     it publishes exactly the same way. A SINGLE-PART interchange import
//     (`.obj` here) mutates `*mesh` IN PLACE, so the address term cannot
//     rescue it and only the epoch decides.
//   * THE PIXEL MUST BE ANSWERABLE ONLY BY THE NEW GEOMETRY. The loaded cube is
//     deliberately much smaller than the base cube, so its vertices project
//     well inside the base cube's silhouette and far from every base-cube
//     vertex. `assertPixelIsLoadedMeshOnly` measures that separation instead of
//     assuming it, and the FIRST unittest block below is the empirical control:
//     the same pixel, with the base cube live, selects NOTHING.
//
// ANTI-VACUITY, THE TIMESTAMPS: the discriminating power lives entirely in the
// event log. The redo keydown/keyup and the pick mousemotion/down/up are
// authored with IDENTICAL timestamps so the player posts them in ONE tick and
// the app dispatches them in ONE frame, with no flush (and therefore no
// bus-driven upload) between the redo and the pick. Spread them out and the
// flush uploads the reloaded mesh anyway and this file asserts nothing. Do not
// "clean up" the timestamps into a spaced sequence.
//
// NOT A CALL-COUNT CHECK. A blind guard and a working one make the same number
// of calls down the same code path; only WHICH GEOMETRY the pick can see
// separates them.
//
// Runner: ./run_test.d test_bus_display_guard_after_load

import std.net.curl : get, post;
import std.json;
import std.format : format;
import std.conv   : to;
import std.math   : sqrt;
import std.file   : write, exists, remove;
import std.string : indexOf;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      playAndWait, Viewport, Vec3;

void main() {}

enum baseUrl = "http://localhost:8080";

/// The temp `.obj` carries the port so two workers can never collide on it.
/// `baseUrl`'s port is what `run_test.d` rewrote for THIS worker.
string objPath() {
    const i = baseUrl.indexOf(":", "http://".length);
    return "/tmp/vibe3d-test-bus-display-guard-" ~ baseUrl[i + 1 .. $] ~ ".obj";
}

/// A cube of half-extent 0.2 at the origin. Small on purpose — see the header:
/// every vertex of it projects inside the base cube's silhouette and far from
/// the base cube's own vertices, which is what makes a stale VBO unable to
/// answer the pick.
enum string kSmallCubeObj = `# vibe3d test fixture (task 1906): half-extent 0.2 cube
v -0.2 -0.2 -0.2
v 0.2 -0.2 -0.2
v 0.2 0.2 -0.2
v -0.2 0.2 -0.2
v -0.2 -0.2 0.2
v 0.2 -0.2 0.2
v 0.2 0.2 0.2
v -0.2 0.2 0.2
f 1 4 3 2
f 5 6 7 8
f 1 5 8 4
f 2 3 7 6
f 4 8 7 3
f 1 2 6 5
`;

void postJson(string path, string body_) {
    auto resp = cast(string)post(baseUrl ~ path, body_);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok" || j["status"].str == "success",
        path ~ " failed: " ~ resp);
}

void cmd(string id, string params = "") {
    postJson("/api/command", params.length
        ? format(`{"id":"%s","params":%s}`, id, params)
        : format(`{"id":"%s"}`, id));
}

JSONValue model() { return parseJSON(cast(string)get(baseUrl ~ "/api/model")); }

int[] selectedVertices() {
    auto j = parseJSON(cast(string)get(baseUrl ~ "/api/selection"));
    int[] r;
    foreach (v; j["selectedVertices"].array) r ~= cast(int)v.integer;
    return r;
}

/// Post-command settle: an HTTP command's reply returns before the frame's
/// flush runs, so give the main loop a few --test frames.
void settle(int ms = 250) { Thread.sleep(dur!"msecs"(ms)); }

Vec3 vertOf(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return Vec3(cast(float)a[0].floating,
                cast(float)a[1].floating,
                cast(float)a[2].floating);
}

/// The vertex of `m` NEAREST the camera, and its window pixel. Nearest-to-eye
/// on a convex body is never occluded, so it is pickable under any occlusion
/// rule — the same choice `test_display_bus_refresh` makes, for the same
/// reason.
void nearestVertexPixel(JSONValue m, out int vid, out int px, out int py) {
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    vid = -1;
    float best = float.max;
    foreach (i; 0 .. m["vertices"].array.length) {
        Vec3 w = vertOf(m, i);
        Vec3 d = w - cam.eye;
        const float d2 = d.x * d.x + d.y * d.y + d.z * d.z;
        if (d2 >= best) continue;
        float sx, sy;
        if (!projectToWindow(w, vp, sx, sy)) continue;
        best = d2; vid = cast(int)i; px = cast(int)sx; py = cast(int)sy;
    }
    assert(vid >= 0, "no projectable vertex in the loaded mesh");
    assert(px > cam.vpX + 20 && px < cam.vpX + cam.width  - 20
        && py > cam.vpY + 20 && py < cam.vpY + cam.height - 20,
        format("the pick pixel (%d,%d) is not comfortably inside the viewport "
             ~ "(%d,%d %dx%d) — the rig aims at nothing", px, py,
               cam.vpX, cam.vpY, cam.width, cam.height));
}

/// THE ANTI-VACUITY MEASUREMENT. A stale VBO holding the BASE cube must be
/// unable to answer this pixel, and that is a property of the two geometries,
/// not something to assume: the vertex picker searches a 4 px radius of the ID
/// buffer, so anything under ~30 px would make "no hit" ambiguous.
void assertPixelIsLoadedMeshOnly(int px, int py) {
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    // The reset cube, written out rather than read back: at this point the
    // live mesh is the LOADED one, so /api/model cannot supply it.
    static immutable float[3][8] kBaseCube = [
        [-0.5f, -0.5f, -0.5f], [0.5f, -0.5f, -0.5f],
        [ 0.5f,  0.5f, -0.5f], [-0.5f, 0.5f, -0.5f],
        [-0.5f, -0.5f,  0.5f], [0.5f, -0.5f,  0.5f],
        [ 0.5f,  0.5f,  0.5f], [-0.5f, 0.5f,  0.5f]];
    float worst = float.max;
    foreach (b; kBaseCube) {
        float sx, sy;
        if (!projectToWindow(Vec3(b[0], b[1], b[2]), vp, sx, sy)) continue;
        const float d = sqrt((sx - px) * (sx - px) + (sy - py) * (sy - py));
        if (d < worst) worst = d;
    }
    assert(worst > 30.0f,
        format("the pick pixel (%d,%d) is only %.1f px from a BASE-cube vertex "
             ~ "— a stale VBO could answer it, and then a green here would "
             ~ "mean nothing", px, py, worst));
}

/// reset → clean history → single-part `.obj` import (mutates `*mesh` IN
/// PLACE) → HTTP undo. Leaves: the base cube live, the import on the redo
/// stack, and the loaded mesh's nearest-vertex pixel in `px`/`py`.
void armLoadedThenUndone(out int vid, out int px, out int py) {
    write(objPath(), kSmallCubeObj);
    postJson("/api/reset", "");
    cmd("history.clear");
    settle();
    const long baseVerts = model()["vertexCount"].integer;

    cmd("file.load", format(`{"path":%s}`, JSONValue(objPath()).toString));
    settle();
    auto loaded = model();
    nearestVertexPixel(loaded, vid, px, py);
    assertPixelIsLoadedMeshOnly(px, py);
    const float lx = vertOf(loaded, vid).x;
    assert(lx > -0.45f && lx < 0.45f,
        format("PREMISE: the imported cube did not land at half-extent 0.2 "
             ~ "(vertex %d has x=%.3f) — the fixture or the OBJ importer "
             ~ "changed and the separation measured above is about the wrong "
             ~ "geometry", vid, lx));

    cmd("history.undo");
    settle();
    assert(model()["vertexCount"].integer == baseVerts,
        "PREMISE: undo did not put the base cube back, so the redo below is "
      ~ "not the transition this file is about");
}

/// The event batch: `Ctrl+Shift+Z` (history.redo) and the pick, ALL at the same
/// timestamp so they land in ONE frame. See the header's anti-vacuity note.
string sameFrameRedoAndPickLog(int px, int py) {
    auto cam = fetchCamera();
    enum double t = 50.0;
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
                  cam.vpX, cam.vpY, cam.width, cam.height)
         // sym 122 = 'z'; mod 65 = KMOD_LCTRL | KMOD_LSHIFT
         ~ format(`{"t":%.3f,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":65,"repeat":0}` ~ "\n", t)
         ~ format(`{"t":%.3f,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":65,"repeat":0}` ~ "\n", t)
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n", t, px, py)
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", t, px, py)
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", t, px, py);
}

// ===========================================================================
// THE CONTROL — IT RUNS FIRST, AND THE ORDER IS THE POINT.
//
// The same pixel, the same batch shape, but WITHOUT the redo: with the base
// cube live AND on the GPU, the click must select NOTHING. That is what turns
// the main block's `[vid]` from "a pick happened" into "a pick that only the
// reloaded geometry can answer".
//
// It is written above the main block deliberately: druntime stops a MODULE at
// its first failed assert, so a control placed after the block it controls
// never executes under exactly the mutation it exists to answer for, and its
// silence would be an artefact of the abort. Do not reorder these two blocks.
// ===========================================================================
unittest {
    int vid, px, py;
    armLoadedThenUndone(vid, px, py);

    auto cam = fetchCamera();
    enum double t = 50.0;
    playAndWait(
        format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
               cam.vpX, cam.vpY, cam.width, cam.height)
      ~ format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n", t, px, py)
      ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", t, px, py)
      ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", t, px, py));
    settle();

    assert(selectedVertices().length == 0,
        format("CONTROL: clicking (%d,%d) with the BASE cube live selected %s. "
             ~ "That pixel is supposed to be answerable only by the imported "
             ~ "cube — if the base cube can answer it, the main block below is "
             ~ "green whether the display guard works or not",
               px, py, selectedVertices().to!string));

    postJson("/api/reset", "");
    cmd("history.clear");
    if (exists(objPath())) remove(objPath());
}

// ===========================================================================
// THE WITNESS. `Ctrl+Shift+Z` re-applies the single-part `.obj` import from
// inside the event batch — the command mutates `*mesh` in place and its tail is
// the ONLY thing that can tell the bus so. The click in the same batch reads
// the GPU ID buffer through `ensureDisplayCurrent`.
//
// MUTATION (measured 2026-08-25): turn `source/commands/file/load.d`'s apply
// tail back into `active.noteChange(MeshChangeAll)` and this block reports
//   selected [] — expected [<vid>]
// because the guard reads its own stamp as current (`matched=true`, epoch
// unmoved) and the ID buffer still rasterises the base cube. With
// `publishChange` the delivery lands between the redo and the pick, the guard
// mismatches, `refreshDisplay` uploads the imported cube, and the pick lands.
// ===========================================================================
unittest {
    int vid, px, py;
    armLoadedThenUndone(vid, px, py);

    playAndWait(sameFrameRedoAndPickLog(px, py));
    settle();

    // The redo itself must have landed, or the selection assert below is
    // asserting against the wrong mesh.
    auto after = model();
    const float rx = vertOf(after, vid).x;
    assert(rx > -0.45f && rx < 0.45f,
        format("PREMISE: Ctrl+Shift+Z did not redo the import (vertex %d is at "
             ~ "x=%.3f, i.e. still the base cube) — the redo binding or the "
             ~ "history path changed, and the selection assert below would be "
             ~ "meaningless", vid, rx));

    auto sel = selectedVertices();
    assert(sel.length == 1 && sel[0] == vid,
        format("the same-batch pick after the redone import selected %s, "
             ~ "expected [%d]. The mid-batch pull guard did not refresh the "
             ~ "GPU buffers, so the ID buffer still holds the PRE-import mesh "
             ~ "— i.e. the command mutated the mesh and told the change bus "
             ~ "nothing (a `noteChange` tail never delivers, and since stage "
             ~ "2a the guard keys on the bus epoch, not on a pending word)",
               sel.to!string, vid));

    postJson("/api/reset", "");
    cmd("history.clear");
    if (exists(objPath())) remove(objPath());
}
