// The live snap PREVIEW — a transform tool hovering with snapping on, no
// button held. Task 0533, S2 phase (b).
//
// WHY THIS FILE EXISTS. Phase (b) migrates a consumer off its own snap query
// and onto the SNAP stage's published result, and proves the substitution with
// a `debug` assertion that the two answers agree. That proof is worth exactly
// as much as the suite's coverage of the migrated path — and the suite had
// NONE. Replacing the migrated branch with `assert(0)` and running all 507
// tests changed nothing: not one of them ever reached
// `TransformTool.evaluateSnap` with snapping enabled. The nine existing
// snap tests either query `/api/snap` directly (no tool, no cursor event) or
// drag (`applySnapToDelta`, a different call site that keeps its own query
// because it has a moving set to exclude). Hovering was untested.
//
// So this test does the one thing none of them did: it moves the mouse with a
// transform tool armed and snapping on, and reads what the preview published.
// It is written against the OBSERVABLE contract (`/api/snap/last`), so it
// holds for the direct query and for the packet alike — which is what makes it
// a regression test for the migration rather than a description of it.
//
// The three cases are the three shapes a snap answer can take, and they are
// chosen to separate fields that a careless migration would merge:
//
//   A. SNAP        — `worldPos` is the winning vertex.
//   B. MISS        — `worldPos` and `highlightPos` are both the tool's own
//                    query SEED (the click-relocate plane hit). The published
//                    packet deliberately carries NEITHER on a miss, so a
//                    consumer that forgot to put its seed back would report
//                    the origin here.
//   C. HIGHLIGHT   — inside the outer range, outside the inner one:
//                    `highlightPos` is the candidate, `worldPos` is still the
//                    seed. This is the one case where the two differ, and the
//                    field the packet did not originally carry.
//
// Ranges rather than geometry do the arranging: the same pixel is replayed
// three times with (inner, outer) = (∞, ∞), (default), (1, ∞). That keeps the
// case selection independent of where the cube happens to project.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math : fabs;
import std.format : format;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

private void script(string s) {
    auto resp = post(BASE ~ "/api/script", s);
    auto j = parseJSON(cast(string)resp);
    assert(j["status"].str == "ok", "script failed: " ~ cast(string)resp);
}

// A hover: motion events only, no button. `buildDragLog` cannot express this
// — it always brackets the motions with a down/up pair, which is precisely the
// state (`dragAxis >= 0`) in which the preview declines to run.
private string buildHoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    // Two events, one pixel apart: the first arms the hover, the second is the
    // one whose answer /api/snap/last reports. `xrel`/`yrel` are non-zero so
    // the motion is not coalesced away.
    log ~= format(
        `{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":3,"yrel":3,"state":0,"mod":0}` ~ "\n",
        x, y);
    log ~= format(
        `{"t":70.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":1,"yrel":0,"state":0,"mod":0}` ~ "\n",
        x + 1, y);
    return log;
}

