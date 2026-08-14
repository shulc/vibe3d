// Module unittests for `constraint`, moved verbatim out of source/constraint.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.constraint_test;

import std.math : sqrt;
import math : Vec3, Viewport, ModelSpace, dot, cross, normalize,
              projectToWindowFull, closestOnSegment2D;
import mesh : Mesh, edgeKey;
import toolpipe.packets : ConstrainPacket, ConstrainGeom, ConstrainHitPacket,
                          HoverTarget, HoverTargetKind, SnapPacket;
import math : lookAt, perspectiveMatrix;
import std.math : PI;
import constraint;

unittest { // closestPointOnTriangle — interior
    // Point above the centroid of a unit triangle in XZ plane.
    Vec3 a = Vec3(0, 0, 0);
    Vec3 b = Vec3(1, 0, 0);
    Vec3 c = Vec3(0, 0, 1);
    Vec3 p = Vec3(0.25f, 5.0f, 0.25f);  // above centroid
    Vec3 r = closestPointOnTriangle(p, a, b, c);
    // Foot is perpendicular drop: Y collapses to 0, XZ unchanged
    import std.math : fabs;
    assert(fabs(r.x - 0.25f) < 1e-5f, "interior x");
    assert(fabs(r.y - 0.0f)  < 1e-5f, "interior y");
    assert(fabs(r.z - 0.25f) < 1e-5f, "interior z");
}

unittest { // closestPointOnTriangle — vertex region
    Vec3 a = Vec3(0, 0, 0);
    Vec3 b = Vec3(1, 0, 0);
    Vec3 c = Vec3(0, 0, 1);
    // Point far "above" vertex A → foot is A
    Vec3 r = closestPointOnTriangle(Vec3(-1.0f, 0, -1.0f), a, b, c);
    import std.math : fabs;
    assert(fabs(r.x) < 1e-5f && fabs(r.y) < 1e-5f && fabs(r.z) < 1e-5f,
           "vertex region A");
}

unittest { // closestPointOnTriangle — edge region
    Vec3 a = Vec3(0, 0, 0);
    Vec3 b = Vec3(2, 0, 0);
    Vec3 c = Vec3(1, 0, 2);
    // Point directly above midpoint of AB
    Vec3 p = Vec3(1, 3.0f, -1.0f);
    Vec3 r = closestPointOnTriangle(p, a, b, c);
    import std.math : fabs;
    assert(fabs(r.x - 1.0f) < 1e-4f, "edge AB midpoint x");
    assert(fabs(r.y - 0.0f) < 1e-4f, "edge AB midpoint y");
    assert(fabs(r.z - 0.0f) < 1e-4f, "edge AB midpoint z");
}

unittest { // closestPointOnMeshes — vert projects onto unit quad at y=0
    import mesh : Mesh;
    // Build a two-triangle quad in XZ at Y=0: verts (0,0,0) (1,0,0)
    // (1,0,1) (0,0,1), faces [(0,1,2), (0,2,3)].
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.faces    = [[0u,1u,2u], [0u,2u,3u]];
    const(BackgroundSource)[] srcs = [BackgroundSource(cast(const(Mesh)*)m, ModelSpace.world())];
    Vec3 p = Vec3(0.5f, 3.0f, 0.5f);  // above centre of quad
    Vec3 hit, hitN;
    int si, fc;
    float d2;
    bool ok = closestPointOnMeshes(p, srcs, false, hit, hitN, si, fc, d2);
    assert(ok, "closestPointOnMeshes should find a hit");
    import std.math : fabs;
    assert(fabs(hit.x - 0.5f) < 1e-4f, "hit x on quad");
    assert(fabs(hit.y - 0.0f) < 1e-4f, "hit y = 0 on quad");
    assert(fabs(hit.z - 0.5f) < 1e-4f, "hit z on quad");
}

