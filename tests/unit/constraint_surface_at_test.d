// `ConstrainStage`'s background surface forms (task 9403, M-CONS): `rayHit` /
// `rayHitAt` (ungated, the pixel CENTRE), `surfaceOnRay` / `surfaceAt` (gated
// `enabled && handle`, the RAW hit) and `offsetPoint`. Rig: two stacked quads
// as two background sources — source 0 the FAR quad (z = -1, larger), source 1
// the NEAR quad (z = 0) — under an ORTHO camera looking -Z through a NON-square
// 400 x 200 viewport (halfH 1, aspect 2: window point (sx, sy) -> world
// x = (sx / 200 - 1) * 2, y = 1 - sy / 100). The far quad is listed FIRST so a
// "first source wins" or "farthest wins" answer reads source 0, not 1. The near
// quad's right and bottom edges sit a quarter pixel into pixels x 320 / y 160,
// so the pixel's corner lies on the near quad and its centre on the far one.
module tests.unit.constraint_surface_at_test;

import std.format : format;
import std.math   : fabs;

import bvh_pick   : SurfaceHit;
import math       : Vec3, Viewport, ModelSpace, lookAt, orthographicMatrix, screenPointToRay;
import mesh       : Mesh;
import snap       : setBackgroundSnapSources;
import toolpipe.stages.constrain : ConstrainStage;

private bool near3(Vec3 a, Vec3 b) {
    return fabs(a.x - b.x) < 1e-5f && fabs(a.y - b.y) < 1e-5f && fabs(a.z - b.z) < 1e-5f;
}

private Mesh quadAt(float z, float x0, float x1, float y0, float y1) {
    Mesh m;
    m.vertices = [Vec3(x0, y0, z), Vec3(x1, y0, z), Vec3(x1, y1, z), Vec3(x0, y1, z)];
    m.faces    = [cast(uint[])[0, 1, 2, 3]];
    return m;
}

private Viewport orthoRig() {
    immutable eye = Vec3(0, 0, 5);
    return Viewport(lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0)),
                    orthographicMatrix(1.0f, 2.0f, 0.01f, 100.0f), 400, 200, 0, 0, eye);
}

