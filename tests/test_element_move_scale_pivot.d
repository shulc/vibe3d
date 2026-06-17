// Element Move with Scale flipped on: the picked element is the ACEN pivot, so
// a scale leaves the picked vertex EXACTLY in place (scale about a point fixes
// that point) while other verts move. Verifies R/S element-move drives the
// transform about the picked-element action center, and that the picked vertex
// (ACEN pivot) is geometry-stable under it. (The gizmo-position drift caveat for
// R/S edge/face picks is display-only and documented in actcenter.d.)

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
void cmd(string s){ auto j = pj("/api/command", s); assert(j["status"].str == "ok", "cmd failed: " ~ s ~ " -> " ~ j.toString); }
void settle(){ import core.thread:Thread; import core.time:msecs; Thread.sleep(150.msecs); }

int hoverVertex() { return cast(int) gj("/api/toolpipe/eval")["hover"]["vertex"].integer; }
Vec3 vpos(int i) {
    auto a = gj("/api/model")["vertices"].array[i].array;
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
    pj("/api/command","tool.pipe.attr falloff mode vertex");
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 v6 = Vec3(0.5f, 0.5f, 0.5f);
    int vx, vy; float sx, sy;
    assert(projectToWindow(v6, vp, sx, sy)); vx = cast(int)sx; vy = cast(int)sy;

    // Pick v6 with a pure click (down + up, no drag) so geometry is unchanged
    // and the action center is anchored on v6.
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height, vx, vy));
    settle();
    assert(hoverVertex() == 6, "v6 must be hoverable for the pick");
    string click = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`~"\n"~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`~"\n"~
        `{"t":100.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`~"\n",
        cam.vpX,cam.vpY,cam.width,cam.height, vx, vy, vx, vy);
    playAndWait(click);
    settle();

    Vec3 v6Before = vpos(6);
    assert(fabs(v6Before.x-0.5f)<1e-3 && fabs(v6Before.y-0.5f)<1e-3 && fabs(v6Before.z-0.5f)<1e-3,
        "pure click must not move geometry; v6=" ~ v6Before.x.to!string);

    // Flip Scale on and scale up about the action center (= picked v6).
    cmd("tool.attr xfrm.elementMove S true");
    cmd("tool.attr xfrm.elementMove SX 2");
    cmd("tool.attr xfrm.elementMove SY 2");
    cmd("tool.attr xfrm.elementMove SZ 2");
    cmd("tool.doApply");
    settle();

    // The pivot point (v6) is fixed under scale-about-itself.
    Vec3 v6After = vpos(6);
    float dPivot = sqrt((v6After.x-v6Before.x)*(v6After.x-v6Before.x)+
                        (v6After.y-v6Before.y)*(v6After.y-v6Before.y)+
                        (v6After.z-v6Before.z)*(v6After.z-v6Before.z));
    assert(dPivot < 1e-3f,
        "picked vertex (= ACEN pivot) must stay fixed under element-move scale; " ~
        "it moved " ~ dPivot.to!string ~ " to (" ~ v6After.x.to!string ~ "," ~
        v6After.y.to!string ~ "," ~ v6After.z.to!string ~ ")");

    // Sanity: some OTHER vertex within the falloff actually moved (so the scale
    // ran and this isn't trivially satisfied).
    int moved = 0;
    foreach (i; 0 .. 8) {
        if (i == 6) continue;
        Vec3 b = Vec3([-0.5f,0.5f,0.5f,-0.5f,-0.5f,0.5f,0.5f,-0.5f][i],
                      [-0.5f,-0.5f,-0.5f,-0.5f,0.5f,0.5f,0.5f,0.5f][i],
                      [-0.5f,-0.5f,0.5f,0.5f,-0.5f,-0.5f,0.5f,0.5f][i]);
        Vec3 a = vpos(i);
        if (sqrt((a.x-b.x)*(a.x-b.x)+(a.y-b.y)*(a.y-b.y)+(a.z-b.z)*(a.z-b.z)) > 1e-3f) moved++;
    }
    assert(moved > 0, "element-move scale should have moved at least one non-pivot vertex");

    pj("/api/script","tool.set xfrm.elementMove off");
    settle();
}
