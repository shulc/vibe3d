module tools.xfrm_transform;

// XfrmTransformTool — `xfrm.transform`: ONE tool that can translate,
// rotate, and scale based on three boolean flags
// (`T`/`R`/`S`). The legacy MoveTool / RotateTool / ScaleTool will
// be retired in favour of this once preset migration lands (see
// doc/unified_transform_plan.md).
//
// Architecture: COMPOSITION. The unified tool owns one
// MoveTool / RotateTool / ScaleTool sub-instance for each enabled
// flag and dispatches events to whichever was clicked. This avoids
// porting ~2 k LOC of intricate drag / falloff / symmetry / snap
// machinery into a new class — the legacy tools already have all of
// it.
//
// Limitations of the composition approach (documented for the
// Step 5 cutover, doc/unified_transform_plan.md):
//
// - When ALL THREE flags are set (the bare Transform preset), each
//   sub-tool maintains its own edit session and commits its own
//   history entry. Most presets toggle only one flag so this
//   doesn't bite in practice.
// - Each sub-tool has its own FalloffGizmo instance. Endpoint
//   handle dragging stays scoped to the sub-tool that owns it; no
//   shared state, no cross-talk.
// - Sub-tool mouse-button-down side effects (screen-falloff disc
//   re-center) fire idempotently when none of the sub-tools
//   short-circuit, which is fine — they all see the same cursor.
//
// Headless `applyHeadless` runs the T → R → S chain through
// xform_kernels directly, NOT through the sub-tools — keeps the
// chain monotonic with respect to a single captured pivot /
// falloff snapshot, in the documented xfrm.transform order
// (T → R → S).

import bindbc.sdl;
import operator : VectorStack;

import math : Vec3, Viewport, screenRay, rayPlaneIntersect,
               closestPointOnSegmentToRay;
import editmode : EditMode;
import mesh;
import shader : Shader;
import params : Param;
import tools.transform : TransformTool;
import tools.move      : MoveTool;
import tools.rotate    : RotateTool;
import tools.scale     : ScaleTool;
import tools.xform_kernels :
    applyTranslateIncremental,
    applyRotateIncremental,
    applyScaleFromActivation;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage    : TaskCode;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.packets  : FalloffType, ElementMode, ElementConnect;
import hover_state       : g_hoveredVertex, g_hoveredEdge, g_hoveredFace;

alias VertexEditFactory = MeshVertexEdit delegate();

class XfrmTransformTool : TransformTool {
public:
    // T/R/S flags — `T integer 0/1` etc. in the preset config.
    // Default to all enabled (the bare `Transform` preset that shows
    // all three handler banks). Preset loader flips these per-preset
    // before the first activate().
    bool flagT = true;
    bool flagR = true;
    bool flagS = true;

