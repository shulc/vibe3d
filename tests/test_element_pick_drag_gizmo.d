// Element Move: during a click+drag on a vertex the VISUAL gizmo must jump
// onto the picked vertex at drag start and then move FROM there — it must NOT
// keep moving relative to its old (pre-click) center.
//
// The during-drag gizmo is drawn from the Move bank's handler.center (NOT the
// action-center packet), exposed as transform.gizmoCenter on /api/toolpipe/eval.
// We drive a down + a few motions but NO mouse-up, so the read lands mid-drag
// while the gizmo == handler.center.

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

Vec3 gizmoCenter() {
    auto t = gj("/api/toolpipe/eval")["transform"];
    auto c = t["gizmoCenter"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating, cast(float)c[2].floating);
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
    assert(projectToWindow(v6, vp, sx, sy));
    vx = cast(int)sx; vy = cast(int)sy;

    // Down at v6, a few small drag motions, NO up — read the gizmo mid-drag.
    string log = format(
        `{"t":0.0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`~"\n",
        cam.vpX,cam.vpY,cam.width,cam.height);
    log ~= format(`{"t":30.0,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`~"\n",vx,vy);
    foreach (i; 1 .. 4)
        log ~= format(`{"t":%.1f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":-4,"state":1,"mod":0}`~"\n",
            30.0+i*20, vx, vy-4*i);
    playAndWait(log);
    settle();

    Vec3 g = gizmoCenter();
    // After ~12px of drag from v6, the gizmo sits at v6 + a SMALL world delta:
    // x≈0.5, z≈0.5 (the drag was vertical). The bug anchored the drag at the
    // old center (origin) → gizmo near (0, small, 0): x≈0, z≈0.
    assert(fabs(g.x - 0.5f) < 0.15f && fabs(g.z - 0.5f) < 0.15f,
        "during the drag the gizmo must be on the picked vertex (x≈0.5,z≈0.5), "
        ~ "not anchored at the old center; gizmoCenter=(" ~ g.x.to!string ~ ","
        ~ g.y.to!string ~ "," ~ g.z.to!string ~ ")");

    // Release cleanly.
    string up = format(
        `{"t":0.0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`~"\n"~
        `{"t":30.0,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`~"\n",
        cam.vpX,cam.vpY,cam.width,cam.height, vx, vy-12);
    playAndWait(up); settle();
    pj("/api/script","tool.set xfrm.elementMove off");
    settle();
}