private bool approx(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

private double[3] arr3(JSONValue v) {
    auto a = v.array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

unittest {
    post(BASE ~ "/api/command", commandBody("scene.reset"));

    // Arm a transform tool. Nothing is selected and nothing is dragged: the
    // preview runs on plain hover, which is the path under test.
    script("tool.set move\n"
         ~ "tool.pipe.attr snap enabled true\n"
         ~ "tool.pipe.attr snap types vertex\n");

    auto cam = fetchCamera(BASE);
    // A pixel in the upper-left quadrant of the viewport: off the gizmo (a
    // cursor ON a handle suppresses the preview by design) and far enough
    // from the cube that the default ranges miss it.
    immutable int px = cam.vpX + cast(int)(cam.width  * 0.06);
    immutable int py = cam.vpY + cast(int)(cam.height * 0.06);
    immutable string hover = buildHoverLog(cam.vpX, cam.vpY, cam.width,
                                           cam.height, px, py);

    // ---- A. a snap -------------------------------------------------------
    script("tool.pipe.attr snap innerRange 999999\n"
         ~ "tool.pipe.attr snap outerRange 999999\n");
    playAndWait(hover, BASE);
    auto a = fetchSnapLast(BASE);
    assert(a["snapped"].type == JSONType.TRUE,
        "an unbounded acceptance range must snap the hover to SOME vertex: "
        ~ a.toString());
    assert(a["targetType"].integer == 1,
        "only the Vertex type is enabled, so the winner must be a vertex");
    immutable int idx = cast(int)a["targetIndex"].integer;
    assert(idx >= 0, "a snap names its element");
    auto vpos = vertexPos(idx, BASE);
    auto aWorld = arr3(a["worldPos"]);
    assert(approx(aWorld[0], vpos[0]) && approx(aWorld[1], vpos[1])
        && approx(aWorld[2], vpos[2]),
        format("the snapped position must BE the winning vertex %d %s, got %s",
               idx, vpos, aWorld));
    auto aHi = arr3(a["highlightPos"]);
    assert(approx(aHi[0], vpos[0]) && approx(aHi[1], vpos[1])
        && approx(aHi[2], vpos[2]),
        "on a snap the highlight point and the snapped point are the same");

    // ---- B. a miss: the SEED survives ------------------------------------
    // The published packet carries no position at all on a miss — the stage
    // has no gesture and so no seed worth publishing. The tool does have one
    // (its click-relocate plane hit), and it is what /api/snap/last has always
    // reported here. Reading the origin instead would mean the consumer took
    // the packet's default for an answer.
    script("tool.pipe.attr snap innerRange 24\n"
         ~ "tool.pipe.attr snap outerRange 40\n");
    playAndWait(hover, BASE);
    auto b = fetchSnapLast(BASE);
    assert(b["snapped"].type == JSONType.FALSE,
        "at the default ranges this pixel is far from every vertex: "
        ~ b.toString());
    assert(b["highlighted"].type == JSONType.FALSE,
        "...and outside the gather range too");
    auto bWorld = arr3(b["worldPos"]);
    auto bHi    = arr3(b["highlightPos"]);
    assert(approx(bWorld[0], bHi[0]) && approx(bWorld[1], bHi[1])
        && approx(bWorld[2], bHi[2]),
        "a miss passes the query seed through BOTH position slots");
    assert(!(approx(bWorld[0], 0) && approx(bWorld[1], 0) && approx(bWorld[2], 0)),
        format("the pass-through position must be the tool's own query seed "
             ~ "— the plane hit under the cursor — not the origin a default-"
             ~ "constructed packet would report: %s", bWorld));

    // ---- C. a highlight without a snap: the two positions DIFFER ---------
    // Inside the gather range, outside acceptance. This is the only shape in
    // which `highlightPos` is not a copy of something else, and it is the
    // field S2's first field list left out.
    script("tool.pipe.attr snap innerRange 1\n"
         ~ "tool.pipe.attr snap outerRange 999999\n");
    playAndWait(hover, BASE);
    auto c = fetchSnapLast(BASE);
    assert(c["snapped"].type == JSONType.FALSE,
        "a 1-pixel acceptance range at this pixel must not snap: " ~ c.toString());
    assert(c["highlighted"].type == JSONType.TRUE,
        "an unbounded gather range must still highlight the nearest vertex");
    immutable int cidx = cast(int)c["targetIndex"].integer;
    assert(cidx >= 0, "a highlight names its element too");
    auto cvpos = vertexPos(cidx, BASE);
    auto cHi   = arr3(c["highlightPos"]);
    assert(approx(cHi[0], cvpos[0]) && approx(cHi[1], cvpos[1])
        && approx(cHi[2], cvpos[2]),
        format("the highlight point must BE the highlighted vertex %d %s, "
             ~ "got %s — this is where the pre-snap ring is drawn",
               cidx, cvpos, cHi));
    auto cWorld = arr3(c["worldPos"]);
    assert(approx(cWorld[0], bWorld[0]) && approx(cWorld[1], bWorld[1])
        && approx(cWorld[2], bWorld[2]),
        format("nothing snapped, so the position is still the seed — the same "
             ~ "seed case B saw at the same pixel: expected %s, got %s",
               bWorld, cWorld));
    assert(!(approx(cWorld[0], cHi[0]) && approx(cWorld[1], cHi[1])
          && approx(cWorld[2], cHi[2])),
        "the whole point of this case: on a highlight-without-snap the "
        ~ "position and the highlight point are DIFFERENT points, and a "
        ~ "channel that carries only one of them cannot serve this consumer");
}
