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

void interactiveCmd(string text) {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/script?interactive=true", text));
    assert(r["status"].str == "ok", "interactive command failed: " ~ text ~ " → " ~ r.toString);
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

// Three selected edges incident to one cube corner. This is deliberately a
// K3 junction, rather than the isolated K1 edge whose old implementation had
// already rounded, so level changes exercise complex standing-preview topology.
void selectCornerEdges() {
    auto m = model();
    int[] es = [edgeIndex(m, 6, 7), edgeIndex(m, 2, 6), edgeIndex(m, 5, 6)];
    foreach (ei; es) assert(ei >= 0, "cube corner edge missing");
    auto r = parseJSON(cast(string)post(BASE ~ "/api/select",
        format(`{"mode":"edges","indices":[%d,%d,%d]}`, es[0], es[1], es[2])));
    assert(r["status"].str == "ok", "corner edge selection failed");
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

// Round Level is a live property of the standing K3 Edge Bevel preview. These
// interactive ToolAttrCommand writes happen after Width has made one preview and
// before the tool is dropped. Returning to L0 must replay its activation
// snapshot exactly.
unittest {
    auto reset = parseJSON(cast(string)post(BASE ~ "/api/reset?type=cube", ""));
    assert(reset["status"].str == "ok", "cube reset failed");
    selectCornerEdges();
    long depthBefore = modelDepth();

    cmd("tool.set edge.bevel on");
    settle();
    interactiveCmd("tool.attr edge.bevel width 0.2");
    settle();
    auto l0State = getJson("/api/tool/state");
    assert(l0State["tool"].str == "edgeBevel" && l0State["built"].type == JSONType.true_,
        "width panel edit did not leave an active, built edge-bevel preview");
    assert(l0State["width"].floating > 0.1, "width attr did not set a non-zero preview");
    auto l0 = model();
    string l0Geometry = l0["vertices"].toString ~ l0["faces"].toString;
    size_t l0Verts = l0["vertices"].array.length, l0Faces = l0["faces"].array.length;

    interactiveCmd("tool.attr edge.bevel roundLevel 1");
    settle();
    auto l1State = getJson("/api/tool/state");
    auto l1 = model();
    size_t l1Verts = l1["vertices"].array.length, l1Faces = l1["faces"].array.length;
    assert(l1State["tool"].str == "edgeBevel" && l1State["built"].type == JSONType.true_
           && l1State["roundLevel"].integer == 1,
        "Round Level 1 dropped or failed to rebuild the active preview");
    assert(l1Verts > l0Verts && l1Faces > l0Faces,
        "Round Level 1 did not add rounded preview segments over L0");
    assert((l1["vertices"].toString ~ l1["faces"].toString) != l0Geometry,
        "Round Level 1 did not change the K3 preview profile");

    interactiveCmd("tool.attr edge.bevel roundLevel 2");
    settle();
    auto l2State = getJson("/api/tool/state");
    auto l2 = model();
    size_t l2Verts = l2["vertices"].array.length, l2Faces = l2["faces"].array.length;
    assert(l2State["tool"].str == "edgeBevel" && l2State["built"].type == JSONType.true_
           && l2State["roundLevel"].integer == 2,
        "Round Level 2 dropped or failed to rebuild the active preview");
    assert(l2Verts > l1Verts && l2Faces > l1Faces,
        "Round Level 2 did not add rounded preview segments over L1");
    assert((l2["vertices"].toString ~ l2["faces"].toString)
           != (l1["vertices"].toString ~ l1["faces"].toString),
        "Round Level 2 did not refine the K3 preview profile");

    interactiveCmd("tool.attr edge.bevel roundLevel 0");
    settle();
    auto l0AgainState = getJson("/api/tool/state");
    auto l0Again = model();
    string l0AgainGeometry = l0Again["vertices"].toString ~ l0Again["faces"].toString;
    assert(l0AgainState["tool"].str == "edgeBevel" && l0AgainState["built"].type == JSONType.true_
           && l0AgainState["roundLevel"].integer == 0,
        "Round Level 0 dropped or failed to rebuild the active preview");
    assert(l0Again["vertices"].array.length == l0Verts && l0Again["faces"].array.length == l0Faces
           && l0AgainGeometry == l0Geometry,
        "returning to Round Level 0 did not reproduce the original flat preview");

    cmd("tool.set edge.bevel off");
    assert(modelDepth() == depthBefore + 1,
        "dropping the standing preview must record exactly one undo entry");
    auto undo = parseJSON(cast(string)post(BASE ~ "/api/undo", ""));
    assert(undo["status"].str == "ok", "undo failed");
    assert(model()["vertexCount"].integer == 8 && model()["faceCount"].integer == 6,
        "undo after Round Level edits did not restore the cube");
}

// Idempotency guard: a standing interactive preview (built==true, mesh already
// beveled) followed by a headless `tool.doApply` must restore the clean cage
// and apply the kernel EXACTLY ONCE — not bevel the already-beveled preview.
// This pins the `if (built && before.filled) before.restore()` guard that the
// whole topology-tool family carries; dropping it double-bevels here.
unittest {
    auto reset = parseJSON(cast(string)post(BASE ~ "/api/reset?type=cube", ""));
    assert(reset["status"].str == "ok", "cube reset failed");
    selectTopFrontEdge();

    cmd("tool.set edge.bevel on");
    settle();
    interactiveCmd("tool.attr edge.bevel width 0.2");
    settle();
    auto preState = getJson("/api/tool/state");
    assert(preState["built"].type == JSONType.true_,
        "interactive width scrub did not leave a standing preview");
    auto pre = model();
    assert(pre["vertexCount"].integer == 10 && pre["faceCount"].integer == 7,
        "isolated-edge L0 preview must be a single clean bevel (10 verts / 7 faces)");
    string preGeometry = pre["vertices"].toString ~ pre["faces"].toString;

    // doApply over the live preview: the guard restores the clean cube first.
    cmd("tool.doApply");
    settle();
    auto post = model();
    assert(post["vertexCount"].integer == 10 && post["faceCount"].integer == 7,
        "doApply over a standing preview double-beveled (idempotency guard gone)");
    assert((post["vertices"].toString ~ post["faces"].toString) == preGeometry,
        "doApply must reproduce the single-bevel geometry, not stack a second bevel");

    cmd("tool.set edge.bevel off");
}
