// Task 0188 Stage R — stress/regression guard for the GET /api/toolpipe
// marshaling (Stage U) + the ACEN Local BFS dedup (Stage D5).
//
// HONEST FRAMING: after Stage U, GET /api/toolpipe is marshaled onto the
// main thread via `toolpipeBridge`, so the display path (listAttrs ->
// currentCenter -> computeCenter -> localCenterAndClustersCached) can no
// longer run concurrently with the main thread's own per-frame evaluate()
// over the SAME ACEN cluster cache — there is nothing left to race. That
// closure is BY CONSTRUCTION (the marshal), not something a test can prove
// from the outside. This test is therefore a CONSTRUCTION + NO-DEADLOCK /
// NO-TORN-RESPONSE regression guard, not a race-closure proof: it hammers
// GET /api/toolpipe in a tight loop while a real Local-mode interactive
// drag plays through /api/play-events, and asserts every response is a
// well-formed, finite ACEN packet — i.e. the bridge never hangs, never
// returns a torn/NaN center, and never 500s while the changed path is
// under load.
//
// Setup mirrors test_toolpipe_acen.d's Local-mode test (two disjoint,
// opposite cube faces -> 2 clusters) + drag_helpers' production drag path
// (the same buildDragLog + /api/play-events flow test_acen_softpin_settle.d
// and friends use for a real gizmo-handle drag).

import std.net.curl;
import std.json;
import std.math    : fabs;
import std.conv    : to;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

void lockCamera() {
    auto r = postJson("/api/camera",
        `{"azimuth":0.5,"elevation":0.4,"distance":3.0,`
      ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`);
    assert(r["status"].str == "ok", "camera lock failed: " ~ r.toString);
}

// Two disjoint, opposite cube faces (4 = y=+0.5, 5 = y=-0.5 — same pair
// test_toolpipe_acen.d uses) -> 2 Local clusters. Face 4's own centroid
// (0, 0.5, 0) is cluster 0's pivot.
void setupLocalTwoClusterScene() {
    postJson("/api/reset?empty=true", "");
    lockCamera();
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1");
    cmd("select.typeFrom polygon");
    auto sel = postJson("/api/select", `{"mode":"polygons","indices":[4,5]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    cmd("tool.set move on");
    cmd("actr.local");
}

Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// Parse the ACEN stage out of a GET /api/toolpipe response body and assert
// it's a well-formed, finite packet (no torn/NaN center, valid clusterCount).
// Returns the number of ACEN stages found (should be exactly 1) so the
// caller can also confirm the endpoint isn't silently returning an empty
// {"stages":[]} for the whole duration of the drag.
int assertWellFormedToolpipe(string body_) {
    JSONValue j;
    try {
        j = parseJSON(body_);
    } catch (Exception e) {
        assert(false, "GET /api/toolpipe returned unparseable JSON during "
            ~ "Local drag: " ~ e.msg ~ " -- body: " ~ body_);
    }
    auto stagesP = "stages" in j.object;
    assert(stagesP !is null, "toolpipe response missing 'stages': " ~ body_);
    int acenFound = 0;
    foreach (st; stagesP.array) {
        if (("task" in st.object) is null || st["task"].str != "ACEN") continue;
        acenFound++;
        auto attrs = st["attrs"];
        string[string] a;
        foreach (k, v; attrs.object) a[k] = v.str;
        assert("cenX" in a && "cenY" in a && "cenZ" in a && "clusterCount" in a,
            "ACEN attrs missing expected keys mid-drag: " ~ st.toString);
        float cx = a["cenX"].to!float;
        float cy = a["cenY"].to!float;
        float cz = a["cenZ"].to!float;
        assert(cx == cx && cy == cy && cz == cz,   // NaN check
            "ACEN center is NaN mid-drag: " ~ a["cenX"] ~ "," ~ a["cenY"]
            ~ "," ~ a["cenZ"]);
        int cc = a["clusterCount"].to!int;
        assert(cc >= 0, "ACEN clusterCount negative mid-drag: "
            ~ a["clusterCount"]);
    }
    return acenFound;
}

unittest { // hammer GET /api/toolpipe during a live Local-mode drag
    setupLocalTwoClusterScene();

    auto ci = getJson("/api/toolpipe/eval")["actionCenter"];
    assert(ci["clusterCenters"].array.length == 2,
        "expected 2 Local clusters, got "
        ~ ci["clusterCenters"].array.length.to!string);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    Vec3 pivot = evalPivot();   // cluster-0 (face 4) centroid

    // Grab the Y-arrow move handle and drag it a modest distance — enough
    // motion to keep the tool in an active drag across many frames, not so
    // much that it matters numerically (this test does not assert on the
    // resulting geometry, only on the concurrently-polled toolpipe reads).
    float size = gizmoSize(pivot, vp);
    Vec3 aStart = Vec3(pivot.x, pivot.y + size / 6.0f, pivot.z);
    Vec3 aEnd   = Vec3(pivot.x, pivot.y + size,         pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(aStart, vp, sx1, sy1), "Y-arrow start off-camera");
    assert(projectToWindow(aEnd,   vp, sx2, sy2), "Y-arrow end off-camera");
    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double sdx = sx2 - sx1, sdy = sy2 - sy1;
    double sLen = (sdx*sdx + sdy*sdy) ^^ 0.5;
    int px = 60;
    int x1 = x0 + cast(int)(px * sdx / sLen);
    int y1 = y0 + cast(int)(px * sdy / sLen);

    // Many small motion steps -> many frames -> a wide window during which
    // the main thread is busy processing the drag AND (post Stage U)
    // servicing toolpipeBridge ticks for our concurrent polls.
    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 80);

    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);

    int polls = 0;
    int acenSightings = 0;
    bool finished = false;
    foreach (i; 0 .. 2000) {   // generous cap; loop exits on "finished" well
                              // before this — a real hang would trip the
                              // run_test.d watchdog, not spin here forever.
        // The polled endpoint under test: hammer it while the drag plays.
        string body_ = cast(string)get(baseUrl ~ "/api/toolpipe");
        acenSightings += assertWellFormedToolpipe(body_);
        polls++;

        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) { finished = true; break; }
        Thread.sleep(dur!"msecs"(5));
    }
    assert(finished, "play-events did not finish -- possible deadlock in "
        ~ "toolpipeBridge under concurrent Local-drag load");
    assert(polls >= 20,
        "too few concurrent GET /api/toolpipe polls landed during the drag "
        ~ "window (" ~ polls.to!string ~ ") to be a meaningful stress guard");
    assert(acenSightings > 0,
        "ACEN stage never appeared in a single /api/toolpipe response "
        ~ "during the drag -- provider likely returned {\"stages\":[]} "
        ~ "throughout, which would defeat this test's purpose");

    // Final sanity: the endpoint is still healthy after the drag settles,
    // and the cluster partition still reflects the same 2-island selection
    // (drag translated the geometry but the mesh topology/selection that
    // determines cluster membership did not change).
    string finalBody = cast(string)get(baseUrl ~ "/api/toolpipe");
    assertWellFormedToolpipe(finalBody);
    auto finalCi = getJson("/api/toolpipe/eval")["actionCenter"];
    assert(finalCi["clusterCenters"].array.length == 2,
        "cluster count changed after the drag settled -- expected 2, got "
        ~ finalCi["clusterCenters"].array.length.to!string);
}
