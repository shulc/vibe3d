module tools.mirror;

import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;
import std.math : PI;

import tool;
import mesh;
import math;
import params : Param, IntEnumEntry;
import command : Command, CmdFlags;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import editmode : EditMode;
import shader : Shader, LitShader;
import handler : MoveHandler, ToolHandles, Arrow, BoxHandler, gizmoSize, drawThickLinesExt;
import drag : planeDragDelta, screenAxisDelta;
import eventlog : queryMouse;

version (unittest) import std.conv : to;

// Reuses the BevelTool factory type — a generic (pre, post) MeshSnapshot
// pair via MeshBevelEdit, matching BoxTool/SphereTool's commit path
// (box.d's BoxEditFactory alias).
alias MirrorEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// rebuildMirrorPreview — the non-cumulative preview recompute (impl plan
// §2.2). Free function (not a method) so a module unittest can exercise it
// directly against a plain `Mesh`, without constructing a MirrorTool (whose
// constructor builds GL-backed handlers via MoveHandler/Arrow/BoxHandler —
// unsafe outside a live GL context).
//
// `baseSnap.restore(previewMesh)` fully overwrites `previewMesh` with the
// pristine base (deep-copied geometry) EVERY call — this is the guarantee
// that N successive calls never accumulate N mirrors (mirrorFaces APPENDS;
// see mesh.d:4172-4310).
// ---------------------------------------------------------------------------
void rebuildMirrorPreview(const ref MeshSnapshot baseSnap, ref Mesh previewMesh,
                         in bool[] baseMask, in MirrorParams params_)
{
    baseSnap.restore(previewMesh);
    float weld = params_.mergeVerts ? params_.distance : 0.0f;
    previewMesh.mirrorFacesPlane(baseMask, params_.center, toolNormal(params_),
                                 weld, params_.invertPolys);
    previewMesh.buildLoops();
}

// ---------------------------------------------------------------------------
// MirrorParams — single source of truth for the Mirror tool (mirrors
// BoxParams, box.d:46). Every handle drag and every panel edit writes into
// this struct; render + handle position + commit derive from it on demand.
//
// v2 (task 0230): the mirror plane is ORIENTED (arbitrary normal), not just
// axis-aligned. `axis` + `angle` together are the single source of truth for
// the plane normal — see `toolNormal(in MirrorParams)` below, a PURE function
// of this struct (NOT a tool-cached field: the free preview path
// `rebuildMirrorPreview` has no MirrorTool instance to read a cached normal
// from). The rotate box (M4) writes ONLY `angle`; `Axis` presets (X/Y/Z) set
// the base direction `angle` rotates away from. `left`/`up` are DERIVED
// readouts (an orthonormal basis of the current normal) recomputed in
// `evaluate()` — read-only in v2 (owner decision (d): editable Left/Up would
// need a 3rd rotate input path, deferred).
//
// `distance`/`mergeVerts`/`invertPolys` are unchanged from v1.
// `mode` stays greyed to Axis (Free-Rotation/Three-Points deferred).
// ---------------------------------------------------------------------------
struct MirrorParams {
    int   axis        = 0;            // 0=X 1=Y 2=Z — base direction `angle` rotates away from
    Vec3  center       = Vec3(0, 0, 0);
    bool  invertPolys  = true;         // -> mirrorFaces flipNormals
    bool  mergeVerts   = true;         // gates the weld pass
    float distance     = 0.001f;       // -> mirrorFaces weld (only when mergeVerts)
    // --- live as of v2 (task 0230): angle drives the rotate box + toolNormal ---
    // Default 180 is the captured reference default (0227 design). Harmless
    // for the mirror OPERATION regardless of value: reflection is invariant
    // under negating the plane normal (v - n*(2*dot(v-c,n)) is unchanged by
    // n -> -n, since both the dot term and the outer factor flip sign), and
    // rotating a fixed axis by exactly 180 degrees about any perpendicular
    // reference axis just negates it — so the DEFAULT axis-aligned geometry
    // is byte-for-byte the same as if angle were 0.
    float angle = 180.0f;
    int   mode  = 0;                   // 0=Axis (only value live; Free-Rotation/Three-Points deferred)
    // --- derived readouts (written by evaluate(), read-only in the panel) ---
    Vec3  left  = Vec3(0, 0, 0);
    Vec3  up    = Vec3(0, 0, 0);
}

// ---------------------------------------------------------------------------
// unitAxis / refAxis / toolNormal — the oriented-plane normal, a PURE
// function of MirrorParams (task 0230, opponent objection #2). No tool field
// caches this; every call site (preview, commit, headless, handle draw)
// recomputes it from `params_` directly.
// ---------------------------------------------------------------------------

