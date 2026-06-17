// Element Move: click+drag must move the CLICKED vertex (the fresh pick), not
// the old anchor region. With a SMALL falloff sphere this is discriminating:
// only the picked vertex (weight=1 via the anchor ring) should move.
//
// The bug: the drag snapshot was taken from the pre-pick VectorStack, so its
// anchor ring + sphere centre were stale (empty / old centre). The picked
// vertex then got weight 0 (not in the stale ring, outside the old sphere) and
// did NOT move; the previously-anchored region moved instead.

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

Vec3 vpos(int i) {
    auto a = gj("/api/model")["vertices"].array[i].array;
    return Vec3(cast(float)a[0].floating, cast(float)a[1].floating, cast(float)a[2].floating);
}

unittest {
    pj("/api/reset","");
    pj("/api/script","tool.set xfrm.elementMove on");
    // SMALL sphere: without the anchor ring a vertex at √0.75≈0.87 from the
    // origin is OUTSIDE it, so only the picked vertex (ring weight=1) moves.
    pj("/api/command","tool.pipe.attr falloff dist 0.3");
    pj("/api/command","tool.pipe.attr falloff mode vertex");
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 v6 = Vec3(0.5f, 0.5f, 0.5f);
    int vx, vy; float sx, sy;
    assert(projectToWindow(v6, vp, sx, sy));
    vx = cast(int)sx; vy = cast(int)sy;

    Vec3 before = vpos(6);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             vx, vy, vx, vy - 40, 8));
    settle();
    Vec3 after = vpos(6);

    float moved = sqrt((after.x-before.x)*(after.x-before.x) +
                       (after.y-before.y)*(after.y-before.y) +
                       (after.z-before.z)*(after.z-before.z));
    assert(moved > 0.1f,
        "the CLICKED vertex must move under click+drag (anchor ring weight=1); " ~
        "it moved only " ~ moved.to!string ~ " — the drag is deforming the old " ~
        "anchor instead of the picked vertex");

    // The opposite corner v0=(-0.5,-0.5,-0.5) is far outside the small sphere
    // and not the pick — it must stay put.
    Vec3 v0 = vpos(0);
    assert(fabs(v0.x + 0.5f) < 1e-2f && fabs(v0.y + 0.5f) < 1e-2f
        && fabs(v0.z + 0.5f) < 1e-2f,
        "far non-picked vertex must stay put; got (" ~ v0.x.to!string ~ ","
        ~ v0.y.to!string ~ "," ~ v0.z.to!string ~ ")");

    pj("/api/script","tool.set xfrm.elementMove off");
    settle();
}
