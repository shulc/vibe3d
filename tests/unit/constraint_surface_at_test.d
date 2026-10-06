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

    // (8) Screen mode offsets the hit, re-casts it along the view and offsets
    // it again (task 9477, capture K-C4 scr): on this camera-facing quad the
    // re-cast lands back on the hit, so the point is hit + 0.1 * normal (the
    // double offset proper needs a slanted surface: suite
    // test_topopen_constraint_modes, cells scr / scr2).
    cs.geom = ConstrainGeom.Screen;
    const screen = publish(200, 100);
    assert(screen.hit && near3(screen.point, want.point + screen.normal * 0.1f),
           format("publish, Screen: the hit %s + 0.1 * normal %s; got hit %s at %s",
                  want.point, screen.normal, screen.hit, screen.point));

    // (9) Screen at offset 0 is the surface under the point (capture K-SC
    // scr0): the pass runs at every offset and its re-cast takes the hit AT
    // the point (t = 0), not the far quad behind it (z = -1).
    cs.offset = 0.0f;
    const screen0 = publish(200, 100);
    assert(screen0.hit && near3(screen0.point, want.point),
           format("publish, Screen, offset 0: the near quad's hit %s; got hit %s at %s",
                  want.point, screen0.hit, screen0.point));

    // (9b) Internal/composition writes preserve stored values. Interactive
    // doors own the bound; notifying restores do not clamp (PRM4).
    assert(cs.setAttr("offset", "-0.1") && cs.offset == -0.1f,
           format("internal offset -0.1 must stand; got %s", cs.offset));
    cs.offset = 0;

    // (9c) The Screen re-cast takes the NEAREST hit on the view line, either
    // direction (K-SC ovh_lo, ovh_flank): from z -0.4 the near quad 0.4 back
    // toward the eye beats the far quad 0.6 ahead (a forward-only cast reads
    // z -1); from z -0.6 the far quad, 0.4 ahead, wins (the control).
    const back = cs.pass(Vec3(0.005f, -0.005f, -0.4f), vp);
    assert(near3(back, Vec3(0.005f, -0.005f, 0)),
           format("pass, Screen, from z -0.4: the near quad behind (z 0); got %s", back));
    const ahead = cs.pass(Vec3(0.005f, -0.005f, -0.6f), vp);
    assert(near3(ahead, Vec3(0.005f, -0.005f, -1)),
           format("pass, Screen, from z -0.6: the far quad ahead (z -1); got %s", ahead));

    // (10) Point runs the nearest-foot pass after the offset (K-C4 law, task
    // 9477): at pixel (320, 100) the hit is the FAR quad (1.205, -0.005,
    // -1); offset 1.5 puts it at z 0.5, nearer the near quad's right
    // edge (0.5) than the far quad (1.5), so the foot is that edge's point and
    // the result (1.2025, -0.005, 1.5) — the bare offset would stay at z 0.5.
    cs.geom   = ConstrainGeom.Point;
    cs.offset = 1.5f;
    const foot = publish(320, 100);
    assert(foot.hit && near3(foot.point, Vec3(1.2025f, -0.005f, 1.5f)),
           format("publish, Point, offset 1.5: the near quad's edge foot + 1.5 * normal "
                  ~ "(1.2025, -0.005, 1.5); got hit %s at %s", foot.hit, foot.point));

    // (11) `pass` carries the stage's `dblSided`: a Vector pass from behind
    // the far quad (z -2, moving +Z) meets its BACK face — kept single-sided,
    // taken double-sided.
    cs.geom   = ConstrainGeom.Vector;
    cs.offset = 0.0f;
    assert(cs.pass(Vec3(0, 0, -2), vp, Vec3(0, 0, 1)) == Vec3(0, 0, -2),
           "pass, Vector, single-sided: the far quad's back face must not take the point");
    // ... and Vector casts FORWARD only, unlike Screen (9c): from z -0.4
    // moving -Z the far quad 0.6 ahead, never the near quad 0.4 behind.
    const fwd = cs.pass(Vec3(0.005f, -0.005f, -0.4f), vp, Vec3(0, 0, -1));
    assert(near3(fwd, Vec3(0.005f, -0.005f, -1)),
           format("pass, Vector, from z -0.4 moving -Z: the far quad ahead (z -1); got %s", fwd));
    cs.dblSided = true;
    const backFace = cs.pass(Vec3(0, 0, -2), vp, Vec3(0, 0, 1));
    assert(near3(backFace, Vec3(0, 0, -1)),
           format("pass, Vector, double-sided: the far quad's back face (0, 0, -1); got %s", backFace));
}

