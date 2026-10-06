module tools.alignment.array_tool;
import display_state : DrawPlan;
import prepared_record_context : PreparedToolParamDoorClient,
    PreparedNamedGpuParamDoorClient;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedPrivateStateToolDoorClient;
import prepared_private_state : PreparedPrivateStateOwner;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind;
import prepared_tool_effect : PreparedArrayParamEffect, PreparedArrayParamKind;
import prepared_param_update : PreparedParamUpdateOwner,
    PreparedParamUpdateProducer, PreparedStateParamImage;
import mesh_gpu : GpuUploadOwner;
import document : Layer;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import tools.topology_step;
import command : Command;
import mesh;
import mesh_gpu : GpuMesh;
import math;
import editmode : EditMode;
import drag : HandleDrag, DragFrame, DragKind, automaticPlanePressHit;
import viewgrid : vectorSnap, viewVectorQuantum;
import overlay_space : OverlaySpace;
import params : Param, IntEnumEntry;
import shader : Shader;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import perf_probe : g_perf, Cat;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import core.stdc.string : memcmp;


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
// The completed grid images belong to ToolSession history. Activation captures
// `before` but does
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
// Each completed drag is one undo entry at mouse-up,
// matching vibe3d's established per-gesture undo granularity (every other
// interactive tool in this codebase does the same; the reference's own
// Command History also nests each step's ToolAdjustment+doApply inside one
// higher-level "Command Block").
//
// The captured drag maps a 2D screen delta onto the reference's Work Plane
// in-plane axes (confirmed live: a pure horizontal screen drag moved BOTH
// Offset X and Offset Y, Offset Z untouched — an oblique combination the
// toolcard itself flags as camera/Work-Plane-position-dependent, not a
// fixed rule). The haul is a free handle (`HandleDrag`, view plane) pressed
// at the snapped press hit less the offset copy's centroid (K-FH C-NT-off),
// and folds the FULL world delta into all three Offset X/Y/Z params. An
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
struct ArrayParamProjection {
    bool active, built;
    int numX, numY, numZ;
    float offX, offY, offZ, jitX, jitY, jitZ;
    float sclX, sclY, sclZ, angP, angH, angB;
    bool between, replace, flip, merge;
    float dist;
    int source;
    string item;
    bool opEquals(const ArrayParamProjection other) const nothrow @nogc {
        bool sameFloat(ref const float a, ref const float b) nothrow @nogc {
            return memcmp(&a, &b, float.sizeof) == 0;
        }
        return active == other.active && built == other.built &&
            numX == other.numX && numY == other.numY && numZ == other.numZ &&
            sameFloat(offX, other.offX) && sameFloat(offY, other.offY) &&
            sameFloat(offZ, other.offZ) && sameFloat(jitX, other.jitX) &&
            sameFloat(jitY, other.jitY) && sameFloat(jitZ, other.jitZ) &&
            sameFloat(sclX, other.sclX) && sameFloat(sclY, other.sclY) &&
            sameFloat(sclZ, other.sclZ) && sameFloat(angP, other.angP) &&
            sameFloat(angH, other.angH) && sameFloat(angB, other.angB) &&
            between == other.between && replace == other.replace &&
            flip == other.flip && merge == other.merge &&
            sameFloat(dist, other.dist) && source == other.source && item == other.item;
    }
}

alias PreparedArrayParamImage = PreparedStateParamImage!(ArrayParamProjection, PreparedArrayParamKind);

