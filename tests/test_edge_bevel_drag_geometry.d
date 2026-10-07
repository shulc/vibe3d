import camera_lens_control_helpers;
// Interactive Edge Bevel width-handle regression.
//
// The handle is pressed through its published part-0 anchor, then held across
// separate event batches.  This catches the old last-event/base-width mix-up:
// its final width depended on how SDL split one physical drag into motions.

import http_client : testBaseUrl, getJson, quiesce;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;
import std.math : fabs, sqrt;
import core.thread : Thread;
import core.time : msecs;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;


void cmd(string text) {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", text));
    assert(r["status"].str == "ok", "command failed: " ~ text ~ " → " ~ r.toString);
}

void interactiveCmd(string text) {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/script?interactive=true", text));
    assert(r["status"].str == "ok", "interactive command failed: " ~ text ~ " → " ~ r.toString);
}


void settle() { quiesce(); }

void play(string log) {
    playAndWaitLensControl(log, BASE);
    settle(); // Let frame-driven tool/preview updates observe the delivered input.
}

void navigate(bool redo) {
    play(format(
        `{"t":0.000,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":%d,"repeat":0}`,
        redo ? 65 : 64));
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
    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("mesh.select", `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`)));
    assert(r["status"].str == "ok", "edge selection failed");
}

// Three selected edges incident to one cube corner. This is deliberately a
// K3 junction, rather than the isolated K1 edge whose old implementation had
// already rounded, so level changes exercise complex standing-preview topology.
void selectCornerEdges() {
    auto m = model();
    int[] es = [edgeIndex(m, 6, 7), edgeIndex(m, 2, 6), edgeIndex(m, 5, 6)];
    foreach (ei; es) assert(ei >= 0, "cube corner edge missing");
    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("mesh.select", format(`{"mode":"edges","indices":[%d,%d,%d]}`, es[0], es[1], es[2]))));
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


// A positive offset on an ordinary cube endpoint must not erase the preview
// or make a subsequent width adjustment inert (task 20261330).
unittest {
    cmd(commandBody("scene.reset", `{"type":"cube"}`));
    selectTopFrontEdge();
    auto d = armHandle();
    auto source = model()["vertices"].toString ~ model()["faces"].toString;
    play(button("SDL_MOUSEBUTTONDOWN", 0, d.x0, d.y0));
    play(motion(0, d.x0 + (d.x1-d.x0)/8, d.y0 + (d.y1-d.y0)/8));
    auto width = getJson("/api/tool/state")["width"].floating;
    auto first = model()["vertices"].toString ~ model()["faces"].toString;
    assert(width > 0 && first != source, "LIVE WIDTH: held gesture changes actual geometry");
    play(button("SDL_MOUSEBUTTONUP", 0, d.x0 + (d.x1-d.x0)/8, d.y0 + (d.y1-d.y0)/8));

    double sx, sy; bool found;
    fetchHandlePart(1, sx, sy, found, BASE);
    assert(found, "LIVE OFFSET: part1 exists");
    int x = cast(int)sx, y = cast(int)sy;
    auto vp = viewportFromCamera(fetchCamera(BASE));
    // Single horizontal edge: native frame up=X, normal=(Y+Z)/sqrt2;
    // miter column0 = cross(X,normal).
    auto axis = normalize(Vec3(0,-1,1));
    float ax, ay, bx, by;
    assert(projectToWindow(Vec3(0,.5f,.5f), vp, ax, ay));
    assert(projectToWindow(Vec3(0,.5f,.5f)+axis, vp, bx, by));
    double len = sqrt((bx-ax)*(bx-ax)+(by-ay)*(by-ay));
    int dx = cast(int)(15*(bx-ax)/len), dy = cast(int)(15*(by-ay)/len);
    play(motion(0,x,y,0) ~ "\n" ~ motion(.03,x,y,0));
    play(button("SDL_MOUSEBUTTONDOWN",0,x,y));
    assert(getJson("/api/tool/state")["dragPart"].integer == 1, "LIVE OFFSET: actual part1 captured");
    play(motion(0,x+dx,y+dy));
    auto state = getJson("/api/tool/state");
    assert(state["miterOffset"].floating > 0 && fabs(state["width"].floating-width)<1e-6,
        "LIVE OFFSET: positive independent scalar reached production");
    auto offset = model()["vertices"].toString ~ model()["faces"].toString;
    assert(offset != source && offset != first && state["built"].type == JSONType.true_,
        "LIVE OFFSET: held part1 changes geometry instead of erasing width preview");
    play(button("SDL_MOUSEBUTTONUP",0,x+dx,y+dy));
    fetchHandlePart(0,sx,sy,found,BASE); assert(found);
    x=cast(int)sx; y=cast(int)sy;
    play(motion(0,x,y,0) ~ "\n" ~ motion(.03,x,y,0));
    play(button("SDL_MOUSEBUTTONDOWN",0,x,y));
    play(motion(0,x+(d.x1-d.x0)/8,y+(d.y1-d.y0)/8));
    auto again=model()["vertices"].toString ~ model()["faces"].toString;
    assert(again!=offset && again!=source, "LIVE WIDTH AFTER OFFSET: actual geometry continues changing");
    play(button("SDL_MOUSEBUTTONUP",0,x+(d.x1-d.x0)/8,y+(d.y1-d.y0)/8));
    cmd("tool.set edge.bevel off");
}
