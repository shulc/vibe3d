module vibe3d.editing.tools.interactive.snap_render_source_helpers;

import vibe3d.util.math.math : Vec3;
import vibe3d.util.spatial.spatial : Viewport, projectToWindowFull, ModelSpace;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.selection.query.snap : SnapResult;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : SnapType;
import d_imgui.imgui_h : ImVec2;
import vibe3d.editing.tools.interactive.snap_render : snapHighlightPixels;

version (unittest) {
    import vibe3d.util.math.math     : lookAt, perspectiveMatrix, transformPoint;
    import vibe3d.documents.model.document : ItemXform, primaryModelSpaceResolver;
    import std.format : format;

    // Deliberately not axis-aligned and not symmetric about any plane.
    private enum Vec3 T0619_POS = Vec3( 1.60f, -0.70f,  0.45f);
    private enum Vec3 T0619_ROT = Vec3(12.0f,  40.0f,  -8.0f);
    private enum Vec3 T0619_SCL = Vec3( 1.70f,  1.00f,  0.60f);

    public float[16] t0619Matrix() {
        ItemXform xf;
        xf.pos = T0619_POS; xf.rot = T0619_ROT; xf.scl = T0619_SCL;
        return xf.composedMatrix();
    }

    public Viewport t0619Viewport() {
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
    public Mesh t0619Mesh() {
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
    public void t0619DrawnPx(const ref Mesh m, size_t vi, const ref Viewport vp,
                              out float px, out float py) {
        float ndcZ;
        immutable float[16] M = t0619Matrix();
        assert(projectToWindowFull(transformPoint(M, m.vertices[vi]), vp,
                                   px, py, ndcZ),
               "fixture: the drawn vertex must be on screen");
    }

    // The pixel the WRONG law would produce: the raw local coordinate through
    // the world viewport.
    public void t0619IdentityPx(const ref Mesh m, size_t vi, const ref Viewport vp,
                                 out float px, out float py) {
        float ndcZ;
        assert(projectToWindowFull(m.vertices[vi], vp, px, py, ndcZ),
               "fixture: the identity-pose vertex must also be on screen — "
               ~ "otherwise the wrong law would merely fail to draw, and the "
               ~ "case would be measuring nothing");
    }

    public double t0619Dist(float ax, float ay, float bx, float by) {
        import std.math : sqrt;
        immutable double dx = ax - bx, dy = ay - by;
        return sqrt(dx * dx + dy * dy);
    }

    // ---- background-source fixtures -------------------------------------
    // Two MORE item transforms, one per background slot. Each carries a
    // translation, a non-uniform scale AND a rotation, and none of the three
    // (primary / bg-A / bg-B) shares an axis with another — so a fixture
    // vertex has three well-separated drawn positions and picking the wrong
    // space is a visibly wrong pixel rather than a rounding difference.
    private enum Vec3 T0619_BGA_POS = Vec3(-1.80f,  1.10f, -0.85f);
    private enum Vec3 T0619_BGA_ROT = Vec3(-25.0f, 15.0f,  33.0f);
    private enum Vec3 T0619_BGA_SCL = Vec3( 0.55f,  1.90f,  1.25f);

    private enum Vec3 T0619_BGB_POS = Vec3( 1.95f, -1.05f,  1.40f);
    private enum Vec3 T0619_BGB_ROT = Vec3(  5.0f, -60.0f,  18.0f);
    private enum Vec3 T0619_BGB_SCL = Vec3( 1.35f,  0.45f,  1.75f);

    public ItemXform t0619Xf(Vec3 p, Vec3 r, Vec3 s) {
        ItemXform xf; xf.pos = p; xf.rot = r; xf.scl = s;
        return xf;
    }

    // The pixel item transform `xf` puts the LOCAL point `v` at — the same
    // two steps the draw path takes, with the transform named explicitly so
    // one case can compare several candidate spaces against each other.
    public void t0619PxUnder(ItemXform xf, Vec3 v, const ref Viewport vp,
                              out float px, out float py) {
        float ndcZ;
        immutable float[16] M = xf.composedMatrix();
        assert(projectToWindowFull(transformPoint(M, v), vp, px, py, ndcZ),
               "fixture: the probe point must be on screen");
    }

    // Two background meshes with no vertex in common, so the case also fails
    // if the wrong SOURCE (rather than the wrong space) is indexed.
    public Mesh t0619BgMeshA() {
        Mesh m;
        m.addVertex(Vec3( 0.75f, -0.95f,  0.30f));
        m.addVertex(Vec3(-0.85f,  0.60f, -1.00f));
        m.addVertex(Vec3( 1.00f,  0.85f,  0.55f));
        m.addFace([0u, 1u, 2u]);
        return m;
    }

    public Mesh t0619BgMeshB() {
        Mesh m;
        m.addVertex(Vec3( 0.10f,  1.25f, -0.65f));
        m.addVertex(Vec3(-1.30f, -0.20f,  0.95f));
        m.addVertex(Vec3( 0.60f, -1.10f, -0.35f));
        m.addFace([0u, 1u, 2u]);
        return m;
    }

    // Install a non-identity primary transform for the duration of a case.
    public void t0619InstallPrimary() {
        primaryModelSpaceResolver = () {
            ItemXform xf;
            xf.pos = T0619_POS; xf.rot = T0619_ROT; xf.scl = T0619_SCL;
            return xf.modelSpace();
        };
    }
}

unittest { // 0619: a BACKGROUND source is marked through ITS OWN space.
    // THE POINT OF THE SLOT MACHINERY. `snapSourceSpace` and the
    // `targetSource >= 1` arm of `snapHighlightPixels` exist for exactly one
    // reason: a winner that came from a BACKGROUND layer must be drawn
    // through THAT layer's transform, not the primary's. Every other case in
    // this file sets `targetSource = 0`, so none of them can tell the two
    // apart — replacing the arm with `primaryModelSpace()`, or reading
    // `g_snapSourceSpaces[slot]` instead of `[slot-1]`, reads the same
    // number through all of them.
    //
    // Four candidate pixels are computed up front, from four different
    // spaces, and the case asserts the answer is the first and none of the
    // other three:
    //
    //   want  bg-A's own space          <- correct
    //   prim  the PRIMARY's space       <- "one space for every slot"
    //   nbr   bg-B's space (slot 2)     <- "[slot]" instead of "[slot-1]"
    //   id    no space at all           <- the pre-0619 law
    import vibe3d.editing.selection.query.snap : setBackgroundSnapSources;

    auto saved = primaryModelSpaceResolver;
    scope (exit) primaryModelSpaceResolver = saved;
    t0619InstallPrimary();
    scope (exit) setBackgroundSnapSources(null, null);

    auto vp = t0619Viewport();

    // The primary mesh the renderer is handed. Slot 1 must NOT read it — it
    // is deliberately a DIFFERENT triangle from either background source, so
    // indexing it would also land somewhere else.
    auto primaryMesh = t0619Mesh();

    auto bgA = t0619BgMeshA();
    auto bgB = t0619BgMeshB();
    auto xfA = t0619Xf(T0619_BGA_POS, T0619_BGA_ROT, T0619_BGA_SCL);
    auto xfB = t0619Xf(T0619_BGB_POS, T0619_BGB_ROT, T0619_BGB_SCL);

    const(Mesh)*[] srcs   = [&bgA, &bgB];
    ModelSpace[]   spaces = [xfA.modelSpace(), xfB.modelSpace()];
    setBackgroundSnapSources(srcs, spaces);

    enum size_t VI = 0;
    immutable Vec3 vLocal = bgA.vertices[VI];

    float wantX, wantY, primX, primY, nbrX, nbrY, idX, idY;
    t0619PxUnder(xfA, vLocal, vp, wantX, wantY);
    t0619PxUnder(t0619Xf(T0619_POS, T0619_ROT, T0619_SCL), vLocal, vp, primX, primY);
    t0619PxUnder(xfB, vLocal, vp, nbrX, nbrY);
    t0619IdentityPx(bgA, VI, vp, idX, idY);

    // Vacuity guards FIRST — one per wrong law. If any of these coincided
    // with the right answer the case could not fail, and a green run would
    // mean nothing.
    assert(t0619Dist(wantX, wantY, primX, primY) > 20.0,
        format("vacuous fixture: bg-A's space and the PRIMARY's space put "
               ~ "this vertex on the same pixel (%.2f px apart)",
               t0619Dist(wantX, wantY, primX, primY)));
    assert(t0619Dist(wantX, wantY, nbrX, nbrY) > 20.0,
        format("vacuous fixture: the two background slots' spaces put this "
               ~ "vertex on the same pixel (%.2f px apart)",
               t0619Dist(wantX, wantY, nbrX, nbrY)));
    assert(t0619Dist(wantX, wantY, idX, idY) > 20.0,
        "vacuous fixture: bg-A's drawn and identity-pose pixels coincide");

    SnapResult r;
    r.highlighted  = true;
    r.snapped      = true;
    r.targetType   = SnapType.Vertex;
    r.targetIndex  = cast(int) VI;
    r.targetSource = 1;                 // the FIRST background source

    ImVec2[] pts;
    assert(snapHighlightPixels(r, vp, primaryMesh, pts),
        "a background-source highlight must resolve");
    assert(pts.length == 1, "a vertex target marks exactly one point");

    assert(t0619Dist(pts[0].x, pts[0].y, wantX, wantY) < 0.5,
        format("the background highlight must sit where bg-A is DRAWN: got "
               ~ "(%.2f,%.2f), bg-A (%.2f,%.2f), primary (%.2f,%.2f), "
               ~ "slot-2 (%.2f,%.2f), identity (%.2f,%.2f)",
               pts[0].x, pts[0].y, wantX, wantY, primX, primY,
               nbrX, nbrY, idX, idY));
    assert(t0619Dist(pts[0].x, pts[0].y, primX, primY) > 20.0,
        format("the background highlight must NOT use the PRIMARY's space: "
               ~ "got (%.2f,%.2f), primary-pose (%.2f,%.2f), off by %.2f px",
               pts[0].x, pts[0].y, primX, primY,
               t0619Dist(pts[0].x, pts[0].y, primX, primY)));
    assert(t0619Dist(pts[0].x, pts[0].y, nbrX, nbrY) > 20.0,
        format("the background highlight must NOT use the NEXT slot's space: "
               ~ "got (%.2f,%.2f), slot-2 pose (%.2f,%.2f), off by %.2f px",
               pts[0].x, pts[0].y, nbrX, nbrY,
               t0619Dist(pts[0].x, pts[0].y, nbrX, nbrY)));
    assert(t0619Dist(pts[0].x, pts[0].y, idX, idY) > 20.0,
        "the background highlight must NOT sit on the identity-pose vertex");
}