final class ArrayTool : Tool, PreparedToolDoorClient, PreparedToolParamDoorClient,
        TopologyStepClient {
    // A recording UI command closes the current grid operation and leaves
    // the tool armed. Completed grids already have ToolSession rows.
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, commandClose: CommandClose.uiDoor,
            sessionSteps: true, historyTopologySteps: true,
            opensAt: OpensAt.firstPress,
            imageAttrs: ["numX", "numY", "numZ", "offX", "offY", "offZ",
                "jitX", "jitY", "jitZ", "sclX", "sclY", "sclZ", "angP",
                "angH", "angB", "between", "replace", "flip", "merge",
                "dist", "source", "item"],
            haulAttrs: ["numX", "numY", "numZ", "offX", "offY", "offZ",
                "jitX", "jitY", "jitZ", "sclX", "sclY", "sclZ", "angP",
                "angH", "angB", "between", "replace", "flip", "merge",
                "dist", "source", "item"]
        };
        return policy;
    }

    mixin PreparedNamedGpuParamDoorClient;
    mixin PreparedPrivateStateToolDoorClient!(Layer,
        PreparedPrivateStateOwner.arraySession);
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;



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
    MeshSnapshot before;       // source cage of the current array operation

    // The press handle (onMouseButtonDown) + travel. The item space (task
    // 0645) is FROZEN at the press: the drag's answer converts back to layer
    // coordinates through the same matrix.
    HandleDrag grab;
    OverlaySpace dragSpace;
    Vec3 dragBaseOffset;       // Offset X/Y/Z at drag start

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
    }

    override string name() const { return "Array"; }

    // Edit-mode-orthogonal — same as mesh.array / mesh.mirror: reads the
    // face selection (or whole mesh if empty) regardless of the current
    // edit mode. Leave supportedModes() at the Tool base default (all
    // three modes).

    override Param[] params() {
        // Count X/Y/Z are bounded at the attribute doors (tool_attr_bounds.d);
        // Mesh.arrayFacesGrid caps their totalSlots PRODUCT.
        return [
            Param.int_("numX", "Count X", &numX_, 2),
            Param.int_("numY", "Count Y", &numY_, 1),
            Param.int_("numZ", "Count Z", &numZ_, 2),
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
            Param.float_("dist", "Distance", &dist_, 0.0f),
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
    final MeshSnapshot prepareActivationBaseline() { return MeshSnapshot.capture(*mesh); }
    final void installPreparedActivation(ref MeshSnapshot image) nothrow @nogc {
        active = true; built = false; dragging = false; image.moveInto(before);
    }
    final PreparedSessionActivateEffect prepareActivate(PreparedRecordContext context,
            PreparedPrivateStateOwner owner) {
        bool accepted = context !is null && owner !is null && owner.owns(this) &&
            context.preparePrivateState(owner) && context.markNoHistoryInstall();
        if (!accepted && context !is null) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.Array, accepted);
    }
    version(unittest) void seedPreparedActivationForTest() nothrow @nogc {
        active = false; built = dragging = true;
    }
    version(unittest) bool preparedActivationInstalledForTest() const nothrow @nogc {
        return active && !built && !dragging && before.filled;
    }
    final bool ownsPreparedLayer(Layer layer) const {
        return layer !is null && &layer.meshRef() is mesh;
    }
    version(unittest) final void seedPreparedParamForTest(ref Mesh live,
            bool interactive, bool isActive, bool isBuilt) {
        interactiveParamEdit = interactive; active = isActive; built = isBuilt;
        before = MeshSnapshot.capture(live);
    }
    version(unittest) final void mutatePreparedParamForTest(float value)
            nothrow @nogc { offX_ = value; }
    version(unittest) final bool preparedParamStateForTest(bool expectedBuilt)
            const nothrow @nogc { return built == expectedBuilt; }

    override void deactivate() {
        active   = false;
        built    = false;
        dragging = false;
    }

    override bool hasUncommittedEdit() const {
        return active && dragging && built;
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

    // A completed haul already has its own row; there is no extra pending
    // edit to commit when the framework asks to continue.
    override bool commitUncommittedEdit() {
        return false;
    }

    override bool commitOperation() {
        if (!active) return false;
        before = MeshSnapshot.capture(*mesh);
        built = dragging = false;
        return true;
    }

    mixin TopologyStepClientBody!("Array", before);
    override void rebaseTopologyStep(MeshSnapshot basis) {
        before = basis;
        built = dragging = false;
        refreshCaches();
    }

    override void onParamChanged(string pname) {
        if (interactiveParamEdit) rebuildPreview();
    }
    final PreparedArrayParamImage buildPreparedParamUpdate(string, ref const Mesh live) {
        auto projection = paramProjection();
        projection.item = item_.dup;
        return PreparedArrayParamImage.prepare(projection, live);
    }
    final bool preparedParamUpdateMatches(in PreparedArrayParamImage image,
            ref const Mesh live) const nothrow @nogc {
        return image.matches(paramProjection(), live);
    }
    final void installPreparedParamUpdate(ref PreparedArrayParamImage image)
            nothrow @nogc {
        image.clear();
    }
    mixin PreparedParamUpdateProducer!(PreparedParamUpdateOwner!(ArrayTool,
        PreparedArrayParamImage, PreparedArrayParamKind), PreparedArrayParamEffect);
    override void evaluate() {}

    // -----------------------------------------------------------------------
    // Headless apply (tool.doApply). Runs the grid kernel once against the
    // clean cage. MUST NOT snapshot — ToolDoApplyCommand wraps it with undo.
    // -----------------------------------------------------------------------
    // A degenerate operand (nothing visible, a 1x1x1 grid) still applies:
    // ok + exactly one record (K-AR AR_E / AR_E_NR, the no-op contract's
    // real-edit branch).
    override bool applyHeadless() {
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        operation(*mesh);
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { closeOwnOperation(false); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;

        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera

        if (mesh.faces.length == 0) return false;

        Vec3 p0;   // the press hit, snapped to the view quantum
        if (!automaticPlanePressHit(e.x, e.y, cachedVp, p0)) return false;
        p0 = vectorSnap(p0, viewVectorQuantum(cachedVp));
        sessionStepBegins();
        dragSpace      = OverlaySpace.ofPrimary();
        dragBaseOffset = offsetVec();
        // K-FH C-NT-off: H = P0 - (c + off0), offset = off0 + the DQ travel from H.
        grab.press(p0 - dragSpace.pos(mesh.selectionCentroidFaces() + dragBaseOffset), e.x, e.y);
        dragging       = true;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragging = false;
        sessionStepEnds();
        built = false;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        bool skip;
        immutable Vec3 c = grab.client(e.x, e.y, DragFrame(DragKind.viewPlane), cachedVp, skip);
        if (!skip) {
            // WORLD in, LAYER out (task 0645): offX_/offY_/offZ_ are the
            // per-copy offset `arrayFacesGrid` adds to layer-space vertices.
            // A full linear inverse — a displacement elects no direction, so
            // there is no gain question as there is on the axis hauls.
            Vec3 local = dragSpace.toLocalDelta(c - grab.point);
            offX_ = dragBaseOffset.x + local.x;
            offY_ = dragBaseOffset.y + local.y;
            offZ_ = dragBaseOffset.z + local.z;
            rebuildPreview();
        }
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts,
                       const ref DrawPlan plan, bool visualOnly = false) {
        cachedVp = vp;
        // No gizmo overlay — the live grid preview on the real mesh is the
        // visual feedback (same choice as CloneTool).
    }

private:
    ArrayParamProjection paramProjection() const nothrow @nogc {
        return ArrayParamProjection(active, built, numX_, numY_, numZ_, offX_, offY_, offZ_,
            jitX_, jitY_, jitZ_, sclX_, sclY_, sclZ_, angP_, angH_, angB_,
            between_, replace_, flip_, merge_, dist_, cast(int)source_, item_);
    }
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
    // The one operation: preview and scripted apply. The
    // mask is the L1 funnel: selected faces, else every VISIBLE face
    // (tasks 9434, 0613).
    size_t operation(ref Mesh target) {
        return target.arrayFacesGrid(target.operandFaceMask(), numX_, numY_, numZ_,
            offsetVec(), jitterVec(), scaleVec(), rotateVec(), between_, replace_,
            flip_, CloneWeld(merge_, dist_));
    }

    // Revert to the pre-array cage, then re-run the grid kernel from the
    // current params — the "Post-Mode" re-evaluate law (module doc comment):
    // WRITE params + RE-RUN from source, never transform the built grid.
    void rebuildPreview() {
        if (!active) return;
        if (previewGated()) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        before.restore(*mesh);
        built = operation(*mesh) != 0 || replace_;
        refreshCaches();
    }

    // Completed steps are already installed at release. Deactivation only
    // installs the tool transition and cannot add a cumulative mesh record.
    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context) {
        if (context is null) return PreparedDeactivateEffect(
            preparedToolStateOwner, PreparedDeactivateKind.Array, false, false);
        const accepted = context.markNoHistoryInstall();
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.Array, false, accepted);
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
        refreshDisplay(mesh, gpu);
    }
}
