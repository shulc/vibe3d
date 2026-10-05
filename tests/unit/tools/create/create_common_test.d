// Module unittests for `tools.create.create_common`, moved verbatim out of source/tools/create/create_common.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.create.create_common_test;

import math : Vec3, Viewport, dot, isOrtho, matrixMirrorsWinding, rayPlaneIntersect,
              screenPointToRay;
import std.math : abs, cos, sin;
import toolpipe.pipeline       : g_pipeCtx;
import toolpipe.packets        : SubjectPacket, WorkplanePacket, SnapPacket;
import toolpipe.stage          : TaskCode;
import toolpipe.stages.workplane : WorkplaneStage;
import operator                : VectorStack;
import mesh : Mesh;
import editmode : EditMode;
import snap : SnapResult, snapCursor;
import snap_render : publishLastSnap, clearLastSnap;
import document : primaryModelSpace;
import tools.create.create_common;

unittest {
    import math : Viewport;

    // Helper: build a Viewport whose view matrix has given column-major
    // elements. Only elements [2], [6], [10] (the forward-vector components)
    // matter for pickMostFacingPlane.
    Viewport makeVp(float v2, float v6, float v10) {
        Viewport vp;
        vp.view[] = 0;
        vp.view[2]  = v2;
        vp.view[6]  = v6;
        vp.view[10] = v10;
        return vp;
    }

    // Camera looking mostly along X — should pick X plane
    {
        auto vp = makeVp(0.9f, 0.3f, 0.1f);
        auto bp = pickMostFacingPlane(vp);
        assert(bp.normal.x == 1 && bp.normal.y == 0 && bp.normal.z == 0);
        assert(bp.axis1.y  == 1);
        assert(bp.axis2.z  == 1);
    }

    // Camera looking mostly along Y — should pick Y plane
    {
        auto vp = makeVp(0.1f, 0.95f, 0.2f);
        auto bp = pickMostFacingPlane(vp);
        assert(bp.normal.y == 1 && bp.normal.x == 0 && bp.normal.z == 0);
        assert(bp.axis1.x  == 1);
        assert(bp.axis2.z  == 1);
    }

    // Camera looking mostly along Z — should pick Z plane
    {
        auto vp = makeVp(0.1f, 0.2f, 0.85f);
        auto bp = pickMostFacingPlane(vp);
        assert(bp.normal.z == 1 && bp.normal.x == 0 && bp.normal.y == 0);
        assert(bp.axis1.x  == 1);
        assert(bp.axis2.y  == 1);
    }

    // Equal X and Z — X wins (avx >= avz in tie)
    {
        auto vp = makeVp(0.7f, 0.0f, 0.7f);
        auto bp = pickMostFacingPlane(vp);
        assert(bp.normal.x == 1);
    }
}

// WorkplaneFrame matrix smoke test — toWorld∘toLocal = identity, and
// local Y maps to the published normal. Independent of g_pipeCtx.
unittest {
    import std.math : abs;
    auto f = frameFromBasis(
        Vec3(0, 1, 0),                  // normal = +Y
        Vec3(1, 0, 0),                  // axis1  = +X
        Vec3(0, 0, 1),                  // axis2  = +Z
        Vec3(2.0f, 3.0f, 4.0f));        // origin offset

    // Local origin → world origin offset.
    auto p0 = transformPoint(f.toWorld, Vec3(0, 0, 0));
    assert(abs(p0.x - 2.0f) < 1e-6f);
    assert(abs(p0.y - 3.0f) < 1e-6f);
    assert(abs(p0.z - 4.0f) < 1e-6f);

    // Round-trip a non-trivial point.
    auto pw = Vec3(7.0f, 8.0f, 9.0f);
    auto pl = transformPoint(f.toLocal, pw);
    auto pw2 = transformPoint(f.toWorld, pl);
    assert(abs(pw2.x - pw.x) < 1e-5f);
    assert(abs(pw2.y - pw.y) < 1e-5f);
    assert(abs(pw2.z - pw.z) < 1e-5f);

    // Local Y axis (direction, no translation) → world normal.
    auto upL = Vec3(0, 1, 0);
    auto upW = transformDir(f.toWorld, upL);
    assert(abs(upW.x - f.normal.x) < 1e-6f);
    assert(abs(upW.y - f.normal.y) < 1e-6f);
    assert(abs(upW.z - f.normal.z) < 1e-6f);
}

