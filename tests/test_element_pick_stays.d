// Element Move: after a full click + drag + release on an element, the gizmo /
// action center must STAY on the picked element — it must NOT snap back to the
// moving-set centroid (the bug: with an empty selection the Move mouse-up
// re-pinned the action center to the whole-mesh centroid).

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;
import std.string : format;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}
void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}
string hoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 20.0, x, y);
    return log;
}

// Vertex mode, empty selection: hover v6, full pick+drag+release, then read the
// pivot AFTER the release — it must still be on the picked vertex, not at the
// mesh centroid.
unittest {
    postJson("/api/reset", "");
    postJson("/api/script", "tool.set xfrm.elementMove on");
    postJson("/api/command", "tool.pipe.attr falloff dist 4");
    postJson("/api/command", "tool.pipe.attr falloff mode vertex");
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 v6 = Vec3(0.5f, 0.5f, 0.5f);
    int vx, vy;
    {
        float sx, sy;
        assert(projectToWindow(v6, vp, sx, sy), "v6 should be on-camera");
        vx = cast(int)sx; vy = cast(int)sy;
    }

    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height, vx, vy));
    settle();
    // Full gesture: down at v6, drag up 80px, release. A LARGE drag so the
    // picked vertex moves well beyond the 0.05 tolerance below — that is what
    // distinguishes "gizmo follows the element" (live) from "gizmo frozen at
    // the click point" (userPlaced) and from "gizmo at the centroid" (the bug).
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             vx, vy, vx, vy - 80, 10));
    settle();

    // reference `center.element` parity: the gizmo / action center is GLUED to the
    // picked element — after the drag it sits at the vertex's NEW position, not
    // at the moving-set centroid (the bug) and not frozen at the click point.
    auto verts = getJson("/api/model")["vertices"].array;
    auto v6now = verts[6].array;
    Vec3 picked = Vec3(cast(float)v6now[0].floating,
                       cast(float)v6now[1].floating,
                       cast(float)v6now[2].floating);
    Vec3 p = evalPivot();
    float d = sqrt((p.x-picked.x)*(p.x-picked.x) +
                   (p.y-picked.y)*(p.y-picked.y) +
                   (p.z-picked.z)*(p.z-picked.z));
    assert(d < 0.05f,
        "Element gizmo must track the picked vertex's CURRENT position " ~
        "(" ~ picked.x.to!string ~ "," ~ picked.y.to!string ~ "," ~
        picked.z.to!string ~ "); pivot=(" ~ p.x.to!string ~ "," ~
        p.y.to!string ~ "," ~ p.z.to!string ~ ") dist=" ~ d.to!string);
    // And the vertex must actually have MOVED up (sanity: the drag did work,
    // so this isn't trivially satisfied by "nothing moved").
    assert(picked.y > 0.5f + 1e-3f,
        "picked vertex should have moved up under the drag; y=" ~
        picked.y.to!string);

    postJson("/api/script", "tool.set xfrm.elementMove off");
    settle();
}