unittest {
    import constraint : surfaceComponentMask, guideComponentEqual;
    assert(surfaceComponentMask(Vec3(0.4f, 0, 0.2f), Vec3(0.4f, -0.2f, 0.2f), 1) == 2,
           "surface-guide: a depth-only hit accepts the view-normal component");
    assert(surfaceComponentMask(Vec3(0.4f, 0, 0.2f), Vec3(0.5f, -0.2f, 0.2f), 1) == 7,
           "surface-guide: changed represented channels accept the whole point");
    assert(surfaceComponentMask(Vec3(0.4f, 0, 0.2f), Vec3(0.4f, -0.2f, 0.2f), -1) == 0,
           "surface-guide: missing orthographic axis does not claim a component producer");
    auto background = quadAt(0, -1, 1, -1, 1);
    setBackgroundSnapSources([cast(const(Mesh)*)&background], [ModelSpace.world()]);
    scope(exit) setBackgroundSnapSources(null, null);
    auto vp = orthoRig();
    vp.focus = Vec3(0, 0, 0);
    auto cs = new ConstrainStage();
    cs.enabled = true;
    const incoming = Vec3(0.4f, 0.2f, 0.3f);
    auto guided = cs.componentGuide(incoming, vp);
    assert(guided.acceptedMask == 4 && near3(guided.valuesWorld, Vec3(0.4f, 0.2f, 0)),
           "surface-guide: gated hit resolves Z while keeping represented X/Y");
    cs.handle = false;
    assert(cs.componentGuide(incoming, vp).acceptedMask == 0,
           "surface-guide: disabled handle refuses an otherwise hittable background");
    cs.handle = true; cs.enabled = false;
    assert(cs.componentGuide(incoming, vp).acceptedMask == 0,
           "surface-guide: disabled constraint refuses an otherwise hittable background");
    cs.enabled = true;
    assert(cs.componentGuide(Vec3(4, 4, 0.3f), vp).acceptedMask == 0,
           "surface-guide: remote background misses despite nonempty inventory");
}

unittest {
    import constraint : guideComponentEqual, surfaceComponentMask;
    assert(guideComponentEqual(0, 0.9e-10), "guide-compare: absolute floor admits a smaller residual");
    assert(!guideComponentEqual(0, 1e-10) && !guideComponentEqual(0, -1e-10),
           "guide-compare: absolute floor boundary is strict on both sides");
    assert(guideComponentEqual(3360000, 3360000.9), "guide-compare: relative tolerance admits a smaller residual");
    assert(!guideComponentEqual(3360000, 3360001.1), "guide-compare: relative tolerance rejects a larger residual");
    assert(surfaceComponentMask(Vec3(0.43f, 0, 0.2f), Vec3(0.43000006f, -0.2f, 0.2f), 1) == 2,
           "guide-compare: representable X residual preserves a depth-only mask");
    size_t n;
    foreach (axis; 0 .. 3) {
        const input = Vec3(0.4f, 0.3f, 0.2f);
        Vec3 resolved = input;
        if (axis == 0) resolved.x = -0.2f;
        else if (axis == 1) resolved.y = -0.2f;
        else resolved.z = -0.2f;
        assert(surfaceComponentMask(input, resolved, axis) == (1 << axis),
               "guide-mask: only the view-normal channel is replaced");
        ++n;
    }
    assert(n == 3, "guide-mask: all three axes exercised");
    size_t changed;
    foreach (axis; 0 .. 3) foreach (channel; 0 .. 3) if (channel != axis) {
        const input = Vec3(0.4f, 0.3f, 0.2f);
        Vec3 resolved = input;
        if (channel == 0) resolved.x += 0.1f;
        else if (channel == 1) resolved.y += 0.1f;
        else resolved.z += 0.1f;
        assert(surfaceComponentMask(input, resolved, axis) == 7,
               "guide-mask: every changed represented channel accepts the whole point");
        ++changed;
    }
    assert(changed == 6, "guide-mask: six represented-channel contrasts exercised");
}

