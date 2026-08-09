module snap_render;

import math : Vec3, Viewport, projectToWindowFull, ModelSpace,
              AimViewport, aimSpace;
import mesh : Mesh;
import snap : SnapResult, snapSource, snapSourceSpace;
import document : primaryModelSpace;
import toolpipe.packets : SnapType;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ---------------------------------------------------------------------------
// Snap visual feedback — Phase 7.3d of doc/snap_plan.md.
//
// drawSnapOverlay() renders two layers:
//
//   1. CYAN element highlight — the actual mesh element snap is locked
//      onto (vertex dot / edge segment / face outline). Drawn first so
//      the cursor marker sits on top.
//
//   2. YELLOW cursor marker at the snap candidate's projected pixel:
//      - Within `outerRangePx` (highlighted, NOT snapped) ⇒ ring only
//        (pre-snap pulse — "if you keep going, this is what you'll
//        snap to").
//      - Within `innerRangePx` (snapped) ⇒ filled disc + ring.
//
// Tools call this from their `draw()` after capturing the most recent
// SnapResult in their motion handler. The renderer is shared because
// every snap-aware tool (Move now, Pen / Create-tools in 7.3f) uses
// the same convention.
//
// `g_lastSnap` is the global "most recent snap result published by any
// tool" — the /api/snap/last HTTP endpoint reads this for headless
// test runs (the test doesn't need a screenshot, just JSON probe).
// ---------------------------------------------------------------------------

__gshared SnapResult g_lastSnap;

/// Update the global last-snap state. Tools call this after every
/// motion event that ran snapCursor, snap-fired or not (so the
/// pre-snap highlight pulse stays current).
void publishLastSnap(SnapResult sr) {
    g_lastSnap = sr;
}

/// Reset the global last-snap. Tools call this at drag end so the
/// stale highlight from the last drag doesn't linger.
void clearLastSnap() {
    g_lastSnap = SnapResult.init;
}

/// Draw the snap overlay for `result`. No-op when `!result.highlighted`
/// (the cursor isn't near any snap target this frame).
void drawSnapOverlay(const ref SnapResult result, const ref Viewport vp,
                     const ref Mesh mesh)
{
    if (!result.highlighted) return;

    auto dl = ImGui.GetForegroundDrawList();

    drawTargetElementHighlight(dl, result, vp, mesh);
    drawCursorMarker(dl, result, vp);
}

