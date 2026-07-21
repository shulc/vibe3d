module tools.alignment.array_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import drag : planeDragDelta;
import params : Param, IntEnumEntry;
import shader : Shader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

alias ArrayEditFactory = MeshSessionEdit delegate();

// ---------------------------------------------------------------------------
// ArrayTool — interactive Array (factory id `mesh.arrayTool`, task 0355).
//
// Promotes the one-shot `mesh.array` command (source/commands/mesh/array.d,
// a 1D line-array — `Mesh.arrayFaces`, left byte-for-byte untouched) to an
// interactive tool backed by the new 3-axis GRID kernel
// (`Mesh.arrayFacesGrid`) — see that method's doc comment in source/mesh.d
// for the full per-attribute semantics. This tool is grounded strictly in
// the captured reference toolcard (task 0355's capture notes) — 23
// attributes across the reference's "Array Generator" + "Clone Effector"
// panel sections, with their captured LIVE defaults (Count 2/1/2, Offset
// 1m/1m/1m, Jitter/Scale/Rotate/Between at neutral, Clone Effector all
// off, Source=Active Meshes).
//
// Lifecycle mirrors EdgeExtendTool/EdgeExtrudeTool's template (topology-
// creating tools own their own undo plumbing, commit ONE before/after
// MeshSnapshot pair per session): activate() captures `before` but does
// NOT build a preview immediately — the captured doc itself requires a
// SEPARATE "click in the 3D viewport to enable interactive tool mode"
// gesture after selecting the tool from the toolbox, so a bare activation
// (tool.set on) legitimately shows no grid yet, matching every sibling
// tool's "preview appears on first drag/param-edit" convention.
//
// Drag law (captured, task 0355's capture notes §4): the reference's "Post-Mode" commit
// model runs the array generator from the ORIGINAL source and commits on
// EVERY haul step, rather than accumulating a transform delta on the built
// preview — this tool follows that "revert-then-re-run-from-baseline" model
// (rebuildPreview() below), same as LoopSliceTool/EdgeExtendTool/CloneTool.
// The whole drag gesture still collapses to ONE undo entry at mouse-up,
// matching vibe3d's established per-gesture undo granularity (every other
// interactive tool in this codebase does the same; the reference's own
// Command History also nests each step's ToolAdjustment+doApply inside one
// higher-level "Command Block").
//
// The captured drag maps a 2D screen delta onto the reference's Work Plane
// in-plane axes (confirmed live: a pure horizontal screen drag moved BOTH
// Offset X and Offset Y, Offset Z untouched — an oblique combination the
// toolcard itself flags as camera/Work-Plane-position-dependent, not a
// fixed rule). vibe3d has no Work Plane system, so — matching CloneTool's
// own documented divergence ("no reference tool-model exists; we use our
// own planeDragDelta") — this tool projects the screen delta onto the
// most-facing world-space plane (`planeDragDelta`, dragAxis=3) and folds
// the FULL resulting world delta into all three Offset X/Y/Z params. An
// axis whose Count is 1 (e.g. the captured default Count Y=1) never shows
// visible new geometry from its own offset regardless, same as the
// reference.
//
// NOT implemented (captured as doc-only / low-confidence, not guessed):
//   - Right-click-drag → Count: doc-only, the one live attempt at this
//     ran against a harness-broken empty selection (capture notes §7.2), so
//     it is UNCONFIRMED evidence, not a real capture. RMB is left bound to
//     the vibe3d-wide "cancel live edit" convention every other interactive
//     tool in this codebase uses (Clone/LoopSlice/EdgeExtend), rather than
//     guessing at an unverified count-drag mapping.
//   - Ctrl-constrain-to-initial-direction: doc-only, not independently
//     live-confirmed.
//   - `type` (Automatic/Manual): the capture notes flag this "static-only,
//     UNCONFIRMED live" (confidence: low) — appears in the reference's own
//     stale tool-help metadata but not in either live docked-panel
//     screenshot. Left out of params() entirely rather than guessed.
//   - Source = Specific Mesh / All BG / Random BG / Preset Shape, and the
//     paired Mesh Item: the enum + item name ARE surfaced as params (panel/
//     schema parity with the captured 23-attribute set), but only
//     Source = Active Meshes is functionally wired — background-item
//     cloning is the same underlying capability the task's own non-goals
//     section excludes for Instance/Replica Array (item-level cloning).
// ---------------------------------------------------------------------------
final class ArrayTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory     history;
    ArrayEditFactory   factory;

    // Source (Clone Effector "Source" enum) — only Active is functional,
    // see the module doc comment. Kept as a real param for panel/schema
    // parity with the captured 23-attribute set.
    enum SourceMode { Active, Specific, Inactive, Random, Preset }
    static immutable IntEnumEntry[5] sourceTable = [
        IntEnumEntry(cast(int)SourceMode.Active,   "active",   "Active Meshes"),
        IntEnumEntry(cast(int)SourceMode.Specific, "specific", "Specific Mesh"),
        IntEnumEntry(cast(int)SourceMode.Inactive, "inactive", "All BG"),
        IntEnumEntry(cast(int)SourceMode.Random,   "random",   "Random BG"),
        IntEnumEntry(cast(int)SourceMode.Preset,   "preset",   "Preset Shape"),
    ];

    // ---- Array Generator (captured live defaults) --------------------
    int   numX_ = 2, numY_ = 1, numZ_ = 2;
    float offX_ = 1.0f, offY_ = 1.0f, offZ_ = 1.0f;
    float jitX_ = 0.0f, jitY_ = 0.0f, jitZ_ = 0.0f;
    float sclX_ = 100.0f, sclY_ = 100.0f, sclZ_ = 100.0f;   // percent
    float angP_ = 0.0f, angH_ = 0.0f, angB_ = 0.0f;          // degrees
    bool  between_ = false;
    // ---- Clone Effector (captured live defaults) ----------------------
    bool   replace_ = false;
    bool   flip_    = false;
    bool   merge_   = false;
    float  dist_    = 0.0f;
    SourceMode source_ = SourceMode.Active;
    string item_    = "";

    // Session state — same shape as CloneTool.
    bool         active;
    bool         built;        // a preview is baked into the live mesh
    bool         dragging;     // between LMB-down and LMB-up
    MeshSnapshot before;       // session baseline (recaptured after each commit)

    int  anchorMX, anchorMY;   // drag-start pixel coords
    Vec3 anchorWorld;          // world-space drag anchor (selection centroid)
    Vec3 dragBaseOffset;       // Offset X/Y/Z at drag start
    Viewport cachedVp;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
    }

    void setUndoBindings(CommandHistory h, ArrayEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Array"; }

    // Edit-mode-orthogonal — same as mesh.array / mesh.mirror: reads the
    // face selection (or whole mesh if empty) regardless of the current
    // edit mode. Leave supportedModes() at the Tool base default (all
    // three modes).

    override Param[] params() {
        // Count X/Y/Z: DoS guard (code review B1) — mirrors prim.cube's
        // segmentsR precedent (`.min(1).max(64).enforceBounds()`). Per-axis
        // max(64) alone still lets 3 axes multiply to ~262k, so
        // Mesh.arrayFacesGrid ALSO caps the totalSlots PRODUCT directly
        // (defense-in-depth — it's a public Mesh method any caller can
        // drive, not only through this panel/attr path).
        return [
            Param.int_("numX", "Count X", &numX_, 2).min(1).max(64).enforceBounds(),
            Param.int_("numY", "Count Y", &numY_, 1).min(1).max(64).enforceBounds(),
            Param.int_("numZ", "Count Z", &numZ_, 2).min(1).max(64).enforceBounds(),
            Param.float_("offX", "Offset X", &offX_, 1.0f),
            Param.float_("offY", "Offset Y", &offY_, 1.0f),
            Param.float_("offZ", "Offset Z", &offZ_, 1.0f),
            Param.float_("jitX", "Jitter X", &jitX_, 0.0f).min(0.0f),
            Param.float_("jitY", "Jitter Y", &jitY_, 0.0f).min(0.0f),
            Param.float_("jitZ", "Jitter Z", &jitZ_, 0.0f).min(0.0f),
            Param.float_("sclX", "Scale X", &sclX_, 100.0f).min(0.0f),
            Param.float_("sclY", "Scale Y", &sclY_, 100.0f).min(0.0f),
            Param.float_("sclZ", "Scale Z", &sclZ_, 100.0f).min(0.0f),
            Param.float_("angP", "Rotate X", &angP_, 0.0f).angle(),
            Param.float_("angH", "Rotate Y", &angH_, 0.0f).angle(),
            Param.float_("angB", "Rotate Z", &angB_, 0.0f).angle(),
            Param.bool_("between", "Between", &between_, false),
            Param.bool_("replace", "Replace Source", &replace_, false),
            Param.bool_("flip", "Invert Polygons", &flip_, false),
            Param.bool_("merge", "Merge Vertices", &merge_, false),
            Param.float_("dist", "Distance", &dist_, 0.0f).min(0.0f),
            Param.intEnum_("source", "Source", cast(int*)&source_,
                           sourceTable, cast(int)SourceMode.Active),
            Param.string_("item", "Mesh Item", &item_, ""),
        ];
    }

    // Distance is greyed unless Merge Vertices is on (matches the captured
    // panel: "Distance ... greyed out live unless Merge Vertices is on").
    // Mesh Item is greyed unless Source = Specific Mesh (captured: "greyed
    // out live under the default Source=Active Meshes") — kept for
    // panel/schema parity even though only Active is functionally wired.
    override bool paramEnabled(string name) const {
        if (name == "dist") return merge_;
        if (name == "item") return source_ == SourceMode.Specific;
        return true;
    }

    override void activate() {
        active   = true;
        built    = false;
        dragging = false;
        before   = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        if (active && built) commitEdit();
        active   = false;
        built    = false;
        dragging = false;
    }

    override bool hasUncommittedEdit() const {
        return active && built;
    }

    override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    override void resyncSession() {
        if (!active) return;
        if (built && before.filled) before.restore(*mesh);
        built    = false;
        dragging = false;
        before   = MeshSnapshot.capture(*mesh);
        refreshCaches();
    }

    // Framework "apply and continue" (task 0461, Shift+click): commit the live
    // edit as its own undo entry, keeping the tool active; the driver follows
    // with resyncSession() to re-arm in place. Mirrors deactivate()'s commit
    // guard minus the teardown.
    override bool commitUncommittedEdit() {
        if (!hasUncommittedEdit()) return false;
        commitEdit();
        return true;
    }

    override void onParamChanged(string pname) {
        if (interactiveParamEdit) rebuildPreview();
    }
    override void evaluate() {}

    // -----------------------------------------------------------------------
    // Headless apply (tool.doApply). Runs the grid kernel once against the
    // clean cage. MUST NOT snapshot — ToolDoApplyCommand wraps it with undo.
    // -----------------------------------------------------------------------
    override bool applyHeadless() {
        if (mesh.faces.length == 0) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        auto mask = currentMask();
        size_t n = mesh.arrayFacesGrid(mask, numX_, numY_, numZ_,
                                       offsetVec(), jitterVec(), scaleVec(), rotateVec(),
                                       between_, replace_, flip_, merge_, dist_);
        if (n == 0 && !replace_) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { cancelLiveEdit(); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;

        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera

        if (mesh.faces.length == 0) return false;

        anchorMX       = e.x;
        anchorMY       = e.y;
        anchorWorld    = mesh.selectionCentroidFaces();
        dragBaseOffset = offsetVec();
        dragging       = true;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragging = false;
        if (built) {
            commitEdit();
            built  = false;
            before = MeshSnapshot.capture(*mesh);   // new baseline for the next drag
        }
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        bool skip;
        // Screen delta -> most-facing world-space plane (dragAxis=3), the
        // same projection CloneTool uses in the absence of a Work Plane
        // system. See the module doc comment for the divergence rationale.
        Vec3 delta = planeDragDelta(e.x, e.y, anchorMX, anchorMY,
                                    3, anchorWorld, cachedVp, skip);
        if (!skip) {
            offX_ = dragBaseOffset.x + delta.x;
            offY_ = dragBaseOffset.y + delta.y;
            offZ_ = dragBaseOffset.z + delta.z;
            rebuildPreview();
        }
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        // No gizmo overlay — the live grid preview on the real mesh is the
        // visual feedback (same choice as CloneTool).
    }

private:
    Vec3 offsetVec() const { return Vec3(offX_, offY_, offZ_); }
    Vec3 jitterVec() const { return Vec3(jitX_, jitY_, jitZ_); }
    Vec3 scaleVec()  const { return Vec3(sclX_ / 100.0f, sclY_ / 100.0f, sclZ_ / 100.0f); }
    Vec3 rotateVec() const { return Vec3(angP_, angH_, angB_); }

    // Empty face selection ⇒ whole mesh — same convention as mesh.array /
    // mesh.mirror / mesh.smooth. (The captured live harness note about an
    // empty selection dropping to 0 polygons was flagged by the capture
    // notes themselves as a HARNESS artifact, not a confirmed reference
    // finding — see task 0355's capture notes §7.2 — so it is not treated
    // as a spec requirement.)
    bool[] currentMask() {
        bool[] mask = new bool[](mesh.faces.length);
        bool any = false;
        foreach (i, b; mesh.selectedFaces) {
            if (b) { mask[i] = true; any = true; }
        }
        if (!any) foreach (i; 0 .. mesh.faces.length) mask[i] = true;
        return mask;
    }

    // Revert to the pre-array cage, then re-run the grid kernel from the
    // current params — the "Post-Mode" re-evaluate law (module doc comment):
    // WRITE params + RE-RUN from source, never transform the built grid.
    void rebuildPreview() {
        if (!active) return;
        before.restore(*mesh);
        auto mask = currentMask();
        size_t n = mesh.arrayFacesGrid(mask, numX_, numY_, numZ_,
                                       offsetVec(), jitterVec(), scaleVec(), rotateVec(),
                                       between_, replace_, flip_, merge_, dist_);
        built = (n != 0) || replace_;
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Array");
        history.record(cmd);
    }

    void cancelLiveEdit() {
        if (built && before.filled) {
            before.restore(*mesh);
            refreshCaches();
        }
        built    = false;
        dragging = false;
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
