// test_viewport_follower_pick.d — reproduces the follower-cell mispick bug
// described in doc/tasks/work/0181-viewport-camera-single-source.md.
//
// `ViewportManager.resolvedSnapshot(id)` computes the follow-resolved camera
// (focus/distance/azimuth/elevation via resolveFollow) and, today, writes it
// back into the cell's `View.eye/view/proj` fields. `View.viewport()` writes
// the SAME fields from the cell's RAW OWN transform. Any command that calls
// `view.viewport()` directly (a "bypass site") on a linked-follower cell
// therefore recomputes the WRONG matrices from the cell's own (unfollowed)
// focus/distance/az/el — `mesh.screenSlice` is one such bypass
// (commands/mesh/screen_slice.d).
//
// Both constructions below build the IDENTICAL 320x480 SplitH-left cell
// (cell 0, active) against the IDENTICAL fixture mesh. The only difference
// is how cell 0 obtains its focus F:
//   - Control B: cell 0 is fully independent; its OWN camera is POSTed to F.
//   - Case A:    cell 0 is a full follower of cell 1 (master); cell 1's
//                camera is POSTed to F, cell 0's own camera stays default.
// A correctly-resolved bypass produces the same cut / same pick in both.
//
// Assertion 1 (screen-slice equivalence) is the reproducer: it FAILS on
// unfixed code (Case A cuts through its own stale focus) and PASSES once
// every bypass site consumes a resolved snapshot.
// Assertion 2 (/api/pick equivalence) is a forward regression guard: the
// pick provider already resolves via `vpm.activeSnapshot()`, so it is
// expected to pass both before and after the fix — it locks the funnel in
// place once Stage 1 lands.

import std.stdio     : writeln, writefln;
import std.net.curl  : HTTP;
import std.json      : parseJSON, JSONValue, JSONType;
import std.exception : enforce;
import std.math      : isClose, fabs;
import std.conv      : to;
import std.format     : format;

// --------------------------------------------------------------------------
// Helpers (mirrors tests/test_viewport_independence.d)
// --------------------------------------------------------------------------

// NOTE: keep the literal "http://localhost:8080" — run_test.d isolates
// parallel workers by textually rewriting "localhost:8080" to the worker's
// port in a scratch copy of the source.
string baseUrl;

string httpGet(string path) {
    import std.net.curl : get;
    return cast(string)get(baseUrl ~ path);
}

string httpPost(string path, string body_) {
    auto http = HTTP();
    string result;
    http.onReceive = (ubyte[] data) { result ~= cast(string)data; return data.length; };
    http.postData = body_;
    http.addRequestHeader("Content-Type", "application/json");
    http.url = baseUrl ~ path;
    http.perform();
    return result;
}

void postCommand(string cmd, string params = "") {
    JSONValue j;
    j["id"] = cmd;
    if (params.length) j["params"] = params;
    string resp = httpPost("/api/command", j.toString);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command " ~ cmd ~ " failed: " ~ resp);
}

// Post a raw argstring command line (e.g. "tool.set move on") — the wire
// format the HTTP dispatcher's argstring parser expects (first non-blank
// char is NOT '{').
void postArg(string argstring) {
    string resp = httpPost("/api/command", argstring);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command '" ~ argstring ~ "' failed: " ~ resp);
}

void resetApp() {
    httpPost("/api/reset", "{}");
}

double getField(JSONValue j, string[] path...) {
    JSONValue cur = j;
    foreach (k; path) cur = cur[k];
    switch (cur.type) {
        case JSONType.float_:   return cur.floating;
        case JSONType.integer:  return cast(double)cur.integer;
        case JSONType.uinteger: return cast(double)cur.uinteger;
        default: throw new Exception("not a number at " ~ path[$-1]);
    }
}

// --------------------------------------------------------------------------
// Fixture — a cube translated away from the origin, then subdivided once.
// Spans roughly [1.5,2.5]x[-0.5,0.5]x[-0.5,0.5] after the translate — a
// region OFFSET from world origin, so a screen-cut through the resolved
// focus F=(2,0,0) is only observable if the follow-resolution is correct;
// a raw own-focus fallback (default focus = world origin) misses the mesh
// entirely, producing an unambiguous divergence.
// --------------------------------------------------------------------------
void buildFixtureMesh() {
    resetApp();
    postArg("tool.set move on");
    postArg("tool.attr move TX 2");
    postArg("tool.doApply");
    postArg("tool.set move off");
    postArg("mesh.subdivide");
}

struct CellRect { float x, y, w, h; }

