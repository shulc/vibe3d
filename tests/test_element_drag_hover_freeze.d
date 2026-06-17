// Element Move: while a click+drag is in progress the hover must FREEZE on the
// element picked at drag-start — dragging the cursor over OTHER vertices must
// NOT re-highlight them. Without the freeze the per-frame pick re-hovered
// whatever the moving cursor passed over.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;
import std.string : format;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";
JSONValue pj(string p, string b){ return parseJSON(cast(string)post(baseUrl~p,b)); }
JSONValue gj(string p){ return parseJSON(cast(string)get(baseUrl~p)); }
void settle(){ import core.thread:Thread; import core.time:msecs; Thread.sleep(150.msecs); }

int hoverVertex() {
    return cast(int) gj("/api/toolpipe/eval")["hover"]["vertex"].integer;
}

unittest {
    pj("/api/reset","");
    // Pre-select a DIFFERENT vertex (v0) as the moving set, with a tiny falloff
    // sphere, so the picked vertex v6 stays STATIONARY during the drag (it is
    // not in the moving set and v0 is far outside v6's sphere → nothing moves).
    // That way the cursor genuinely DIVERGES from v6 — if the per-frame pick
    // weren't frozen it would re-hover whatever is under the moving cursor.
    pj("/api/select", `{"mode":"vertices","indices":[0]}`);
    pj("/api/script","tool.set xfrm.elementMove on");
    pj("/api/command","tool.pipe.attr falloff dist 0.2");
    pj("/api/command","tool.pipe.attr falloff mode vertex");
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 v6 = Vec3(0.5f, 0.5f, 0.5f);
    int v6x, v6y, cx, cy; float sx, sy;
    assert(projectToWindow(v6, vp, sx, sy)); v6x = cast(int)sx; v6y = cast(int)sy;
    // Mesh-interior target: the origin projects to the front-face interior,
    // away from every corner vertex — no vertex sits under that pixel.
    assert(projectToWindow(Vec3(0,0,0), vp, sx, sy)); cx = cast(int)sx; cy = cast(int)sy;

    // Down on v6, then drag the cursor onto the face interior — DON'T release
    // (read hover mid-drag). v6 is stationary, so the cursor leaves it.
    string log = format(
        `{"t":0.0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`~"\n",
        cam.vpX,cam.vpY,cam.width,cam.height);
    log ~= format(`{"t":30.0,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`~"\n",v6x,v6y);
    foreach (i; 1 .. 6) {
        int mxp = v6x + (cx - v6x) * cast(int)i / 5;
        int myp = v6y + (cy - v6y) * cast(int)i / 5;
        log ~= format(`{"t":%.1f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":1,"yrel":1,"state":1,"mod":0}`~"\n",
            30.0+i*15, mxp, myp);
    }
    playAndWait(log);
    settle();

    // Frozen: still the picked vertex 6 even though the cursor is now over a
    // face. Without the freeze the per-frame pick would have set vertex=-1
    // (no vert under the cursor) and lit a face instead.
    int hv = hoverVertex();
    assert(hv == 6,
        "during the drag hover must stay frozen on the picked vertex 6; got " ~
        "hover.vertex=" ~ hv.to!string ~ " (cursor moved onto the face interior)");

    string up = format(
        `{"t":0.0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`~"\n"~
        `{"t":30.0,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`~"\n",
        cam.vpX,cam.vpY,cam.width,cam.height, cx, cy);
    playAndWait(up); settle();
    pj("/api/script","tool.set xfrm.elementMove off");
    settle();
}