unittest { // closestPointOnMeshes — P2 (doc/topopen_p2_plan.md): srcIndex/face
           // identify the WINNING source/face, feeding the CONS stage's
           // Point-mode branch the same face the Screen-mode branch already
           // gets from BvhPick's SurfaceHit.face.
    import mesh : Mesh;
    // Same quad as above: faces[0]=(0,1,2) covers the XZ half where x>=z,
    // faces[1]=(0,2,3) covers the half where z>=x.
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.faces    = [[0u,1u,2u], [0u,2u,3u]];
    const(BackgroundSource)[] srcs = [BackgroundSource(cast(const(Mesh)*)m, ModelSpace.world())];
    import std.math : fabs;

    // Seed over face 0's interior (x > z).
    Vec3 hitA, hitNA;
    int siA, faceA;
    float d2A;
    bool okA = closestPointOnMeshes(Vec3(0.7f, 3.0f, 0.2f), srcs, false,
                                    hitA, hitNA, siA, faceA, d2A);
    assert(okA, "expected a hit over face 0's interior");
    assert(siA == 0, "single source -> srcIndex 0");
    assert(faceA == 0, "seed over face 0's interior must resolve to face 0");
    assert(fabs(hitA.x - 0.7f) < 1e-4f && fabs(hitA.y - 0.0f) < 1e-4f
        && fabs(hitA.z - 0.2f) < 1e-4f,
        "hit must equal closestPointOnTriangle's own foot");

    // Seed over face 1's interior (z > x).
    Vec3 hitB, hitNB;
    int siB, faceB;
    float d2B;
    bool okB = closestPointOnMeshes(Vec3(0.2f, 3.0f, 0.7f), srcs, false,
                                    hitB, hitNB, siB, faceB, d2B);
    assert(okB && siB == 0 && faceB == 1,
        "seed over face 1's interior must resolve to face 1");
}

unittest { // closestPointOnMeshes — P2: not-found leaves srcIndex/face at -1
    const(BackgroundSource)[] srcs = [];
    Vec3 hit, hitN;
    int si, fc;
    float d2;
    bool ok = closestPointOnMeshes(Vec3(0,0,0), srcs, false, hit, hitN, si, fc, d2);
    assert(!ok, "empty sources must not find a hit");
    assert(si == -1 && fc == -1, "not-found must leave srcIndex/face at -1");
}

