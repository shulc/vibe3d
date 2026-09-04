// Asynchronous subpatch preview builds (task 1500).
//
// WHAT THIS FILE IS FOR, said plainly: the change it guards makes NO WORK GO
// AWAY. Same stencil table, same cost, bit-identical result. What it buys is
// that the window stops freezing while the build runs. So none of the rows
// below measure a speed-up, and one of them (`builds`/`workerBuildNs`)
// deliberately measures that the work is STILL BEING DONE.
//
// ---------------------------------------------------------------------------
// THE FIXTURE RULE THIS FILE OBEYS, and it was measured, not reasoned
// ---------------------------------------------------------------------------
//
// A row whose PREVIEW answer equals its CAGE answer is blind to asynchrony by
// construction. Task 1500's phase 0 ran the discriminator against
// `tests/test_hide_geometry_pick.d` and found exactly that: with the rebuild
// deferred by three seconds, the polygon row (`[1,3,5]`) and the vertex row
// (`[2..13]`) both stayed GREEN, because on that strip the preview and the
// cage give the same set. The only row that moved was EDGES —
// `[1,4,5,6,8,10,11,12,14,16,17,18]` (preview, 12) versus `[1,4..18]` (cage,
// 16). So the M-DET row below uses the edge lasso and nothing else, and the
// two expected sets are those two, verbatim.
//
// ---------------------------------------------------------------------------
// THE CONTRACT THIS FILE INTRODUCES for everyone else
// ---------------------------------------------------------------------------
//
// `httpServer.tickAll()` is NOT gated by the input barrier, on purpose — so
// `/api/reset`, `/api/command`, `/api/select`, `/api/pick` and
// `/api/subpatch/preview` all answer WHILE a build is in flight. The price is
// a new rule: A TEST THAT NEEDS THE LIMIT SURFACE MUST WAIT FOR
// `pending == false`. `waitPreviewSettled()` below is that wait. RECORDED
// input (`/api/play-events`, `--playback`) needs no such call: the barrier
// holds it, which is what M-DET witnesses.
import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import std.math   : fabs;
import std.algorithm : sort, max;
import core.thread : Thread;
import core.time   : msecs, MonoTime, dur;

void main() {}

alias BASE = testBaseUrl;


void cmd(string script) {
    auto r = postJson("/api/command", script);
    assert(r["status"].str == "ok", "/api/command " ~ script ~ " failed: " ~ r.toString);
}
void cmdId(string id) { cmd(`{"id":"` ~ id ~ `"}`); }

void resetApp() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