/// The Axis preset's base unit direction (before any rotate-box tilt).
Vec3 unitAxis(int axis) pure nothrow @nogc @safe {
    final switch (axis) {
        case 0: return Vec3(1, 0, 0);
        case 1: return Vec3(0, 1, 0);
        case 2: return Vec3(0, 0, 1);
    }
}

/// The FIXED in-plane reference axis the rotate-box single-DOF drag turns
/// `angle` about — perpendicular to `unitAxis(axis)`, constant for the whole
/// gesture (does NOT retarget off the live tilting normal: recomputing it
/// from the current normal mid-drag would reintroduce the documented
/// mid-drag basis-flip/oscillation family from the transform-tool handles).
/// Convention (task 0230 spec): base X -> ref Z; base Y -> ref X; base Z ->
/// ref X. Any fixed, per-axis-perpendicular choice works — this one just
/// needs to stay consistent between draw() and the drag handler.
Vec3 refAxis(int axis) pure nothrow @nogc @safe {
    final switch (axis) {
        case 0: return Vec3(0, 0, 1);   // base X -> ref Z
        case 1: return Vec3(1, 0, 0);   // base Y -> ref X
        case 2: return Vec3(1, 0, 0);   // base Z -> ref X
    }
}

/// The live mirror-plane normal: `R(angle, refAxis(axis)) * unitAxis(axis)`.
/// Single-DOF Axis-mode rotation (task 0230 design §Risk 3) — recommended
/// over a full free-rotation basis since there is no geometry golden to pin
/// the drag->angle transfer (a UX-mapping divergence, not a mesh-geometry
/// one: the reflection itself is deterministic given center+normal).
Vec3 toolNormal(in MirrorParams p) {
    float rad = p.angle * (PI / 180.0f);
    auto  R   = pivotRotationMatrix(Vec3(0, 0, 0), refAxis(p.axis), rad);
    return normalize(transformPoint(R, unitAxis(p.axis)));
}

/// Derived Up/Left readouts (task 0230 M5, owner decision (d): read-only in
/// v2) — an orthonormal basis of the current normal, built from the same
/// fixed `refAxis` the rotate box turns about so the panel's Left/Up track
/// the live plane without a separate stored basis.
Vec3 derivedUp(in MirrorParams p) pure nothrow @nogc @safe { return refAxis(p.axis); }
Vec3 derivedLeft(in MirrorParams p) {
    return normalize(cross(derivedUp(p), toolNormal(p)));
}

