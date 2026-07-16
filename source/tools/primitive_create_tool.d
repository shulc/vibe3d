module tools.primitive_create_tool;

// ---------------------------------------------------------------------------
// PrimitiveCreateTool / HandledCreateTool / SizedRadialCreateTool(P) — the
// shared base tiers for the primitive create-tools (task 0414, 0407 sec
// A.D2 dedup). Extracted from cylinder.d/cone.d/capsule.d/torus.d/tube.d,
// which independently reimplemented the same state machine, preview/commit
// plumbing, mover/size-handle rig, and local<->world workplane helpers.
//
// This is a PURE internal refactor: no reference-editor-facing behaviour
// changes. Every leaf tool must stay byte-identical to its pre-refactor
// self, interactively and headlessly (see the task's Phase-0 regression
// tests, tests/test_primitive_{cylinder,torus,tube,sphere}_interactive.d).
//
// Hierarchy:
//   Tool
//    L PrimitiveCreateTool          infra: preview/commit/local<->world/
//      |                            mover/choosePlane/idle-snap/
//      |                            setupHeightPlane. NO size handles;
//      |                            draw() default = mover-only rig.
//      L HandledCreateTool          + sizeH[6] + size+mover draw rig +
//        |                          size-grab helpers.
//        L SizedRadialCreateTool!P  2-drag ellipse/height machine (the
//          |                        cylinder/cone/capsule/sphere shape) +
//          |                        virtual size-accessors so sphere's
//          |                        ellipsoid axis permutation plugs in
//          |                        without touching the machine's text.
//          L CylinderTool/ConeTool/CapsuleTool/SphereTool (cylinder.d etc)
//
// TorusTool (torus.d) extends HandledCreateTool directly (its own 2-drag
// major/minor machine, own size-handle routing). TubeTool (tube.d) extends
// PrimitiveCreateTool directly (its own 3-drag machine, no size handles at
// all — mover-only, using the base's default drawToolHandles rig).
// ---------------------------------------------------------------------------

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;

import tool;
import mesh;
import math;
import handler : MoveHandler, BoxHandler, gizmoSize, ToolHandles;
import eventlog : queryMouse;
import drag : axisDragDelta, planeDragDelta, screenAxisDelta;
import shader : Shader, LitShader, drawLitPreview;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import tools.create_common : pickWorkplaneFrame, WorkplaneFrame, currentWorkplaneFrame,
                              mostFacingAxis, transformPoint, transformDir, snapLocalHit;
import editmode : EditMode;
import snap : SnapResult;
import snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;

import std.math : abs, sqrt;

/// Shared snapshot-pair edit factory — every primitive create-tool uses the
/// identical delegate signature (was duplicated per-tool as CylinderEditFactory
/// / ConeEditFactory / ... / TorusEditFactory / TubeEditFactory).
alias PrimitiveEditFactory = MeshSessionEdit delegate();

// ---------------------------------------------------------------------------
// PrimitiveCreateTool — infra shared by every primitive create-tool: mesh/
// gpu/history plumbing, preview mesh + commit-on-deactivate, the mover
// gizmo, local<->world workplane transforms, choosePlane/setupHeightPlane,
// and the Idle-state snap overlay. Owns NO size handles (HandledCreateTool
// adds those) — draw()'s default handle rig is mover-only, matching
// TubeTool's id scheme (arrowX/Y/Z=0/1/2, centerBox=10).
// ---------------------------------------------------------------------------
abstract class PrimitiveCreateTool : Tool {
protected:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*    gpu;
    LitShader   litShader;

    CommandHistory      history;
    PrimitiveEditFactory factory;

    Mesh    previewMesh;
    GpuMesh previewGpu;
    bool    meshChanged;

    // Construction-plane frame chosen at first click and locked for the
    // whole interaction. Internal coords (params_.cen*, center(), the
    // various drag anchors, handle positions) live in this frame's LOCAL
    // space; mesh upload / commit transforms vertices through frame.toWorld.
    Vec3 planeNormal;
    Vec3 planeAxis1;
    Vec3 planeAxis2;
    WorkplaneFrame frame;

    // Last snap query — drives the Idle-state cyan/yellow overlay.
    SnapResult lastSnap;

    // Drag anchors — only valid for the matching state(s). Shared field
    // set across every leaf-group's own machine (cylinder-family, torus,
    // tube); a group that doesn't need one (e.g. torus has no baseAnchor
    // use) simply never references it.
    Vec3 startPoint;
    Vec3 currentPoint;
    Vec3 hpOrigin;
    Vec3 hpn;
    Vec3 heightDragStart;
    Vec3 baseAnchor;