unittest { // closestPointOnMeshes / nearestFaceVertex / nearestFaceEdge —
           // task 0617 Stage 4 review BLOCKER 1: a background source's
           // ModelSpace must be folded in BEFORE the metric search runs,
           // not ignored. Same quad this file's identity tests use, but
           // now the mesh's LOCAL vertices sit 3 world units away from
           // where the review's own repro names — "a background layer at
           // position x=3" — and the query points are WORLD (as
           // `bgSurfaceRayHit`'s seed and the CONS stage's candidate
           // fields genuinely are).
           //
           // Without the fix (searching `m.vertices[]` raw, ignoring
           // `bg.space`), every query below misses the translated quad
           // entirely — `closestPointOnMeshes` still finds SOME foot on
           // the identity-pose quad (it never returns `false` for a
           // non-empty source), but at the WRONG position, exactly the
           // review's point: "drags the point onto the identity-pose
           // surface and turns the reported distance into the layer's
           // translation magnitude". `nearestFaceVertex`/`nearestFaceEdge`
           // likewise elect against the untransformed local vertices, so
           // for a query near a TRANSLATED corner they resolve to
           // whichever corner happens to be nearest in the wrong
           // (identity) frame — for this fixture's translation that is a
           // WRONG vertex index, not merely a wrong position, which is
           // what the assertions below pin.
    import mesh : Mesh;
    import math : translationMatrix;
    import std.math : fabs;

    immutable Vec3 T = Vec3(3, 0, 0);   // the review's own repro: x=3
    ModelSpace ms;
    ms.m    = translationMatrix(T);
    ms.mInv = translationMatrix(Vec3(-T.x, -T.y, -T.z));
    ms.isIdentity = false;

    auto m = new Mesh();
    // The IDENTICAL local quad the identity tests use — this fixture's
    // whole point is that the SAME local geometry now sits somewhere else
    // in world space (`ms.toWorldPoint` maps these to
    // (3,0,0)/(4,0,0)/(4,0,1)/(3,0,1), i.e. the identity quad shifted by
    // +T — "a background layer at position x=3").
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u, 1u, 2u, 3u]);   // ONE quad face — addFace builds edges + edgeIndexMap
    m.buildLoops();

    const(BackgroundSource)[] srcs = [BackgroundSource(cast(const(Mesh)*)m, ms)];

    // --- closestPointOnMeshes: world query above the TRANSLATED quad -------
    Vec3 p = Vec3(0.5f, 3.0f, 0.5f) + T;   // world: (3.5, 3.0, 0.5)
    Vec3 hit, hitN;
    int si, fc;
    float d2;
    bool ok = closestPointOnMeshes(p, srcs, false, hit, hitN, si, fc, d2);
    assert(ok, "closestPointOnMeshes should find a hit on the translated quad");
    assert(fabs(hit.x - (0.5f + T.x)) < 1e-4f
        && fabs(hit.y - 0.0f) < 1e-4f
        && fabs(hit.z - 0.5f) < 1e-4f,
        "the foot must land on the quad WHERE IT IS DRAWN (world), not at "
      ~ "the identity pose the raw local vertices sit at");

    // --- nearestFaceVertex: a query near the TRANSLATED corner 0 -----------
    // Deliberately the LOCAL-x=0 corner, not a LOCAL-x=1 one: a broken
    // (un-transformed) search always favours whichever LOCAL vertex has the
    // LARGEST local x here, because the world query sits near local-x + T
    // and T dominates every candidate's distance the same way — so a query
    // near a local-x=1 corner would (mis)elect the SAME corner whether or
    // not the fix is applied, proving nothing. Querying near the local-x=0
    // corner forces the broken path to disagree.
    Vec3 nearCorner0 = Vec3(-0.1f, 0.05f, -0.1f) + T;
    assert(nearestFaceVertex(*m, ms, 0, nearCorner0) == 0,
        "nearestFaceVertex must elect the WORLD-nearest corner — reverting "
      ~ "the fix elects against the mesh's raw LOCAL vertices (which all "
      ~ "sit 3 world units nearer +x than this query, so the search always "
      ~ "prefers the local-x=1 corners) and picks corner 1 instead of 0");

    // --- nearestFaceEdge: a query near the TRANSLATED edge (3,0)'s midpoint
    // Same reasoning as the vertex case above: edge (3,0) is the LOCAL-x=0
    // edge, so it is the one a broken (un-transformed) search systematically
    // avoids in favour of edge (1,2) (LOCAL-x=1), independent of where the
    // query world point actually is.
    import mesh : edgeKey;
    Vec3 nearEdge30 = Vec3(-0.05f, 0.05f, 0.5f) + T;
    int gotEdge = nearestFaceEdge(*m, ms, 0, nearEdge30);
    auto expEdgePtr = edgeKey(3, 0) in m.edgeIndexMap;
    assert(expEdgePtr !is null, "fixture: edge (3,0) must be in the map");
    assert(gotEdge == cast(int)*expEdgePtr,
        "nearestFaceEdge must elect the WORLD-nearest edge — reverting the "
      ~ "fix elects against the raw LOCAL vertices and picks edge (1,2) "
      ~ "instead of (3,0)");
}

unittest { // constrainPoint — point mode projects onto plane
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(-5,0,-5), Vec3(5,0,-5), Vec3(5,0,5), Vec3(-5,0,5)];
    m.faces    = [[0u,1u,2u], [0u,2u,3u]];
    const(BackgroundSource)[] srcs = [BackgroundSource(cast(const(Mesh)*)m, ModelSpace.world())];
    ConstrainPacket cfg;
    cfg.enabled = true;
    cfg.geom    = ConstrainGeom.Point;
    cfg.offset  = 0.0f;
    Viewport vp;  // zero-init, unused for point mode
    Vec3 moved = Vec3(1.0f, 2.5f, 1.0f);
    Vec3 result = constrainPoint(moved, Vec3(0,0,0), vp, srcs, cfg);
    import std.math : fabs;
    assert(fabs(result.x - 1.0f) < 1e-4f, "x preserved");
    assert(fabs(result.y - 0.0f) < 1e-4f, "y projected to 0");
    assert(fabs(result.z - 1.0f) < 1e-4f, "z preserved");
}