    // Headless TRS attrs — always exposed regardless of flag state
    // so scripted callers can set TX with R=1 S=1 without first
    // flipping flags. Defaults: 0 for translate / rotate, 1 for scale.
    Vec3 headlessTranslate = Vec3(0, 0, 0);
    Vec3 headlessRotate    = Vec3(0, 0, 0);
    Vec3 headlessScale     = Vec3(1, 1, 1);

    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        super(mesh, gpu, editMode);
        moveSub   = new MoveTool  (mesh, gpu, editMode);
        rotateSub = new RotateTool(mesh, gpu, editMode);
        scaleSub  = new ScaleTool (mesh, gpu, editMode);
    }

    override string name() const { return "Transform"; }

    // Forward the undo bindings into each sub-tool so their drags
    // record on the same global history.
    override public void setUndoBindings(CommandHistory h,
                                  VertexEditFactory factory) {
        super.setUndoBindings(h, factory);
        moveSub.setUndoBindings(h, factory);
        rotateSub.setUndoBindings(h, factory);
        scaleSub.setUndoBindings(h, factory);
    }

    override void activate() {
        super.activate();
        headlessTranslate = Vec3(0, 0, 0);
        headlessRotate    = Vec3(0, 0, 0);
        headlessScale     = Vec3(1, 1, 1);
        if (flagT) moveSub.activate();
        if (flagR) rotateSub.activate();
        if (flagS) scaleSub.activate();
        activeDrag = null;
    }

    override void deactivate() {
        if (flagT) moveSub.deactivate();
        if (flagR) rotateSub.deactivate();
        if (flagS) scaleSub.deactivate();
        super.deactivate();
        activeDrag = null;
    }

    override void update(ref VectorStack vts) {
        if (!active) return;
        // Each sub-tool's update() pulls handler.center from ACEN
        // and refreshes its gizmo orientation from AXIS. They all
        // see the same pipeline state so the three gizmos co-locate.
        if (flagT) moveSub.update(vts);
        if (flagR) rotateSub.update(vts);
        if (flagS) scaleSub.update(vts);
        syncGpuMatrix();
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts) {
        if (!active) return;
        cachedVp = vp;
        if (flagT) moveSub.draw(shader, vp, vts);
        if (flagR) rotateSub.draw(shader, vp, vts);
        if (flagS) scaleSub.draw(shader, vp, vts);
        syncGpuMatrix();
    }

    override Param[] params() {
        return [
            Param.bool_ ("T",  "Translate", &flagT, true),
            Param.bool_ ("R",  "Rotate",    &flagR, true),
            Param.bool_ ("S",  "Scale",     &flagS, true),
            Param.float_("TX", "Translate X", &headlessTranslate.x, 0.0f),
            Param.float_("TY", "Translate Y", &headlessTranslate.y, 0.0f),
            Param.float_("TZ", "Translate Z", &headlessTranslate.z, 0.0f),
            Param.float_("RX", "Rotate X",    &headlessRotate.x,    0.0f),
            Param.float_("RY", "Rotate Y",    &headlessRotate.y,    0.0f),
            Param.float_("RZ", "Rotate Z",    &headlessRotate.z,    0.0f),
            Param.float_("SX", "Scale X",     &headlessScale.x,     1.0f),
            Param.float_("SY", "Scale Y",     &headlessScale.y,     1.0f),
            Param.float_("SZ", "Scale Z",     &headlessScale.z,     1.0f),
        ];
    }

    override void drawProperties() {
        if (flagT) moveSub.drawProperties();
        if (flagR) rotateSub.drawProperties();
        if (flagS) scaleSub.drawProperties();
    }

    override bool consumesFalloff() const { return true; }

    // Element-falloff hover gating.
    // When falloff.element is the active WGHT stage, the user wants to
    // click any vert / edge / face to set the falloff anchor — so the
    // tool opts into hover-highlight for every type matching the
    // FalloffStage's elementMode pick selector. Falls through to the
    // base (no hover) when no Element falloff is active — keeps the
    // gizmo-only highlight for plain Move / Rotate / Scale presets.
    override bool wantsHoverForType(EditMode type) const {
        auto fs = activeFalloffStage();
        if (fs is null || fs.type != FalloffType.Element) return false;
        final switch (fs.elementMode) {
            case ElementMode.Auto:
            case ElementMode.AutoCent: return true;
            case ElementMode.Vertex:   return type == EditMode.Vertices;
            case ElementMode.Edge:
            case ElementMode.EdgeCent: return type == EditMode.Edges;
            case ElementMode.Polygon:
            case ElementMode.PolyCent: return type == EditMode.Polygons;
        }
    }

    // No queryActionCenter override here on purpose: ACEN is the
    // single source of truth for the gizmo pivot. When falloff.element
    // is active, ACEN.mode == element (set by the preset) and
    // ACEN.Element honours userPlaced first — tryPickElement below
    // pushes the picked element's centroid through setUserPlaced, so
    // ACEN.center == picked centroid for both the gizmo AND
    // FalloffStage.evaluate's `pickedCenter` snapshot (which now
    // reads state.actionCenter.center directly).

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        // Element-falloff click-pick PRE-step: when falloff.element
        // is active and the user clicks any element (vert/edge/face)
        // with no modifier keys, we push the picked element's
        // centroid through ACEN.setUserPlaced. ACEN.center then
        // becomes that point for every consumer (gizmo via
        // queryActionCenter, falloff sphere via state.actionCenter.center).
        // This DOES NOT add the picked element to the moving set —
        // ElementMove uses pick only as the pivot/anchor. The drag
        // moves the prior selection through the falloff sphere.
        bool picked = false;
        bool ctrlMod = false;
        if (e.button == SDL_BUTTON_LEFT) {
            SDL_Keymod mods = SDL_GetModState();
            ctrlMod = (mods & KMOD_CTRL) != 0;
            bool plain = (mods & (KMOD_ALT | KMOD_CTRL | KMOD_SHIFT)) == 0;
            if (plain) picked = tryPickElement(e.x, e.y);
        }

        // Dispatch to the first enabled sub-tool that consumes the
        // event. The sub-tool's own hit-test determines whether
        // this click lands on its handler bank or falls through to
        // ACEN click-relocate.
        if (flagT && moveSub.onMouseButtonDown(e, vts)) {
            activeDrag = moveSub;  return true;
        }
        if (flagR && rotateSub.onMouseButtonDown(e, vts)) {
            activeDrag = rotateSub; return true;
        }
        if (flagS && scaleSub.onMouseButtonDown(e, vts)) {
            activeDrag = scaleSub;  return true;
        }

        // Click landed OFF every gizmo handler bank. If we just
        // picked an element under falloff.element, snap moveSub's
        // handler.center to the new ACEN-pivot and start a
        // screen-plane drag immediately — the same click+drag UX
        // ElementMove uses. The drag moves the prior selection
        // (empty ⇒ whole mesh per the universal rule); the falloff
        // sphere now centred on the picked element attenuates the
        // per-vertex displacement. ACEN's normal click-relocate
        // gate (acenAllowsClickRelocate refuses Element mode) does
        // NOT apply here — Element mode IS the gate.
        //
        // Requires the T flag: with T off (TransformRotate /
        // TransformScale) there's no moveSub.handler to anchor on.
        if (picked && flagT) {
            Vec3 pivot = queryActionCenter(vts);
            // notifyAcen=false because tryPickElement already wrote
            // userPlaced (notifyAcenUserPlaced) — don't overwrite it
            // with the ray-hit point.
            moveSub.beginScreenPlaneDragAt(e.x, e.y, pivot,
                                           ctrlMod, /*notifyAcen=*/false, vts);
            activeDrag = moveSub;
            syncGpuMatrix();
            return true;
        }
        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        bool r;
        if (activeDrag !is null)
            r = activeDrag.onMouseMotion(e, vts);
        else {
            // Idle: let each enabled sub-tool refresh its own hover /
            // snap preview. None will consume the event (dragAxis ==
            // -1 path on every sub-tool returns false after updating
            // the preview).
            if (flagT) moveSub.onMouseMotion(e, vts);
            if (flagR) rotateSub.onMouseMotion(e, vts);
            if (flagS) scaleSub.onMouseMotion(e, vts);
        }
        // GPU bypass: forward the active sub-tool's gpuMatrix.
        // app.d reads `activeTool.gpuMatrix` to drive the shader's
        // u_model uniform during whole-mesh drags; without this
        // forwarding the wrapper's gpuMatrix stays at identity and
        // the visible mesh lags behind the sub-tool's CPU vertices.
        syncGpuMatrix();
        return r;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        bool r;
        if (activeDrag !is null) {
            r = activeDrag.onMouseButtonUp(e, vts);
            activeDrag = null;
        } else {
            // No active drag: still forward LMB-up to each sub-tool
            // so they get a chance to close screen-falloff disc
            // overlays etc. None should claim the event.
            if (flagT) moveSub.onMouseButtonUp(e, vts);
            if (flagR) rotateSub.onMouseButtonUp(e, vts);
            if (flagS) scaleSub.onMouseButtonUp(e, vts);
        }
        syncGpuMatrix();
        return r;
    }

    // Headless T → R → S chain. Follows the documented `xfrm.transform`
    // order and the implementation in doc/unified_transform_plan.md.
    // The pivot is captured BEFORE
    // the translate step so rotate / scale stay anchored to the
    // pre-mutation action center (ACEN.Element re-averages on every
    // query — re-evaluating mid-chain would drift it). Falloff +
    // symmetry packets are captured ONCE so each kernel sees a
    // consistent snapshot through the whole chain.
    //
    // Runs DIRECTLY through the kernels (not via the sub-tools) so
    // the chain stays monotonic with respect to a single snapshot.
    override bool applyHeadless() {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);

        Vec3 pivot = queryActionCenter(vts);

        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        vertexCacheDirty = true;
        buildVertexCacheIfNeeded();
        if (vertexProcessCount == 0) return false;

        // Per `xfrm.transform` semantics, per-vert falloff
        // weights are snapshotted at the pre-chain BASELINE — every
        // T/R/S stage in the chain uses the same weight even though
        // the geometry mutates between stages. Capturing once here
        // (before T) gives the scale stage a stable weight source
        // independent of the post-T/R activation positions it scales
        // through. Translate is the first stage so its
        // `evaluateFalloff(dragFalloff, mesh.vertices[vi], ...)` is
        // already at baseline — no extra plumbing needed there.
        Vec3[] baselineVerts = mesh.vertices.dup;

        Vec3 bX, bY, bZ;
        currentBasis(bX, bY, bZ, vts);

        if (flagT) {
            bool hasT = (headlessTranslate.x != 0
                      || headlessTranslate.y != 0
                      || headlessTranslate.z != 0);
            if (hasT)
                applyTranslateIncremental(mesh, vertexIndicesToProcess,
                                          headlessTranslate,
                                          dragFalloff, cachedVp,
                                          dragSymmetry, toProcess);
        }

        if (flagR) {
            import std.math : PI;
            auto cp = queryClusterPivots(vts);
            auto ap = queryClusterAxes(vts);
            if (headlessRotate.x != 0)
                applyRotateIncremental(mesh, vertexIndicesToProcess,
                                       pivot, bX, -1,
                                       headlessRotate.x * cast(float)(PI / 180.0),
                                       dragFalloff, cachedVp,
                                       cp, ap, dragSymmetry, toProcess);
            if (headlessRotate.y != 0)
                applyRotateIncremental(mesh, vertexIndicesToProcess,
                                       pivot, bY, -1,
                                       headlessRotate.y * cast(float)(PI / 180.0),
                                       dragFalloff, cachedVp,
                                       cp, ap, dragSymmetry, toProcess);
            if (headlessRotate.z != 0)
                applyRotateIncremental(mesh, vertexIndicesToProcess,
                                       pivot, bZ, -1,
                                       headlessRotate.z * cast(float)(PI / 180.0),
                                       dragFalloff, cachedVp,
                                       cp, ap, dragSymmetry, toProcess);
        }

        if (flagS) {
            bool hasS = (headlessScale.x != 1
                      || headlessScale.y != 1
                      || headlessScale.z != 1);
            if (hasS) {
                auto cp = queryClusterPivots(vts);
                auto ap = queryClusterAxes(vts);
                Vec3[] activation = mesh.vertices.dup;
                applyScaleFromActivation(mesh, vertexIndicesToProcess,
                                         activation, pivot,
                                         bX, bY, bZ,
                                         headlessScale,
                                         dragFalloff, cachedVp,
                                         cp, ap, dragSymmetry, toProcess,
                                         baselineVerts);
            }
        }

        return true;
    }