    Viewport cachedVp;

    // Move gizmo (axis-only) — used by every leaf-group.
    MoveHandler mover;
    int         moverDragAxis = -1;
    int         moverLastMX, moverLastMY;

    // Single-source hover/capture arbiter for the mover (+ size handles,
    // once HandledCreateTool adds those).
    ToolHandles toolHandles;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.litShader = litShader;
        mover = new MoveHandler(Vec3(0, 0, 0));
        mover.circleXY.setVisible(false);
        mover.circleYZ.setVisible(false);
        mover.circleXZ.setVisible(false);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        mover.destroy();
    }

    void setUndoBindings(CommandHistory history, PrimitiveEditFactory factory) {
        this.history = history;
        this.factory = factory;
    }

    // ----- Points of extension (hook table, task 0414 plan sec 1) ----------

    /// The primitive's center, in workplane-local space. Every leaf-group's
    /// params_ carries cenX/Y/Z, so this is implemented once at the
    /// SizedRadialCreateTool!P / TorusTool / TubeTool level.
    protected Vec3 center() const;
    protected void setCenter(Vec3 c);

    protected bool isIdle() const;
    protected bool showHandles() const;
    /// True iff dropping the tool RIGHT NOW would commit geometry — the
    /// exact compound condition each group's deactivate()/hasUncommittedEdit
    /// tested individually pre-refactor (task 0414 risk #2). NOT
    /// `state != Idle`.
    protected bool willCommit() const;
    protected string commitLabel() const;
    /// Reset the leaf-group's own state enum to its Idle value. Kept
    /// abstract (rather than a shared `state = Idle` statement) because
    /// each leaf-group has its own enum TYPE (RadialState / TorusState /
    /// TubeState).
    protected void goIdle();

    /// Emit the primitive into `dst` (LOCAL workplane space) from the
    /// current params_. Used by BOTH the interactive preview
    /// (rebuildPreview) and commit (appendBuildInto) — for cylinder/cone/
    /// capsule/torus/tube this is a PURE function of params_ so all three
    /// paths (preview / interactive commit / headless) agree by
    /// construction. Sphere is the one exception (state-aware — see
    /// SphereTool's own applyHeadless override, task 0414 plan sec 1a).
    protected void buildInto(Mesh* dst);

    /// Additional per-group session reset beyond the shared `goIdle()` +
    /// activate() field resets below — e.g. HandledCreateTool's
    /// sizeDragIdx=-1, sphere's globe-lock + axisAtLastSync capture.
    /// Default no-op (PrimitiveCreateTool itself has nothing extra).
    protected void resetSession() {}

    /// Virtual: default true (matches every leaf-group pre-refactor, which
    /// had no such gate). TorusTool overrides it (majorRadius/minorRadius
    /// both need to clear an epsilon before a preview is worth drawing).
    protected bool previewValid() const { return true; }

    /// Render this tool's interactive handle rig. Default = mover-only,
    /// matching TubeTool's pre-refactor id scheme exactly (arrowX/Y/Z =
    /// 0/1/2, centerBox = 10). HandledCreateTool overrides this to add the
    /// 6 size handles (id scheme 0..5, mover shifted to 10..13).
    protected void drawToolHandles(const ref Shader shader, const ref Viewport vp) {
        mover.setPosition(toWorldP(center()));
        mover.setOrientation(frame.axis1, frame.normal, frame.axis2);
        toolHandles.begin();
        toolHandles.add(mover.centerBox, 10);
        toolHandles.add(mover.arrowX,    0);
        toolHandles.add(mover.arrowY,    1);
        toolHandles.add(mover.arrowZ,    2);
        if (moverDragAxis >= 0) toolHandles.setHaul(moverDragAxis <= 2 ? moverDragAxis : 10);
        else                    toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);
        mover.draw(shader, vp);
    }

    // ----- Tool lifecycle (concrete — shared skeleton, task 0414 risk #3/#4) -

    override void activate() {
        goIdle();
        meshChanged   = false;
        moverDragAxis = -1;
        resetSession();
        toolHandles.clearHaul();
        previewGpu.init();
    }

    override void deactivate() {
        bool wc = willCommit();

        MeshSnapshot pre;
        if (wc) pre = MeshSnapshot.capture(*mesh);

        if (wc) {
            appendBuildInto();
            meshChanged = true;
        }
        goIdle();
        previewGpu.destroy();

        if (wc) commitEdit(pre);

        lastSnap = SnapResult.init;
        clearLastSnap();
    }

    override void evaluate() {
        if (isIdle()) return;
        rebuildPreview();
    }

    /// Default headless apply: append buildInto(mesh) under the active
    /// workplane. PURE(params_) for cylinder/cone/capsule/torus/tube, so
    /// this default is correct for all of them. Sphere overrides this
    /// entirely (task 0414 plan sec 1a / PRAVKA 1) because its buildInto is
    /// STATE-aware and would silently emit a flat ellipse fan headlessly
    /// (state == Idle at headless-call time) if routed through here.
    override bool applyHeadless() {
        frame = currentWorkplaneFrame();
        appendBuildInto();
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        drawSnapOverlay(lastSnap, vp, *mesh);
        if (isIdle()) return;

        drawLitPreview(litShader, shader, vp, previewGpu);

        if (showHandles()) drawToolHandles(shader, vp);
    }

    override bool drawImGui() { return false; }

    // ----- History-coordination hooks (undo/redo migration P0) -------------
    // willCommit() IS the exact compound condition each leaf's
    // hasUncommittedEdit()/deactivate() commit-guard tested individually —
    // see the hook doc above. cancelUncommittedEdit/resyncSession both drop
    // to Idle: Category B preview-only cancel (the scene mesh is untouched
    // until commit), and no scene-mesh baseline is cached to resync from.
    public override bool hasUncommittedEdit() const { return willCommit(); }
    public override void cancelUncommittedEdit() { goIdle(); }
    public override void resyncSession()         { goIdle(); }

    // ----- Shared helpers (protected — used by every leaf-group's own or ---
    // -----  inherited event handlers) --------------------------------------
