// Element Move, elementMode=polygon: the gizmo must land at the face CENTROID
// regardless of where on the face the click lands — anchor is click-independent.

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
int hoverFace() { return cast(int) gj("/api/toolpipe/eval")["hover"]["face"].integer; }
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
    pj("/api/command","tool.pipe.attr falloff mode polygon");
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    auto m   = gj("/api/model");
    auto faces = m["faces"].array;

    int chosen = -1; Vec3 fCent, fClick; int cpx, cpy;
    foreach (fi, f; faces) {
        auto idx = f.array;
        if (idx.length < 3) continue;
        Vec3 c = Vec3(0,0,0);
        foreach (vi; idx) c = c + vtx(m, cast(size_t)vi.integer);
        c = c * (1.0f / idx.length);
        Vec3 v0 = vtx(m, cast(size_t) idx[0].integer);
        // Click halfway from the centroid toward vertex 0 — clearly off-centre.
        Vec3 cl = c + (v0 - c) * 0.5f;
        float sx, sy;
        if (!projectToWindow(cl, vp, sx, sy)) continue;
        int px = cast(int)sx, py = cast(int)sy;
        playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height, px, py));
        settle();
        if (hoverFace() == cast(int)fi) { chosen = cast(int)fi; fCent = c; fClick = cl; cpx = px; cpy = py; break; }
    }
    assert(chosen >= 0, "no pickable face found at off-centre pixel");

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

    float dCent  = sqrt((p.x-fCent.x)*(p.x-fCent.x)+(p.y-fCent.y)*(p.y-fCent.y)+(p.z-fCent.z)*(p.z-fCent.z));
    float dClick = sqrt((p.x-fClick.x)*(p.x-fClick.x)+(p.y-fClick.y)*(p.y-fClick.y)+(p.z-fClick.z)*(p.z-fClick.z));
    assert(dCent < 0.12f,
        "polygon-mode gizmo must land at the face CENTROID (click-independent) " ~
        "(" ~ fCent.x.to!string ~ "," ~ fCent.y.to!string ~ "," ~ fCent.z.to!string ~ "); got (" ~
        p.x.to!string ~ "," ~ p.y.to!string ~ "," ~ p.z.to!string ~ ") distCent=" ~ dCent.to!string);
    assert(dCent < dClick,
        "gizmo should be closer to the face centroid than the (off-centre) click point; " ~
        "distCent=" ~ dCent.to!string ~ " distClick=" ~ dClick.to!string);

    pj("/api/script","tool.set xfrm.elementMove off");
    settle();
}
