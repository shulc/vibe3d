// Interactive Edge Bevel width-handle regression.
//
// The handle is pressed through its published part-0 anchor, then held across
// separate event batches.  This catches the old last-event/base-width mix-up:
// its final width depended on how SDL split one physical drag into motions.

import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;
import std.math : fabs, sqrt;
import core.thread : Thread;
import core.time : msecs;

import drag_helpers;

void main() {}

enum BASE = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string)get(BASE ~ path)); }

void cmd(string text) {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", text));
    assert(r["status"].str == "ok", "command failed: " ~ text ~ " → " ~ r.toString);
}

void settle() { Thread.sleep(130.msecs); }

void play(string log) {
    playAndWait(log, BASE);
    settle(); // EventPlayer reports posted events; let the SDL queue drain.
}

string motion(double t, int x, int y, int state = 1) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":0}`,
                  t, x, y, state);
}

string button(string kind, double t, int x, int y) {
    return format(`{"t":%.3f,"type":"%s","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  t, kind, x, y);
}

long modelDepth() { return getJson("/api/undo/status")["modelDepth"].integer; }

JSONValue model() { return getJson("/api/model"); }

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer, y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

void selectTopFrontEdge() {
    auto m = model();
    int ei = edgeIndex(m, 6, 7);
    assert(ei >= 0, "cube top-front edge missing");
    auto r = parseJSON(cast(string)post(BASE ~ "/api/select",
        `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`));
    assert(r["status"].str == "ok", "edge selection failed");
}

struct DragSetup { int x0, y0, x1, y1; }

DragSetup armHandle() {
    cmd("tool.set edge.bevel on");
    settle(); // draw() must publish the ToolHandles bank first.

    double sx, sy;
    bool found;
    fetchHandlePart(0, sx, sy, found, BASE);
    assert(found, "edge-bevel Width part 0 missing from /api/tool/handles");
    auto handles = getJson("/api/tool/handles")["handles"];
    assert(handles["captured"].integer == -1, "handle unexpectedly captured before down");

    // Hover twice before down: queryMouse is intentionally the tool's hit-test
    // source and may otherwise still report the previous SDL position.
    int x0 = cast(int)sx, y0 = cast(int)sy;
    play(motion(0.0, x0, y0, 0) ~ "\n" ~ motion(0.03, x0, y0, 0));

    auto cam = fetchCamera(BASE);
    auto vp = viewportFromCamera(cam);
    // Selected edge (6,7) has adjacent +Y/+Z faces, hence this frozen axis.
    Vec3 anchor = Vec3(0.0f, 0.5f, 0.5f);
    Vec3 axis = normalize(Vec3(0.0f, 1.0f, 1.0f));
    float ax, ay, bx, by;
    assert(projectToWindow(anchor, vp, ax, ay), "bevel anchor projects off camera");
    assert(projectToWindow(anchor + axis, vp, bx, by), "bevel width axis projects off camera");
    double dx = bx - ax, dy = by - ay;
    double d = sqrt(dx*dx + dy*dy);
    assert(d > 1.0, "bevel width axis too short on screen");
    return DragSetup(x0, y0,
        x0 + cast(int)(120.0 * dx / d), y0 + cast(int)(120.0 * dy / d));
}

unittest {
    auto reset = parseJSON(cast(string)post(BASE ~ "/api/reset?type=cube", ""));
    assert(reset["status"].str == "ok", "cube reset failed");
    selectTopFrontEdge();
    long depthBefore = modelDepth();

    auto d = armHandle();
    play(button("SDL_MOUSEBUTTONDOWN", 0.0, d.x0, d.y0));
    assert(getJson("/api/tool/state")["dragPart"].integer == 0,
        "Width handle did not capture on mouse-down");
    assert(getJson("/api/tool/handles")["handles"]["captured"].integer == 0,
        "arbiter did not report captured Width part");

    // Zero motion must preserve the baseline; the following three motions are
    // deliberately separate playback batches to prevent event coalescing.
    play(motion(0.0, d.x0, d.y0));
    assert(fabs(getJson("/api/tool/state")["width"].floating) < 1e-6,
        "zero motion changed Width");

    double prev = 0;
    foreach (numer; [1, 2, 3]) {
        int x = d.x0 + (d.x1 - d.x0) * numer / 3;
        int y = d.y0 + (d.y1 - d.y0) * numer / 3;
        play(motion(0.0, x, y));
        auto st = getJson("/api/tool/state");
        double w = st["width"].floating;
        assert(w > prev + 1e-5, "Width did not grow monotonically at motion " ~ numer.to!string);
        assert(st["built"].type == JSONType.true_, "non-zero Width did not rebuild preview");
        prev = w;
    }
    double multiWidth = prev;
    string multiVerts = model()["vertices"].toString;

    // Move back to the exact press pixel: a total-delta drag must return to
    // its baseline rather than retain the last incremental displacement.
    play(motion(0.0, d.x0, d.y0));
    assert(fabs(getJson("/api/tool/state")["width"].floating) < 1e-6,
        "backward drag did not restore Width baseline");
    play(motion(0.0, d.x1, d.y1));
    assert(fabs(getJson("/api/tool/state")["width"].floating - multiWidth) < 1e-5,
        "return to endpoint changed Width");
    play(button("SDL_MOUSEBUTTONUP", 0.0, d.x1, d.y1));
    assert(getJson("/api/tool/state")["dragPart"].integer == -1, "mouse-up kept Width captured");

    cmd("tool.set edge.bevel off");
    assert(modelDepth() == depthBefore + 1, "one drag must commit exactly one undo entry");
    auto undo = parseJSON(cast(string)post(BASE ~ "/api/undo", ""));
    assert(undo["status"].str == "ok", "undo failed");
    assert(model()["vertexCount"].integer == 8 && model()["faceCount"].integer == 6,
        "one undo did not restore the cube");

    // Same endpoint in one motion produces the same preview geometry.
    selectTopFrontEdge();
    auto one = armHandle();
    play(button("SDL_MOUSEBUTTONDOWN", 0.0, one.x0, one.y0));
    play(motion(0.0, one.x1, one.y1));
    auto oneState = getJson("/api/tool/state");
    assert(fabs(oneState["width"].floating - multiWidth) < 1e-5,
        "one-step and three-step drag widths differ");
    assert(model()["vertices"].toString == multiVerts,
        "one-step and three-step drag previews differ");
    play(button("SDL_MOUSEBUTTONUP", 0.0, one.x1, one.y1));
    cmd("tool.set edge.bevel off");
}