protected:
    void choosePlane(const ref Viewport vp) {
        // Capture workplane as a local<->world transform; tool-internal
        // coords are in local-space (workplane = identity XZ plane).
        frame = pickWorkplaneFrame(vp);
        // Pick the construction plane by camera (most-facing-axis in
        // workplane basis), matching every Create-tool / the corner gizmo.
        Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
        final switch (mostFacingAxis(camBack, frame.axis1, frame.normal, frame.axis2)) {
            case 0:
                planeNormal = Vec3(1, 0, 0);
                planeAxis1  = Vec3(0, 1, 0);
                planeAxis2  = Vec3(0, 0, 1);
                break;
            case 1:
                planeNormal = Vec3(0, 1, 0);
                planeAxis1  = Vec3(1, 0, 0);
                planeAxis2  = Vec3(0, 0, 1);
                break;
            case 2:
                planeNormal = Vec3(0, 0, 1);
                planeAxis1  = Vec3(1, 0, 0);
                planeAxis2  = Vec3(0, 1, 0);
                break;
        }
    }

    // ---- Local <-> world helpers (workplane refactor) ---------------------
    Vec3 localEye() const { return transformPoint(frame.toLocal, cachedVp.eye); }
    Vec3 localRay(int x, int y) const {
        return transformDir(frame.toLocal, screenRay(x, y, cachedVp));
    }
    Vec3 toWorldP(Vec3 p) const { return transformPoint(frame.toWorld, p); }
    Vec3 toWorldD(Vec3 d) const { return transformDir  (frame.toWorld, d); }
    Vec3 toLocalD(Vec3 d) const { return transformDir  (frame.toLocal, d); }
    void applyFrameToMeshRange(Mesh* m, size_t firstIdx) {
        foreach (i; firstIdx .. m.vertices.length)
            m.vertices[i] = transformPoint(frame.toWorld, m.vertices[i]);
    }

    void setupHeightPlane() {
        hpOrigin = center();
        Vec3 toCamera = localEye() - hpOrigin;
        Vec3 inPlane  = toCamera - planeNormal * dot(toCamera, planeNormal);
        float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
        hpn = len > 1e-6f ? inPlane / len : planeAxis1;
    }

    static int worldAxisIdxOf(Vec3 v) {
        if (abs(v.x) > 0.5f) return 0;
        if (abs(v.y) > 0.5f) return 1;
        return 2;
    }

    // Delegates to the shared MoveHandler.hitTest (task 0410, dedup 0407
    // sec A.D5).
    int moverHitTest(int mx, int my) {
        return mover.hitTest(mx, my, cachedVp);
    }

    // Build the preview mesh from the current params_ (via the buildInto
    // hook) in LOCAL workplane space, then transform every vertex through
    // frame.toWorld for on-screen rendering.
    void rebuildPreview() {
        previewMesh.clear();
        if (previewValid()) {
            buildInto(&previewMesh);
            applyFrameToMeshRange(&previewMesh, 0);
            previewMesh.buildLoops();
        }
        previewGpu.upload(previewMesh);
    }

    void uploadPreview() { rebuildPreview(); }

    // Append into the SCENE mesh (same convention every leaf's
    // commit*/applyHeadless followed) — mesh emitted in LOCAL workplane
    // space; only the newly-appended vertex range is transformed via
    // frame.toWorld so existing scene geometry stays put. Does NOT set
    // meshChanged (task 0414 PRAVKA 3: that field is dead — written, never
    // read, superseded by the change-bus — kept write-only for hygiene;
    // callers that need it set it themselves, matching the pre-refactor
    // commit-vs-headless split).
    void appendBuildInto() {
        size_t firstNewVert = mesh.vertices.length;
        buildInto(mesh);
        applyFrameToMeshRange(mesh, firstNewVert);
        mesh.buildLoops();
        gpu.upload(*mesh);
    }

    void commitEdit(MeshSnapshot pre) {
        if (history is null || factory is null) return;
        if (!pre.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, commitLabel());
        history.record(cmd);
    }

    // ----- Mover-only grab/release/drag (tube uses these directly; --------
    // -----  HandledCreateTool wraps them with the size-handle priority) ----
    bool tryGrabMover(int mx, int my) {
        int hit = moverHitTest(mx, my);
        if (hit >= 0) {
            moverDragAxis = hit;
            moverLastMX   = mx;
            moverLastMY   = my;
            return true;
        }
        return false;
    }

    bool tryReleaseMover() {
        if (moverDragAxis >= 0) { moverDragAxis = -1; toolHandles.clearHaul(); return true; }
        return false;
    }

    bool handleMoverDrag(int mx, int my) {
        if (moverDragAxis < 0) return false;
        bool skip;
        Vec3 delta = moverDragAxis <= 2
            ? axisDragDelta (mx, my, moverLastMX, moverLastMY,
                             moverDragAxis, mover, cachedVp, skip)
            : planeDragDelta(mx, my, moverLastMX, moverLastMY,
                             moverDragAxis, mover.center, cachedVp, skip,
                             mover.axisX, mover.axisY, mover.axisZ,
                             frame.normal);
        if (!skip) {
            Vec3 dl = toLocalD(delta);
            Vec3 c  = center();
            c.x += dl.x; c.y += dl.y; c.z += dl.z;
            setCenter(c);
            rebuildPreview();
        }
        moverLastMX = mx; moverLastMY = my;
        return true;
    }

    // Idle-state live snap preview — the cyan/yellow overlay showing where
    // the next click would anchor the primitive.
    void updateIdleSnap(int mx, int my) {
        WorkplaneFrame f = pickWorkplaneFrame(cachedVp);
        Vec3 lEye = transformPoint(f.toLocal, cachedVp.eye);
        Vec3 lRay = transformDir  (f.toLocal, screenRay(mx, my, cachedVp));
        Vec3 hit;
        if (rayPlaneIntersect(lEye, lRay, Vec3(0, 0, 0), Vec3(0, 1, 0), hit)) {
            lastSnap = snapLocalHit(hit, f, mx, my, cachedVp, *mesh, EditMode.Vertices);
            publishLastSnap(lastSnap);
        } else {
            lastSnap = SnapResult.init;
            clearLastSnap();
        }
    }
}