unittest { // constrainPoint — disabled → identity
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,0,1)];
    m.faces    = [[0u,1u,2u]];
    const(BackgroundSource)[] srcs = [BackgroundSource(cast(const(Mesh)*)m, ModelSpace.world())];
    ConstrainPacket cfg;
    cfg.enabled = false;
    cfg.geom    = ConstrainGeom.Point;
    Viewport vp;
    Vec3 p = Vec3(0.3f, 7.0f, 0.3f);
    Vec3 r = constrainPoint(p, Vec3(0,0,0), vp, srcs, cfg);
    import std.math : fabs;
    assert(fabs(r.y - 7.0f) < 1e-5f, "disabled: y unchanged");
}

unittest { // constrainPoint — off mode → identity even when enabled
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,0,1)];
    m.faces    = [[0u,1u,2u]];
    const(BackgroundSource)[] srcs = [BackgroundSource(cast(const(Mesh)*)m, ModelSpace.world())];
    ConstrainPacket cfg;
    cfg.enabled = true;
    cfg.geom    = ConstrainGeom.Off;
    Viewport vp;
    Vec3 p = Vec3(0.3f, 7.0f, 0.3f);
    Vec3 r = constrainPoint(p, Vec3(0,0,0), vp, srcs, cfg);
    import std.math : fabs;
    assert(fabs(r.y - 7.0f) < 1e-5f, "off mode: y unchanged");
}

unittest { // constrainPoint — empty sources → identity
    const(BackgroundSource)[] srcs = [];
    ConstrainPacket cfg;
    cfg.enabled = true;
    cfg.geom    = ConstrainGeom.Point;
    Viewport vp;
    Vec3 p = Vec3(1.0f, 2.0f, 3.0f);
    Vec3 r = constrainPoint(p, Vec3(0,0,0), vp, srcs, cfg);
    import std.math : fabs;
    assert(fabs(r.x - 1.0f) < 1e-5f
        && fabs(r.y - 2.0f) < 1e-5f
        && fabs(r.z - 3.0f) < 1e-5f,
        "empty sources: position unchanged");
}

unittest { // constrainPoint — vector mode: downward delta hits +Y plane at Y=0
    import mesh : Mesh;
    import std.math : fabs;
    // Build a Y=0 quad wound for +Y normal: face [0,2,1] and [0,3,2].
    // v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1)
    // face [0,2,1]: e1=v2-v0=(1,0,1), e2=v1-v0=(1,0,0) → n=cross(e1,e2)=(0,1,0) +Y ✓
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.faces    = [[0u,2u,1u], [0u,3u,2u]];
    const(BackgroundSource)[] srcs = [BackgroundSource(cast(const(Mesh)*)m, ModelSpace.world())];
    ConstrainPacket cfg;
    cfg.enabled  = true;
    cfg.geom     = ConstrainGeom.Vector;
    cfg.dblSided = false;
    cfg.offset   = 0.0f;
    Viewport vp;  // unused by vector mode

    // Forward hit: delta (0,-1,0) from (0.5,2,0.5) → hits Y=0 at (0.5,0,0.5)
    Vec3 result = constrainPoint(Vec3(0.5f, 2.0f, 0.5f), Vec3(0,-1,0), vp, srcs, cfg);
    assert(fabs(result.x - 0.5f) < 1e-4f, "vector hit: x preserved");
    assert(fabs(result.y - 0.0f) < 1e-4f, "vector hit: y projected to 0");
    assert(fabs(result.z - 0.5f) < 1e-4f, "vector hit: z preserved");
}

unittest { // constrainPoint — vector mode: upward delta misses +Y plane → identity
    import mesh : Mesh;
    import std.math : fabs;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.faces    = [[0u,2u,1u], [0u,3u,2u]];
    const(BackgroundSource)[] srcs = [BackgroundSource(cast(const(Mesh)*)m, ModelSpace.world())];
    ConstrainPacket cfg;
    cfg.enabled  = true;
    cfg.geom     = ConstrainGeom.Vector;
    cfg.dblSided = false;
    cfg.offset   = 0.0f;
    Viewport vp;
    Vec3 pos    = Vec3(0.5f, 2.0f, 0.5f);
    // Upward ray: forward direction is away from the plane → miss → keep pos
    Vec3 result = constrainPoint(pos, Vec3(0,1,0), vp, srcs, cfg);
    assert(fabs(result.y - 2.0f) < 1e-4f, "vector miss: y unchanged (keep-on-miss)");
}