// ---------------------------------------------------------------------------
// MirrorTool — interactive generator tool wrapping Mesh.mirrorFacesPlane
// (source/mesh.d, task 0230). Modelled on BoxTool (source/tools/box.d): the
// document mesh is never mutated during interaction, only in deactivate().
//
// v2 (task 0230) = ORIENTED plane (Axis + Angle + Center all live; Left/Up
// derived readouts; Mode greyed to Axis). Two box handles: `mover.centerBox`
// (enlarged — "large box": click-to-place + drag-move the plane center) and
// `rotateBox` (small — drags `angle`, tilting the plane about the fixed
// `refAxis(axis)`), plus a wire-quad + dashed-axis plane visualization.
// ---------------------------------------------------------------------------
class MirrorTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*  gpu;
    LitShader litShader;

    // params_ is the single source of truth for the mirror plane + options.
    MirrorParams params_;

    // Base state captured at activate() — the pristine mesh + face mask the
    // preview/commit mirror from. Mask rule matches the mesh.mirror command
    // (commands/mesh/mirror.d:74-84): empty face selection ⇒ whole mesh.
    MeshSnapshot baseSnap;
    bool[]       baseMask;

    // Own preview mesh (M3, §2 of the impl plan) — the document mesh is
    // NEVER mutated during interaction; only deactivate() writes it.
    Mesh    previewMesh;
    GpuMesh previewGpu;

    // Dirty guard (fold #3): property_panel.d calls evaluate() every frame
    // the panel is open, and evaluate() is also called on every handle-drag
    // motion event — without this cache a full snapshot-restore +
    // mirrorFaces + buildLoops + GPU upload would run every such call even
    // when nothing changed. Caches the last-evaluated param snapshot;
    // evaluate() early-returns when unchanged.
    bool  havePreviewCache;
    int   cachedAxis;
    Vec3  cachedCenter;
    bool  cachedInvert;
    bool  cachedMerge;
    float cachedDistance;
    float cachedAngle;   // task 0230 M2: normal is derived from axis+angle —
                         // an angle-only edit (rotate-box drag) must also
                         // invalidate the cache, or the preview silently
                         // no-ops on orientation changes.

    // Commit guard (§4.2 of the impl plan): true once the user has actually
    // interacted (handle drag / param edit / headless attr write). Prevents
    // an accidental mirror when the tool is picked and dropped untouched.
    bool engaged;

    CommandHistory    history;
    MirrorEditFactory mirrorEditFactory;

    // ----- Center handle (M2) — reuse MoveHandler exactly as BoxTool does
    // (box.d:1857/1896), with the three plane-corner circles AND the three
    // axis arrows hidden (task 0233: reference gizmo is 2 boxes + plane, no
    // arrows) so only the center box remains from MoveHandler. Center MOVE is
    // driven by dragging that (enlarged) center box (planeDragDelta), not the
    // arrows. `mover.centerBoxScale` (handler.d) enlarges it into the
    // reference's "large box"; `mover.arrowsVisible=false` drops the arrows.
    MoveHandler mover;
    // ----- Rotate box (M4) — small BoxHandler, world position derived each
    // frame from `center + toolNormal(params_) * rotateArm(...)`; dragging it
    // writes `params_.angle` only (see onMouseMotion).
    BoxHandler  rotateBox;
    ToolHandles toolHandles;
    int      moverDragAxis = -1;  // 0/1/2 = X/Y/Z arrow, 3 = centerBox, 4 = rotateBox, -1 = none
    int      moverLastMX, moverLastMY;
    Viewport cachedVp;

    // ----- Plane visualization (M4) — a wire quad ⟂ normal + a dashed line
    // along the normal through center, both rebuilt (world-space vertex data
    // re-uploaded) every draw() call — mirrors MoveTool's constraintLineVao
    // pattern (tools/move.d:492-506): lazy VAO init, GL_DYNAMIC_DRAW update.
    GLuint planeQuadVao, planeQuadVbo;
    GLuint axisLineVao,  axisLineVbo;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.litShader = litShader;
        mover = new MoveHandler(Vec3(0, 0, 0));
        mover.circleXY.setVisible(false);
        mover.circleYZ.setVisible(false);
        mover.circleXZ.setVisible(false);
        // Task 0233: drop the X/Y/Z axis arrows entirely — the reference
        // Mirror gizmo is 2 boxes + a plane, no arrows. Center MOVE stays on
        // the (enlarged) center box drag (planeDragDelta). arrowsVisible=false
        // hides them from draw AND hit-test (see MoveHandler.arrowsVisible).
        mover.arrowsVisible = false;
        mover.centerBoxScale = 2.4f;   // "large box" — reads distinctly bigger than rotateBox
        rotateBox = new BoxHandler(Vec3(0, 0, 0), Vec3(0.95f, 0.55f, 0.05f));
        toolHandles = new ToolHandles();
    }

    void destroy() {
        mover.destroy();
        rotateBox.destroy();
        if (planeQuadVao != 0) { glDeleteVertexArrays(1, &planeQuadVao); glDeleteBuffers(1, &planeQuadVbo); }
        if (axisLineVao  != 0) { glDeleteVertexArrays(1, &axisLineVao);  glDeleteBuffers(1, &axisLineVbo); }
    }

    /// CPU-only preview rebuild (fold #2) — no GL calls, so it can be driven
    /// directly by a module unittest. Non-cumulative: delegates to the free
    /// `rebuildMirrorPreview` (module scope) which restores the pristine
    /// base snapshot before every `mirrorFaces` call.
    void rebuildPreviewMesh() {
        rebuildMirrorPreview(baseSnap, previewMesh, baseMask, params_);
    }

    /// Inject undo plumbing — called by app.d after construction (mirrors
    /// BoxTool.setUndoBindings, box.d:1915).
    void setUndoBindings(CommandHistory h, MirrorEditFactory factory) {
        this.history           = h;
        this.mirrorEditFactory = factory;
    }

    override string name() const { return "Mirror"; }

    override void activate() {
        baseSnap = MeshSnapshot.capture(*mesh);
        baseMask = buildMaskFromSelection();
        engaged  = false;
        moverDragAxis = -1;
        toolHandles.clearHaul();
        previewGpu.init();
        havePreviewCache = false;
        evaluate();   // show the preview immediately (§2.2 of the impl plan)
    }

    override void deactivate() {
        bool willCommit = engaged;
        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        size_t inserted = 0;
        if (willCommit) {
            float weld = params_.mergeVerts ? params_.distance : 0.0f;
            inserted = mesh.mirrorFacesPlane(commitMask(), params_.center,
                                             toolNormal(params_), weld, params_.invertPolys);
            if (inserted > 0) {
                mesh.buildLoops();
                gpu.upload(*mesh);
            }
        }

        previewGpu.destroy();
        if (willCommit && inserted > 0) commitMirrorEdit(pre);
        engaged = false;
        havePreviewCache = false;
    }

    // ----- History-coordination hooks (mirror BoxTool's, box.d:1963-1988) --

    public override bool hasUncommittedEdit() const { return engaged; }

    public override void cancelUncommittedEdit() {
        // The document mesh was never touched during interaction (own
        // preview mesh) — nothing to revert, just drop the guard. The
        // preview keeps showing whatever params_ currently holds (there is
        // no "unstarted" state for an axis-aligned generator — defaults
        // already describe a valid plane).
        engaged = false;
    }

    public override void resyncSession() {
        // External undo/redo moved geometry beneath the tool — re-base
        // against the current mesh and force the preview to rebuild from
        // the new baseline (dirty guard would otherwise skip it since
        // params_ itself didn't change).
        baseSnap = MeshSnapshot.capture(*mesh);
        baseMask = buildMaskFromSelection();
        havePreviewCache = false;
        evaluate();
    }

    // ----- Mask (fold #4: interactive commit + applyHeadless must build the
    // SAME mask from LIVE mesh.selectedFaces — empty ⇒ all faces. Identical
    // rule to commands/mesh/mirror.d:74-84.) -------------------------------

    private bool[] buildMaskFromSelection() const {
        bool[] mask = new bool[](mesh.faces.length);
        bool any = false;
        foreach (i, b; mesh.selectedFaces) {
            if (b) { mask[i] = true; any = true; }
        }
        if (!any) foreach (i; 0 .. mesh.faces.length) mask[i] = true;
        return mask;
    }

    /// The mask used at commit time — re-derived from the LIVE selection
    /// (identical rule to buildMaskFromSelection; the doc mesh is untouched
    /// during interaction so this matches what was captured at activate()).
    private bool[] commitMask() const { return buildMaskFromSelection(); }

    private void commitMirrorEdit(MeshSnapshot pre) {
        if (history is null || mirrorEditFactory is null) return;
        auto cmd  = mirrorEditFactory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Mirror");
        history.record(cmd);
    }

    // ----- Params / panel (§1.2-1.3 of the impl plan) -----------------------

    override Param[] params() {
        return [
            Param.intEnum_("axis", "Axis", cast(int*)&params_.axis,
                [IntEnumEntry(0, "X", "X"),
                 IntEnumEntry(1, "Y", "Y"),
                 IntEnumEntry(2, "Z", "Z")],
                0),
            Param.vec3_("center", "Center", &params_.center, Vec3(0, 0, 0)),
            Param.bool_("invertPolys", "Invert Polygons", &params_.invertPolys, true),
            Param.bool_("mergeVerts", "Merge Vertices", &params_.mergeVerts, true),
            Param.float_("distance", "Distance", &params_.distance, 0.001f).min(0.0f),
            // --- live as of v2 (task 0230): angle drives the rotate box + toolNormal ---
            Param.float_("angle", "Angle", &params_.angle, 180.0f).angle(),
            // Mode stays greyed to Axis — Free-Rotation/Three-Points deferred.
            Param.intEnum_("mode", "Mode", cast(int*)&params_.mode,
                [IntEnumEntry(0, "axis", "Axis")], 0),
            // Left/Up are DERIVED readouts (written in evaluate()) — read-only
            // in v2 (owner decision (d)): editing them would need a 3rd rotate
            // input path on top of the rotate box's single `angle` DOF.
            Param.vec3_("left", "Left", &params_.left, Vec3(0, 0, 0)).readonly(),
            Param.vec3_("up", "Up", &params_.up, Vec3(0, 0, 0)).readonly(),
        ];
    }

    override bool paramEnabled(string name) const {
        // Mode stays greyed to Axis-only (Free-Rotation/Three-Points deferred).
        if (name == "mode") return false;
        // Distance only matters when merge is on.
        if (name == "distance") return params_.mergeVerts;
        return true;
    }

    override void onParamChanged(string name) {
        engaged = true;
    }

    // ----- Headless one-shot (fold #4: builds its OWN mask from the live
    // mesh — ToolHeadlessCommand never calls activate(), so baseMask/baseSnap
    // are never populated on that throwaway instance). ----------------------

    override bool applyHeadless() {
        bool[] mask = buildMaskFromSelection();
        float weld  = params_.mergeVerts ? params_.distance : 0.0f;
        size_t inserted = mesh.mirrorFacesPlane(mask, params_.center,
                                                toolNormal(params_), weld, params_.invertPolys);
        if (inserted == 0) return false;
        mesh.buildLoops();
        gpu.upload(*mesh);
        return true;
    }

    override bool drawImGui() { return false; }

    // ----- Live preview (M3, §2.2-2.3 of the impl plan) ---------------------
    //
    // Re-apply the preview after a parameter change or handle drag. Guarded
    // (fold #3) so property_panel.d's per-frame call (property_panel.d:72)
    // and every drag-motion call are cheap no-ops once the params settle.
    override void evaluate() {
        if (havePreviewCache
            && cachedAxis     == params_.axis
            && cachedCenter   == params_.center
            && cachedInvert   == params_.invertPolys
            && cachedMerge    == params_.mergeVerts
            && cachedDistance == params_.distance
            && cachedAngle    == params_.angle)
            return;

        rebuildPreviewMesh();
        previewGpu.upload(previewMesh);

        // Derived Left/Up readouts (task 0230 M5) — recomputed alongside the
        // preview since both are pure functions of axis+angle, the exact
        // fields this dirty guard already keys on.
        params_.left = derivedLeft(params_);
        params_.up   = derivedUp(params_);

        cachedAxis       = params_.axis;
        cachedCenter     = params_.center;
        cachedInvert     = params_.invertPolys;
        cachedMerge      = params_.mergeVerts;
        cachedDistance   = params_.distance;
        cachedAngle      = params_.angle;
        havePreviewCache = true;
    }

    // ----- Center handle (M2) + preview draw (M3) ---------------------------

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        // `visualOnly` is the non-interactive replica draw in an inactive
        // Quad cell (tool.d:132 contract) — skip the cachedVp write and the
        // ToolHandles register/hit cycle there, but still draw the preview +
        // handle so they appear (reprojected) in every cell — mirrors
        // BoxTool's draw() (box.d:2438).
        if (!visualOnly) cachedVp = vp;

        // --- Solid preview faces (mirrors box.d:2447-2458) ---
        immutable float[16] identity = identityMatrix;
        Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));

        glUseProgram(litShader.program);
        glUniformMatrix4fv(litShader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(litShader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(litShader.locProj,  1, GL_FALSE, vp.proj.ptr);
        glUniform3f(litShader.locLightDir, lightDir.x, lightDir.y, lightDir.z);
        glUniform3f(litShader.locEyePos,   vp.eye.x, vp.eye.y, vp.eye.z);
        glUniform1f(litShader.locAmbient,  0.20f);
        glUniform1f(litShader.locSpecStr,  0.25f);
        glUniform1f(litShader.locSpecPow,  32.0f);

        previewGpu.drawFaces(litShader);

        // --- Wireframe preview edges ---
        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);

        previewGpu.drawEdges(shader.locColor, -1, []);

        mover.setPosition(params_.center);
        mover.setOrientation(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));

        // --- Rotate box + plane viz (M4) — derived every frame from
        // toolNormal(params_); computed regardless of `visualOnly` so the
        // plane/handle reprojects correctly in every Quad cell (tool.d:132
        // contract), matching the preview draw above.
        Vec3  curNormal = toolNormal(params_);
        float gs        = gizmoSize(params_.center, vp);
        float arm       = gs * 0.55f;
        rotateBox.pos  = params_.center + curNormal * arm;
        rotateBox.size = gs * 0.03f;

        drawPlaneViz(vp, params_.center, curNormal, gs, shader.program);
        rotateBox.draw(shader, vp);

        if (!visualOnly) {
            toolHandles.begin();
            // Task 0233: only the center box + rotate box are registered — the
            // axis arrows are gone (mover.arrowsVisible=false). moverDragAxis is
            // now only ever 3 (centerBox) or 4 (rotateBox).
            toolHandles.add(mover.centerBox, 13);
            toolHandles.add(rotateBox,       14);
            if (moverDragAxis >= 0)
                toolHandles.setHaul(moverDragAxis == 3 ? 13 : 14);
            else
                toolHandles.setHaul(-1);
            int hmx, hmy;
            queryMouse(hmx, hmy);
            toolHandles.update(hmx, hmy, vp);
        }

        mover.draw(shader, vp);
    }

    /// Wire quad ⟂ `normal` at `center` + a dashed line along `normal` through
    /// `center` — the mirror-plane visualization (task 0230 M4). Lazy VAO
    /// init + `GL_DYNAMIC_DRAW` re-upload every call, mirroring MoveTool's
    /// `constraintLineVao` pattern (tools/move.d:492-506): the geometry (world
    /// positions) changes every frame the plane tilts or moves, so there is no
    /// static VAO to reuse — only the buffer OBJECT is cached.
    private void drawPlaneViz(const ref Viewport vp, Vec3 center, Vec3 normal, float gs,
                              GLuint restoreProgram) {
        immutable Vec3 planeColor = Vec3(0.85f, 0.25f, 0.85f);   // magenta, matches the reference viz

        // In-plane orthonormal basis (⟂ normal) — same construction as
        // handler.d's private `localFrame`, inlined here since that helper
        // isn't exported.
        Vec3 tmp = (normal.x < 0.9f && normal.x > -0.9f) ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
        Vec3 tA  = normalize(cross(normal, tmp));
        Vec3 tB  = cross(normal, tA);

        float qs = gs * 0.9f;
        Vec3 c0 = center + tA * qs + tB * qs;
        Vec3 c1 = center - tA * qs + tB * qs;
        Vec3 c2 = center - tA * qs - tB * qs;
        Vec3 c3 = center + tA * qs - tB * qs;
        float[12] quadData = [
            c0.x, c0.y, c0.z,  c1.x, c1.y, c1.z,
            c2.x, c2.y, c2.z,  c3.x, c3.y, c3.z,
        ];

        if (planeQuadVao == 0) {
            glGenVertexArrays(1, &planeQuadVao);
            glGenBuffers(1, &planeQuadVbo);
            glBindVertexArray(planeQuadVao);
            glBindBuffer(GL_ARRAY_BUFFER, planeQuadVbo);
            glBufferData(GL_ARRAY_BUFFER, quadData.sizeof, quadData.ptr, GL_DYNAMIC_DRAW);
            glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
            glEnableVertexAttribArray(0);
            glBindVertexArray(0);
        } else {
            glBindBuffer(GL_ARRAY_BUFFER, planeQuadVbo);
            glBufferData(GL_ARRAY_BUFFER, quadData.sizeof, quadData.ptr, GL_DYNAMIC_DRAW);
            glBindBuffer(GL_ARRAY_BUFFER, 0);
        }

        // Dashed axis/normal line through center, drawn as a series of short
        // GL_LINES segments (GL 3.3 core has no glLineStipple).
        float dashLen = qs * 0.10f;
        float gapLen  = qs * 0.07f;
        float axisLen = qs * 1.3f;
        float[] axisData;
        for (float t = -axisLen; t < axisLen; t += dashLen + gapLen) {
            float t1 = t + dashLen;
            if (t1 > axisLen) t1 = axisLen;
            Vec3 p0 = center + normal * t;
            Vec3 p1 = center + normal * t1;
            axisData ~= [p0.x, p0.y, p0.z, p1.x, p1.y, p1.z];
        }
        int axisVertCount = cast(int)(axisData.length / 3);

        if (axisLineVao == 0) {
            glGenVertexArrays(1, &axisLineVao);
            glGenBuffers(1, &axisLineVbo);
            glBindVertexArray(axisLineVao);
            glBindBuffer(GL_ARRAY_BUFFER, axisLineVbo);
            glBufferData(GL_ARRAY_BUFFER, axisData.length * float.sizeof, axisData.ptr, GL_DYNAMIC_DRAW);
            glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
            glEnableVertexAttribArray(0);
            glBindVertexArray(0);
        } else {
            glBindBuffer(GL_ARRAY_BUFFER, axisLineVbo);
            glBufferData(GL_ARRAY_BUFFER, axisData.length * float.sizeof, axisData.ptr, GL_DYNAMIC_DRAW);
            glBindBuffer(GL_ARRAY_BUFFER, 0);
        }

        glDisable(GL_DEPTH_TEST);
        drawThickLinesExt(planeQuadVao, 4, GL_LINE_LOOP, identityMatrix, vp,
                          planeColor, 1.5f, restoreProgram);
        if (axisVertCount > 0)
            drawThickLinesExt(axisLineVao, axisVertCount, GL_LINES, identityMatrix, vp,
                              planeColor, 1.5f, restoreProgram);
        glEnable(GL_DEPTH_TEST);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera

        int hit = moverHitTest(e.x, e.y);
        if (hit < 0) {
            // Click-to-place (task 0230 M3): a viewport click that misses
            // every handle places the plane center under the cursor,
            // projected onto a SCREEN-FACING plane through the CURRENT
            // center — a fresh placement lands at the prior center's depth
            // regardless of the mirror plane's own tilt, mirroring the
            // transform tool's relocate feel. The upstream viewport-input
            // gate (app.d's onMouseButtonDown dispatch, which only reaches a
            // tool for genuine viewport clicks — not cell-widget/camera-chord
            // ones) already filters what gets here; no extra gate is added
            // (opponent objection #4: tools cannot call the nested
            // viewportInputAllowed() app.d helper directly).
            //
            // Behaviour change vs v1 (documented, task 0230 §Risk 4): a
            // no-handle click used to fall through to selection-clear; while
            // Mirror is active it now places the center instead.
            Vec3 origin, dir;
            screenPointToRay(cast(float)e.x, cast(float)e.y, cachedVp, origin, dir);
            Vec3 planeN = cameraForwardDir(cachedVp);
            Vec3 hitPt;
            if (rayPlaneIntersect(origin, dir, params_.center, planeN, hitPt)) {
                params_.center = hitPt;
                engaged = true;
                evaluate();
                return true;
            }
            return false;
        }
        moverDragAxis = hit;
        moverLastMX   = e.x;
        moverLastMY   = e.y;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (moverDragAxis < 0) return false;
        moverDragAxis = -1;
        toolHandles.clearHaul();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (moverDragAxis < 0) return false;

        if (moverDragAxis == 4) {
            // Rotate box (M4): single-DOF drag along the tangent direction
            // `refAxis(axis) × currentNormal` — the direction the box itself
            // moves along as `angle` increases — converted to an angle delta
            // via arc length / radius (radius = the SAME `arm` used to place
            // the box in draw(), so the pixel/degree ratio matches what's
            // rendered). Reuses `screenAxisDelta` (drag.d) rather than a
            // bespoke projection, consistent with the center handle's reuse
            // of axisDragDelta/planeDragDelta.
            Vec3  curNormal = toolNormal(params_);
            Vec3  rAxis     = refAxis(params_.axis);
            Vec3  tangent   = normalize(cross(rAxis, curNormal));
            float arm       = gizmoSize(params_.center, cachedVp) * 0.55f;
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, moverLastMX, moverLastMY,
                                         rotateBox.pos, tangent, cachedVp, skip);
            if (!skip && arm > 1e-6f) {
                float d = dot(delta, tangent);   // signed world length along tangent
                params_.angle += (d / arm) * (180.0f / PI);
                engaged = true;
                evaluate();
            }
            moverLastMX = e.x;
            moverLastMY = e.y;
            return true;
        }

        // Task 0233: with the axis arrows gone, the only remaining center
        // drag is the center box (moverDragAxis == 3) — always a planar drag.
        bool skip;
        Vec3 delta = planeDragDelta(e.x, e.y, moverLastMX, moverLastMY,
                                    moverDragAxis, mover.center, cachedVp, skip);
        if (!skip) {
            params_.center += delta;
            engaged = true;
            evaluate();
        }
        moverLastMX = e.x;
        moverLastMY = e.y;
        return true;
    }

    /// Mirrors BoxTool.moverHitTest (box.d:2768) — Arrow.hitTest is
    /// `protected` (handler.d), so the segment-distance test is duplicated
    /// here rather than called; BoxHandler.hitTest is re-exported public
    /// (handler.d:1086) so centerBox/rotateBox can be hit-tested directly.
    /// rotateBox is tested FIRST — it is the smaller target and (depending on
    /// camera distance) can sit close to the enlarged centerBox's screen area.
    private int moverHitTest(int mx, int my) {
        if (rotateBox.hitTest(mx, my, cachedVp)) return 4;
        if (mover.centerBox.hitTest(mx, my, cachedVp)) return 3;
        Arrow[3] arrows = [mover.arrowX, mover.arrowY, mover.arrowZ];
        foreach (i, arrow; arrows) {
            if (!arrow.isVisible()) continue;
            float sax, say, ndcZa, sbx, sby, ndcZb;
            if (!projectToWindowFull(arrow.start, cachedVp, sax, say, ndcZa)) continue;
            if (!projectToWindowFull(arrow.end,   cachedVp, sbx, sby, ndcZb)) continue;
            float t;
            if (closestOnSegment2D(cast(float)mx, cast(float)my,
                                   sax, say, sbx, sby, t) < 8.0f)
                return cast(int)i;
        }
        return -1;
    }
}