// ---------------------------------------------------------------------------
// HandledCreateTool — adds the 6-box size-handle rig (outward world axes
// +-X/+-Y/+-Z) on top of PrimitiveCreateTool's mover. Used by the cylinder
// family (via SizedRadialCreateTool!P) and TorusTool. TubeTool does NOT
// extend this — it has no size handles at all.
// ---------------------------------------------------------------------------
abstract class HandledCreateTool : PrimitiveCreateTool {
protected:
    // Six handles on the primitive's bbox surface — outward axes:
    //   0:+X  1:-X  2:+Y  3:-Y  4:+Z  5:-Z
    BoxHandler[6] sizeH;
    int           sizeDragIdx = -1;
    int           sizeLastMX, sizeLastMY;

    static immutable Vec3[6] SIZE_AXES = [
        Vec3( 1, 0, 0), Vec3(-1, 0, 0),
        Vec3( 0, 1, 0), Vec3( 0,-1, 0),
        Vec3( 0, 0, 1), Vec3( 0, 0,-1),
    ];

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        super(meshSrc, gpu, litShader);
        foreach (i; 0 .. 6) {
            Vec3 col = (i < 2) ? Vec3(0.9f, 0.2f, 0.2f)
                     : (i < 4) ? Vec3(0.2f, 0.9f, 0.2f)
                               : Vec3(0.2f, 0.2f, 0.9f);
            sizeH[i] = new BoxHandler(Vec3(0, 0, 0), col);
        }
    }

    override void destroy() {
        super.destroy();
        foreach (h; sizeH) h.destroy();
    }

    protected override void resetSession() {
        super.resetSession();
        sizeDragIdx = -1;
    }

    /// Update sizeH[i].pos/size for the current frame. Abstract: cylinder-
    /// family default lives in SizedRadialCreateTool!P (drives it off the
    /// virtual worldSize() hook so sphere's ellipsoid permutation Just
    /// Works); TorusTool implements its own (+-(R+r)/r placement).
    protected void updateSizeHandlers(const ref Viewport vp);

    /// Apply a size-handle drag. Abstract for the same reason.
    protected void applySizeDelta(int idx, Vec3 delta);

    protected override void drawToolHandles(const ref Shader shader, const ref Viewport vp) {
        updateSizeHandlers(vp);
        mover.setPosition(toWorldP(center()));
        mover.setOrientation(frame.axis1, frame.normal, frame.axis2);
        // Single-source hover/capture: size handles (priority) then the
        // mover (centerBox, arrows) — same order tryGrabHandles/click use,
        // so the highlighted handle is the one a click grabs. The dragged
        // handle (sizeDragIdx / moverDragAxis) stays highlighted.
        toolHandles.begin();
        foreach (i; 0 .. 6) toolHandles.add(sizeH[i], cast(int)i);
        toolHandles.add(mover.centerBox, 13);
        toolHandles.add(mover.arrowX,    10);
        toolHandles.add(mover.arrowY,    11);
        toolHandles.add(mover.arrowZ,    12);
        if      (sizeDragIdx >= 0)   toolHandles.setHaul(sizeDragIdx);
        else if (moverDragAxis >= 0) toolHandles.setHaul(10 + moverDragAxis);
        else                         toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);
        foreach (i; 0 .. 6) sizeH[i].draw(shader, vp);
        mover.draw(shader, vp);
    }

