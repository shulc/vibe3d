// Element Move, elementMode=edgeCent: the gizmo must land at the edge MIDPOINT
// regardless of where along the edge the click lands (the "Cent" variant), in
// contrast to bare `edge` mode which uses the click point
// (test_element_pick_edge_clickpoint).

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;
import std.string : format;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";
JSONValue pj(string p, string b){ return parseJSON(cast(string)post(baseUrl~p,b)); }
JSONValue gj(string p){ return parseJSON(cast(string)get(baseUrl~p)); }
void settle(){ import core.thread:Thread; import core.time:msecs; Thread.sleep(150.msecs); }

Vec3 evalPivot() {
    auto c = gj("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating, cast(float)c[2].floating);
}
int hoverEdge() { return cast(int) gj("/api/toolpipe/eval")["hover"]["edge"].integer; }
Vec3 vtx(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return Vec3(cast(float)a[0].floating, cast(float)a[1].floating, cast(float)a[2].floating);
}
string hoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`~"\n",
        vpX,vpY,vpW,vpH);
    foreach (i; 0 .. 5)
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`~"\n",
            50.0+i*20.0, x, y);
    return log;
}

unittest {
    pj("/api/reset","");
    pj("/api/script","tool.set xfrm.elementMove on");
    pj("/api/command","tool.pipe.attr falloff dist 4");
    pj("/api/command","tool.pipe.attr falloff mode edgeCent");
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    auto m   = gj("/api/model");
    auto edges = m["edges"].array;

    int chosen = -1; Vec3 ea, eb; int cpx, cpy;
    foreach (ei, e; edges) {
        size_t a = cast(size_t) e.array[0].integer;
        size_t b = cast(size_t) e.array[1].integer;
        Vec3 va = vtx(m, a), vb = vtx(m, b);
        Vec3 click = vb + (va - vb) * 0.75f;   // click 75% toward a — NOT the midpoint
        float sx, sy, ax, ay, bx, by;
        if (!projectToWindow(click, vp, sx, sy)) continue;
        if (!projectToWindow(va, vp, ax, ay) || !projectToWindow(vb, vp, bx, by)) continue;
        if (sqrt((ax-bx)*(ax-bx)+(ay-by)*(ay-by)) < 40.0f) continue;
        int px = cast(int)sx, py = cast(int)sy;
        playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height, px, py));
        settle();
        if (hoverEdge() == cast(int)ei) { chosen = cast(int)ei; ea = va; eb = vb; cpx = px; cpy = py; break; }
    }
    assert(chosen >= 0, "no pickable edge found");

    Vec3 mid   = (ea + eb) * 0.5f;
    Vec3 click = eb + (ea - eb) * 0.75f;

    string downOnly = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`~"\n"~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`~"\n"~
        `{"t":100.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":1,"yrel":0,"state":1,"mod":0}`~"\n",
        cam.vpX,cam.vpY,cam.width,cam.height, cpx, cpy, cpx+1, cpy);
    playAndWait(downOnly);
    settle();
    Vec3 p = evalPivot();

    string up = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`~"\n"~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`~"\n",
        cam.vpX,cam.vpY,cam.width,cam.height, cpx+1, cpy);
    playAndWait(up); settle();

    float dMid   = sqrt((p.x-mid.x)*(p.x-mid.x)+(p.y-mid.y)*(p.y-mid.y)+(p.z-mid.z)*(p.z-mid.z));
    float dClick = sqrt((p.x-click.x)*(p.x-click.x)+(p.y-click.y)*(p.y-click.y)+(p.z-click.z)*(p.z-click.z));
    assert(dMid < 0.12f,
        "edgeCent gizmo must land at the edge MIDPOINT " ~
        "(" ~ mid.x.to!string ~ "," ~ mid.y.to!string ~ "," ~ mid.z.to!string ~ "); got (" ~
        p.x.to!string ~ "," ~ p.y.to!string ~ "," ~ p.z.to!string ~ ") distMid=" ~ dMid.to!string);
    assert(dMid < dClick,
        "edgeCent must be closer to the midpoint than the (off-center) click point; " ~
        "distMid=" ~ dMid.to!string ~ " distClick=" ~ dClick.to!string);

    pj("/api/script","tool.set xfrm.elementMove off");
    settle();
}