/// The window pixels the cyan element highlight is drawn at — the whole of
/// this overlay's geometry, with nothing but colour and stroke width left
/// behind in the drawing code below.
///
/// Split out for task 0619 so the value that carries the item transform is
/// assertable. `drawTargetElementHighlight` emits into ImGui's foreground
/// drawlist, which no headless probe can read (`/api/viewport/probe` reads a
/// cell FBO, and this overlay is not in one), so a test written against the
/// draw could only ever assert that it did not crash. The pixels are the
/// thing under test, and this returns them.
///
/// Fills `pts` with one point for a vertex target, two for an edge, and one
/// per corner for a face. Returns false when the target cannot be resolved or
/// any of its points fails to project — the same fail-soft the draw takes.
bool snapHighlightPixels(const ref SnapResult result, const ref Viewport vp,
                         const ref Mesh mesh, ref ImVec2[] pts)
{
    pts.length = 0;
    if (!result.highlighted) return false;

    int idx = result.targetIndex;
    auto t  = result.targetType;

    // Resolve the source the winning candidate came from (layers Stage 5).
    // `targetIndex` is a SOURCE-LOCAL element index; indexing the active mesh
    // for a background-source winner would highlight the wrong element (or be
    // silently dropped by the range guard). Slot 0 = the active `mesh` arg
    // (common path); slots 1..N resolve to their own source mesh via
    // snap.snapSource. A null resolution (background source gone this frame)
    // ⇒ skip — same fail-soft as the out-of-range guard.
    //
    // ...and, with it, the ModelSpace that source is DRAWN through (task
    // 0619). `m.vertices[]` are LOCAL to their layer; projecting them with the
    // plain world `vp` drew the cyan highlight where the element would sit
    // under an IDENTITY item transform, while the yellow cursor marker
    // (a genuine world point) was drawn correctly — so on a transformed layer
    // the two markers visibly separated. Aiming kind **Pixel** (plan §1.1):
    // keep the geometry local and compose the viewport, which is exact
    // (`proj·(view·M)·v == proj·view·(M·v)`) and costs one 4x4 multiply for
    // the whole overlay instead of one per vertex.
    const(Mesh)* m;
    ModelSpace   ms;
    if (result.targetSource == 0) {
        // Slot 0 is the active mesh, which snap.d does not hold — the caller
        // passes it in, so its transform is the primary layer's, read fresh
        // here (there is no invalidation signal to cache it against; 0617
        // §2.4 proved none exists).
        m  = &mesh;
        ms = primaryModelSpace();
    } else if (!snapSourceSpace(result.targetSource, ms)) {
        return false;                // background source gone — fail soft
    } else {
        m = snapSource(result.targetSource);
    }
    if (m is null) return false;

    const AimViewport vpAim = aimSpace(vp, ms);

    if (t == SnapType.Vertex) {
        if (idx < 0 || idx >= cast(int)m.vertices.length) return false;
        ImVec2 pt;
        if (!projectLocal(m.vertices[idx], vpAim, pt)) return false;
        pts = [pt];
        return true;
    }
    if (t == SnapType.Edge || t == SnapType.EdgeCenter) {
        if (idx < 0 || idx >= cast(int)m.edges.length) return false;
        auto edge = m.edges[idx];
        ImVec2 a, b;
        if (!projectLocal(m.vertices[edge[0]], vpAim, a)) return false;
        if (!projectLocal(m.vertices[edge[1]], vpAim, b)) return false;
        pts = [a, b];
        return true;
    }
    if (t == SnapType.Polygon || t == SnapType.PolyCenter) {
        if (idx < 0 || idx >= cast(int)m.faces.length) return false;
        auto face = m.faces[idx];
        if (face.length < 3) return false;
        ImVec2[] out_;
        out_.length = face.length;
        foreach (i, vi; face) {
            if (vi >= m.vertices.length) return false;
            if (!projectLocal(m.vertices[vi], vpAim, out_[i])) return false;
        }
        pts = out_;
        return true;
    }
    // SnapType.Grid / SnapType.Workplane have no geometric element to
    // highlight — the cursor marker alone suffices.
    return false;
}

private void drawTargetElementHighlight(ImGui.ImDrawList* dl,
                                        const ref SnapResult result,
                                        const ref Viewport vp,
                                        const ref Mesh mesh)
{
    // Brighter cyan when actually snapped, dimmer when only highlighted —
    // mirrors the yellow cursor marker's snapped-vs-pre-snap intensity. NOTE:
    // the highlight is INTERACTION FEEDBACK drawn full-bright on top of the 3D
    // scene; it is intentionally NOT dimmed to match a background layer's
    // dimmed geometry pass — the targeted element must stay the most legible
    // thing on screen regardless of which layer it lives on (layers Stage 5).
    immutable uint elemCol = result.snapped
        ? IM_COL32(0, 220, 255, 230)
        : IM_COL32(0, 220, 255, 150);
    immutable uint elemFill = result.snapped
        ? IM_COL32(0, 220, 255,  60)
        : IM_COL32(0, 220, 255,  30);
    immutable float lineThick = result.snapped ? 2.5f : 1.8f;

    // All of the geometry — including the item transform — is in
    // `snapHighlightPixels`. What is left here is colour and stroke.
    ImVec2[] pts;
    if (!snapHighlightPixels(result, vp, mesh, pts)) return;

    auto t = result.targetType;
    if (t == SnapType.Vertex) {
        dl.AddCircleFilled(pts[0], 5.0f, elemCol, 16);
    }
    else if (t == SnapType.Edge || t == SnapType.EdgeCenter) {
        dl.AddLine(pts[0], pts[1], elemCol, lineThick);
    }
    else {
        // Outline. Fill is risky for non-convex faces — skip the fill on
        // anything but tris/quads where convexity is virtually
        // guaranteed.
        if (pts.length <= 4)
            dl.AddConvexPolyFilled(pts.ptr, cast(int)pts.length, elemFill);
        dl.AddPolyline(pts.ptr, cast(int)pts.length, elemCol,
                       ImDrawFlags.Closed, lineThick);
    }
}

