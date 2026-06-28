import std.net.curl;
import std.json;
import std.math : fabs, sqrt, sin, cos, PI;
import std.conv : to;
import std.format : format;
import std.stdio : writeln, writefln;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

import drag_helpers;

void waitPlaybackFinish() {
    import core.thread : Thread;
    import core.time   : msecs;
    foreach (_; 0 .. 200) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "playback didn't finish within 10s");
}

string buildPartialDragLog(int vpX, int vpY, int vpW, int vpH,
                           int x0, int y0, int x1, int y1,
                           int steps, bool release, double tStart = 50.0)
{
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        tStart, x0, y0);
    double stepMs = 50.0;
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        double t = tStart + i * stepMs;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, x, y, x - lastX, y - lastY);
        lastX = x; lastY = y;
    }
    if (release) {
        double tUp = tStart + (steps + 1) * stepMs;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
            tUp, x1, y1);
    }
    return log;
}

unittest {
    postJson("/api/reset", "");
    postJson("/api/script", "tool.set scale");
    // Set far pivot
    postJson("/api/script", "tool.pipe.attr actionCenter userPlacedX 10000.0");
    postJson("/api/script", "tool.pipe.attr actionCenter userPlacedY 10000.0");
    postJson("/api/script", "tool.pipe.attr actionCenter userPlacedZ 10000.0");
    
    // Set camera to look at far pivot
    postJson("/api/camera", `{"eye":{"x":10003.0,"y":10001.0,"z":10002.0},"focus":{"x":10000,"y":10000,"z":10000}}`);
    
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    
    Vec3 farPiv = Vec3(10000.0f, 10000.0f, 10000.0f);
    float size = gizmoSize(farPiv, vp);
    writefln("gizmoSize = %g", size);
    
    float sx1, sy1, sx2, sy2;
    bool ok1 = projectToWindow(Vec3(farPiv.x + size * (1.0f/7), farPiv.y, farPiv.z), vp, sx1, sy1);
    bool ok2 = projectToWindow(Vec3(farPiv.x + size * 1.18f, farPiv.y, farPiv.z), vp, sx2, sy2);
    writefln("proj ok: %s %s", ok1, ok2);
    writefln("px1=(%g,%g) px2=(%g,%g)", sx1, sy1, sx2, sy2);
    
    int gx, gy; double ux, uy;
    axisGrabPx(farPiv, vp, gx, gy, ux, uy);
    writefln("grab=(%d,%d) dir=(%g,%g)", gx, gy, ux, uy);
    int x1d = gx + cast(int)(50.0 * ux);
    int y1d = gy + cast(int)(50.0 * uy);
    writefln("drag to (%d,%d)", x1d, y1d);
    
    auto preDragVerts = getJson("/api/model")["vertices"].array;
    writefln("pre-drag vert[0]: %g %g %g",
        preDragVerts[0].array[0].floating,
        preDragVerts[0].array[1].floating,
        preDragVerts[0].array[2].floating);
    
    auto log = buildPartialDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                   gx, gy, x1d, y1d, 10, true);
    auto r = postJson("/api/play-events", log);
    
    import core.thread : Thread; import core.time : msecs;
    foreach (_; 0 .. 200) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.TRUE) break;
        Thread.sleep(50.msecs);
    }
    
    auto cpu = getJson("/api/model")["vertices"].array;
    writefln("post-drag vert[0]: %g %g %g",
        cpu[0].array[0].floating,
        cpu[0].array[1].floating,
        cpu[0].array[2].floating);
    
    double px = 10000.0, py = 10000.0, pz = 10000.0;
    foreach (i, v; cpu) {
        double pre_x = preDragVerts[i].array[0].floating;
        double pre_y = preDragVerts[i].array[1].floating;
        double pre_z = preDragVerts[i].array[2].floating;
        double rdx = pre_x - px, rdy = pre_y - py, rdz = pre_z - pz;
        double rlen = sqrt(rdx*rdx + rdy*rdy + rdz*rdz);
        double post_x = v.array[0].floating;
        double post_y = v.array[1].floating;
        double post_z = v.array[2].floating;
        double qx = post_x - px, qy = post_y - py, qz = post_z - pz;
        double dot = qx*(rdx/rlen) + qy*(rdy/rlen) + qz*(rdz/rlen);
        double latx = qx - dot*(rdx/rlen), laty = qy - dot*(rdy/rlen), latz = qz - dot*(rdz/rlen);
        double latErr = sqrt(latx*latx + laty*laty + latz*latz);
        writefln("vert[%d]: pre=(%g,%g,%g) post=(%g,%g,%g) latErr=%g",
            i, pre_x, pre_y, pre_z, post_x, post_y, post_z, latErr);
    }
    
    postJson("/api/script", "tool.set scale off");
    postJson("/api/camera", `{"eye":{"x":1.3,"y":1.2,"z":2.5},"focus":{"x":0,"y":0,"z":0}}`);
}
