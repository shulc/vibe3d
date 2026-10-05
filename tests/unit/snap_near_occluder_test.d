// NEAR OCCLUDERS of the visibility probe (task 9387, wave plan §24.2 V-near).
//
// A front-facing face with SOME corner behind the eye has no screen ring, so
// the screen-space broad phase cannot test it. Once every unhidden vertex is a
// snap candidate (the seed rule), such a face must still hide what lies behind
// it: it joins the near list and is tested inside its own plane.
//
// Rig: perspective eye at (0,0,5) looking down -Z. Q is a large open quad
// tilted so its two +Y corners lie BEHIND the eye (z = 8) while it faces the
// eye. C sits 0.5 m behind Q on a ray that crosses Q's interior, owned only by
// a back-facing open triangle (so neither its own face nor its facing decides
// anything); C2 sits on the SAME ray between the eye and Q.
module tests.unit.snap_near_occluder_test;

import std.format : format;
import std.math : PI, sqrt, abs;
import math : Vec3, Viewport, ModelSpace, lookAt, perspectiveMatrix,
              frontFacingLocal, projectToWindowFull;
import mesh : Mesh, g_visCounters, visibilityProbe;

private Viewport eyeViewport() {
    Viewport vp;
    vp.eye   = Vec3(0, 0, 5);
    vp.focus = Vec3(0, 0, 0);
    vp.view  = lookAt(vp.eye, vp.focus, Vec3(0, 1, 0));
    vp.proj  = perspectiveMatrix(PI / 4, 4.0f / 3.0f, 0.1f, 100.0f);
    vp.width = 800; vp.height = 600;
    return vp;
}

private enum Vec3[4] kQ = [Vec3(-3, -3, 0), Vec3(3, -3, 0), Vec3(3, 3, 8), Vec3(-3, 3, 8)];
// The ray from the eye through Q's interior: eye + s * kDir.
private enum Vec3 kDir = Vec3(0, -2, -6);

private Vec3 onRay(double s) {
    return Vec3(cast(float)(s * kDir.x), cast(float)(s * kDir.y),
                cast(float)(5 + s * kDir.z));
}

/// Q (verts 0..3) plus a back-facing open triangle at `c` (verts 4..6).
private Mesh rig(Vec3 c) {
    Mesh m;
    foreach (q; kQ) m.addVertex(q);
    m.addFace([0u, 1u, 2u, 3u]);
    immutable uint b = m.addVertex(c);
    m.addVertex(c + Vec3(0.05f, 0, 0));
    m.addVertex(c + Vec3(0, 0.05f, 0));
    m.addFace([b, b + 2, b + 1]);   // normal -Z: back-facing from the eye
    m.buildLoops();
    return m;
}

unittest {
    const Viewport vp = eyeViewport();
    const Vec3 eye = vp.eye;
    // The ray meets Q's plane where z = 4/3 * (y + 3): s_H = 0.3, H = (0, -0.6, 3.2).
    enum double sH = 0.3;
    immutable double lenDir = sqrt(cast(double)(kDir.x * kDir.x + kDir.y * kDir.y
                                                + kDir.z * kDir.z));
    const Vec3 c  = onRay(sH + 0.5 / lenDir);   // 0.5 m behind Q
    const Vec3 c2 = onRay(sH / 2);              // between the eye and Q

    Mesh behind = rig(c);
    Mesh before = rig(c2);

    // --- preconditions, computed first --------------------------------------
    assert(frontFacingLocal(behind.vertices, behind.faces[0], eye),
        "rig: Q must be FRONT-facing from the eye");
    assert(!frontFacingLocal(behind.vertices, behind.faces[1], eye),
        "rig: C's own triangle must be BACK-facing (it may neither seed nor occlude)");
    float sx, sy, z;
    assert(!projectToWindowFull(kQ[2], vp, sx, sy, z)
        && projectToWindowFull(kQ[0], vp, sx, sy, z),
        "rig: Q must have a corner behind the eye AND one in front");
    assert(projectToWindowFull(c, vp, sx, sy, z), "rig: C must project");
    {   // The segment eye -> C crosses Q's interior, in 3D (independent algebra:
        // Q's plane is y = 3/4 z - 3 over x in [-3, 3], y in [-3, 3]).
        const Vec3 h = onRay(sH);
        assert(abs(h.y - (0.75 * h.z - 3)) < 1e-5 && abs(h.x) < 3 && abs(h.y) < 3,
            format("rig: eye->C must cross Q's interior; H = %s", h));
        assert(sH < sH + 0.5 / lenDir && sH > sH / 2,
            "rig: C beyond H and C2 before it along the ray");
    }

    // --- control: the candidate IN FRONT of Q stays visible ------------------
    g_visCounters.reset();
    auto pBefore = visibilityProbe(before, eye, vp, ModelSpace.world());
    assert(g_visCounters.nearOccluders == 1,
        format("near-occluder-front: Q must be the ONE near occluder, got %d",
               g_visCounters.nearOccluders));
    assert(pBefore.visible(4),
        "near-occluder-front: a vertex between the eye and the near face is visible");

    // --- near-occluder-backward: a ray that meets Q's plane only BEHIND the eye
    // (t < 0, at H = (0, 1.2, 5.6), inside Q's behind-eye part) is not
    // occluded by it. C3 = eye + (0, -2, -1) lies in front of the eye.
    {
        const Vec3 c3 = Vec3(0, -2, 4);
        Mesh away = rig(c3);
        assert(projectToWindowFull(c3, vp, sx, sy, z), "rig: C3 must project");
        g_visCounters.reset();
        auto pAway = visibilityProbe(away, eye, vp, ModelSpace.world());
        assert(g_visCounters.nearOccluders == 1, "near-occluder-backward: Q is the near occluder");
        assert(pAway.visible(4),
            "near-occluder-backward: a plane met only behind the eye occludes nothing");
    }

    // --- near-occluder-psp: the candidate BEHIND Q is hidden ------------------
    g_visCounters.reset();
    auto pBehind = visibilityProbe(behind, eye, vp, ModelSpace.world());
    assert(g_visCounters.nearOccluders == 1,
        format("near-occluder-psp: Q must be the ONE near occluder, got %d",
               g_visCounters.nearOccluders));
    assert(!pBehind.visible(4),
        "near-occluder-psp: a vertex 0.5 m behind a front face with a corner "
        ~ "behind the eye must be occluded by it");
}