/// Camera forward direction from a Viewport's view matrix (not necessarily
/// unit length — rayPlaneIntersect's t = dot(n,d)/dot(n,dir) is invariant
/// under scaling n, so this is safe to use unnormalized as a plane normal).
/// Not exported from math.d as a reusable helper; inlined here since it's
/// only needed for the click-to-place screen-facing plane (M3).
private Vec3 cameraForwardDir(const ref Viewport vp) pure nothrow @nogc @safe {
    return Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
}

// ---------------------------------------------------------------------------
// Module unittest (fold #2, riskiest item §8.1 of the impl plan) — proves
// rebuildMirrorPreview is NON-CUMULATIVE: 5 successive calls against the same
// baseSnap/baseMask/params_ must all land on the SAME face/vertex count, not
// grow by 6 faces / 8 verts each time. CPU-only (plain Mesh, no GpuMesh/GL),
// so this runs in the dubtest lane without a GL context. A committed-count
// test (tests/test_mirror_tool.d) cannot exercise this directly, since
// deactivate() only ever calls mirrorFaces ONCE by construction — this is
// the only test that would catch a "preview recomputes on top of itself"
// regression.
// ---------------------------------------------------------------------------
unittest {
    Mesh cube = makeCube();               // 8 verts, 6 faces
    MeshSnapshot baseSnap = MeshSnapshot.capture(cube);
    bool[] baseMask = new bool[](cube.faces.length);
    baseMask[] = true;                    // whole-mesh mirror

    MirrorParams params_;
    params_.axis       = 0;               // X
    params_.center     = Vec3(1, 0, 0);
    params_.mergeVerts = false;           // weld = 0 -> no dedup
    params_.invertPolys = true;

    Mesh previewMesh;
    size_t expectedVerts = size_t.max, expectedFaces = size_t.max;
    foreach (i; 0 .. 5) {
        rebuildMirrorPreview(baseSnap, previewMesh, baseMask, params_);
        if (i == 0) {
            expectedVerts = previewMesh.vertices.length;
            expectedFaces = previewMesh.faces.length;
            assert(expectedVerts == 16, "expected 16 verts after one mirror, got "
                ~ expectedVerts.to!string);
            assert(expectedFaces == 12, "expected 12 faces after one mirror, got "
                ~ expectedFaces.to!string);
        } else {
            assert(previewMesh.vertices.length == expectedVerts,
                "preview accumulated verts on repeat #" ~ i.to!string ~ ": expected "
                ~ expectedVerts.to!string ~ ", got " ~ previewMesh.vertices.length.to!string);
            assert(previewMesh.faces.length == expectedFaces,
                "preview accumulated faces on repeat #" ~ i.to!string ~ ": expected "
                ~ expectedFaces.to!string ~ ", got " ~ previewMesh.faces.length.to!string);
        }
    }
}