// Switch to SplitH (2 cells; cell 0 = left half, active) and return the rect
// cell 0's OWN projection actually uses.
//
// Cell 0 is ALWAYS the active cell in this test (viewport.master/ind* target
// `vpm.views[vpm.activeId]`), and the render loop's per-frame
// `cameraView.setSize(layout.vpW, layout.vpH)` (app.d, unconditional — a
// pre-existing quirk out of this task's scope; see the plan's "V1 rect
// quad-store" note) stomps the ACTIVE cell's own View.width/height back to
// the FULL 3D-area size every frame, even though its visual/input-routing
// rect stays the true SplitH half. `mesh.screenSlice` and `/api/pick` both
// build their projection from the View's (stomped) width/height, so the
// pixel line must be centered against THAT rect, not the visual half-width
// — which is exactly what the no-viewport-arg `/api/camera` reports (cell 0
// is active, so it reflects the stomped size). SplitH is still required so
// cell 1 exists as a `viewport.master` target; its rect is irrelevant here.
CellRect splitHLeftCell() {
    postCommand("viewport.layout", "SplitH");
    auto full = parseJSON(httpGet("/api/camera"));
    CellRect r;
    r.x = cast(float)getField(full, "vpX");
    r.y = cast(float)getField(full, "vpY");
    r.w = cast(float)getField(full, "width");
    r.h = cast(float)getField(full, "height");
    enforce(r.w > 0 && r.h > 0, "cell 0 must have positive dimensions");
    return r;
}

// F.x = 2.15, NOT the mesh's own geometric center (2.0): a Catmull-Clark
// subdivision of a cube leaves several vertices (face-points of the 4 faces
// parallel to X) sitting exactly on the mesh's symmetric mid-plane, so a cut
// through x=2.0 exactly grazes existing vertices/edges instead of crossing
// face interiors (cutByPlane finds no straddling edge → nSplit=0, a
// degenerate no-op unrelated to the follower bug this test targets). x=2.15
// stays well inside the mesh's [1.5,2.5] span while avoiding that alignment.
enum string FOCUS_JSON =
    `{"focus":{"x":2.15,"y":0,"z":0},"distance":5,"azimuth":0,"elevation":0}`;

// Control B: cell 0 fully independent; POST cell 0's OWN camera to F.
void makeControlBIndependent() {
    postCommand("viewport.master", "-1");
    postCommand("viewport.indCenter", "yes");
    postCommand("viewport.indScale",  "yes");
    postCommand("viewport.indRotate", "yes");
    auto r = parseJSON(httpPost("/api/camera?viewport=0", FOCUS_JSON));
    enforce(r["status"].str == "ok", "POST camera?viewport=0 failed: " ~ r.toString);
}

// Case A: cell 0 a full follower of cell 1 (master); POST the MASTER's
// camera to F. Cell 0's own camera stays at the default (focus = origin).
void makeCaseAFollower() {
    postCommand("viewport.master", "1");
    postCommand("viewport.indCenter", "no");
    postCommand("viewport.indScale",  "no");
    postCommand("viewport.indRotate", "no");
    auto r = parseJSON(httpPost("/api/camera?viewport=1", FOCUS_JSON));
    enforce(r["status"].str == "ok", "POST camera?viewport=1 failed: " ~ r.toString);
}

struct ModelState {
    long        vertexCount;
    long        faceCount;
    double[3][] vertices;
}

ModelState readModel() {
    auto m = parseJSON(httpGet("/api/model"));
    ModelState s;
    s.vertexCount = m["vertexCount"].integer;
    s.faceCount   = m["faces"].array.length;
    foreach (v; m["vertices"].array) {
        auto c = v.array;
        s.vertices ~= [c[0].floating, c[1].floating, c[2].floating];
    }
    return s;
}

int pickFace(int x, int y, string engine) {
    auto r = parseJSON(httpGet(format("/api/pick?x=%d&y=%d&engine=%s", x, y, engine)));
    return cast(int)r["faceIndex"].integer;
}

// Run mesh.screenSlice with the nested-params wire format (matches
// tests/test_screen_slice.d) — NOT postCommand(), whose `params` field is a
// single JSON string value (right for the "yes"/"no"/"<id>" viewport.*
// commands elsewhere in this file, wrong here: it would wrap the whole
// {"ax":...} object as one escaped string instead of a nested object, so
// the command would see no ax/ay/bx/by and silently no-op on the pixelEps
// short-line guard).
void runScreenSlice(float ax, float ay, float bx, float by) {
    auto r = parseJSON(httpPost("/api/command", format(
        `{"id":"mesh.screenSlice","params":{"ax":%g,"ay":%g,"bx":%g,"by":%g}}`,
        ax, ay, bx, by)));
    enforce(r["status"].str == "ok" || r["status"].str == "success",
        "mesh.screenSlice failed: " ~ r.toString);
}

// --------------------------------------------------------------------------
// Assertion 1 — screen-slice equivalence (the reproducer).
// --------------------------------------------------------------------------