// 90° workplane (worldX preset: normal = +X, axis1 = -Y, axis2 = +Z)
// plus a centre offset — verifies the inverse against a non-identity
// rotation, which is the case alignToSelection-style frames hit.
unittest {
    import std.math : abs;
    auto f = frameFromBasis(
        Vec3(1, 0, 0),                  // normal  = +X
        Vec3(0, -1, 0),                 // axis1   = -Y
        Vec3(0, 0, 1),                  // axis2   = +Z
        Vec3(5, 0, 0));                 // origin

    // World point (5, 1, 0) is at local (-1, 0, 0) — origin shifted, then
    // y-flipped because axis1 = -Y so local-X maps to negative-world-Y.
    auto pl = transformPoint(f.toLocal, Vec3(5, 1, 0));
    assert(abs(pl.x - (-1.0f)) < 1e-5f);
    assert(abs(pl.y -   0.0f)  < 1e-5f);
    assert(abs(pl.z -   0.0f)  < 1e-5f);

    auto pw = transformPoint(f.toWorld, Vec3(2, 0, 3));
    // local (2,0,3) → world: origin + 2*axis1 + 0*normal + 3*axis2
    //                       = (5,0,0) + (0,-2,0) + (0,0,3) = (5,-2,3)
    assert(abs(pw.x - 5.0f)  < 1e-5f);
    assert(abs(pw.y - (-2)) < 1e-5f);
    assert(abs(pw.z - 3.0f) < 1e-5f);
}

unittest { // perspective is untouched: the ray still leaves the eye
    import std.math : abs;
    import math : perspectiveMatrix, screenRay;

    Viewport vp;
    vp.width = 640; vp.height = 480;
    vp.focus = Vec3(0, 0, 0);
    vp.eye   = Vec3(0, 0, 3);
    vp.view  = [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, -3, 1];
    vp.proj  = perspectiveMatrix(0.785398f, 640.0f / 480.0f, 0.1f, 100.0f);
    assert(!isOrtho(vp), "rig premise: this arm must be perspective");

    auto f = frameFromBasis(Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0),
                            Vec3(0, 0, 0), true);
    Vec3 hitLocal;
    assert(workplaneCursorPlaneHit(f, vp, 500.0f, 120.0f, Vec3(0, 0, 0),
                                   Vec3(0, 1, 0), hitLocal));
    Vec3 mine = transformPoint(f.toWorld, hitLocal);

    // What the pre-0661 pair computed, spelled out.
    Vec3 oldEye = transformPoint(f.toLocal, vp.eye);
    Vec3 oldRay = transformDir (f.toLocal, screenRay(500.0f, 120.0f, vp));
    Vec3 oldHit;
    assert(rayPlaneIntersect(oldEye, oldRay, Vec3(0, 0, 0), Vec3(0, 1, 0), oldHit));
    Vec3 old = transformPoint(f.toWorld, oldHit);

    assert(abs(mine.x - old.x) < 1e-5f && abs(mine.y - old.y) < 1e-5f
        && abs(mine.z - old.z) < 1e-5f,
        "the perspective arm must be byte-for-byte the behaviour it replaces");
}

// frameIsLeftHanded — determinant sign for pickMostFacingPlane's three
// canonical bases (task 0424). The X-dominant and Z-dominant cases are the
// bug trigger (PrimitiveCreateTool.applyFrameToMeshRange / BoxTool's own
// applyFrameToMesh both branch on this); Y-dominant (and the world-XZ
// default) must stay right-handed so every non-triggering camera/preset/
// headless path is byte-stable.
unittest {
    // Y-dominant (pickMostFacingPlane case 1): axis1=X, normal=Y, axis2=Z —
    // right-handed (this is also worldXZFrame()'s shape).
    auto fY = frameFromBasis(Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1), Vec3(0, 0, 0));
    assert(!frameIsLeftHanded(fY), "Y-dominant frame should be right-handed");

    // X-dominant (case 0): axis1=Y, normal=X, axis2=Z — left-handed.
    auto fX = frameFromBasis(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1), Vec3(0, 0, 0));
    assert(frameIsLeftHanded(fX), "X-dominant frame should be left-handed");

    // Z-dominant (case 2): axis1=X, normal=Z, axis2=Y — left-handed.
    auto fZ = frameFromBasis(Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 0));
    assert(frameIsLeftHanded(fZ), "Z-dominant frame should be left-handed");
}

// reverseFaceWinding — reverses only faces[firstFaceIdx .. $] in place;
// anything before firstFaceIdx (pre-existing scene geometry from another
// tool/gesture) must be left untouched.
unittest {
    Mesh m;
    m.faces ~= [0u, 1u, 2u];        // pre-existing face — must be left alone
    m.faces ~= [3u, 4u, 5u, 6u];    // "new" face 1
    m.faces ~= [7u, 8u, 9u];        // "new" face 2

    reverseFaceWinding(&m, 1);      // only faces[1 .. $] should reverse

    assert(m.faces[0] == [0u, 1u, 2u],       "pre-existing face must be untouched");
    assert(m.faces[1] == [6u, 5u, 4u, 3u],   "new face 1 should reverse in place");
    assert(m.faces[2] == [9u, 8u, 7u],       "new face 2 should reverse in place");
}

