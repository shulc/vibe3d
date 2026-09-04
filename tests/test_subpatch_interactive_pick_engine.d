// Task 1540, option C — while a subpatch preview is LIVE the interactive face
// pick answers from the GPU ID buffer instead of the BVH, because installing a
// preview moves both terms of the BVH cache key and the next hover pick would
// otherwise pay a full construction over the LIMIT surface (measured 1588.9 ms
// of a 1719.6 ms frame at grid n=316; see the comment at app.d's pickFaces).
//
// WHAT THIS FILE PINS, and it is deliberately narrower than the change:
// the INTERACTIVE path — a real click delivered through /api/play-events —
// still answers in CAGE face indices that agree with the BVH oracle while a
// preview is active. That is the obligation option C has to discharge, because
// the two engines reach a cage index by DIFFERENT routes: the GPU one
// translates a preview id through `gpu.faceOriginGpu` after readback, the BVH
// one folds the same map into `_triToFace` at build time. A C that pointed the
// GPU picker at the wrong mesh, or that lost the translation, reddens here.
//
// WHAT IT DOES NOT PIN, said out loud so nobody reads more into a green:
// the ENGINE CHOICE ITSELF. Both engines are equivalent by construction and by
// `tests/test_bvh_pick_equivalence.d`, so reverting option C leaves every
// assertion below GREEN — this file cannot tell which engine answered. The
// choice is observable only through `Cat.bvhRebuild` / `Cat.bvhRebuildEnter`,
// which report `{}` outside the `perf` buildType, so it is gated in the PERF
// lane instead: `tools/perf/run.d frames tab-cold` asserts F-I11 (no BVH
// construction over the limit surface). Two lanes, two halves, neither
// pretending to be the other.
//
// Run via: ./run_test.d subpatch_interactive_pick_engine

import http_client : testBaseUrl, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv    : to;
import std.stdio   : writeln, writefln;
import std.format  : format;
import core.thread : Thread;
import core.time   : dur;

void main() {}

alias BASE = testBaseUrl;

// The viewport rect the replayed pixels are mapped through.
enum int VP_X = 150, VP_Y = 28, VP_W = 650, VP_H = 544;

void waitPlayerIdle() {
    for (int i = 0; i < 200; ++i) {
        auto s = parseJSON(get(BASE ~ "/api/play-events/status"));
        auto f = "finished" in s;
        if (f is null || f.type != JSONType.FALSE) {
            Thread.sleep(dur!"msecs"(120));
            return;
        }
        Thread.sleep(dur!"msecs"(10));
    }
}


