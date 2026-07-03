module tools.mirror;

import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;

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
import handler : MoveHandler, ToolHandles, Arrow;
import drag : axisDragDelta, planeDragDelta;
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
    previewMesh.mirrorFaces(baseMask, "XYZ"[params_.axis], params_.center,
                            weld, params_.invertPolys);
    previewMesh.buildLoops();
}

// ---------------------------------------------------------------------------
// MirrorParams — single source of truth for the Mirror tool (mirrors
// BoxParams, box.d:46). Every handle drag and every panel edit writes into
// this struct; render + handle position + commit derive from it on demand.
//
// v1 is axis-aligned (Mesh.mirrorFaces, mesh.d:4172): axis/center/
// invertPolys/mergeVerts/distance are live. angle/mode/left/up are shown in
// the panel (matching the reference layout) but greyed via paramEnabled() —
// they have no backend wiring yet (v2: oriented Center/Left/Up plane).
// ---------------------------------------------------------------------------
struct MirrorParams {
    int   axis        = 0;            // 0=X 1=Y 2=Z — mirrorFaces wants uppercase 'X'/'Y'/'Z'
    Vec3  center       = Vec3(0, 0, 0);
    bool  invertPolys  = true;         // -> mirrorFaces flipNormals
    bool  mergeVerts   = true;         // gates the weld pass
    float distance     = 0.001f;       // -> mirrorFaces weld (only when mergeVerts)
    // --- shown but greyed in v1 (no backend wiring yet; v2 oriented plane) ---
    float angle = 180.0f;
    int   mode  = 0;                   // 0=Axis (only value live)
    Vec3  left  = Vec3(0, 0, 0);
    Vec3  up    = Vec3(0, 0, 0);
}

// ---------------------------------------------------------------------------
// MirrorTool — interactive generator tool wrapping Mesh.mirrorFaces
// (source/mesh.d:4172). Modelled on BoxTool (source/tools/box.d): the
// document mesh is never mutated during interaction, only in deactivate().
//
// v1 = axis-aligned (Axis + Center live; Angle/Mode/Left/Up greyed).
// M1 (this milestone): panel + commit-on-deactivate only — no handle, no
// preview mesh yet (M2/M3).
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

    // Commit guard (§4.2 of the impl plan): true once the user has actually
    // interacted (handle drag / param edit / headless attr write). Prevents
    // an accidental mirror when the tool is picked and dropped untouched.
    bool engaged;

    CommandHistory    history;
    MirrorEditFactory mirrorEditFactory;

    // ----- Center handle (M2) — axis-aligned drag only (§3 of the impl
    // plan): reuse MoveHandler exactly as BoxTool does (box.d:1857/1896),
    // with the three plane-corner circles hidden so only the 3 axis arrows
    // + center box remain. World-axis orientation (no workplane concept —
    // the mirror plane is genuinely world-axis-aligned in v1).
    MoveHandler mover;
    ToolHandles toolHandles;
    int      moverDragAxis = -1;  // 0/1/2 = X/Y/Z arrow, 3 = centerBox, -1 = none
    int      moverLastMX, moverLastMY;
    Viewport cachedVp;

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
            inserted = mesh.mirrorFaces(commitMask(), "XYZ"[params_.axis],
                                        params_.center, weld, params_.invertPolys);
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
            // --- shown but greyed (v2 oriented plane) ---
            Param.float_("angle", "Angle", &params_.angle, 180.0f).angle(),
            Param.intEnum_("mode", "Mode", cast(int*)&params_.mode,
                [IntEnumEntry(0, "axis", "Axis")], 0),
            Param.vec3_("left", "Left", &params_.left, Vec3(0, 0, 0)),
            Param.vec3_("up", "Up", &params_.up, Vec3(0, 0, 0)),
        ];
    }

    override bool paramEnabled(string name) const {
        // v2-deferred fields: shown but greyed in v1.
        if (name == "angle" || name == "mode" || name == "left" || name == "up")
            return false;
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
        size_t inserted = mesh.mirrorFaces(mask, "XYZ"[params_.axis],
                                           params_.center, weld, params_.invertPolys);
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
            && cachedDistance == params_.distance)
            return;

        rebuildPreviewMesh();
        previewGpu.upload(previewMesh);

        cachedAxis       = params_.axis;
        cachedCenter     = params_.center;
        cachedInvert     = params_.invertPolys;
        cachedMerge      = params_.mergeVerts;
        cachedDistance   = params_.distance;
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

        if (!visualOnly) {
            toolHandles.begin();
            toolHandles.add(mover.centerBox, 13);
            toolHandles.add(mover.arrowX,    10);
            toolHandles.add(mover.arrowY,    11);
            toolHandles.add(mover.arrowZ,    12);
            if (moverDragAxis >= 0)
                toolHandles.setHaul(moverDragAxis <= 2 ? 10 + moverDragAxis : 13);
            else
                toolHandles.setHaul(-1);
            int hmx, hmy;
            queryMouse(hmx, hmy);
            toolHandles.update(hmx, hmy, vp);
        }

        mover.draw(shader, vp);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera

        int hit = moverHitTest(e.x, e.y);
        if (hit < 0) return false;
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
        bool skip;
        Vec3 delta = moverDragAxis <= 2
            ? axisDragDelta (e.x, e.y, moverLastMX, moverLastMY,
                             moverDragAxis, mover, cachedVp, skip)
            : planeDragDelta(e.x, e.y, moverLastMX, moverLastMY,
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
    /// (handler.d:1086) so centerBox can be hit-tested directly.
    private int moverHitTest(int mx, int my) {
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
