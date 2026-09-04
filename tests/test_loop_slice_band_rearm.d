// Task 1054 Phase 4 -- two of the plan's remaining items:
//
// (1) the scrub RAIL decision for `activationSeeds()`'s fallback branch
//     (`refreshSeedRail`/`bandFirstRail`, source/tools/slice/loop_slice_tool.d).
//     The Phase-3 review flagged that for a lone/disjoint band selection (no
//     interior edge -- the fallback grabs an ARBITRARY edge of the
//     lowest-index selected face, only to prove "there is something to cut"),
//     the drag rail could point a direction the cut never uses. DECIDED (not
//     deferred): when the fallback produced `seeds_`, the rail is now the
//     FIRST band cell's own resolved side -- an edge the walk actually cuts,
//     computed by the same `bandWalk` law the kernel commits. P1 pins this
//     against the debug-only `seedRailA`/`seedRailB` fields on
//     `/api/tool/state` (no UI control reads them -- see the field comment).
//
// (2) re-arm ROBUSTNESS across the `select` attribute hook (`onParamChanged`,
//     which already re-runs `rebuildCut()` while armed). P2: toggling
//     `select` OFF mid-arm on a lone/disjoint selection (whose latched
//     `seeds_` cannot collect a ring at all) degrades gracefully -- `built_`
//     goes false, the mesh reverts to baseline, `armed_` stays true -- and
//     toggling `select` back ON recovers the IDENTICAL cut, with no
//     stuck/corrupted state. TASK 1240 moved P2's degradation half to a NEW
//     case P2b: since the ring walk no longer refuses a seed with a non-quad
//     on one side, the flap mesh CAN be ring-cut, so the "nothing to collect"
//     branch is now reached only where there is no quad at all -- an
//     all-triangle fan. P2 keeps the toggle-robustness subject on the
//     original mesh with its answers re-measured; P2b keeps the degradation.
//
// P2 uses the non-quad-neighbour mesh from
// test_loop_slice_band_arm_nonquad.d (one quad + 4 triangle flaps, one on
// each edge) -- the base quad is the ONLY selected face, so the arm goes
// through `activationSeeds()`'s empty-interior fallback in both cases here.
//
// NOT covered here, and why: the plan also asks to check that the kernel's
// §3.8 silent "band forces ngon=false" downgrade does not desync `built_`
// mid-arm. Verified interactively (toggling `ngon` ON mid-arm on this exact
// scenario leaves `built_` true and the model byte-identical: 10V/6F/15E
// before and after) -- but NO automated assertion is added for it, because
// the mutation that would back one (deleting the kernel's `if (bandMode)
// ngon = false;` at source/mesh_ops/loop_slice.d) does NOT redden anything
// observable: band mode routes every cell through `emitNgonRingSplit` via
// its own `.band` flag, never `.ngon`, so the force-off line is dead code
// for the reachable (all-quad) path today -- confirmed by running that exact
// mutation, not asserted from the comment. This matches Phase 3's own log
// note on this line and the task brief's explicit instruction to keep the
// line without manufacturing false rigor around it. See the task log.

import http_client : testBaseUrl, getJson;
import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import std.math    : abs;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

alias BASE = testBaseUrl;

void resetScene() {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

void loadMesh(string body_) {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/load-mesh", body_));
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);
}