unittest {
    Mesh far  = quadAt(-1.0f, -1.5f, 1.5f,    -0.75f,   0.75f);
    Mesh near = quadAt( 0.0f, -1.0f, 1.2025f, -0.6025f, 0.6f);
    setBackgroundSnapSources([cast(const(Mesh)*)&far, cast(const(Mesh)*)&near],
                             [ModelSpace.world(), ModelSpace.world()]);
    scope(exit) setBackgroundSnapSources(null, null);   // no leak into later modules
    auto vp = orthoRig();
    auto cs = new ConstrainStage();
    cs.enabled = true;
    SurfaceHit h, want;
    Vec3 org, dir;

    // (1) The pointer gate. Must stay green first: with `handle` off neither
    // gated form answers ...
    cs.handle = false;
    screenPointToRay(200.5f, 100.5f, vp, org, dir);
    assert(!cs.surfaceAt(200, 100, vp, h), "handle off: surfaceAt must refuse");
    assert(!cs.surfaceOnRay(org, dir, h), "handle off: surfaceOnRay must refuse");
    // ... while the ungated forms do, at the same pixel and ray.
    assert(cs.rayHitAt(200, 100, vp, h), "handle off: rayHitAt is ungated and must hit");
    assert(cs.rayHit(org, dir, h), "handle off: rayHit is ungated and must hit");
    cs.handle  = true;
    cs.enabled = false;
    assert(!cs.surfaceAt(200, 100, vp, h), "constraint off: surfaceAt must refuse");
    assert(!cs.surfaceOnRay(org, dir, h), "constraint off: surfaceOnRay must refuse");
    assert(cs.rayHitAt(200, 100, vp, h), "constraint off: rayHitAt is ungated and must hit");
    cs.enabled = true;

    // (2) The centre pixel over BOTH sources is the NEAR quad (source 1),
    // equal EXACTLY to `rayHit` on the hand-built pixel-centre ray, in both
    // the pixel and the ray forms.
    assert(cs.rayHit(org, dir, want) && want.source == 1 && near3(want.point, Vec3(0.005f, -0.005f, 0)),
           format("oracle: the centre ray must hit the near quad (1) at (0.005, -0.005, 0); got %s at %s",
                  want.source, want.point));
    assert(cs.surfaceAt(200, 100, vp, h) && h.source == 1 && h.point == want.point && h.t == want.t,
           format("centre pixel: surfaceAt must equal the ray oracle %s; got source %s at %s",
                  want.point, h.source, h.point));
    assert(cs.surfaceOnRay(org, dir, h) && h.point == want.point,
           format("centre ray: surfaceOnRay must equal the ray oracle %s; got %s", want.point, h.point));

    // (3) The offset is the client's: `surfaceAt` keeps the RAW hit, and
    // `offsetPoint` moves it 0.1 along the facet normal.
    cs.offset = 0.1f;
    assert(cs.surfaceAt(200, 100, vp, h) && h.point == want.point,
           format("offset 0.1: surfaceAt must return the un-offset hit %s; got %s", want.point, h.point));
    assert(fabs(fabs(h.normal.z) - 1) < 1e-6f, format("the quad's facet normal is +-Z; got %s", h.normal));
    const off = cs.offsetPoint(h.point, h.normal);
    assert(off == h.point + h.normal * 0.1f && fabs(fabs(off.z) - 0.1f) < 1e-6f,
           format("offsetPoint must be the hit + 0.1 * normal; got %s from %s along %s", off, h.point, h.normal));
    cs.offset = 0.0f;

    // (4) The pixel CENTRE on a quad edge: the corners of pixels (320, 100) and
    // (200, 160) lie on the near quad, their centres a quarter pixel past its
    // right / bottom edge, on the far quad (z = -1). A corner ray (no +0.5) or
    // an x/y swap reads the near quad.
    foreach (px; [[320, 100], [200, 160]]) {
        assert(cs.rayHitAt(px[0], px[1], vp, h) && h.source == 0 && fabs(h.point.z + 1) < 1e-6f,
               format("edge pixel %s: rayHitAt must read the FAR quad (0) at the pixel centre; got %s at %s",
                      px, h.source, h.point));
        assert(cs.surfaceAt(px[0], px[1], vp, h) && h.source == 0,
               format("edge pixel %s: surfaceAt must read the FAR quad (0); got %s", px, h.source));
    }

    // (5) A pixel off both quads misses: (390, 10) is world (1.905, 0.895).
    assert(!cs.rayHitAt(390, 10, vp, h),
           format("pixel (390, 10) is off both quads and must miss; got source %s at %s", h.source, h.point));

    // (6) The hover publish (Point mode, the topology pen's): the centre
    // pixel's hit offset 0.1 along the normal, then a miss publishes NO hit
    // (the packet is rebuilt per event, never the last hit kept).
    import toolpipe.packets : ConstrainGeom, ConstrainHitPacket, SubjectPacket;
    import operator : VectorStack;
    cs.geom   = ConstrainGeom.Point;
    cs.offset = 0.1f;
    ConstrainHitPacket publish(int x, int y) {
        SubjectPacket subj;
        subj.viewport = vp; subj.cursorValid = true; subj.cursorX = x; subj.cursorY = y;
        VectorStack vts;
        vts.put(&subj);
        assert(cs.evaluate(vts), "an enabled stage evaluates");
        auto p = vts.get!ConstrainHitPacket();
        assert(p !is null, format("Point mode must publish a hit packet at (%s, %s)", x, y));
        return *p;
    }
    const hp = publish(200, 100);
    assert(hp.hit && near3(hp.point, want.point + hp.normal * 0.1f) && fabs(fabs(hp.normal.z) - 1) < 1e-6f,
           format("publish: the hit offset 0.1 along the normal (%s + 0.1 * %s); got hit %s at %s",
                  want.point, hp.normal, hp.hit, hp.point));
    const miss = publish(390, 10);
    assert(!miss.hit, format("publish: a miss after a hit must publish no hit; got %s at %s", miss.hit, miss.point));

    // (7) The publish is UNGATED by `handle` (as before 9403; no capture backs
    // a gate): with `handle` off the hover still hits, offset in Point mode.
    cs.handle = false;
    const ungated = publish(200, 100);
    assert(ungated.hit && near3(ungated.point, want.point + ungated.normal * 0.1f),
           format("publish, handle off: the hover must still hit at %s + 0.1 * normal; got hit %s at %s",
                  want.point, ungated.hit, ungated.point));
    cs.handle = true;

    // (8) Screen mode publishes the RAW hit (no offset, as before 9403).
    cs.geom = ConstrainGeom.Screen;
    const screen = publish(200, 100);
    assert(screen.hit && screen.point == want.point,
           format("publish, Screen: the un-offset hit %s (offset 0.1 must not apply); got hit %s at %s",
                  want.point, screen.hit, screen.point));
}