unittest { // constrainPoint — vector mode: zero delta → identity
    import mesh : Mesh;
    import std.math : fabs;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,0,1)];
    m.faces    = [[0u,1u,2u]];
    const(BackgroundSource)[] srcs = [BackgroundSource(cast(const(Mesh)*)m, ModelSpace.world())];
    ConstrainPacket cfg;
    cfg.enabled = true;
    cfg.geom    = ConstrainGeom.Vector;
    Viewport vp;
    Vec3 pos    = Vec3(0.3f, 5.0f, 0.3f);
    Vec3 result = constrainPoint(pos, Vec3(0,0,0), vp, srcs, cfg);
    assert(fabs(result.y - 5.0f) < 1e-5f, "vector zero-delta: identity");
}

unittest { // constrainPoint — screen mode: top-down view hits +Y plane at Y=0
    import mesh : Mesh;
    import std.math : fabs;
    // Same +Y quad as the vector test.
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.faces    = [[0u,2u,1u], [0u,3u,2u]];
    const(BackgroundSource)[] srcs = [BackgroundSource(cast(const(Mesh)*)m, ModelSpace.world())];
    ConstrainPacket cfg;
    cfg.enabled  = true;
    cfg.geom     = ConstrainGeom.Screen;
    cfg.dblSided = false;
    cfg.offset   = 0.0f;
    // Build a Viewport with camFwd = (0,-1,0) (top-down).
    // Column-major lookAt convention: -f stored at m[2],m[6],m[10].
    // f=(0,-1,0) → -f=(0,1,0) → view[2]=0, view[6]=1, view[10]=0.
    // Right vector r=(1,0,0) at view[0]=1,view[4]=0,view[8]=0 (rLenSq=1>1e-6).
    Viewport vp;
    vp.width  = 800;
    vp.height = 600;
    vp.view[0]  = 1.0f;  // r.x
    vp.view[2]  = 0.0f;  // -f.x
    vp.view[6]  = 1.0f;  // -f.y  (f.y = -1 → -f.y = 1)
    vp.view[10] = 0.0f;  // -f.z
    // camFwd = normalize(-view[2],-view[6],-view[10]) = (0,-1,0) ✓

    Vec3 result = constrainPoint(Vec3(0.5f, 2.0f, 0.5f), Vec3(0,0,0), vp, srcs, cfg);
    assert(fabs(result.x - 0.5f) < 1e-4f, "screen hit: x preserved");
    assert(fabs(result.y - 0.0f) < 1e-4f, "screen hit: y projected to 0");
    assert(fabs(result.z - 0.5f) < 1e-4f, "screen hit: z preserved");
}

unittest { // constrainPoint — screen mode: zero-width viewport → identity
    import mesh : Mesh;
    import std.math : fabs;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,0,1)];
    m.faces    = [[0u,1u,2u]];
    const(BackgroundSource)[] srcs = [BackgroundSource(cast(const(Mesh)*)m, ModelSpace.world())];
    ConstrainPacket cfg;
    cfg.enabled = true;
    cfg.geom    = ConstrainGeom.Screen;
    Viewport vp;   // zero-init: width=0, height=0
    Vec3 pos    = Vec3(0.3f, 5.0f, 0.3f);
    Vec3 result = constrainPoint(pos, Vec3(0,0,0), vp, srcs, cfg);
    assert(fabs(result.y - 5.0f) < 1e-5f, "screen degenerate-view: identity");
}

unittest { // nearestFaceVertex — 4 corners of a unit quad each resolve exactly
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u,1u,2u,3u]);   // addFace incrementally builds edges + edgeIndexMap
    m.buildLoops();

    // A point offset slightly toward each corner resolves to that corner's
    // vertex index — clearly closer than any other corner.
    assert(nearestFaceVertex(*m, ModelSpace.world(), 0, Vec3(-0.1f, 0.05f, -0.1f)) == 0, "corner 0");
    assert(nearestFaceVertex(*m, ModelSpace.world(), 0, Vec3( 1.1f, 0.05f, -0.1f)) == 1, "corner 1");
    assert(nearestFaceVertex(*m, ModelSpace.world(), 0, Vec3( 1.1f, 0.05f,  1.1f)) == 2, "corner 2");
    assert(nearestFaceVertex(*m, ModelSpace.world(), 0, Vec3(-0.1f, 0.05f,  1.1f)) == 3, "corner 3");
}