void cmd(string s) {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/command", s));
    assert(r["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ r.toString);
}

void postSelect(int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto r = parseJSON(cast(string) post(BASE ~ "/api/select",
        `{"mode":"polygons","indices":` ~ idxJson ~ `}`));
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}


void playAndSettle(string log) {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/play-events", log));
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    bool finished = false;
    foreach (_; 0 .. 200) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) { finished = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(finished, "play-events replay did not finish within 10s");
    Thread.sleep(150.msecs);   // settle (post-playback drain, CLAUDE.md flake note)
}

enum VPX = 150, VPY = 28, VPW = 650, VPH = 544;
enum CX  = VPX + VPW / 2, CY = VPY + VPH / 2;

string viewportLine() {
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                   VPX, VPY, VPW, VPH);
}

void clickArm() {
    string log = viewportLine() ~ "\n"
        ~ format(`{"t":10.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`, CX, CY) ~ "\n"
        ~ format(`{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY) ~ "\n"
        ~ format(`{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY);
    playAndSettle(log);
}

void loadFlapMesh() {
    resetScene();
    loadMesh(`{"vertices":[
        [-1,0,-1],[1,0,-1],[1,0,1],[-1,0,1],
        [0,1,-2],[2,1,0],[0,1,2],[-2,1,0]
    ],"faces":[
        [0,1,2,3],
        [0,1,4],
        [1,2,5],
        [2,3,6],
        [3,0,7]
    ]}`);
}

double num(JSONValue v) { return v.floating; }
bool near(double a, double b) { return abs(a - b) < 1e-3; }

unittest { // P1 -- fallback-case rail: `seedRailA`/`seedRailB` resolve to the
    // FIRST band cell's own side (face 0's local edge 2: verts (1,0,1)-(-1,0,1)),
    // NOT face 0's local edge 0 (verts (-1,0,-1)-(1,0,-1)) that the pre-fix
    // `seedRail(seeds_[0], ...)` would have picked from the "any" fallback's
    // first entry.
    loadFlapMesh();
    postSelect([0]);
    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool select 1");
    clickArm();

    auto st = getJson("/api/tool/state");
    assert(st["armed"].type == JSONType.true_, "arm click must succeed");
    assert(st["seedRailA"].array.length == 3 && st["seedRailB"].array.length == 3,
        "seedRailA/B must be populated once armed, got " ~ st.toString);

    auto ra = st["seedRailA"].array;
    auto rb = st["seedRailB"].array;
    V3 a = V3(num(ra[0]), num(ra[1]), num(ra[2]));
    V3 b = V3(num(rb[0]), num(rb[1]), num(rb[2]));

    V3 wantA = V3(1, 0, 1), wantB = V3(-1, 0, 1);     // face 0's local edge 2
    bool matchesFix = (near(a.x,wantA.x)&&near(a.y,wantA.y)&&near(a.z,wantA.z)
                     && near(b.x,wantB.x)&&near(b.y,wantB.y)&&near(b.z,wantB.z))
                    || (near(a.x,wantB.x)&&near(a.y,wantB.y)&&near(a.z,wantB.z)
                     && near(b.x,wantA.x)&&near(b.y,wantA.y)&&near(b.z,wantA.z));
    assert(matchesFix,
        "fallback-case rail should be the FIRST band cell's own resolved "
        ~ "side (face 0's local edge 2, (1,0,1)-(-1,0,1)), got a="
        ~ a.to!string ~ " b=" ~ b.to!string);

    // Negative half: the rail must NOT be face 0's local edge 0 (the "any"
    // fallback's first raw entry, (-1,0,-1)-(1,0,-1)) -- pins that the fix
    // actually changed which edge feeds the rail, not just that SOME rail
    // exists.
    V3 oldA = V3(-1, 0, -1), oldB = V3(1, 0, -1);
    bool matchesOld = (near(a.x,oldA.x)&&near(a.y,oldA.y)&&near(a.z,oldA.z))
                    || (near(a.x,oldB.x)&&near(a.y,oldB.y)&&near(a.z,oldB.z));
    assert(!matchesOld,
        "fallback-case rail must not be the OLD arbitrary-edge choice (face "
        ~ "0's local edge 0) -- got a=" ~ a.to!string);
}

struct V3 { double x, y, z; }

unittest { // P2 -- `select` toggle mid-arm degrades gracefully and recovers.
    loadFlapMesh();
    postSelect([0]);
    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool select 1");
    clickArm();

    auto st1 = getJson("/api/tool/state");
    assert(st1["armed"].type == JSONType.true_ && st1["built"].type == JSONType.true_,
        "initial band arm must succeed and build");
    auto m1 = getJson("/api/model");
    assert(m1["vertexCount"].integer == 10 && m1["faceCount"].integer == 6,
        "initial band cut should be 10V/6F, got "
        ~ m1["vertexCount"].integer.to!string ~ "V/" ~ m1["faceCount"].integer.to!string ~ "F");

    // Toggle OFF: TASK 1240 CHANGED WHAT HAPPENS HERE (ledger rows 27/53).
    // The latched fallback seeds used to collect NOTHING in ring mode -- a
    // seed with a non-quad on either side was refused outright -- so this
    // toggle was the "nothing to cut" degradation path. The refusal is gone:
    // the ring now starts from the quad side and the triangle flaps absorb
    // the terminating midpoints, so ring mode cuts this mesh too. `built_`
    // therefore stays TRUE across the toggle. What P2 still pins is the same
    // subject -- the toggle leaves no stuck or corrupt state.
    // The genuine degradation path (a selection with no quad anywhere) is
    // exercised by P2b below, so the coverage this reversal removed here is
    // not simply lost.
    cmd("tool.attr mesh.loopSliceTool select 0");
    auto st2 = getJson("/api/tool/state");
    assert(st2["armed"].type == JSONType.true_,
        "toggling select OFF mid-arm must not drop the tool's arm");
    assert(st2["built"].type == JSONType.true_,
        "toggling select OFF mid-arm must now BUILD the ring cut (the quad's "
        ~ "triangle neighbours absorb the terminating midpoints)");
    auto m2 = getJson("/api/model");
    assert(m2["vertexCount"].integer == 10 && m2["faceCount"].integer == 6,
        "select=off mid-arm should be the 10V/6F ring cut, got "
        ~ m2["vertexCount"].integer.to!string ~ "V/" ~ m2["faceCount"].integer.to!string ~ "F");
    // Watertight, not a T-junction: every triangle flap that borders the cut
    // took its midpoint into its own ring.
    assert(cast(int)m2["vertexCount"].integer
           - cast(int)m2["edgeCount"].integer
           + cast(int)m2["faceCount"].integer == 1,
        "ring cut on the flap mesh must keep the open sheet's Euler number "
        ~ "(V-E+F == 1), got "
        ~ (cast(int)m2["vertexCount"].integer - cast(int)m2["edgeCount"].integer
           + cast(int)m2["faceCount"].integer).to!string);

    // Toggle back ON: recovers the IDENTICAL cut as the original arm.
    cmd("tool.attr mesh.loopSliceTool select 1");
    auto st3 = getJson("/api/tool/state");
    assert(st3["armed"].type == JSONType.true_ && st3["built"].type == JSONType.true_,
        "toggling select back ON mid-arm must re-build the band cut");
    auto m3 = getJson("/api/model");
    assert(m3["vertexCount"].integer == 10 && m3["faceCount"].integer == 6,
        "select=on recovery should reproduce the 10V/6F band cut, got "
        ~ m3["vertexCount"].integer.to!string ~ "V/" ~ m3["faceCount"].integer.to!string ~ "F");
}

/// A triangle fan -- four triangles round a centre vertex, no quad anywhere.
void loadFanMesh() {
    resetScene();
    loadMesh(`{"vertices":[
        [-1,0,-1],[1,0,-1],[1,0,1],[-1,0,1],[0,0,0]
    ],"faces":[
        [0,1,4],
        [1,2,4],
        [2,3,4],
        [3,0,4]
    ]}`);
}

unittest { // P2b -- the degradation path P2 used to carry, on the mesh that
    // still triggers it after task 1240: a selection with NO QUAD ON EITHER
    // SIDE of any candidate seed. The ring walk has no quad frame to take its
    // p/q rails from, so `collectEdgeRing` still returns [] there -- that
    // refusal survived the 1240 relaxation on purpose. Band mode arms and
    // cuts; toggling `select` OFF degrades gracefully (armed stays true,
    // `built_` goes false, the mesh reverts to baseline); toggling back ON
    // recovers the identical cut.
    loadFanMesh();
    postSelect([0]);
    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool select 1");
    clickArm();

    auto st1 = getJson("/api/tool/state");
    assert(st1["armed"].type == JSONType.true_ && st1["built"].type == JSONType.true_,
        "band arm on an all-triangle fan must succeed and build");
    auto m1 = getJson("/api/model");
    assert(m1["vertexCount"].integer == 7 && m1["faceCount"].integer == 5,
        "band cut on the fan should be 7V/5F, got "
        ~ m1["vertexCount"].integer.to!string ~ "V/" ~ m1["faceCount"].integer.to!string ~ "F");

    cmd("tool.attr mesh.loopSliceTool select 0");
    auto st2 = getJson("/api/tool/state");
    assert(st2["armed"].type == JSONType.true_,
        "toggling select OFF mid-arm must not drop the tool's arm");
    assert(st2["built"].type == JSONType.false_,
        "with no quad on any candidate seed, ring mode has nothing to collect "
        ~ "and must leave built=false");
    auto m2 = getJson("/api/model");
    assert(m2["vertexCount"].integer == 5 && m2["faceCount"].integer == 4,
        "select=off mid-arm should revert to the 5V/4F fan baseline, got "
        ~ m2["vertexCount"].integer.to!string ~ "V/" ~ m2["faceCount"].integer.to!string ~ "F");

    cmd("tool.attr mesh.loopSliceTool select 1");
    auto st3 = getJson("/api/tool/state");
    assert(st3["armed"].type == JSONType.true_ && st3["built"].type == JSONType.true_,
        "toggling select back ON mid-arm must re-build the band cut");
    auto m3 = getJson("/api/model");
    assert(m3["vertexCount"].integer == 7 && m3["faceCount"].integer == 5,
        "select=on recovery should reproduce the 7V/5F band cut, got "
        ~ m3["vertexCount"].integer.to!string ~ "V/" ~ m3["faceCount"].integer.to!string ~ "F");
}