/// Empty the polygon selection. `/api/select` with an empty index list rather
/// than a command id: there is no `select.clear` in the registry, and a click
/// that lands on a face already selected would otherwise be indistinguishable
/// from one that selected nothing.
void clearSelection() {
    auto r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[]}`));
    assert("error" !in r, "/api/select clear failed: " ~ r.toString);
}

void runCmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
           "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void setCamera(float az, float el, float dist) {
    auto r = postJson("/api/camera",
        format(`{"azimuth":%.4f,"elevation":%.4f,"distance":%.4f}`, az, el, dist));
    assert("error" !in r, "/api/camera failed: " ~ r.toString);
}

/// The BVH oracle. `/api/pick?engine=bvh` reaches `BvhPick.pickFace` directly
/// and is NOT routed through the pickFaces engine decision, which is exactly
/// what makes it usable as the reference for that decision.
int oracleBvh(int x, int y) {
    return parseJSON(get(format(BASE ~ "/api/pick?x=%d&y=%d&engine=bvh", x, y)))
           ["faceIndex"].integer.to!int;
}

int[] selectedFaces() {
    auto j = parseJSON(get(BASE ~ "/api/selection"));
    // `selectedFaces`, not `faces` — /api/selection publishes three parallel
    // arrays (selectedVertices / selectedEdges / selectedFaces) and a missing
    // key here reads as "nothing selected" on every click, which is a green
    // this file cannot distinguish from a broken pick.
    auto p = "selectedFaces" in j;
    if (p is null || p.type != JSONType.array) return [];
    int[] out_;
    foreach (v; p.array) out_ ~= v.integer.to!int;
    return out_;
}

long faceCount() {
    auto j = parseJSON(get(BASE ~ "/api/layers"));
    return j["layers"].array[0]["faceCount"].integer;
}

/// A single LMB click at a window pixel, replayed through the event player so
/// it travels the SAME path a user's click does — `pickFaces` included. A
/// direct /api/pick would bypass the very branch under test.
void clickAt(int wx, int wy) {
    // The VIEWPORT line the player maps every replayed pixel through. The key
    // names are `vpX/vpY/vpW/vpH` — a nested {"viewport":{…}} object is
    // accepted by the JSON parser and silently ignored by the player, which
    // leaves every click at the default rect and selects nothing.
    string log = format(
        `{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}` ~ "\n", VP_X, VP_Y, VP_W, VP_H);
    foreach (i; 0 .. 3)
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,`
                      ~ `"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
                      30.0 + i * 10.0, wx, wy);
    log ~= format(`{"t":80.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,`
                  ~ `"y":%d,"clicks":1,"mod":0}` ~ "\n", wx, wy);
    log ~= format(`{"t":120.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,`
                  ~ `"y":%d,"clicks":1,"mod":0}` ~ "\n", wx, wy);
    postJson("/api/play-events", log);
    waitPlayerIdle();
    Thread.sleep(dur!"msecs"(140));   // post-playback drain, see the skill
}

void resetFixture() {
    waitPlayerIdle();
    post(BASE ~ "/api/command", commandBody("scene.reset"));
    Thread.sleep(dur!"msecs"(120));
    runCmd("select.typeFrom polygon");
}

// ---------------------------------------------------------------------------
// A click under a LIVE preview selects the cage face the oracle names.
//
// The cube is the fixture on purpose here and it is not the facing trap from
// CLAUDE.md: nothing below asserts a VISIBILITY rule. What is asserted is that
// two engines agree on an INDEX, and for that a closed solid is fine — the
// discriminator is the index space (cage vs limit), not which side is culled.
// MUTATION, run and recorded rather than predicted — and the prediction was
// wrong, which is why it is written down. Deleting the `faceOriginGpu`
// translation in `gpu_select.d` reddens this file at
// "expected exactly one selected face, got []", NOT at the `< faceCount`
// assertion: `pick` already bounds-checks the translated index against
// `mesh.faces.length`, so a raw limit id (up to 4x the cage range at level 1)
// is rejected inside the picker and the click selects nothing at all. The
// range assertion is kept for the mutation that removes THAT bounds check —
// it is a second guard, not the first one.
// ---------------------------------------------------------------------------
unittest {
    resetFixture();
    setCamera(0.5f, 0.4f, 3.0f);

    immutable long cageFaces = faceCount();
    assert(cageFaces > 0, "fixture has no faces");

    runCmd("mesh.subpatch_toggle");
    Thread.sleep(dur!"msecs"(400));      // preview build + GPU upload land

    // Sample a few pixels around the centre rather than one: a single pixel
    // that happens to miss would make this vacuous, and a single pixel that
    // hits proves nothing about the mapping's range.
    immutable int cx = VP_X + VP_W / 2, cy = VP_Y + VP_H / 2;
    immutable int[2][5] px = [[cx, cy], [cx - 60, cy], [cx + 60, cy],
                              [cx, cy - 50], [cx, cy + 50]];

    int hits = 0;
    foreach (p; px) {
        immutable int want = oracleBvh(p[0], p[1]);
        if (want < 0) continue;          // a miss pixel says nothing here
        ++hits;

        clearSelection();
        clickAt(p[0], p[1]);
        auto got = selectedFaces();

        assert(got.length == 1,
               format("preview click at (%d,%d): expected exactly one selected "
                      ~ "face, got %s", p[0], p[1], got));
        assert(got[0] < cageFaces,
               format("preview click at (%d,%d) selected face %d, which is "
                      ~ "outside the CAGE range [0,%d) — the preview index was "
                      ~ "not translated through faceOriginGpu",
                      p[0], p[1], got[0], cageFaces));
        assert(got[0] == want,
               format("preview click at (%d,%d): interactive path selected "
                      ~ "face %d, BVH oracle says %d", p[0], p[1], got[0], want));
    }
    assert(hits >= 3,
           format("only %d of %d sample pixels hit the mesh — the fixture "
                  ~ "cannot exhibit the property", hits, px.length));

    runCmd("mesh.subpatch_toggle");      // leave the document as we found it
    Thread.sleep(dur!"msecs"(200));
    writeln("PASS interactive face pick agrees with the BVH oracle under a live preview");
}

// ---------------------------------------------------------------------------
// The cage path is unchanged. Option C only re-routes while `active` is true,
// so this is the control: with NO preview the same clicks must still land on
// the same faces. Without it, "the interactive pick works" would be asserted
// only in the state the change touched.
// ---------------------------------------------------------------------------
unittest {
    resetFixture();
    setCamera(0.5f, 0.4f, 3.0f);

    immutable long cageFaces = faceCount();
    immutable int cx = VP_X + VP_W / 2, cy = VP_Y + VP_H / 2;

    immutable int want = oracleBvh(cx, cy);
    assert(want >= 0, "centre pixel should hit the cage");

    clearSelection();
    clickAt(cx, cy);
    auto got = selectedFaces();
    assert(got.length == 1 && got[0] == want && got[0] < cageFaces,
           format("cage click: selected %s, oracle says %d", got, want));

    writeln("PASS interactive face pick unchanged with no preview");
}