private void drawCursorMarker(ImGui.ImDrawList* dl,
                              const ref SnapResult result,
                              const ref Viewport vp)
{
    // `SnapResult.highlightPos` is a genuine WORLD point — `snapCursor`
    // folds every candidate through its source's ModelSpace before ranking
    // (snap.d `walkSource`'s `toWorld`), and this is the winner it published.
    // So it takes the plain world viewport, and the TYPE says so.
    ImVec2 pos;
    if (!projectWorld(result.highlightPos, vp, pos)) return;

    // Yellow (matches the existing test-mode cursor colour at
    // app.d:3235).
    enum uint outlineCol = IM_COL32(255, 220,   0, 230);
    enum uint fillCol    = IM_COL32(255, 220,   0, 140);

    enum float outerR = 10.0f;   // ring radius
    enum float innerR =  4.0f;   // filled-disc radius (snapped only)

    if (result.snapped) {
        dl.AddCircleFilled(pos, innerR, fillCol, 16);
        dl.AddCircle(pos, outerR, outlineCol, 24, 2.0f);
    } else {
        // Pre-snap: outline only, slightly thinner.
        dl.AddCircle(pos, outerR, outlineCol, 24, 1.5f);
    }
}

// One projection per SPACE, not one projection with a parameter named after
// the space it usually holds (task 0619 §2.0, the same split `topology_pen.d`
// carries). The old single `project(Vec3 worldPos, ...)` was named `worldPos`
// and was handed a raw LOCAL vertex at four of its five call sites; a name
// cannot be wrong in a way the compiler notices, but a TYPE can. `AimViewport`
// is constructible only through `aimSpace(vp, ms)`, so passing the world
// viewport where the composed one belongs is a compile error rather than a
// silently misplaced highlight.

/// Project a point that is LOCAL to its layer, through the aim space that
/// already carries that layer's model matrix.
private bool projectLocal(Vec3 pLocal, const ref AimViewport vpAim, out ImVec2 pt) {
    float sx, sy, ndcZ;
    if (!projectToWindowFull(pLocal, vpAim.vp, sx, sy, ndcZ)) return false;
    pt = ImVec2(sx, sy);
    return true;
}

/// Project a point that is already WORLD, through the plain world viewport.
private bool projectWorld(Vec3 pWorld, const ref Viewport vp, out ImVec2 pt) {
    float sx, sy, ndcZ;
    if (!projectToWindowFull(pWorld, vp, sx, sy, ndcZ)) return false;
    pt = ImVec2(sx, sy);
    return true;
}

// ===========================================================================
// VERIFIED BY MUTATION. Each was applied to the green tree, built and run;
// the observed failure is recorded, and the tree restored and re-run green.
//
//   1. `snapHighlightPixels` composed `ModelSpace.world()` instead of the
//      resolved source space — the pre-0619 law, verbatim.
//      RED (vertex): "got (441.05,362.48), drawn (600.64,424.52), off by
//      171.22 px" — the highlight landed exactly on the identity-pose pixel.
//      RED (edge):   "a off by 73.87 px, b off by 171.22 px".
//      RED (face):   "corner 0 ... off by 73.87 px".
//      (D aborts a module at the first AssertError, so the edge and face
//      values were read by relaxing the earlier cases in turn.)
//
//   2. `projectWorld` composed the primary's matrix in too — the opposite
//      error, "fixing" a value that was already world.
//      RED: "the cursor marker must project through the PLAIN world
//      viewport: off by 148.0039 px".
// ===========================================================================

