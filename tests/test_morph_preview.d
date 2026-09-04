// The MEASURED preview (task 1069, plan Stage 7).
//
// Phase 0 drove the reference's GUI viewport and measured three things: the
// surface is drawn at BASE + DELTA while a morph is selected; it is ONE
// deformed mesh, not a base plus a ghost overlay; and POLYGON picking follows
// the drawn surface. Four boots, a 70x margin on the decisive per-vertex pixel
// shift, and the three drawn pixels bit-identical across three independent
// boots.
//
// This file is the vibe3d-side mirror of those results, plus the guard for the
// half that must NOT follow the morph: the geometry kernels.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.file   : remove, exists, readText;
import std.conv   : to;
import std.format : format;
import std.math   : fabs;
import core.thread : Thread;
import core.time   : dur;

void main() {}

alias kBase = testBaseUrl;


void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}
void runCmd(string id, string paramsJson) {
    auto j = postJson("/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`);
    assert(j["status"].str == "ok", id ~ " failed: " ~ j.toString);
}
void resetCube() {
    auto j = postJson("/api/command", commandBody("scene.reset"));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
}
void postSelect(string mode, int[] indices) {
    string idx = "[";
    foreach (i, v; indices) { if (i > 0) idx ~= ","; idx ~= v.to!string; }
    idx ~= "]";
    auto j = postJson("/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":` ~ idx ~ `}`));
    assert(j["status"].str == "ok", "/api/select failed: " ~ j.toString);
}
bool approxEq(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

/// The action centre's WORLD position — `CLAUDE.md` names ActionCenterStage
/// the single source of truth for the gizmo pivot, and `/api/toolpipe/eval`
/// reports it directly. A world position rather than a screen one: it is what
/// the stage actually computes, so the assertion names the quantity under test
/// instead of a projection of it.
double[3] actionCentre() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return [c[0].floating, c[1].floating, c[2].floating];
}

size_t vertexCount() {
    return getJson("/api/model")["vertices"].array.length;
}

double[3] modelVertex(size_t vi) {
    auto a = getJson("/api/model")["vertices"].array[vi].array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

// ==========================================================================

unittest { // (7b) THE GIZMO FOLLOWS THE PREVIEW.
           //
           // This is objection 8, and it is the assertion that a pick test
           // cannot stand in for: with the surface measured to draw morphed,
           // an action centre still reading base positions puts the gizmo
           // where the user is not looking. Leaving ActionCenterStage unrouted
           // leaves the PICK test below green and only this one red.
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    postSelect("vertices", [6]);
    cmd("tool.set move");
    Thread.sleep(dur!"msecs"(80));
    auto before = actionCentre();

    // Push vertex 6 a long way in the map. The base does not move.
    runCmd("mesh.morph.set", `{"name":"m","vert":6,"x":2.0,"y":0.0,"z":0.0}`);
    Thread.sleep(dur!"msecs"(120));
    auto after = actionCentre();

    // The selection is the single vertex 6, so its action centre IS its drawn
    // position: base (0.5,0.5,0.5) plus the delta (2,0,0).
    assert(approxEq(after[0], 2.5) && approxEq(after[1], 0.5)
        && approxEq(after[2], 0.5),
        format("the action centre must sit at the DRAWN position (2.5,0.5,0.5), "
             ~ "got (%.4f,%.4f,%.4f). An ActionCenterStage reading base "
             ~ "positions reports (0.5,0.5,0.5) here -- and the pick "
             ~ "assertions below stay GREEN while it does, which is exactly "
             ~ "why this needs its own test",
               after[0], after[1], after[2]));
    assert(!approxEq(before[0], after[0]),
        format("...and it must have MOVED: it was (%.4f,%.4f,%.4f)",
               before[0], before[1], before[2]));

    // ...and the BASE really did not move, so the gizmo followed the DRAWN
    // position rather than a geometry edit.
    auto v = modelVertex(6);
    assert(approxEq(v[0], 0.5) && approxEq(v[1], 0.5) && approxEq(v[2], 0.5),
        format("the base vertex must be untouched, got (%.4f,%.4f,%.4f)",
               v[0], v[1], v[2]));
    cmd("tool.set move off");
}

unittest { // (7a) PICKING FOLLOWS THE DRAWN SURFACE.
           //
           // The vibe3d mirror of Phase 0's polygon probe: a ray aimed at the
           // MORPHED corner resolves to a face; the same probe with the morph
           // target cleared does not (nothing is drawn out there).
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    // Move the corner far enough that its new position is clear of the cube's
    // own silhouette.
    runCmd("mesh.morph.set", `{"name":"m","vert":6,"x":2.0,"y":0.0,"z":0.0}`);
    postSelect("vertices", []);
    Thread.sleep(dur!"msecs"(120));

    // Sweep for a pixel that hits ONLY because of the morph: with the target
    // bound it hits, with it cleared it misses.
    int hitX = -1, hitY = -1;
    outer: for (int y = 60; y < 560; y += 12) {
        for (int x = 160; x < 790; x += 12) {
            auto j = parseJSON(get(format("%s/api/pick?x=%d&y=%d&engine=bvh",
                                          kBase, x, y)));
            if (j["faceIndex"].integer < 0) continue;
            // Candidate: now check the same pixel with NO morph bound.
            runCmd("mesh.morph.select", `{"name":""}`);
            Thread.sleep(dur!"msecs"(120));
            auto k = parseJSON(get(format("%s/api/pick?x=%d&y=%d&engine=bvh",
                                          kBase, x, y)));
            const bool missesWithoutMorph = k["faceIndex"].integer < 0;
            runCmd("mesh.morph.select", `{"name":"m"}`);
            Thread.sleep(dur!"msecs"(120));
            if (missesWithoutMorph) { hitX = x; hitY = y; break outer; }
        }
    }
    assert(hitX >= 0,
        "found no pixel that the MORPHED surface covers and the base does "
      ~ "not -- either the preview is not live, or the delta is too small to "
      ~ "clear the base silhouette and this test is inert");

    // Pin it: with the target bound that pixel resolves to a face.
    auto j = parseJSON(get(format("%s/api/pick?x=%d&y=%d&engine=bvh",
                                  kBase, hitX, hitY)));
    assert(j["faceIndex"].integer >= 0,
        "the morphed surface must be pickable at its DRAWN position");
}

unittest { // (7m2 guard / law L8) THE GEOMETRY KERNELS DO NOT SEE THE MORPH.
           //
           // Subdivide with a target bound must produce the same mesh as with
           // none. The morph is a display + aim concept; routing it into a
           // geometry kernel would make the base drift by the delta on every
           // topology op, and L8 is the measured statement that it must not.
    resetCube();
    postSelect("vertices", []);
    runCmd("mesh.subdivide", `{}`);
    const size_t nPlain = vertexCount();
    double[3][] plain;
    foreach (i; 0 .. nPlain) plain ~= modelVertex(i);

    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    runCmd("mesh.morph.set", `{"name":"m","vert":6,"x":2.0,"y":0.0,"z":0.0}`);
    postSelect("vertices", []);
    runCmd("mesh.subdivide", `{}`);
    const size_t nMorphed = vertexCount();

    assert(nPlain == nMorphed,
        format("subdivide with a morph target bound must give the SAME mesh: "
             ~ "%d vs %d vertices", nPlain, nMorphed));
    // EVERY vertex, not just one: a kernel that read the drawn positions
    // would move the morphed corner by 2.0 and drag its whole neighbourhood
    // with it through the subdivision averaging, and a single-vertex check
    // could sit outside that neighbourhood and see nothing.
    foreach (i; 0 .. nMorphed) {
        auto got = modelVertex(i);
        assert(approxEq(plain[i][0], got[0]) && approxEq(plain[i][1], got[1])
            && approxEq(plain[i][2], got[2]),
            format("subdivide must read the BASE, not the drawn position: "
                 ~ "vertex %d is (%.5f,%.5f,%.5f) with a target bound and "
                 ~ "(%.5f,%.5f,%.5f) without",
                   i, got[0], got[1], got[2],
                   plain[i][0], plain[i][1], plain[i][2]));
    }
}