void selectMode(string mode, int[] indices) {
    immutable string tok = mode == "polygons" ? "polygon"
                         : mode == "edges"    ? "edge" : "vertex";
    cmd("select.typeFrom " ~ tok);
    string idx = "[";
    foreach (i, v; indices) { if (i) idx ~= ","; idx ~= v.to!string; }
    idx ~= "]";
    auto r = postJson("/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":` ~ idx ~ `}`));
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

void hidePolygons(int[] faces) {
    selectMode("polygons", faces);
    cmdId("mesh.hide");
}

void loadMesh(string json) {
    auto r = postJson("/api/load-mesh", json);
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);
}

void lookDownZ(double distance) {
    auto r = postJson("/api/camera", format(
        `{"azimuth":0.0,"elevation":0.0,"distance":%.3f,"focus":{"x":0,"y":0,"z":0}}`,
        distance));
    assert(r["status"].str == "ok", "/api/camera failed: " ~ r.toString);
}

struct Vp { int x, y, w, h; }
Vp viewport() {
    auto c = getJson("/api/camera");
    return Vp(cast(int)c["vpX"].integer, cast(int)c["vpY"].integer,
              cast(int)c["width"].integer, cast(int)c["height"].integer);
}

int[] selected(string key) {
    int[] r;
    foreach (v; getJson("/api/selection")[key].array) r ~= cast(int)v.integer;
    r.sort();
    return r;
}

// ---------------------------------------------------------------------------
// The async-state handle. ONE source for every number this file asserts on,
// the perf lane reads, and the indicator prints — so there is nowhere for two
// of them to disagree.
// ---------------------------------------------------------------------------
struct Prev {
    bool  active, pending, abandoned;
    long  generation, builds, discarded, pendingFrames;
    long  workerBuildNs, workerAllocBytes;
    long  workerBuildNsTotal, workerAllocBytesTotal;
    long  topologiesCreated, topologiesRetired;
    long  previewFaces, previewEdges;
    string indicator;
}

Prev prev() {
    auto j = getJson("/api/subpatch/preview");
    Prev p;
    p.active      = j["active"].type      == JSONType.true_;
    p.pending     = j["pending"].type     == JSONType.true_;
    p.abandoned   = j["abandoned"].type   == JSONType.true_;
    p.generation  = j["generation"].integer;
    p.builds      = j["builds"].integer;
    p.discarded   = j["discarded"].integer;
    p.pendingFrames = j["pendingFrames"].integer;
    p.workerBuildNs    = j["workerBuildNs"].integer;
    p.workerAllocBytes = j["workerAllocBytes"].integer;
    p.workerBuildNsTotal    = j["workerBuildNsTotal"].integer;
    p.workerAllocBytesTotal = j["workerAllocBytesTotal"].integer;
    p.topologiesCreated = j["topologiesCreated"].integer;
    p.topologiesRetired = j["topologiesRetired"].integer;
    p.previewFaces = j["previewFaces"].integer;
    p.previewEdges = j["previewEdges"].integer;
    p.indicator    = j["indicator"].str;
    return p;
}

void hold(long ms, long ceilingMs = 0) {
    auto r = postJson("/api/subpatch/hold",
        format(`{"ms":%d,"ceilingMs":%d}`, ms, ceilingMs));
    assert(r["status"].str == "ok", "/api/subpatch/hold failed: " ~ r.toString);
}

/// THE NEW CONTRACT, in one function. Anything that wants the LIMIT surface
/// (`/api/pick` in preview mode, `/api/gpu/face-vbo`) waits here first.
void waitPreviewSettled(int timeoutMs = 30_000) {
    foreach (_; 0 .. timeoutMs / 20) {
        if (!prev().pending) { Thread.sleep(60.msecs); return; }
        Thread.sleep(20.msecs);
    }
    assert(false, "subpatch preview build did not settle within "
                  ~ timeoutMs.to!string ~ " ms");
}

// The strip fixture, verbatim from tests/test_hide_geometry_pick.d — six quads
// in a row plus one occluded triangle behind quad 3. Copied rather than
// shared because the numbers this file asserts were MEASURED on exactly this
// arrangement (task 1500 phase 0), and a shared fixture that drifts would
// silently re-point them.
string stripScene() {
    string v = "[";
    foreach (i; 0 .. 7) {
        immutable double x = -1.5 + 0.5 * i;
        if (i) v ~= ",";
        v ~= format("[%.4f,-0.25,0.0],[%.4f,0.25,0.0]", x, x);
    }
    v ~= ",[0.10,-0.15,-1.0],[0.50,-0.15,-1.0],[0.30,0.15,-1.0]]";
    string f = "[";
    foreach (i; 0 .. 6) {
        if (i) f ~= ",";
        f ~= format("[%d,%d,%d,%d]", 2*i, 2*i + 2, 2*i + 3, 2*i + 1);
    }
    f ~= ",[14,15,16]]";
    return `{"vertices":` ~ v ~ `,"faces":` ~ f ~ `}`;
}

string lassoLog(Vp vp) {
    immutable int x0 = vp.x + 8,      y0 = vp.y + 8;
    immutable int x1 = vp.x + vp.w - 8, y1 = vp.y + vp.h - 8;
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":150.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":200.0,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":250.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":1,"yrel":0,"state":4,"mod":0}` ~ "\n" ~
        `{"t":300.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":1,"state":4,"mod":0}` ~ "\n" ~
        `{"t":350.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":-1,"yrel":0,"state":4,"mod":0}` ~ "\n" ~
        `{"t":400.0,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        vp.x, vp.y, vp.w, vp.h,
        x0, y0, x0, y0, x1, y0, x1, y1, x0, y1, x0, y1);
}

/// Post a recorded log and poll until the player says it finished.
/// `budgetMs` is generous on purpose: under the barrier the whole log waits
/// for the build, so the poll has to outlast the hold.
bool playAndWait(string log, int budgetMs = 12_000) {
    auto resp = post(BASE ~ "/api/play-events", log);
    assert(parseJSON(cast(string)resp)["status"].str == "success",
        "play-events failed: " ~ cast(string)resp);
    foreach (_; 0 .. budgetMs / 50) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.TRUE) {
            Thread.sleep(250.msecs);      // post-playback drain settle
            return true;
        }
        Thread.sleep(50.msecs);
    }
    return false;
}

/// Length, in floats, of the face position VBO as it stands ON THE GPU.
///
/// The size is the discriminator between "the cage is drawn" and "a limit
/// surface is drawn" (task 1730), and it is read back from GL rather than
/// inferred from any CPU-side flag — the whole point of that task is that a
/// flag and the buffers had come apart.
size_t faceVboFloats() {
    auto j = parseJSON(get(BASE ~ "/api/gpu/face-vbo"));
    auto p = "positions" in j;
    assert(p !is null && p.type == JSONType.array,
           "/api/gpu/face-vbo has no positions array: " ~ j.toString);
    return p.array.length;
}

/// The strip with every face subpatched and the preview LIVE.
void stripWithLivePreview() {
    resetApp();
    loadMesh(stripScene());
    lookDownZ(5.0);
    selectMode("polygons", [0, 1, 2, 3, 4, 5, 6]);
    cmdId("mesh.subpatch_toggle");
    selectMode("polygons", []);
    waitPreviewSettled();
    assert(prev().active, "setup: the preview must be live before the row starts");
}

immutable int[] kPreviewEdgeSet = [1, 4, 5, 6, 8, 10, 11, 12, 14, 16, 17, 18];
immutable int[] kCageEdgeSet    = [1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
                                   14, 15, 16, 17, 18];

// ===========================================================================
// M-DET — recorded input is not delivered into an unfinished preview
// ===========================================================================
//
// THE MUTATION IS A PRODUCT OF TWO CONDITIONS, and that is not pedantry: it
// is the correction of a claim the plan made and then withdrew. Deleting the
// barrier ALONE leaves this green, because a real async build of seven cage
// faces finishes inside one frame — measured at ~0.5 ms. Arming the hold
// ALONE is the ordinary supported scenario and is also green (that is the row
// below). Only (hold armed) x (barrier deleted) reddens, and the red is the
// CAGE's 16 edges where the preview's 12 are asserted.
unittest {
    stripWithLivePreview();

    // Hold RECEPTION. The worker still finishes normally, so `/api/reset`
    // and the join stay instant; what is delayed is the publish.
    hold(2000);
    scope(exit) hold(0);

    // Changing the HIDE mask changes which limit faces are kept, i.e. the
    // preview's index space — so `active` drops immediately and build #2 goes
    // out and is held.
    hidePolygons([0, 2, 4]);
    auto during = prev();
    assert(during.pending, "the hide must have dispatched a build: " ~ during.to!string);
    assert(!during.active,
        "the preview must stop participating in selection AT DISPATCH, not at "
        ~ "arrival — otherwise a stale trace picks against a live cage");

    selectMode("edges", []);
    assert(playAndWait(lassoLog(viewport())),
        "the lasso log never finished — the barrier is not bounded");

    auto got = selected("selectedEdges");
    assert(got == kPreviewEdgeSet,
        "edge lasso answered with the CAGE set instead of the PREVIEW set — "
        ~ "recorded input was delivered into an unfinished build. got "
        ~ got.to!string ~ ", want " ~ kPreviewEdgeSet.to!string);
    assert(!prev().pending, "the build must have landed by now");
}

// The FIRST half of M-DET's negative control: the hold ALONE is green.
// (The second half — the barrier alone — is shown in the task's `## Мутация`
// section, since it needs the barrier's `if` removed from the source.)
unittest {
    stripWithLivePreview();
    hold(0);
    hidePolygons([0, 2, 4]);
    waitPreviewSettled();
    selectMode("edges", []);
    assert(playAndWait(lassoLog(viewport())));
    auto got = selected("selectedEdges");
    assert(got == kPreviewEdgeSet,
        "control: with no hold the same scenario must give the preview set; got "
        ~ got.to!string);
}

// ===========================================================================
// M-ASYNC — the window EXISTS, is observable, and the main thread is alive
// ===========================================================================
//
// THE INJECTION POINT IS `/api/pick`, and the choice is not arbitrary: it is
// un-gated (a main-thread bridge, and `tickAll` is outside the barrier), it
// READS without selecting, and it already branches on
// `subpatchPreview.active ? preview : cage` — which is exactly the fork the
// window has to be able to show.
//
// `pendingFrames` is read from THIS route and not from `/api/frames`:
// `FrameProbe` is a no-op stub in the default build (perf_probe.d), so
// `frameCount` is identically zero in this lane and a check on it would be
// vacuous.
unittest {
    stripWithLivePreview();
    hold(2500);
    scope(exit) hold(0);

    auto before = prev();
    auto selBefore = getJson("/api/selection").toString;

    hidePolygons([0, 2, 4]);

    // (a) the main thread is alive and answering while the build is in flight
    auto a = prev();
    assert(a.pending, "no async window at all: " ~ a.to!string);

    // (b) frames are being drawn inside the window — the whole promise
    Thread.sleep(300.msecs);
    auto b = prev();
    assert(b.pending, "window closed too early to measure it");
    assert(b.pendingFrames > a.pendingFrames,
        "the window is frozen: pendingFrames did not advance ("
        ~ a.pendingFrames.to!string ~ " -> " ~ b.pendingFrames.to!string ~ ")");

    // (c) a reading pick answers, and answers in CAGE space
    auto vp = viewport();
    auto pick = getJson(format("/api/pick?x=%d&y=%d&engine=bvh",
                               vp.x + vp.w/2, vp.y + vp.h/2));
    immutable long fi = pick["faceIndex"].integer;
    assert(fi < 7, "a pick during the build window must answer in CAGE index "
                   ~ "space (the strip has 7 faces); got " ~ fi.to!string);

    hold(0);
    waitPreviewSettled();
    auto after = prev();
    assert(!after.pending, "build never landed");
    assert(after.builds == before.builds + 1,
        "exactly one build should have completed; "
        ~ before.builds.to!string ~ " -> " ~ after.builds.to!string);
    // THE WORK DID NOT GO AWAY. This task moves cost, it does not remove it.
    assert(after.workerBuildNs > 0,
        "workerBuildNs is zero — the build did not run on the worker thread, "
        ~ "i.e. the task silently went back to being synchronous");
    assert(getJson("/api/selection").toString == selBefore,
        "the hide must not have changed the selection under our feet");
}

// ===========================================================================
// M-SEL — a selection made INSIDE the window survives the arrival, byte-exact
// ===========================================================================
//
// The reason this can be asserted at all is the invariant the plan verified by
// reading every pick path: they all answer in CAGE indices. `gpu_select.d`
// translates through `*OriginGpu` (identity while the cage is loaded),
// `bvh_pick` fills `_triToFace` from the same map, and the lasso walks
// `trace.*Origin` and then calls `symmetricSelect*` on the CAGE. So an
// arriving preview has nothing to re-map and nothing to invalidate — and this
// row is what refuses a future "helpful" re-mapping at reception.
unittest {
    stripWithLivePreview();
    hold(2500);
    scope(exit) hold(0);

    hidePolygons([1, 3]);
    assert(prev().pending, "setup: a build must be in flight");

    selectMode("polygons", [0, 2, 4]);
    auto during = selected("selectedFaces");
    assert(during.length > 0, "setup: the in-window selection must be non-empty");

    hold(0);
    waitPreviewSettled();

    auto after = selected("selectedFaces");
    assert(after == during,
        "the selection made during the build changed when the preview landed: "
        ~ during.to!string ~ " -> " ~ after.to!string);
}

// ===========================================================================
// M-GEN-TOPO — a result built against a cage that has moved on is DISCARDED
// ===========================================================================
//
// The control is a second run of the same final state with no race in it. A
// receiver that installs without checking publishes a preview of the OLD cage
// — a different face count, and a `faceOrigin` that indexes past the new
// cage's `faces.length`.
unittest {
    // --- control: the un-raced answer -----------------------------------
    stripWithLivePreview();
    hidePolygons([0, 2, 4]);
    waitPreviewSettled();
    selectMode("polygons", []);
    cmdId("mesh.subdivide");
    waitPreviewSettled();
    immutable long controlFaces = prev().previewFaces;
    assert(controlFaces > 0, "control produced no preview");

    // --- the race --------------------------------------------------------
    stripWithLivePreview();
    hold(2500);
    scope(exit) hold(0);

    hidePolygons([0, 2, 4]);            // build #2 dispatched, held
    auto mid = prev();
    assert(mid.pending, "setup: build must be in flight");

    selectMode("polygons", []);
    cmdId("mesh.subdivide");            // cage topology changes UNDER the build

    hold(0);
    waitPreviewSettled();

    auto after = prev();
    // GEOMETRY FIRST, counter second, and the order is the point: the
    // `discarded` counter is written at the only site that could increment
    // it, so on its own it is close to a tautology. What actually says the
    // stale build did not get published is the limit-face count of the
    // preview that DID.
    assert(after.previewFaces == controlFaces,
        "the published preview is not the one the CURRENT cage asks for: got "
        ~ after.previewFaces.to!string ~ " limit faces, the un-raced control "
        ~ "gives " ~ controlFaces.to!string);
    assert(after.discarded > mid.discarded,
        "the stale result was not discarded (discarded "
        ~ mid.discarded.to!string ~ " -> " ~ after.discarded.to!string ~ ")");
}

// ===========================================================================
// M-GEN-POS — a version-silent move during the build does NOT publish a stale
//             surface
// ===========================================================================
//
// Positions are deliberately absent from the dispatch key: `positionsDirty` is
// raised on every drag frame, so a positions-sensitive key would mean a build
// that never completes while the user drags. What closes the hole instead is
// that the receiver ALWAYS re-runs the stencil evaluate against the LIVE cage
// before publishing. `/api/gpu/face-vbo` is the observable, and it is already
// used for exactly this purpose by test_subpatch_move.
unittest {
    resetApp();                       // cube; /api/transform works on it
    selectMode("polygons", []);
    cmdId("mesh.subpatch_toggle");
    waitPreviewSettled();

    double[3][] surfaceNow() {
        auto j = getJson("/api/gpu/face-vbo");
        double[3][] r;
        foreach (p; j["positions"].array) {
            auto a = p.array;
            r ~= [a[0].floating, a[1].floating, a[2].floating];
        }
        return r;
    }
    auto pre = surfaceNow();

    // Force a REBUILD (not a position refresh) and hold its reception, then
    // move the cage while it is in flight.
    hold(2500);
    scope(exit) hold(0);
    hidePolygons([5]);
    assert(prev().pending, "setup: a build must be in flight");

    selectMode("vertices", [0]);
    auto r = postJson("/api/command", commandBody("mesh.transform", `{"kind":"translate","delta":[0,3,0]}`));
    assert(r["status"].str == "ok", "/api/transform failed: " ~ r.toString);

    hold(0);
    waitPreviewSettled();

    auto post_ = surfaceNow();
    double maxD = 0;
    immutable size_t n = pre.length < post_.length ? pre.length : post_.length;
    foreach (i; 0 .. n) foreach (k; 0 .. 3) {
        immutable double d = fabs(pre[i][k] - post_[i][k]);
        if (d > maxD) maxD = d;
    }
    assert(maxD > 0.2,
        "the published surface is the PRE-move one — reception did not "
        ~ "re-evaluate positions from the live cage (max |delta| = "
        ~ maxD.to!string ~ ")");
}

// ===========================================================================
// M-LEAK — a discarded result gives its topology back
// ===========================================================================
//
// `osdc_topology_t` is the single most expensive object in the system. Under
// "last dispatch wins" nothing else will ever free a discarded one, so
// `created - retired` is the witness: the LRU holds at most 2, so anything
// above that is a leak per discarded Tab.
unittest {
    stripWithLivePreview();
    hold(400);
    scope(exit) hold(0);

    long discards = 0;
    foreach (i; 0 .. 5) {
        auto b = prev();
        // Flip the subpatch mask on ONE face: changes the sharpness vector,
        // hence the dispatch key, hence the in-flight result's fate.
        selectMode("polygons", [cast(int)i % 6]);
        cmdId("mesh.subpatch_toggle");
        Thread.sleep(80.msecs);
        selectMode("polygons", [cast(int)(i + 1) % 6]);
        cmdId("mesh.subpatch_toggle");
        waitPreviewSettled();
        discards += prev().discarded - b.discarded;
    }

    auto p = prev();
    assert(p.topologiesCreated > 0, "no topology was ever built");
    immutable long live = p.topologiesCreated - p.topologiesRetired;
    assert(live <= 2,
        "topologies are leaking: created " ~ p.topologiesCreated.to!string
        ~ ", retired " ~ p.topologiesRetired.to!string ~ ", live "
        ~ live.to!string ~ " (the LRU holds at most 2)");
}

// ===========================================================================
// M-DRAW — the cage is NEVER drawn while a rebuild is in flight (task 1730)
// ===========================================================================
//
// The flicker the owner reported in dogfood was two full VBO uploads that
// cancelled each other: `dispatchBuild` dropped `active`, the upload block saw
// `wantPreview == false` with `stateChanged == true` and uploaded the CAGE,
// and the arriving build uploaded the preview back. Between them the viewport
// showed polygons.
//
// WHAT IS OBSERVED, and why it is the right observable: `/api/gpu/face-vbo`
// reads back the actual face VBO on the GL thread, so its LENGTH answers "what
// is on screen" rather than "what the CPU thinks is active". A test keyed on
// `/api/subpatch/preview`'s `active` bit would pass on a build that drew the
// cage anyway — `active` is precisely the flag the fix stops the buffers from
// following.
//
// `hold(-1, huge)` is what makes this deterministic: the build never publishes
// and the ceiling never fires, so the in-flight window is as long as the test
// needs instead of the ~150 ms it lasts in life.
unittest {
    stripWithLivePreview();
    immutable size_t previewVbo = faceVboFloats();
    assert(previewVbo > 0, "setup: the preview VBO must be non-empty");

    // The cage's own VBO size, for a yardstick that is measured rather than
    // assumed. Toggling the preview off leaves the cage uploaded.
    selectMode("polygons", [0, 1, 2, 3, 4, 5, 6]);
    cmdId("mesh.subpatch_toggle");
    selectMode("polygons", []);
    waitPreviewSettled();
    assert(!prev().active, "setup: the preview must be off");
    immutable size_t cageVbo = faceVboFloats();
    assert(cageVbo != previewVbo,
        "setup is vacuous: cage and preview VBOs are the same size ("
        ~ cageVbo.to!string ~ "), so this test cannot tell them apart");

    // Back to a live preview, then wedge the next build.
    stripWithLivePreview();
    hold(-1, 600_000);                   // never publish, ceiling far away
    scope(exit) { hold(0, 15_000); waitPreviewSettled(); }

    hidePolygons([0, 2, 4]);             // a real topology change -> dispatch
    assert(prev().pending, "setup: the build must be in flight");

    // THE ASSERTION IS AGAINST `previewVbo`, NOT AGAINST `cageVbo`, and the
    // reason is a trap worth writing down: `hidePolygons` is the topology
    // change that triggers the dispatch, and hidden faces LEAVE THE VBO
    // (task 0613 consumes the Hide bit at upload time). So the cage uploaded
    // after the hide is a DIFFERENT size from the cage measured before it, and
    // `now != cageVbo` would be satisfied by the flicker itself. "The buffer
    // still holds the stale preview" is the property, and it is exact.
    //
    // Sampled over a stretch of frames rather than once: the flicker is a
    // TRANSIENT, and a single probe can land on either side of a one-frame
    // cage upload and call it clean.
    foreach (i; 0 .. 12) {
        immutable size_t now = faceVboFloats();
        assert(now == previewVbo,
            "frame sample " ~ i.to!string ~ ": the stale preview left the VBO "
            ~ "while a rebuild is in flight (" ~ now.to!string ~ " floats, "
            ~ "want the preview's " ~ previewVbo.to!string ~ "; the unhidden "
            ~ "cage measures " ~ cageVbo.to!string ~ ") — the flicker is back");
        Thread.sleep(40.msecs);
    }
    assert(prev().pending, "the build must still be held at the end");
}

// ===========================================================================
// M-DRAW-CEIL — and the freeze gives up at the SAME ceiling as the barrier
// ===========================================================================
//
// The control for M-DRAW, and it is the assertion that keeps the freeze from
// being a wedge. An unbounded freeze would hold the stale surface forever on a
// build that never finishes, and there is nothing to interrupt such a build
// with — the point of no return is inside the third-party stencil builder. So
// past the ceiling the freeze lifts and the cage comes back: a wedged build
// degrades to the pre-1730 flicker, never to a viewport that stopped
// answering. Without this case M-DRAW above would be satisfied by a fix that
// simply never lets go.
unittest {
    stripWithLivePreview();
    immutable size_t previewVbo = faceVboFloats();

    hold(-1, 300);                       // never publish; freeze expires at 300 ms
    scope(exit) { hold(0, 15_000); waitPreviewSettled(); }

    hidePolygons([0, 2, 4]);
    assert(prev().pending, "setup: the build must be in flight");

    // "The stale preview LEFT the buffer", for the same reason M-DRAW asserts
    // it stayed: the cage that comes back has three faces hidden and so is not
    // the size of any cage this test could have measured up front.
    bool freezeExpired = false;
    foreach (_; 0 .. 60) {               // up to ~3 s, well past the 300 ms bound
        if (faceVboFloats() != previewVbo) { freezeExpired = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(freezeExpired,
        "the freeze never expired: the stale preview (" ~ previewVbo.to!string
        ~ " floats) is still in the VBO although the build is wedged and its "
        ~ "ceiling is 300 ms — an unbounded freeze is a wedged viewport");
    assert(prev().pending, "reception is still held, so the build is still pending");
}

// ===========================================================================
// M-CEIL — the barrier is BOUNDED
// ===========================================================================
//
// A gate with no ceiling turns a build wedged inside the third-party stencil
// builder into a wedged lane. `ms:-1` holds reception forever, which is the
// only way a test can stand in for "the build never finishes"; the ceiling
// then has to deliver the input against the cage anyway.
unittest {
    stripWithLivePreview();
    hold(-1, 400);                       // never publish; barrier ceiling 400 ms
    scope(exit) { hold(0, 15_000); waitPreviewSettled(); }

    hidePolygons([0, 2, 4]);
    assert(prev().pending, "setup: the build must be held");

    selectMode("edges", []);
    auto t0 = MonoTime.currTime;
    assert(playAndWait(lassoLog(viewport()), 8_000),
        "the barrier never lifted — it is unbounded, and a build that does "
        ~ "not finish would wedge the lane");
    auto elapsed = (MonoTime.currTime - t0).total!"msecs";
    assert(elapsed >= 200,
        "the input was delivered without ever waiting — the ceiling cannot be "
        ~ "the reason this passed (elapsed " ~ elapsed.to!string ~ " ms)");
    // Delivered against the CAGE, which is the correct degraded answer.
    auto got = selected("selectedEdges");
    assert(got == kCageEdgeSet,
        "past the ceiling the input must be answered in CAGE space; got "
        ~ got.to!string ~ ", want " ~ kCageEdgeSet.to!string);
    assert(prev().pending, "reception is still held, so the build is still pending");
}

// ===========================================================================
// The indicator rises and falls with `pending`
// ===========================================================================
//
// WHAT THIS DOES AND DOES NOT COVER. It pins the TEXT LAW — the string is
// non-empty exactly while a build is in flight. It does NOT cover the DRAW:
// nothing in this codebase can read an ImGui label, so the overlay and the
// window-title suffix are unwitnessed by construction. That is stated here
// rather than implied by a green row.
unittest {
    stripWithLivePreview();
    assert(prev().indicator.length == 0,
        "the indicator must be down when no build is running");

    hold(1500);
    scope(exit) hold(0);
    hidePolygons([0, 2, 4]);
    auto during = prev();
    assert(during.pending);
    assert(during.indicator.length > 0,
        "the indicator must be up while a build is in flight");

    hold(0);
    waitPreviewSettled();
    assert(prev().indicator.length == 0,
        "the indicator must come back down when the build lands");
}
