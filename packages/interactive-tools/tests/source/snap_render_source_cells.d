module snap_render_source_cells;

import snap_render;
import math : Vec3;
import vibe3d.util.spatial.spatial : Viewport, projectToWindowFull, ModelSpace;
import vibe3d.mesh.core.mesh : Mesh;
import snap : SnapResult;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : SnapType;
import d_imgui.imgui_h : ImVec2;
version (unittest) import vibe3d.documents.model.document : ItemXform, primaryModelSpaceResolver;
version (unittest) import std.format : format;
version (unittest) import snap_render_source_helpers : t0619Matrix, t0619Viewport, t0619Mesh, t0619DrawnPx, t0619IdentityPx, t0619Dist, t0619Xf, t0619PxUnder, t0619BgMeshA, t0619BgMeshB, t0619InstallPrimary;

version (unittest) unittest {
    auto owner = new SnapOverlayOwner();
    SnapResult seeded; seeded.snapped = true; seeded.targetIndex = 17;
    publishLastSnap(seeded);
    assert(owner.beginClear());
    assert(g_lastSnap == seeded);
    SnapResult changed = seeded; changed.targetIndex = 18;
    publishLastSnap(changed);
    assert(!owner.validateClear());
    owner.abortClear();
    assert(g_lastSnap == changed);
    assert(owner.beginClear() && owner.validateClear());
    owner.installClear();
    assert(g_lastSnap == SnapResult.init);
    publishLastSnap(seeded);
    owner.installClear();
    assert(g_lastSnap == seeded, "snap reset installed twice");
    clearLastSnap();
}

unittest { // 0619: the highlighted VERTEX is marked where it is drawn.
    auto saved = primaryModelSpaceResolver;
    scope (exit) primaryModelSpaceResolver = saved;
    t0619InstallPrimary();

    auto m  = t0619Mesh();
    auto vp = t0619Viewport();

    enum size_t VI = 1;
    float wantX, wantY, idX, idY;
    t0619DrawnPx(m, VI, vp, wantX, wantY);
    t0619IdentityPx(m, VI, vp, idX, idY);

    // Vacuity guard FIRST: if the two laws landed on the same pixel this case
    // could not fail, and a green run would mean nothing.
    assert(t0619Dist(wantX, wantY, idX, idY) > 20.0,
        "vacuous fixture: the drawn and identity-pose pixels coincide");

    SnapResult r;
    r.highlighted = true;
    r.snapped     = true;
    r.targetType  = SnapType.Vertex;
    r.targetIndex = cast(int) VI;
    r.targetSource = 0;

    ImVec2[] pts;
    assert(snapHighlightPixels(r, vp, m, pts), "vertex highlight must resolve");
    assert(pts.length == 1, "a vertex target marks exactly one point");
    assert(t0619Dist(pts[0].x, pts[0].y, wantX, wantY) < 0.5,
        format("the vertex highlight must sit on the DRAWN vertex: got "
               ~ "(%.2f,%.2f), drawn (%.2f,%.2f), off by %.2f px",
               pts[0].x, pts[0].y, wantX, wantY,
               t0619Dist(pts[0].x, pts[0].y, wantX, wantY)));
    // ...and the other half of the pair, stated explicitly rather than implied
    // by the tolerance above.
    assert(t0619Dist(pts[0].x, pts[0].y, idX, idY) > 20.0,
        format("the vertex highlight must NOT sit on the identity-pose "
               ~ "vertex: got (%.2f,%.2f), identity (%.2f,%.2f), off by %.2f px",
               pts[0].x, pts[0].y, idX, idY,
               t0619Dist(pts[0].x, pts[0].y, idX, idY)));
}

unittest { // 0619: the highlighted EDGE is marked where it is drawn.
    auto saved = primaryModelSpaceResolver;
    scope (exit) primaryModelSpaceResolver = saved;
    t0619InstallPrimary();

    auto m  = t0619Mesh();
    auto vp = t0619Viewport();
    assert(m.edges.length >= 1, "fixture: the triangle must have edges");

    // Take edge 0 and read its own endpoints — never assume an ordering.
    immutable uint a = m.edges[0][0];
    immutable uint b = m.edges[0][1];
    float aX, aY, bX, bY, aIdX, aIdY;
    t0619DrawnPx(m, a, vp, aX, aY);
    t0619DrawnPx(m, b, vp, bX, bY);
    t0619IdentityPx(m, a, vp, aIdX, aIdY);
    assert(t0619Dist(aX, aY, aIdX, aIdY) > 20.0,
        "vacuous fixture: the drawn and identity-pose endpoints coincide");
    // The two endpoints must also be far apart, or an implementation that
    // returned the same point twice would pass.
    assert(t0619Dist(aX, aY, bX, bY) > 20.0,
        "vacuous fixture: the edge's two endpoints project to one pixel");

    SnapResult r;
    r.highlighted = true;
    r.targetType  = SnapType.Edge;
    r.targetIndex = 0;
    r.targetSource = 0;

    ImVec2[] pts;
    assert(snapHighlightPixels(r, vp, m, pts), "edge highlight must resolve");
    assert(pts.length == 2, "an edge target marks exactly two points");
    assert(t0619Dist(pts[0].x, pts[0].y, aX, aY) < 0.5
        && t0619Dist(pts[1].x, pts[1].y, bX, bY) < 0.5,
        format("the edge highlight must span the DRAWN endpoints: a off by "
               ~ "%.2f px, b off by %.2f px",
               t0619Dist(pts[0].x, pts[0].y, aX, aY),
               t0619Dist(pts[1].x, pts[1].y, bX, bY)));
    assert(t0619Dist(pts[0].x, pts[0].y, aIdX, aIdY) > 20.0,
        "the edge highlight must NOT span the identity-pose endpoints");
}

unittest { // 0619: the highlighted FACE outline follows the drawn corners.
    auto saved = primaryModelSpaceResolver;
    scope (exit) primaryModelSpaceResolver = saved;
    t0619InstallPrimary();

    auto m  = t0619Mesh();
    auto vp = t0619Viewport();

    SnapResult r;
    r.highlighted = true;
    r.targetType  = SnapType.Polygon;
    r.targetIndex = 0;
    r.targetSource = 0;

    ImVec2[] pts;
    assert(snapHighlightPixels(r, vp, m, pts), "face highlight must resolve");
    assert(pts.length == 3, "the fixture face has three corners");
    foreach (i, vi; m.faces[0]) {
        float wx, wy, ix, iy;
        t0619DrawnPx(m, vi, vp, wx, wy);
        t0619IdentityPx(m, vi, vp, ix, iy);
        assert(t0619Dist(wx, wy, ix, iy) > 20.0,
            "vacuous fixture: corner projects to the same pixel in both laws");
        assert(t0619Dist(pts[i].x, pts[i].y, wx, wy) < 0.5,
            format("face outline corner %d must sit on the DRAWN vertex: "
                   ~ "off by %.2f px", i,
                   t0619Dist(pts[i].x, pts[i].y, wx, wy)));
        assert(t0619Dist(pts[i].x, pts[i].y, ix, iy) > 20.0,
            "face outline corner must NOT sit on the identity-pose vertex");
    }
}