protected:
    bool tryGrabHandles(int mx, int my) {
        foreach (i; 0 .. 6) {
            if (sizeH[i].hitTest(mx, my, cachedVp)) {
                sizeDragIdx = cast(int)i;
                sizeLastMX  = mx;
                sizeLastMY  = my;
                return true;
            }
        }
        return tryGrabMover(mx, my);
    }

    bool tryReleaseHandles() {
        if (sizeDragIdx >= 0) { sizeDragIdx = -1; toolHandles.clearHaul(); return true; }
        return tryReleaseMover();
    }

    bool handleSizeDrag(int mx, int my) {
        if (sizeDragIdx < 0) return false;
        // SIZE_AXES are LOCAL outward directions; screenAxisDelta consumes
        // WORLD origin + axis, so route through toWorldD.
        Vec3 outwardWorld = toWorldD(SIZE_AXES[sizeDragIdx]);
        bool skip;
        Vec3 delta = screenAxisDelta(mx, my, sizeLastMX, sizeLastMY,
                                     sizeH[sizeDragIdx].pos, outwardWorld,
                                     cachedVp, skip);
        if (!skip) applySizeDelta(sizeDragIdx, delta);
        sizeLastMX = mx; sizeLastMY = my;
        return true;
    }
}

// ---------------------------------------------------------------------------
// RadialState — the shared 5-stage machine for the cylinder/cone/capsule/
// sphere family:
//   Idle -- LMB drag on viewport --> DrawingBase (flat ellipse; axis
//                                     aligned to the construction plane)
//   DrawingBase -- LMB up --> BaseSet
//   BaseSet -- LMB drag on viewport --> DrawingHeight (extrudes ellipse)
//   DrawingHeight -- LMB up --> HeightSet
// ---------------------------------------------------------------------------
private enum RadialState { Idle, DrawingBase, BaseSet, DrawingHeight, HeightSet }