unittest {
    import drag : HandleDrag, DragFrame, DragKind;
    import std.math : fabs;
    auto vp = Viewport(lookAt(Vec3(0, 5, 0), Vec3(0, 0, 0), Vec3(0, 0, -1)),
        orthographicMatrix(300.0f / 440.0f, 800.0f / 600.0f, 0.01f, 100), 800, 600, 0, 0, Vec3(0, 5, 0));
    vp.focus = Vec3(0, 0, 0);
    size_t n;
    foreach (depth; [-0.005f, -0.2f]) {
        Mesh background;
        background.vertices = [Vec3(-2, depth, -2), Vec3(2, depth, -2), Vec3(2, depth, 2), Vec3(-2, depth, 2)];
        background.faces = [cast(uint[])[0, 3, 2, 1]];
        setBackgroundSnapSources([cast(const(Mesh)*)&background], [ModelSpace.world()]);
        scope(exit) setBackgroundSnapSources(null, null);
        auto cs = new ConstrainStage(); cs.enabled = true;
        const expectedY = depth == -0.005f ? -0.0048828125f : -0.2001953125f;
        SurfaceHit admitted;
        assert(cs.surfaceOnRay(Vec3(0.285f, 10000, 0.295f), Vec3(0, -1, 0), admitted, true),
               "guided-depth: precise reconstruction must use a real admitted surface hit");
        assert(fabs(admitted.preciseT - (10000.0 - cast(double)depth)) < 1e-9,
               "guided-depth: t is reconstructed in double on the admitted triangle");
        SurfaceHit ordinary;
        assert(cs.surfaceOnRay(Vec3(0.285f, 10000, 0.295f), Vec3(0, -1, 0), ordinary) &&
               ordinary.preciseT == double.infinity && ordinary.point == admitted.point && ordinary.t == admitted.t,
               "guided-depth: ordinary surface reader preserves point/t without precise reconstruction");
        assert(admitted.productRoundedPoint.y == expectedY,
               "guided-depth: narrow only the ray product before adding the origin");
        const direct = cs.componentGuide(Vec3(0.285f, 0, 0.295f), vp);
        assert(direct.acceptedMask == 2 && direct.valuesWorld.y == expectedY,
               format("guided-depth: orthographic ray hit carries binary32 product residual; depth=%s mask=%s got=%s want=%s",
                      depth, direct.acceptedMask, direct.valuesWorld.y, expectedY));
        HandleDrag g; g.press(Vec3(0.272742241f, 0, 0.297731015f), 0, 0);
        scope resolve = (Vec3 u) { return cs.componentGuide(u, vp); };
        bool skip;
        const point = g.client(70, -42, DragFrame(DragKind.viewPlane), vp, skip, resolve);
        assert(!skip && near3(point, Vec3(0.43f, expectedY, 0.2f)), "guided-depth: actual stage feeds component values to shared client");
        const delta = point - g.point;
        assert(fabs(delta.x - 0.157257759f) < 1e-6f && fabs(delta.z + 0.097731015f) < 1e-6f,
               "guided-depth: accepted Y changes unmasked X/Z anchor subtraction to raw H");
        ++n;
    }
    assert(n == 2, "guided-depth: shallow and deep producer values exercised");
}