// ===========================================================================
// Task 0619 — the snap highlight is drawn where the element IS DRAWN.
//
// THE PAIR THESE CASES ASSERT, and the wrong implementation they separate:
//
//   correct law   project `M * v_local` (compose the layer's matrix into the
//                 viewport, which is what `aimSpace` does)
//   wrong  law    project `v_local` through the WORLD viewport   <- pre-0619
//
// The oracle is the pixel itself, computed in the test through the app's own
// `projectToWindowFull` from `ItemXform.composedMatrix()` — the same matrix
// the DRAW path binds — rather than by re-running the function under test.
//
// The fixture is asymmetric on every axis the law touches: translation on all
// three, rotation on all three, and a NON-UNIFORM scale. A 90/180-degree
// rotation or a mirror-only transform maps a symmetric vertex SET to itself,
// so it can only ever measure winding and never position — the fixture shape
// that shipped the 0617 bug, named in its retro. Each case therefore opens
// with a vacuity guard: the drawn pixel and the identity pixel must be far
// enough apart that a wrong answer cannot hide inside the tolerance.
// ===========================================================================
version (unittest) {
    import math     : lookAt, perspectiveMatrix, transformPoint;
    import document : ItemXform, primaryModelSpaceResolver;
    import std.format : format;

    // Deliberately not axis-aligned and not symmetric about any plane.
    private enum Vec3 T0619_POS = Vec3( 1.60f, -0.70f,  0.45f);
    private enum Vec3 T0619_ROT = Vec3(12.0f,  40.0f,  -8.0f);
    private enum Vec3 T0619_SCL = Vec3( 1.70f,  1.00f,  0.60f);

    private float[16] t0619Matrix() {
        ItemXform xf;
        xf.pos = T0619_POS; xf.rot = T0619_ROT; xf.scl = T0619_SCL;
        return xf.composedMatrix();
    }

    private Viewport t0619Viewport() {
        import std.math : PI;
        Viewport vp;
        Vec3 eye = Vec3(4.0f, 3.0f, 9.0f);
        vp.view   = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
        vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f, 800.0f / 600.0f,
                                      0.01f, 100.0f);
        vp.width  = 800; vp.height = 600; vp.x = 0; vp.y = 0;
        vp.eye    = eye; vp.focus = Vec3(0, 0, 0);
        return vp;
    }

    // A triangle whose three corners differ in x, y AND z, so no two of them
    // can alias under the transform above.
    private Mesh t0619Mesh() {
        Mesh m;
        m.addVertex(Vec3(-1.20f,  0.35f, -0.90f));
        m.addVertex(Vec3( 0.90f, -0.55f,  0.70f));
        m.addVertex(Vec3(-0.40f,  1.10f,  0.80f));
        m.addFace([0u, 1u, 2u]);
        return m;
    }

    // The pixel the DRAW path puts vertex `vi` at, derived independently of
    // the function under test: transform by the composed matrix, then project
    // with the plain world viewport.
    private void t0619DrawnPx(const ref Mesh m, size_t vi, const ref Viewport vp,
                              out float px, out float py) {
        float ndcZ;
        immutable float[16] M = t0619Matrix();
        assert(projectToWindowFull(transformPoint(M, m.vertices[vi]), vp,
                                   px, py, ndcZ),
               "fixture: the drawn vertex must be on screen");
    }

    // The pixel the WRONG law would produce: the raw local coordinate through
    // the world viewport.
    private void t0619IdentityPx(const ref Mesh m, size_t vi, const ref Viewport vp,
                                 out float px, out float py) {
        float ndcZ;
        assert(projectToWindowFull(m.vertices[vi], vp, px, py, ndcZ),
               "fixture: the identity-pose vertex must also be on screen — "
               ~ "otherwise the wrong law would merely fail to draw, and the "
               ~ "case would be measuring nothing");
    }

    private double t0619Dist(float ax, float ay, float bx, float by) {
        import std.math : sqrt;
        immutable double dx = ax - bx, dy = ay - by;
        return sqrt(dx * dx + dy * dy);
    }

    // Install a non-identity primary transform for the duration of a case.
    private void t0619InstallPrimary() {
        primaryModelSpaceResolver = () {
            ItemXform xf;
            xf.pos = T0619_POS; xf.rot = T0619_ROT; xf.scl = T0619_SCL;
            return xf.modelSpace();
        };
    }
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

unittest { // 0619: the CURSOR MARKER is a world point and must NOT move.
    // The other half of the split: `highlightPos` is published in world space
    // by `snapCursor`, so composing the layer matrix into ITS projection would
    // be a NEW bug of the same family in the opposite direction. This case
    // fails if someone "fixes" the marker too.
    auto saved = primaryModelSpaceResolver;
    scope (exit) primaryModelSpaceResolver = saved;
    t0619InstallPrimary();

    auto vp = t0619Viewport();
    immutable Vec3 world = Vec3(0.8f, 0.4f, -0.3f);

    ImVec2 got;
    assert(projectWorld(world, vp, got), "the world marker must project");

    float wx, wy, ndcZ;
    assert(projectToWindowFull(world, vp, wx, wy, ndcZ));
    assert(t0619Dist(got.x, got.y, wx, wy) < 1e-3,
        format("the cursor marker must project through the PLAIN world "
               ~ "viewport: off by %.4f px", t0619Dist(got.x, got.y, wx, wy)));

    // And the discriminator: composing the transform in would move it.
    immutable float[16] M = t0619Matrix();
    float mx, my;
    assert(projectToWindowFull(transformPoint(M, world), vp, mx, my, ndcZ));
    assert(t0619Dist(wx, wy, mx, my) > 20.0,
        "vacuous fixture: composing M would not move this marker anyway");
}