unittest { // backgroundPoint with no surface: the plane point snapped to q (task 9404)
    import math : orthographicMatrix;
    import viewgrid : vectorSnap, viewVectorQuantum;
    import std.format : format;
    auto saved = g_pipeCtx;
    g_pipeCtx = null;               // no pipeline => no constraint stage => no surface
    scope (exit) g_pipeCtx = saved;
    Viewport vp;
    vp.width = 640; vp.height = 480;
    vp.eye  = Vec3(0, 0, 3);
    vp.view = [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, -3, 1];
    vp.proj = orthographicMatrix(1.2f, 640.0f / 480.0f, 0.1f, 100.0f);
    immutable q = viewVectorQuantum(vp);
    immutable p = Vec3(3.37f * q, -2.71f * q, 0.43f * q);
    immutable want = vectorSnap(p, q);
    assert(q > 0 && abs(want.x - p.x) > 1e-4f && abs(want.y - p.y) > 1e-4f,
           format("rig premise: the point must sit off the q lattice (q %s, p %s, q(p) %s)", q, p, want));
    auto f = frameFromBasis(Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1), Vec3(0, 0, 0));
    bool onSurface = true;
    immutable got = backgroundPoint(p, vp, f, onSurface);
    assert(!onSurface && got == want,
           "no surface: the background point is the plane point snapped to the view quantum");
}

unittest { // box-drag-oblique: the base-drag point off the background (task 9473, K-C3 C3a / C3b)
    // The reference's oblique perspective rig (pinhole focal 1004.7546 px on
    // (576, 487), eye (0.07, 33.96, 19.03) on the focus (0.07, 1, 0), q 0.05):
    // the captured corner is q(T), T = Pq + the pixel travel through the map
    // forward-differenced at Pq; the projective plane hit is 0.117 / 1.25 off T.
    import std.math : atan;
    import drag : HandleDrag;
    import math : lookAt, perspectiveMatrix;
    import viewgrid : viewVectorQuantum;
    auto saved = g_pipeCtx;
    g_pipeCtx = null;               // no constraint stage: the plane branch
    scope (exit) g_pipeCtx = saved;
    immutable eye = Vec3(0.07f, 33.959961496f, 19.029442725f);
    Viewport vp = Viewport(lookAt(eye, Vec3(0.07f, 1, 0), Vec3(0, 1, 0)),
        perspectiveMatrix(cast(float)(2 * atan(487 / 1004.7545726038318)), 1152.0f / 974.0f,
                          0.1f, 1000.0f), 1152, 974, 0, 0, eye);
    vp.focus = Vec3(0.07f, 1, 0);
    assert(abs(viewVectorQuantum(vp) - 0.05f) < 1e-6f, "rig: the view quantum must be the record's 0.05");
    auto f = frameFromBasis(Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1), Vec3(0, 0, 0));
    static struct Cell { string id; Vec3 pq; int dx, dy; Vec3 corner; }
    immutable Cell[2] cells = [Cell("C3a", Vec3(-8.15f, 0, 2.6f), 240, 24, Vec3(0.95f, 0, 3.6f)),
                               Cell("C3b", Vec3(4.05f, 0, -0.1f), 0, 240, Vec3(3.5f, 0, 10.55f))];
    size_t n;
    foreach (c; cells) {
        HandleDrag g;
        g.press(c.pq, 500, 500);
        Vec3 d;
        assert(baseDragPoint(g, 500 + c.dx, 500 + c.dy, Vec3(0, 1, 0), vp, f, d)
            && (d - c.corner).length <= 1e-5f, c.id ~ ": the base-drag corner must be q(T)");
        ++n;
    }
    assert(n == 2);
    // A press corner behind the camera has no map: refused, the corner untouched.
    HandleDrag behind;
    behind.press(Vec3(0.07f, 0, 200), 500, 500);
    Vec3 kept = Vec3(7, 7, 7);
    assert(!baseDragPoint(behind, 540, 520, Vec3(0, 1, 0), vp, f, kept) && kept == Vec3(7, 7, 7),
        "behind the camera: baseDragPoint must refuse and leave the caller's corner");
    // A pinned plane is the identity frame seen through the plane-local view:
    // the drag under a frame turned 30 deg about X equals the identity-frame drag
    // on `planeLocalViewport` (the map reads the LOCAL view; the world one is
    // 0.1+ off here).
    import std.math : PI;
    immutable float a = 30 * PI / 180;
    auto turned = frameFromBasis(Vec3(0, cos(a), sin(a)), Vec3(1, 0, 0), Vec3(0, -sin(a), cos(a)),
                                 Vec3(0, 0, 0));
    auto lvp = planeLocalViewport(vp, turned);
    HandleDrag gl;
    gl.press(Vec3(-2.05f, 0, 1.6f), 500, 500);
    Vec3 viaFrame, viaView;
    assert(baseDragPoint(gl, 640, 455, Vec3(0, 1, 0), vp, turned, viaFrame)
        && baseDragPoint(gl, 640, 455, Vec3(0, 1, 0), lvp, f, viaView)
        && (viaFrame - viaView).length <= 1e-5f && (viaFrame - gl.point).length > 0.1f,
        "pinned plane: the base drag must read the plane-local view");
}
