// test_reset_parks_pointer.d — the automation reset must put the pointer back.
//
// WHAT LEAKED. `eventlog`'s override pointer is moved by every replayed
// SDL_MOUSEMOTION / SDL_MOUSEBUTTON event and, until this test's fix, was never
// moved back. Inside one test that is the point: `hoverAt` in
// test_gizmo_hover_highlight.d parks the cursor on a handle precisely so the
// hover survives into the frames it probes afterwards, and says so. Across
// tests it is a leak, because `run_test.d` gives a worker ONE `vibe3d --test`
// for its whole slice: the cursor the previous test walked away from goes on
// being hover-picked, every frame, against the next test's freshly reset scene.
//
// WHAT IT COST. Two live failures, both "passes in isolation", both from this
// one channel:
//   * a cursor left on a cube vertex adds one GL_POINTS submission to the
//     vertex-dot pass, so test_frame_counts read 9 verts on an 8-vertex mesh;
//   * a cursor left on the move gizmo's centre repaints that handle in the
//     hover colour, so test_gizmo_handle_alpha's control probe read the hover
//     colour where it expected the idle one.
// Which pair of tests lands together is re-decided every run — the LPT
// scheduler packs slices from a timing cache that each run rewrites — which is
// why it presented as "a different test each time, green on the rerun".
//
// WHAT THIS ASSERTS, AND WHY IT IS A DIFFERENTIAL. No colour constant appears
// below. The same pixel is read three times: with the pointer away, with the
// pointer on it, and after a reset. The first two MUST differ — that is the
// liveness check, without which the third reading would prove nothing (a pixel
// that never responds to hover matches "parked" trivially). The third must
// equal the first, exactly. So this fails if the reset stops parking the
// pointer, and it also fails if the hover cue itself disappears — and it cannot
// be satisfied by a constant.

import http_client : testBaseUrl;
import std.stdio     : writeln, writefln;
import std.net.curl  : HTTP, get;
import std.json      : parseJSON, JSONValue, JSONType;
import std.exception : enforce;
import std.format    : format;
import std.math      : round;
import core.thread   : Thread;
import core.time     : msecs;

// Resolve the port assigned to this worker by run_test.d.
alias BASE = testBaseUrl;

string httpGet(string p) { return cast(string)get(BASE ~ p); }

string httpPost(string path, string body_) {
    auto http = HTTP();
    string result;
    http.onReceive = (ubyte[] data) { result ~= cast(string)data; return data.length; };
    http.postData = body_;
    http.addRequestHeader("Content-Type", "application/json");
    http.url = BASE ~ path;
    http.perform();
    return result;
}

void script(string line) {
    auto resp = httpPost("/api/script", line);
    enforce(parseJSON(resp)["status"].str == "ok", "script `" ~ line ~ "` failed: " ~ resp);
}

/// A state change is visible to a probe only once a frame has RENDERED with it.
void settle() { Thread.sleep(400.msecs); }

double num(JSONValue j, string[] path...) {
    JSONValue c = j;
    foreach (k; path) c = c[k];
    switch (c.type) {
        case JSONType.float_:   return c.floating;
        case JSONType.integer:  return cast(double)c.integer;
        case JSONType.uinteger: return cast(double)c.uinteger;
        default: throw new Exception("not a number at ." ~ path[$ - 1]);
    }
}

struct Cell { int vx, vy, vw, vh; }

Cell cell() {
    auto c = parseJSON(httpGet("/api/camera"));
    return Cell(cast(int)num(c, "vpX"), cast(int)num(c, "vpY"),
                cast(int)num(c, "width"), cast(int)num(c, "height"));
}

/// Park the pointer at a window-space point and leave it there.
void pointerAt(Cell c, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
        ~ "\n", c.vx, c.vy, c.vw, c.vh);
    foreach (i; 0 .. 3)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
            ~ "\n", 20.0 + i * 20.0, x, y);
    auto resp = httpPost("/api/play-events", log);
    enforce(parseJSON(resp)["status"].str == "success", "play-events failed: " ~ resp);
    foreach (_; 0 .. 200) {
        auto s = parseJSON(httpGet("/api/play-events/status"));
        if (s["finished"].type == JSONType.TRUE) break;
        Thread.sleep(20.msecs);
    }
    settle();
}