// ---------------------------------------------------------------------------
// TILTED-plane non-cumulative preview (task 0230 M2 §5) — the same 5×-repeat
// proof as above, but with a genuinely non-axis-aligned normal (angle=45 off
// the X axis) to prove the oriented-plane preview path (rebuildMirrorPreview
// -> mirrorFacesPlane -> toolNormal) is non-cumulative too, not just the
// axis-aligned v1 path exercised above.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    Mesh cube = makeCube();               // 8 verts, 6 faces
    MeshSnapshot baseSnap = MeshSnapshot.capture(cube);
    bool[] baseMask = new bool[](cube.faces.length);
    baseMask[] = true;                    // whole-mesh mirror

    MirrorParams params_;
    params_.axis        = 0;              // base X ...
    params_.angle       = 45.0f;          // ... tilted 45 degrees off-axis
    params_.center      = Vec3(1, 0, 0);
    params_.mergeVerts  = false;          // weld = 0 -> no dedup
    params_.invertPolys = true;

    // Sanity: this really is a non-axis-aligned normal (not incidentally
    // reducing to +-X/+-Y/+-Z), so the test exercises the oriented path.
    Vec3 n = toolNormal(params_);
    assert(n.x > 0.01f && n.y > 0.01f && abs(n.z) < 1e-4f,
        "test setup: expected a tilted-in-XY normal, got " ~ n.to!string);

    Mesh previewMesh;
    size_t expectedVerts = size_t.max, expectedFaces = size_t.max;
    foreach (i; 0 .. 5) {
        rebuildMirrorPreview(baseSnap, previewMesh, baseMask, params_);
        if (i == 0) {
            expectedVerts = previewMesh.vertices.length;
            expectedFaces = previewMesh.faces.length;
            assert(expectedVerts == 16, "tilted preview: expected 16 verts, got "
                ~ expectedVerts.to!string);
            assert(expectedFaces == 12, "tilted preview: expected 12 faces, got "
                ~ expectedFaces.to!string);
        } else {
            assert(previewMesh.vertices.length == expectedVerts,
                "tilted preview accumulated verts on repeat #" ~ i.to!string
                ~ ": expected " ~ expectedVerts.to!string ~ ", got "
                ~ previewMesh.vertices.length.to!string);
            assert(previewMesh.faces.length == expectedFaces,
                "tilted preview accumulated faces on repeat #" ~ i.to!string
                ~ ": expected " ~ expectedFaces.to!string ~ ", got "
                ~ previewMesh.faces.length.to!string);
        }
    }
}