private:
    // Element-falloff click-pick. Reads the GPU-resolved hover state
    // (g_hoveredVertex/Edge/Face — published by app.d after each
    // render frame) and pushes the picked element's anchor point
    // through ACEN.setUserPlaced (via notifyAcenUserPlaced). The
    // anchor depends on the FalloffStage's `elementMode`:
    //
    //   - `*Cent` variants (AutoCent / EdgeCent / PolyCent): element
    //     centroid (edge midpoint / Newell-method polygon centroid).
    //   - Non-Cent variants (Auto / Edge / Polygon): exact click-point
    //     on the element — closest point on the edge segment to the
    //     picking ray (edges) or ray ∩ face plane (polygons). This
    //     follows the per-mode distinction (e.g. `polygon` →
    //     intersection of click + polygon; `polyCent` → centroid).
    //
    // FalloffStage's connectMask is also updated (mask seed is the
    // picked element's vert ring). Pick-type restricted by the
    // stage's elementMode. Returns true iff the click landed on a
    // hovered element.
    bool tryPickElement(int mx, int my) {
        FalloffStage stage = activeFalloffStage();
        if (stage is null || stage.type != FalloffType.Element) return false;

        ElementMode em = stage.elementMode;
        bool autoMode = (em == ElementMode.Auto) || (em == ElementMode.AutoCent);
        bool wantV = autoMode || (em == ElementMode.Vertex);
        bool wantE = autoMode || (em == ElementMode.Edge)
                              || (em == ElementMode.EdgeCent);
        bool wantF = autoMode || (em == ElementMode.Polygon)
                              || (em == ElementMode.PolyCent);
        // Non-Cent variants (Auto / Edge / Polygon) use the exact
        // click-point on the element instead of its centroid.
        // EdgeCent / PolyCent / AutoCent and the *Cent-only modes
        // fall back to centroid. Vertex has no distinction (vertex
        // IS the click target).
        bool clickPointE = (em == ElementMode.Auto) || (em == ElementMode.Edge);
        bool clickPointF = (em == ElementMode.Auto) || (em == ElementMode.Polygon);

        if (wantV && g_hoveredVertex >= 0
            && g_hoveredVertex < cast(int)mesh.vertices.length)
            return takeVert(stage, g_hoveredVertex);
        if (wantE && g_hoveredEdge >= 0
            && g_hoveredEdge < cast(int)mesh.edges.length)
            return takeEdge(stage, g_hoveredEdge, clickPointE, mx, my);
        if (wantF && g_hoveredFace >= 0
            && g_hoveredFace < cast(int)mesh.faces.length)
            return takeFace(stage, g_hoveredFace, clickPointF, mx, my);
        return false;
    }

    // Per take*, two pieces are written:
    //   1. ACEN.userPlaced ← picked element's anchor point (gizmo
    //      pivot + falloff sphere anchor). Either the centroid
    //      (*Cent modes) or the exact click-point on the element.
    //   2. FalloffStage.anchorRing ← picked element's vert indices
    //      (every one gets weight=1 in elementWeight, so the picked
    //      element drags as a rigid unit regardless of sphere radius).
    // Both pieces together form the `falloff.element` internal
    // hybrid (anchor + sphere).

    bool takeVert(FalloffStage stage, int vi) {
        notifyAcenUserPlaced(mesh.vertices[vi]);
        stage.anchorRing = [cast(uint)vi];
        updateConnectMask(stage, vi);
        return true;
    }

    bool takeEdge(FalloffStage stage, int ei, bool clickPoint,
                  int mx, int my) {
        auto edge = mesh.edges[ei];
        Vec3 a = mesh.vertices[edge[0]];
        Vec3 b = mesh.vertices[edge[1]];
        Vec3 anchor = clickPoint
            ? closestPointOnSegmentToRay(a, b, cachedVp.eye,
                                         screenRay(cast(float)mx,
                                                   cast(float)my,
                                                   cachedVp))
            : (a + b) * 0.5f;
        notifyAcenUserPlaced(anchor);
        stage.anchorRing = [cast(uint)edge[0], cast(uint)edge[1]];
        updateConnectMask(stage, cast(int)edge[0]);
        return true;
    }

    bool takeFace(FalloffStage stage, int fi, bool clickPoint,
                  int mx, int my) {
        Vec3 anchor;
        bool gotClickHit = false;
        if (clickPoint) {
            // Ray ∩ face plane. The face was already hit by the
            // picker (g_hoveredFace >= 0) so the ray crosses the
            // plane; rayPlaneIntersect only returns false for ray ∥
            // plane (effectively edge-on, which the picker also
            // rejects). Fall back to the centroid if the projection
            // misbehaves — same anchor the *Cent path uses.
            Vec3 n = mesh.faceNormal(cast(uint)fi);
            Vec3 c = mesh.faceCentroid(cast(uint)fi);
            Vec3 dir = screenRay(cast(float)mx, cast(float)my, cachedVp);
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, dir, c, n, hit)) {
                anchor       = hit;
                gotClickHit  = true;
            }
        }
        if (!gotClickHit)
            anchor = mesh.faceCentroid(cast(uint)fi);
        notifyAcenUserPlaced(anchor);
        auto face = mesh.faces[fi];
        stage.anchorRing.length = face.length;
        foreach (i, vi; face)
            stage.anchorRing[i] = vi;
        if (face.length > 0)
            updateConnectMask(stage, cast(int)face[0]);
        return true;
    }


    // Connected-component BFS seeded at the picked vert, written into
    // FalloffStage.connectMask. Active only when connect != Off.
    void updateConnectMask(FalloffStage stage, int seedVi) {
        if (stage.connect == ElementConnect.Off) {
            stage.connectMask = null;
            return;
        }
        size_t n = mesh.vertices.length;
        if (seedVi < 0 || seedVi >= cast(int)n) {
            stage.connectMask = null;
            return;
        }
        size_t[][] adj = new size_t[][](n);
        foreach (e; mesh.edges) {
            adj[e[0]] ~= e[1];
            adj[e[1]] ~= e[0];
        }
        bool[] visited = new bool[](n);
        size_t[] queue;
        queue ~= cast(size_t)seedVi;
        visited[seedVi] = true;
        while (queue.length > 0) {
            size_t v = queue[$ - 1];
            queue.length -= 1;
            foreach (nb; adj[v])
                if (!visited[nb]) { visited[nb] = true; queue ~= nb; }
        }
        stage.connectMask = visited;
    }

    FalloffStage activeFalloffStage() const {
        if (g_pipeCtx is null) return null;
        return cast(FalloffStage)
               g_pipeCtx.pipeline.findByTask(TaskCode.Wght);
    }

    MoveTool   moveSub;
    RotateTool rotateSub;
    ScaleTool  scaleSub;

    // Sub-tool that owns the currently active drag, set on
    // mouse-down and cleared on mouse-up. Null when no drag is
    // active; in that state mouse motion goes to every enabled
    // sub-tool for hover-preview updates.
    TransformTool activeDrag;

    // Forward the active sub-tool's gpuMatrix onto our public
    // `gpuMatrix` field — app.d reads `activeTool.gpuMatrix` to
    // drive u_model during whole-mesh drag bypass paths. Without
    // this the wrapper stays at identity while MoveTool /
    // RotateTool / ScaleTool internally translate / rotate / scale
    // their GPU matrix.
    void syncGpuMatrix() {
        if (activeDrag !is null) {
            gpuMatrix = activeDrag.gpuMatrix;
            return;
        }
        // Idle: sub-tools have reset to identity. Pick the first
        // enabled one's matrix (all are identity at this point).
        if      (flagT) gpuMatrix = moveSub.gpuMatrix;
        else if (flagR) gpuMatrix = rotateSub.gpuMatrix;
        else if (flagS) gpuMatrix = scaleSub.gpuMatrix;
    }
}