unittest { // nearestFaceVertex — out-of-range face -> -1 (best-effort, never throws)
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u,1u,2u,3u]);   // addFace incrementally builds edges + edgeIndexMap
    m.buildLoops();
    assert(nearestFaceVertex(*m, ModelSpace.world(), 7, Vec3(0,0,0)) == -1, "face index too high");
    assert(nearestFaceVertex(*m, ModelSpace.world(), -1, Vec3(0,0,0)) == -1, "negative face index");
}

unittest { // nearestFaceEdge — 4 edge midpoints of a unit quad each resolve to
           // the CORRECT mesh.edges index, looked up via edgeKey (not a
           // hardcoded assumption about buildLoops' edge ordering).
    import mesh : Mesh, edgeKey;
    import std.conv : to;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u,1u,2u,3u]);   // addFace incrementally builds edges + edgeIndexMap
    m.buildLoops();

    uint[2][4] pairs = [[0,1], [1,2], [2,3], [3,0]];
    Vec3[4] mids = [
        Vec3(0.5f,  0.05f, -0.05f),  // near edge (0,1) midpoint (0.5,0,0)
        Vec3(1.05f, 0.05f,  0.5f),   // near edge (1,2) midpoint (1,0,0.5)
        Vec3(0.5f,  0.05f,  1.05f),  // near edge (2,3) midpoint (0.5,0,1)
        Vec3(-0.05f,0.05f,  0.5f),   // near edge (3,0) midpoint (0,0,0.5)
    ];
    foreach (i; 0 .. 4) {
        int got = nearestFaceEdge(*m, ModelSpace.world(), 0, mids[i]);
        auto expPtr = edgeKey(pairs[i][0], pairs[i][1]) in m.edgeIndexMap;
        assert(expPtr !is null, "edgeIndexMap missing pair " ~ i.to!string);
        assert(got == cast(int)*expPtr,
            "edge midpoint " ~ i.to!string ~ ": expected " ~ (*expPtr).to!string
            ~ ", got " ~ got.to!string);
    }
}

unittest { // nearestFaceEdge — miss cases: out-of-range face, and a mesh whose
           // edgeIndexMap was never built (best-effort -1, no crash).
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u,1u,2u,3u]);   // addFace incrementally builds edges + edgeIndexMap
    m.buildLoops();
    assert(nearestFaceEdge(*m, ModelSpace.world(), 9, Vec3(0.5f, 0, 0)) == -1, "out-of-range face");

    auto m2 = new Mesh();   // never buildLoops()'d — edgeIndexMap stale/empty
    m2.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m2.faces    = [[0u,1u,2u,3u]];
    assert(nearestFaceEdge(*m2, ModelSpace.world(), 0, Vec3(0.5f, 0, 0)) == -1,
        "edgeIndexMap not built -> best-effort -1");
}

unittest { // nearestFaceEdge — grazing case: a point at a shared CORNER is
           // equidistant-ish from its two incident edges; the argmin must
           // still resolve to SOME valid edge (no crash, no spurious -1).
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u,1u,2u,3u]);   // addFace incrementally builds edges + edgeIndexMap
    m.buildLoops();
    int got = nearestFaceEdge(*m, ModelSpace.world(), 0, Vec3(1.0f, 0.05f, 0.0f));  // corner (1,0,0)
    assert(got >= 0 && got < cast(int)m.edges.length,
        "grazing corner case should still resolve to a valid edge index");
}

unittest { // consistentCandidateIndex — review NIT-1's invariant helper:
           // in-range passes through unchanged, negative and out-of-range
           // (a stale index whose backing array has since shrunk) collapse
           // to -1.
    assert(consistentCandidateIndex(2, 3) == 2, "in-range index must pass through");
    assert(consistentCandidateIndex(0, 3) == 0, "index 0 is in-range for len 3");
    assert(consistentCandidateIndex(-1, 3) == -1, "already-negative index stays -1");
    assert(consistentCandidateIndex(3, 3) == -1, "index == len is out of range");
    assert(consistentCandidateIndex(5, 3) == -1,
        "stale index past a shrunk array must collapse to -1, not pass through");
    assert(consistentCandidateIndex(0, 0) == -1, "any index against a zero-length array is -1");
}