/// The four channel values at one FBO pixel of the rendered cell.
int[4] probe(Cell c, int wx, int wy) {
    auto j = parseJSON(httpGet(format("/api/viewport/probe?points=%d,%d",
                                      wx - c.vx, wy - c.vy)));
    enforce("error" !in j, "probe failed: " ~ j.toString);
    enforce(j["renders"].type == JSONType.TRUE,
            "the probed cell is not rendered under --test; the reading is void");
    auto e = j["points"].array[0];
    enforce("error" !in e, "probe point out of range: " ~ e.toString);
    return [cast(int)num(e, "r"), cast(int)num(e, "g"),
            cast(int)num(e, "b"), cast(int)num(e, "a")];
}

string show(int[4] p) { return format("rgba(%d,%d,%d,%d)", p[0], p[1], p[2], p[3]); }

/// Arm Move and return the window-space centre of its centre handle (part 3).
void armAndFindCentre(out Cell c, out int cx, out int cy) {
    script("tool.set move");
    settle();
    auto j = parseJSON(httpGet("/api/tool/handles"));
    enforce(j["handles"].type != JSONType.null_,
            "/api/tool/handles reports no handles — the Move tool did not arm");
    auto h = j["handles"];
    c = Cell(cast(int)num(h, "viewport", "x"), cast(int)num(h, "viewport", "y"),
             cast(int)num(h, "viewport", "width"), cast(int)num(h, "viewport", "height"));
    bool found;
    foreach (e; h["parts"].array) {
        if (cast(int)num(e, "part") != 3) continue;
        cx = cast(int)round(e["screen"].array[0].floating);
        cy = cast(int)round(e["screen"].array[1].floating);
        found = true;
    }
    enforce(found, "the move bank must publish a centre handle (part 3)");
}

void main() {}

unittest {
    writeln("=== test_reset_parks_pointer ===");

    httpPost("/api/reset", "{}");
    settle();

    Cell c;
    int cx, cy;
    armAndFindCentre(c, cx, cy);

    // (1) Pointer away from the handle. The cell's top-left corner is inside
    //     the cell (so the probe is valid) and nowhere near the gizmo.
    immutable int awayX = c.vx + 8, awayY = c.vy + 8;
    pointerAt(c, awayX, awayY);
    immutable int[4] idle = probe(c, cx, cy);

    // (2) Pointer ON the handle.
    pointerAt(c, cx, cy);
    immutable int[4] hovered = probe(c, cx, cy);

    // Liveness. Without this the reading in (3) proves nothing: a pixel that
    // never reacts to the pointer would "stay parked" no matter what.
    assert(idle != hovered,
           format("the centre handle at (%d,%d) reads %s with the pointer on it "
                  ~ "and %s with the pointer away — identical, so this pixel "
                  ~ "carries no hover cue and the parking check below would be "
                  ~ "vacuous", cx, cy, show(hovered), show(idle)));
    writefln("    hover cue is live: idle %s vs hovered %s", show(idle), show(hovered));

    // (3) THE CLAIM. The automation reset parks the pointer, so the very next
    //     frame is drawn as if nothing were hovered — which is the baseline the
    //     FIRST test of a worker's slice gets, and the one every later test in
    //     that slice is entitled to. Re-arm afterwards: the reset drops the
    //     tool, and the pixel only means something with the gizmo drawn.
    httpPost("/api/reset", "{}");
    settle();
    int cx2, cy2;
    Cell c2;
    armAndFindCentre(c2, cx2, cy2);
    assert(cx2 == cx && cy2 == cy,
           format("the gizmo centre moved across the reset (%d,%d -> %d,%d); "
                  ~ "the three readings are no longer of the same pixel",
                  cx, cy, cx2, cy2));

    immutable int[4] afterReset = probe(c2, cx, cy);
    assert(afterReset == idle,
           format("POST /api/reset left the pointer where the previous replay "
                  ~ "parked it: the centre handle still reads %s (its HOVERED "
                  ~ "value) instead of %s (its idle value). Every test that "
                  ~ "runs next on this shared --test instance inherits that "
                  ~ "hover — see eventlog.parkOverrideMouse.",
                  show(afterReset), show(idle)));
    writefln("    after reset: %s — parked", show(afterReset));

    script("tool.set move off");
    settle();
}
