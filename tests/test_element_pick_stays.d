// Element Move: after a full click + drag + release on an element, the gizmo /
// action center must STAY AT THE POINT THE PICKING CLICK CAPTURED — it must not
// snap back to the moving-set centroid, and it must not follow the picked
// element as that element moves.
//
// THIS FILE STATED THE OPPOSITE LAW UNTIL TASK 1530, and it is worth saying why
// rather than just editing the assert. It was written when `Mode.Element`'s
// pivot was the LIVE centroid of the picked vertex ring, recomputed from
// `mesh_.vertices` every read; on that law "glued to the element" was correct
// and "frozen at the click point" was, in this file's own words, one of the
// wrong answers. The owner hit the consequence in ordinary work — a pivot
// recomputed from the geometry the tool is moving closes a feedback loop, and a
// scale about it diverges — and signed the reference's law instead: the pivot
// is a POINT captured on the button-DOWN of a picking click, held for that
// gesture and every later one until the next such click. So the assertion below
// is inverted BY DECISION, not because the test was wrong for its time.
//
// It is also, unplanned, the second independent measurement of the defect. When
// task 1530's change landed and this file was still on the old law, it failed
// with the pivot sitting at exactly (0.5,0.5,0.5) — the click point — while the
// picked vertex had travelled to (0.489374,0.774534,0.5), `dist=0.27474`. The
// purpose-built cell (tests/test_acen_element_freeze_translate.d) measured
// 0.2646 on the same cube under its own mutation. Two instruments written for
// different purposes, agreeing on the size of the drift, one of them for free.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;
import std.string : format;

import drag_helpers;

void main() {}

alias baseUrl = testBaseUrl;


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
    postJson("/api/command", commandBody("scene.reset"));
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

    // The captured point survives the gesture. Three answers are distinguishable
    // here and the cell separates all three, which is why it is still worth
    // running after the inversion:
    //   (a) the CLICK POINT, v6's pre-drag position (0.5,0.5,0.5) — the law;
    //   (b) v6's post-drag position — the live ring centroid, the defect;
    //   (c) the moving-set / whole-mesh centroid, near the origin — the older
    //       bug this file was originally written against, still guarded.
    auto verts = getJson("/api/model")["vertices"].array;
    auto v6now = verts[6].array;
    Vec3 picked = Vec3(cast(float)v6now[0].floating,
                       cast(float)v6now[1].floating,
                       cast(float)v6now[2].floating);
    Vec3 p = evalPivot();

    float dClick = sqrt((p.x-v6.x)*(p.x-v6.x) +
                        (p.y-v6.y)*(p.y-v6.y) +
                        (p.z-v6.z)*(p.z-v6.z));
    assert(dClick < 0.05f,
        "Element pivot must STAY at the point the picking click captured " ~
        "(" ~ v6.x.to!string ~ "," ~ v6.y.to!string ~ "," ~ v6.z.to!string ~
        "); pivot=(" ~ p.x.to!string ~ "," ~ p.y.to!string ~ "," ~
        p.z.to!string ~ ") dist=" ~ dClick.to!string);

    // The vertex must actually have MOVED (sanity: the drag did work, so the
    // green above is not trivially satisfied by "nothing moved" — without this
    // a tool that refused the gesture would pass).
    assert(picked.y > 0.5f + 1e-3f,
        "picked vertex should have moved up under the drag; y=" ~
        picked.y.to!string);

    // (b) must be REFUTED, not merely un-asserted: the vertex has moved, so a
    // pivot that tracked it live would now be a measurable distance away. This
    // is the assert that goes red if the live ring centroid ever comes back.
    float dLive = sqrt((p.x-picked.x)*(p.x-picked.x) +
                       (p.y-picked.y)*(p.y-picked.y) +
                       (p.z-picked.z)*(p.z-picked.z));
    assert(dLive > 0.1f,
        "Element pivot must NOT follow the picked vertex to its new position " ~
        "(" ~ picked.x.to!string ~ "," ~ picked.y.to!string ~ "," ~
        picked.z.to!string ~ ") — that is the feedback loop task 1530 removed; " ~
        "pivot=(" ~ p.x.to!string ~ "," ~ p.y.to!string ~ "," ~
        p.z.to!string ~ ") dist=" ~ dLive.to!string);

    // (c) the original bug this file guarded, unchanged in force: the pivot must
    // not be the whole-mesh centroid either.
    float dOrigin = sqrt(p.x*p.x + p.y*p.y + p.z*p.z);
    assert(dOrigin > 0.5f,
        "Element pivot must not snap back to the moving-set / whole-mesh " ~
        "centroid near the origin; pivot=(" ~ p.x.to!string ~ "," ~
        p.y.to!string ~ "," ~ p.z.to!string ~ ")");

    postJson("/api/script", "tool.set xfrm.elementMove off");
    settle();
}