// ---------------------------------------------------------------------------
// SizedRadialCreateTool(P) — the cylinder/cone/capsule/sphere mid-layer:
// owns `P params_` directly (P must carry cenX/Y/Z, sizeX/Y/Z, axis — true
// for CylinderParams/ConeParams/CapsuleParams/SphereParams) and implements
// the full 2-drag onMouseButtonDown/Up/Motion machine ONCE, textually as
// close as possible to cylinder.d's pre-refactor body (task 0414 plan sec
// 2, option A — minimises transcription risk for the byte-stability
// requirement). Size/world-axis accessors are virtual so sphere's ellipsoid
// axis permutation (worldAxisToOrig) plugs in without touching the machine.
//
// buildInto/commitLabel/params()/name() stay abstract here — each leaf
// (CylinderTool/ConeTool/CapsuleTool/SphereTool) supplies its own builder
// function, wire-schema, and undo label.
// ---------------------------------------------------------------------------
abstract class SizedRadialCreateTool(P) : HandledCreateTool {
protected:
    P params_;

private:
    RadialState state;
    // Sticky modifier captured at LMB-down: Ctrl held forces a uniform
    // drag (all three sizes equal during DrawingBase, all three sizes
    // equal during DrawingHeight).
    bool dragUniform;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        super(meshSrc, gpu, litShader);
    }

    // ----- PrimitiveCreateTool hook implementations (shared across the ----
    // -----  whole family — P is guaranteed cenX/Y/Z/sizeX/Y/Z/axis) --------
    protected override Vec3 center() const { return Vec3(params_.cenX, params_.cenY, params_.cenZ); }
    protected override void setCenter(Vec3 c) {
        params_.cenX = c.x; params_.cenY = c.y; params_.cenZ = c.z;
    }

    protected override bool isIdle() const { return state == RadialState.Idle; }
    protected override bool showHandles() const { return state >= RadialState.BaseSet; }
    // Commit guard mirror of every pre-refactor group's deactivate()/
    // hasUncommittedEdit(): compound, NOT `state != Idle` — a sub-epsilon
    // height drag commits nothing.
    protected override bool willCommit() const {
        return (state == RadialState.BaseSet)
            || (state >= RadialState.DrawingHeight && currentHeight() > 1e-5f);
    }
    protected override void goIdle() { state = RadialState.Idle; }

    // Exposed for a leaf's drawProperties() (cosmetic UI hint text) so it
    // never needs to reach into RadialState directly.
    protected bool isBaseSet() const { return state == RadialState.BaseSet; }

    // ----- HandledCreateTool hook implementations (cylinder-family default;
    // -----  SphereTool overrides both via the worldSize/setWorldSize hooks
    // -----  below — see applySizeDelta's own override there) ---------------
    protected override void updateSizeHandlers(const ref Viewport vp) {
        Vec3 cen = center();   // local
        float sx = worldSize(0);
        float sy = worldSize(1);
        float sz = worldSize(2);
        // Compute in LOCAL frame, then transform each to world for hit-
        // test / gizmoSize against the live viewport.
        Vec3[6] localPts = [
            cen + Vec3( sx, 0, 0), cen + Vec3(-sx, 0, 0),
            cen + Vec3(0,  sy, 0), cen + Vec3(0, -sy, 0),
            cen + Vec3(0, 0,  sz), cen + Vec3(0, 0, -sz),
        ];
        foreach (i; 0 .. 6) {
            Vec3 worldPos = toWorldP(localPts[i]);
            sizeH[i].pos  = worldPos;
            sizeH[i].size = gizmoSize(worldPos, vp, 0.04f);
        }
    }

    // Box-style anchored-opposite handle drag: the dragged face follows the
    // cursor while the opposite face stays fixed in world space. d is the
    // signed projection of the cursor delta on the outward face normal.
    // Size is a half-extent, so the change in half-extent equals d/2 and
    // the center shifts by d/2 along the outward direction — full extent
    // changes by exactly d, not 2*d.
    //
    // Flip-through: if the drag pushed the size negative, the primitive
    // has crossed the opposite face. Swap to the OPPOSITE handle so
    // subsequent motion continues to follow the cursor on the new "front"
    // side. SIZE_AXES is laid out in pairs (+/-) per world axis — XOR 1
    // toggles 0<->1, 2<->3, 4<->5.
    protected override void applySizeDelta(int idx, Vec3 delta) {
        // delta arrives in WORLD; SIZE_AXES are LOCAL outward dirs.
        Vec3  outward  = SIZE_AXES[idx];
        Vec3  deltaL   = toLocalD(delta);
        float d        = dot(deltaL, outward);
        int   worldIdx = idx / 2;
        float oldSize  = worldSize(worldIdx);
        float signedSz = oldSize + d * 0.5f;
        float newSize  = abs(signedSz);

        setWorldSize(worldIdx, newSize);
        Vec3 cenShift = outward * (d * 0.5f);
        params_.cenX += cenShift.x;
        params_.cenY += cenShift.y;
        params_.cenZ += cenShift.z;

        if (signedSz < 0.0f)
            sizeDragIdx ^= 1;

        rebuildPreview();
    }

    // ----- The shared 2-drag machine (task 0414 plan sec 1: "Base tiers ---
    // -----  do NOT own onMouse* — only the helpers it calls" is true for --
    // -----  torus/tube; the mid-layer DOES own it, since it's byte- -------
    // -----  identical text for cylinder/cone/capsule and (modulo the ------
    // -----  narrow virtual hooks below) sphere) ----------------------------
    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button == SDL_BUTTON_RIGHT && state != RadialState.Idle) {
            state = RadialState.Idle;
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        bool ctrlAtClick = (mods & KMOD_CTRL) != 0;

        // Size handles take priority once a base/primitive exists.
        if (state >= RadialState.BaseSet) {
            if (tryGrabHandles(e.x, e.y)) return true;
        }

        if (state == RadialState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                   Vec3(0, 0, 0), planeNormal, hit))
                return false;
            // Snap the click anchor to the closest pipeline-enabled target.
            lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                    *mesh, EditMode.Vertices);
            publishLastSnap(lastSnap);
            startPoint   = hit;
            currentPoint = hit;
            alignAxisOnFirstClick(planeNormal);
            params_.sizeX = 0; params_.sizeY = 0; params_.sizeZ = 0;
            dragUniform = ctrlAtClick;
            state = RadialState.DrawingBase;
            uploadPreview();
            return true;
        }

        if (state == RadialState.BaseSet) {
            if (ctrlAtClick) {
                baseAnchor = center();
                Vec3 hit;
                if (!rayPlaneIntersect(localEye(),
                                       localRay(e.x, e.y),
                                       baseAnchor, planeNormal, hit))
                    return false;
                Vec3  d = hit - baseAnchor;
                float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
                setWorldSize(0, r);
                setWorldSize(1, r);
                setWorldSize(2, r);
                dragUniform = true;
                state = RadialState.DrawingHeight;
                uploadPreview();
                return true;
            }
            setupHeightPlane();
            baseAnchor = center();
            Vec3 hit;
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  hpOrigin, hpn, hit))
                heightDragStart = hit;
            else
                heightDragStart = hpOrigin;
            dragUniform = false;
            state = RadialState.DrawingHeight;
            uploadPreview();
            return true;
        }
        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;

        if (tryReleaseHandles()) return true;

        if (state == RadialState.DrawingBase) {
            if (dragUniform) {
                if (!(sizeOnAxis(planeAxis1) > 1e-5f)) {
                    state = RadialState.Idle;
                    return true;
                }
                state = RadialState.HeightSet;
                uploadPreview();
                return true;
            }
            float r1 = sizeOnAxis(planeAxis1);
            float r2 = sizeOnAxis(planeAxis2);
            if (!(r1 > 1e-5f) || !(r2 > 1e-5f)) {
                state = RadialState.Idle;
                return true;
            }
            state = RadialState.BaseSet;
            uploadPreview();
            return true;
        }
        if (state == RadialState.DrawingHeight) {
            state = RadialState.HeightSet;
            return true;
        }
        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        // Idle-state live snap preview.
        if (state == RadialState.Idle) updateIdleSnap(e.x, e.y);

        if (handleSizeDrag(e.x, e.y))  return true;
        if (handleMoverDrag(e.x, e.y)) return true;

        if (state == RadialState.DrawingBase) {
            Vec3 hit;
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  Vec3(0, 0, 0), planeNormal, hit))
            {
                lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                         *mesh, EditMode.Vertices);
                publishLastSnap(lastSnap);
                currentPoint = hit;
                if (dragUniform) syncParamsFromUniformDrag();
                else             syncParamsFromBaseDrag();
                uploadPreview();
            }
            return true;
        }
        if (state == RadialState.DrawingHeight) {
            if (dragUniform) {
                Vec3 hit;
                if (rayPlaneIntersect(localEye(),
                                      localRay(e.x, e.y),
                                      baseAnchor, planeNormal, hit))
                {
                    lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                             *mesh, EditMode.Vertices);
                    publishLastSnap(lastSnap);
                    Vec3  d = hit - baseAnchor;
                    float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
                    params_.cenX = baseAnchor.x;
                    params_.cenY = baseAnchor.y;
                    params_.cenZ = baseAnchor.z;
                    setWorldSize(0, r);
                    setWorldSize(1, r);
                    setWorldSize(2, r);
                    uploadPreview();
                }
                return true;
            }
            Vec3 hit;
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  hpOrigin, hpn, hit))
            {
                lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                         *mesh, EditMode.Vertices);
                publishLastSnap(lastSnap);
                applyNonUniformHeightDrag(hit);
                uploadPreview();
            }
            return true;
        }
        return false;
    }