bool testScreenSliceEquivalence() {
    writeln("  [1] mesh.screenSlice equivalence (follower vs independent)...");

    // --- Control B ---
    buildFixtureMesh();
    auto rectB = splitHLeftCell();
    makeControlBIndependent();
    float cxB = rectB.x + rectB.w * 0.5f;
    float ayB = rectB.y + rectB.h * 0.1f;
    float byB = rectB.y + rectB.h * 0.9f;
    runScreenSlice(cxB, ayB, cxB, byB);
    auto modelB = readModel();

    // --- Case A ---
    buildFixtureMesh();
    auto rectA = splitHLeftCell();
    enforce(isClose(rectA.x, rectB.x) && isClose(rectA.y, rectB.y) &&
            isClose(rectA.w, rectB.w) && isClose(rectA.h, rectB.h),
            "Case A and Control B must use the identical cell 0 rect");
    makeCaseAFollower();
    float cxA = rectA.x + rectA.w * 0.5f;
    float ayA = rectA.y + rectA.h * 0.1f;
    float byA = rectA.y + rectA.h * 0.9f;
    runScreenSlice(cxA, ayA, cxA, byA);
    auto modelA = readModel();

    writefln("    Control B: %d verts, %d faces", modelB.vertexCount, modelB.faceCount);
    writefln("    Case    A: %d verts, %d faces", modelA.vertexCount, modelA.faceCount);

    enforce(modelA.vertexCount == modelB.vertexCount,
        format("vertex count mismatch: Case A=%d, Control B=%d " ~
               "(follower cell resolved a different focus than its master)",
               modelA.vertexCount, modelB.vertexCount));
    enforce(modelA.faceCount == modelB.faceCount,
        format("face count mismatch: Case A=%d, Control B=%d",
               modelA.faceCount, modelB.faceCount));

    foreach (i; 0 .. modelA.vertices.length) {
        foreach (c; 0 .. 3) {
            double a = modelA.vertices[i][c], b = modelB.vertices[i][c];
            enforce(fabs(a - b) < 1e-3,
                format("vertex %d component %d mismatch: Case A=%.6f, Control B=%.6f",
                       i, c, a, b));
        }
    }

    writeln("    PASS: Case A (follower) matches Control B (independent)");
    return true;
}

// --------------------------------------------------------------------------
// Assertion 2 — /api/pick equivalence (forward regression guard).
// --------------------------------------------------------------------------

bool testPickEquivalence() {
    writeln("  [2] /api/pick equivalence (follower vs independent)...");

    // --- Control B --- (no screenSlice — just the uncut fixture mesh).
    buildFixtureMesh();
    auto rectB = splitHLeftCell();
    makeControlBIndependent();
    int pxB = cast(int)(rectB.x + rectB.w * 0.5f);
    int pyB = cast(int)(rectB.y + rectB.h * 0.5f);
    int gpuB = pickFace(pxB, pyB, "gpu");
    int bvhB = pickFace(pxB, pyB, "bvh");

    // --- Case A ---
    buildFixtureMesh();
    auto rectA = splitHLeftCell();
    makeCaseAFollower();
    int pxA = cast(int)(rectA.x + rectA.w * 0.5f);
    int pyA = cast(int)(rectA.y + rectA.h * 0.5f);
    int gpuA = pickFace(pxA, pyA, "gpu");
    int bvhA = pickFace(pxA, pyA, "bvh");

    writefln("    Control B: gpu=%d bvh=%d", gpuB, bvhB);
    writefln("    Case    A: gpu=%d bvh=%d", gpuA, bvhA);

    enforce(gpuA == gpuB,
        format("GPU pick mismatch: Case A=%d, Control B=%d", gpuA, gpuB));
    enforce(bvhA == bvhB,
        format("BVH pick mismatch: Case A=%d, Control B=%d", bvhA, bvhB));
    enforce(gpuB >= 0, "expected a real face hit in Control B (fixture/camera setup wrong)");

    writeln("    PASS: pick agrees (forward guard — already resolved)");
    return true;
}

// --------------------------------------------------------------------------
// Main
// --------------------------------------------------------------------------

int main(string[] args) {
    baseUrl = "http://localhost:8080";

    writeln("=== test_viewport_follower_pick ===");
    int passed = 0, failed = 0;

    void run(bool function() fn, string name) {
        try {
            if (fn()) { writeln("  PASS: ", name); passed++; }
            else       { writeln("  FAIL: ", name); failed++; }
        } catch (Exception e) {
            writefln("  FAIL: %s — %s", name, e.msg);
            failed++;
        }
    }

    run(&testScreenSliceEquivalence, "screen-slice equivalence (reproducer)");
    run(&testPickEquivalence,        "pick equivalence (forward guard)");

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