private:
    // Total extent along the plane normal = 2x half-extent stored in the
    // size param along that axis. Used by willCommit() to decide commit.
    float currentHeight() const { return sizeOnAxis(planeNormal) * 2.0f; }

protected:
    // ---- World-axis <-> orig-param size mapping [virtual] -----------------
    // Cylinder-family default: direct 1:1. SphereTool overrides both
    // (worldAxisToOrig ellipsoid permutation, sphere.d:1066-1116) so every
    // caller below (updateSizeHandlers, applySizeDelta, syncParamsFrom*,
    // onMouseButtonDown/Motion's setWorldSize(0..2,r) calls) picks up the
    // ellipsoid remapping automatically without their own text changing.
    float worldSize(int worldIdx) const {
        final switch (worldIdx) {
            case 0: return params_.sizeX;
            case 1: return params_.sizeY;
            case 2: return params_.sizeZ;
        }
    }
    void setWorldSize(int worldIdx, float v) {
        float a = abs(v);
        final switch (worldIdx) {
            case 0: params_.sizeX = a; break;
            case 1: params_.sizeY = a; break;
            case 2: params_.sizeZ = a; break;
        }
    }
    float sizeOnAxis(Vec3 axisVec) const { return worldSize(worldAxisIdxOf(axisVec)); }
    void writeSizeOnAxis(Vec3 axisVec, float v) { setWorldSize(worldAxisIdxOf(axisVec), v); }

    // First click's axis alignment [virtual]. Cylinder-family default sets
    // params_.axis to the construction plane's world axis. SphereTool
    // overrides this to a no-op (sphere.d:788-792: auto-rotating axis here
    // would re-permute sizeX/Y/Z meanings, pointing the world-axis handles
    // at the wrong sizes post-commit).
    void alignAxisOnFirstClick(Vec3 n) { params_.axis = worldAxisIdxOf(n); }

    // The DrawingHeight non-uniform (second) drag's per-frame update
    // [virtual]. Cylinder-family default: box-style anchored-opposite (the
    // disk drawn in DrawingBase is one face; this extrudes the OTHER face
    // along signedH, center sits halfway between). sizeOnAxis is a half-
    // extent, so full height changes by |signedH|, center shifts by
    // signedH/2.
    //
    // NOT shared by sphere (task 0414 Phase-0 finding, see
    // tests/test_primitive_sphere_interactive.d): sphere's equivalent
    // branch keeps the center FIXED at baseAnchor and writes the FULL
    // |signedH| as the radius (no half, no center shift) — a Phase-5
    // migration must override this hook rather than assume it's shared.
    void applyNonUniformHeightDrag(Vec3 hit) {
        float signedH = dot(hit - heightDragStart, planeNormal);
        float fullH   = abs(signedH);
        Vec3  newCen  = baseAnchor + planeNormal * (signedH * 0.5f);
        params_.cenX = newCen.x;
        params_.cenY = newCen.y;
        params_.cenZ = newCen.z;
        writeSizeOnAxis(planeNormal, fullH * 0.5f);
    }

    // First click anchors the center; the cursor traces a point on the
    // ellipse perimeter, so each in-plane radius equals the absolute
    // projection of the drag onto that plane axis (no /2). Plane-normal
    // size stays 0 (flat ellipse).
    void syncParamsFromBaseDrag() {
        Vec3  d  = currentPoint - startPoint;
        float d1 = dot(d, planeAxis1);
        float d2 = dot(d, planeAxis2);
        params_.cenX = startPoint.x;
        params_.cenY = startPoint.y;
        params_.cenZ = startPoint.z;
        params_.sizeX = 0; params_.sizeY = 0; params_.sizeZ = 0;
        writeSizeOnAxis(planeAxis1, abs(d1));
        writeSizeOnAxis(planeAxis2, abs(d2));
    }

    void syncParamsFromUniformDrag() {
        Vec3  d = currentPoint - startPoint;
        float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
        params_.cenX = startPoint.x;
        params_.cenY = startPoint.y;
        params_.cenZ = startPoint.z;
        setWorldSize(0, r);
        setWorldSize(1, r);
        setWorldSize(2, r);
    }
}
