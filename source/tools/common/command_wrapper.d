module tools.common.command_wrapper;
import display_state : DrawPlan;
import prepared_tool_effect : PreparedParamDelta, PreparedParamKind,
    PreparedSessionActivateEffect, PreparedActivateKind;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedToolParamDoorClient;
import prepared_command_wrapper_activation : PreparedCommandWrapperActivationOwner;
import handler : ClickPointResourceOwner;
import command_history : PreparedHistoryKind;
private struct WrapperPreparedParamHandle {
    bool applyDirty, consumable;
    @disable this(this);
}

struct PreparedCommandWrapperActivationImage {
    bool valid;
    Vec3[] baseline;
    FalloffPacket[] falloffs;
    ClickPointHandler clickHandle;
    void clear() nothrow @nogc {
        valid = false; baseline = null; falloffs = null; clickHandle = null;
    }
}

import bindbc.sdl;

import command : Command;
import mesh : Mesh;
import mesh_gpu : GpuMesh;
import view    : View;
import editmode : EditMode;
import seltype  : SelType;
import display_sync : refreshDisplay;
import tool   : Tool, GestureRecordMode;
import edit_session : FrameParameterEvalClient, RefireClient;
import params : Param;
import math   : Vec3, Viewport;
import tools.create.create_common : screenToConstructionPlane;
import shader : Shader;
import handler : ClickPointHandler;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import commands.mesh.vertex_position_result : VertexPositionResult,
    VertexPositionResultBuilder;
import toolpipe.packets : FalloffPacket, SubjectPacket;
import operator        : VectorStack;
import pipe_gizmo_host : PipeGizmoHost;
import document : Layer;

import commands.mesh.smooth   : MeshSmooth;
import commands.mesh.jitter   : MeshJitter;
import commands.mesh.quantize : MeshQuantize;

import ImGui = d_imgui;

/// Tool wrapper around a one-shot Command. Lets a Command be activated
/// via `tool.set <id> on`, configured via `tool.attr`, and applied via
/// `tool.doApply` — the same activation surface used by `xfrm.smooth`,
/// `xfrm.jitter`, `xfrm.quantize`.
///
/// Interactive drag ("hauling" — mouse down/move/up drives a live preview):
///  - First LMB-down records the click point and resets the per-vert
///    BASELINE to the pre-drag mesh state.
///  - Motion restores baseline → `onDragDelta(dx, dy)` updates the
///    inner Command's attrs → the wrapper builds and installs a sparse live
///    preview result.
///  - LMB-up ends the drag session; mesh stays at preview.
///  - Subsequent LMB-down on the same active tool resets the baseline
///    again so the new drag composes on top of the previous preview
///    (post-Apply state when Apply ran, or the pre-activation state
///    otherwise).
///
/// Commit semantics (matching `TransformTool.deactivate` →
/// `commitEdit("Move")` pattern in source/tools/transform/move.d):
///  - `setGestureBindings(history, vxEditFactory)` — the BASE binder
///    (`Tool.setGestureBindings`, task 1905 group G6) — injects the
///    undo plumbing at construction time. The factory builds a fresh
///    `MeshVertexEdit` pre-wired to the same gpu/caches the inner
///    Command mutates; it arrives typed as `Command delegate()` and is
///    cast back when wrapping a result for history.
///  - `deactivate()` wraps the cached deterministic result
///    in `MeshVertexEdit` and records it on history. Spacebar →
///    `dropActiveTool` → here. Tool switches and tab close hit
///    the same path.
///  - The "Apply" button in `drawProperties()` runs the same commit
///    path then refreshes the baseline so further drags compose on
///    top of the now-committed state. Tool stays active.
// RefireClient (task 0428): the sole implementor of the refire capability —
// the wantsRefire / buildRefireCommand / setRefireDriving / onRefireCommitted
// overrides below are the interface's implementations (EditSession discovers
// them by cast).
abstract class CommandWrapperTool : Tool, FrameParameterEvalClient, RefireClient,
                                    PreparedToolDoorClient,
                                    PreparedToolParamDoorClient {
    protected Command inner;
    protected Mesh*   meshPtr;
    protected GpuMesh*        gpu;
    protected View             viewRef;

    // Undo plumbing — same shape as TransformTool. Optional: tests /
    // older callers can leave these null and skip history recording.

    // Drag bookkeeping.
    private bool   dragging;
    private int    dragStartX, dragStartY;
    // Set by `onParamChanged` when an attribute write edits a slider value;
    // consumed by the lifecycle's batch evaluation to re-run the preview
    // against the current baseline. Without this hook, slider edits update
    // the inner Command's stored attrs but the mesh stays at the old preview
    // state until the next drag or Apply.
    private bool   paramsDirty;

    // Baseline = mesh.vertices.dup at the moment the current edit
    // session started (activation or last Apply). `dirty` flips on
    // the first motion event after a new baseline; nothing commits
    // when the user activates / deactivates without any drag.
    private Vec3[] baseline;
    private bool   dirty;

    // R6 deterministic builders: Quantize/Smooth compute one sparse result.
    // Preview installs it; commit/refire only wrap the same value.
    private VertexPositionResult latestResult_;
    private bool                 latestResultValid_;
    private FalloffPacket        resultFalloff_;
    private bool                 resultPipeValid_;
    private bool                 resultFalloffPresent_;

    // Refire bookkeeping (undo/redo migration P4). While a panel-param-edit
    // refire session is driving this tool, the driver fires buildRefireCommand()
    // each tick and the history's refireEnd() lands ONE undo entry. The tool's
    // internal evaluate()/onParamChanged() preview is suppressed in that window
    // (the fired command owns the mutation), and the eventual commitNow() at
    // deactivate must NOT record a second entry for the same session.
    //
    //  refireDriving_   : true between the driver's first fire and refireEnd —
    //                     suppresses the internal preview so the two paths can't
    //                     both mutate the mesh in one tick.
    //  refireCommitted_ : set when a refire session committed an entry (the
    //                     driver called the tool back to mark it). Latched so the
    //                     single commitNow() chokepoint skips its own record(),
    //                     then cleared once consumed — the double-record guard.
    private bool   refireDriving_;
    private bool   refireCommitted_;

    // Click-point handle. Drawn ONLY while LMB is held — the gizmo
    // (sphere-with-rings at the click pixel) appears at click time and
    // disappears on release. Size is
    // updated per frame from `handleSize()` so the rings visually
    // scale with the current attribute magnitude.
    private ClickPointHandler clickHandle;

    // Cached viewport from the last frame — needed for falloff
    // evaluation (some falloff types like Screen / Lasso need vp;
    // linear / radial / cylinder / element ignore it).
    private Viewport cachedVp;

    // Last falloff config SET seen by `applyWithLivePipeline` — used by
    // `evaluate()` to detect live changes (the FalloffStage's panel
    // widgets fire onParamChanged on the stage, not on this Tool, so
    // the wrapper's own `paramsDirty` flag misses falloff edits and
    // the viewport doesn't refresh). Same pattern as MoveTool /
    // ScaleTool / RotateTool `falloffPacketsEqual`-based detection.
    //
    // SET-aware: one packet per ACTIVE falloff stage (in pipe order). A change
    // fires when the COUNT differs (an instance added/removed) OR any per-stage
    // config differs. With a single active falloff this is a 1-element array,
    // identical to the prior single-packet behaviour.
    private FalloffPacket[] lastAppliedFalloffs;

    // Falloff stage-gizmo refactor (step 5): the interactive falloff
    // endpoint gizmo is no longer owned per-tool. The single persistent
    // app-level PipeGizmoHost owns the one emitter; CommandWrapperTool has
    // no gizmo banks of its own, so it drives the host's FULL-cycle draw on
    // the host's OWN pool (exactly like the no-tool path) and routes events
    // through the host. Injected by app.d at each construction site via
    // setPipeGizmoHost(); nullable for tests / older callers.
    private PipeGizmoHost pipeGizmoHost;

    override string name() const { return "CommandWrapperTool"; }
    override Param[] params() { return inner.params(); }
    override bool paramEnabled(string name) const {
        return inner.paramEnabled(name);
    }

    // THE BINDER IS THE BASE'S (task 1905, group G6). `CommandWrapperTool`
    // used to declare its own `setUndoBindings(CommandHistory,
    // VertexEditFactory)` and its own `vertexEditFactory` field; both are gone,
    // and the four registrations (xfrm.smooth / xfrm.jitter / xfrm.quantize /
    // edge.slide) now call `Tool.setGestureBindings`, which is `final`.
    //
    // WHY THIS FAMILY MIGRATED AT ALL, since the plan (§6, D7) says its present
    // form "is already the target and a migration would prove nothing new".
    // That sentence is true of `commitNow`'s CONTRACT — seven early exits and
    // "true iff it really committed" — and it is preserved below untouched.
    // It was NOT true of the record CALL. `commitNow` used to reach the undo
    // stack directly, and that was the last writing history primitive under
    // `source/tools/**` outside the transform zone — sitting in no census
    // population at all. (The primitive is deliberately NOT spelled out in this
    // sentence: a comment that names its own needle is the self-matching grep
    // the plan had to repair at `app.d:3618`.) Measured, not argued: an
    // unrostered call on the history surface added to this file left
    // `dub test --config=tests` at 383/383 GREEN, while the identical line in
    // `source/tools/deform/magnet.d` reddened `tool_commit_seam_census_g1_test`
    // and `_g3_test`, each naming the file and the line. The site was unwatched;
    // it is now on the seam and rostered by
    // `tests/unit/tool_commit_seam_census_g6_test.d`.

    /// Inject the app-level persistent falloff gizmo host (mirror of
    /// setUndoBindings / XfrmTransformTool.setPipeGizmoHost). app.d calls
    /// this at each CommandWrapperTool construction site so the wrapper
    /// drives/routes the single shared falloff emitter instead of owning
    /// its own. Covers subclasses (the setter lives on the base).
    public void setPipeGizmoHost(PipeGizmoHost h) {
        this.pipeGizmoHost = h;
    }

    // ---- subclass hooks ----------------------------------------------

    /// Map the running drag delta (pixels relative to LMB-down) into
    /// the inner Command's param fields. Subclasses mutate their own
    /// stored attrs (e.g. JitterTool sets rangeX_/rangeY_/rangeZ_).
    protected abstract void onDragDelta(int dx, int dy);

    /// Current world-units magnitude for the click-point handle. Reads
    /// the subclass's inner Command attribute that the drag haul is
    /// modulating (Jitter Range, Smooth strength, Quantize step) so
    /// the rings visually scale with the active effect. Returns 0 ⇒
    /// handle collapses to a point (still drawn but invisible).
    protected abstract float handleSize() const;

    /// Every member of this closed wrapper family supplies an explicit result
    /// builder. Keeping this abstract makes the capability a subclass compile-
    /// time obligation instead of a dynamic fallback decision.
    protected abstract VertexPositionResultBuilder resultBuilder();

    /// Whether to draw the click-point handle during a drag. Defaults
    /// to true; subclasses whose haul has no meaningful world-space
    /// radius (e.g. Quantize, where the step magnitude is per-axis
    /// rather than a sphere) return false to suppress it.
    protected bool drawsClickHandle() const { return true; }

    // ---- Tool lifecycle ----------------------------------------------

    override void activate() {
        if (meshPtr is null) return;
        reinitSession();
        clickHandle = new ClickPointHandler();
    }

    final PreparedCommandWrapperActivationImage buildPreparedActivation()
    {
        PreparedCommandWrapperActivationImage image;
        if (meshPtr is null) return image;
        image.valid = true;
        image.baseline = meshPtr.vertices.dup;
        image.falloffs = currentFalloffConfigs();
        image.clickHandle = new ClickPointHandler();
        return image;
    }

    final Mesh* preparedActivationMesh() nothrow @nogc { return meshPtr; }
    final bool preparedActivationMatches(Mesh* source, const(Vec3)[] vertices)
            nothrow @nogc {
        if (source is null || meshPtr !is source || source.vertices.length != vertices.length)
            return false;
        foreach (i; 0 .. vertices.length)
            if (source.vertices[i] != vertices[i]) return false;
        return true;
    }
    final void installPreparedActivation(ref PreparedCommandWrapperActivationImage image)
            nothrow @nogc {
        baseline = image.baseline; image.baseline = null;
        dirty = false; paramsDirty = false; dragging = false;
        refireDriving_ = false; refireCommitted_ = false;
        lastAppliedFalloffs = image.falloffs; image.falloffs = null;
        clickHandle = image.clickHandle; image.clickHandle = null;
        clearResultState();
        image.valid = false;
    }
    final PreparedSessionActivateEffect prepareActivate(PreparedRecordContext context) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.CommandWrapper, false);
        scope(failure) { context.discard(); }
        auto owner = PreparedCommandWrapperActivationOwner.prepare(this);
        bool ok = owner !is null && context.prepareCommandWrapperActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) { context.discard(); }
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.CommandWrapper, ok);
    }

    override bool prepareDoorActivate(PreparedRecordContext context, Layer,
            ulong, ulong) {
        return prepareActivate(context).accepted;
    }

    version(unittest) final ClickPointHandler seedPreparedActivationForTest() {
        baseline = [Vec3(91, 92, 93)];
        lastAppliedFalloffs = [FalloffPacket.init];
        dirty = paramsDirty = dragging = true;
        refireDriving_ = refireCommitted_ = true;
        clickHandle = new ClickPointHandler();
        return clickHandle;
    }
    version(unittest) final bool preparedActivationInstalledForTest(
            ClickPointHandler oldHandle = null) {
        if (baseline.length != (meshPtr is null ? 0 : meshPtr.vertices.length) ||
            clickHandle is null || clickHandle is oldHandle || dirty || paramsDirty ||
            dragging || refireDriving_ || refireCommitted_) return false;
        foreach (i; 0 .. baseline.length)
            if (baseline[i] != meshPtr.vertices[i]) return false;
        return falloffSetsEqual(lastAppliedFalloffs, currentFalloffConfigs());
    }

    // (Re)capture the session baseline from the CURRENT mesh — shared by
    // activate() and resyncSession() (undo/redo migration P1) so the two can't
    // drift. The deform drag reverts to `baseline` every motion event, so after
    // a committed history pop moved geometry beneath the active tool the stale
    // baseline would restore the pre-undo mesh on the next LMB-down; re-dup'ing
    // here pins it to the now-current mesh. Does NOT create clickHandle (that is
    // one-time activation wiring).
    private void reinitSession() {
        if (meshPtr is null) return;
        baseline = meshPtr.vertices.dup;
        dirty       = false;
        paramsDirty = false;   // a restore-fired onParamChanged (sticky-tool-
                                // defaults restore runs BEFORE activate()) must
                                // not survive into the first evaluate() as a
                                // whole-mesh deform against an empty selection.
        refireDriving_   = false;
        refireCommitted_ = false;
        clearResultState();
        // Seed the falloff-change baseline to the CURRENT global pipe state.
        // `lastAppliedFalloffs` starts empty (`[]`) on every freshly
        // constructed instance (first activation OR reactivation — it is
        // per-instance bookkeeping, never restored), while a persistent WGHT
        // stage normally exists in the pipe from app init onward (even when
        // inactive), so `currentFalloffConfigs()` is almost never also empty.
        // Left un-seeded, evaluate()'s `falloffChanged` compare sees a bogus
        // mismatch on the FIRST post-activation evaluate() call regardless of
        // `paramsDirty` — a second, independent path to the same "deform on
        // activation" hazard the `paramsDirty` fix above guards against. On a
        // tool with no legacy schema panel (a Forms-driven tool — see
        // config/forms/*.yaml) this is unreachable (evaluate() only runs
        // there as a side effect of an actual `tool.attr` write, which would
        // trigger a re-apply anyway); on a tool without a form (e.g.
        // edge.slide) `property_panel.d`'s `drawProvider` calls `evaluate()`
        // unconditionally every drawn frame, so it is otherwise directly
        // reachable with zero user action.
        lastAppliedFalloffs = currentFalloffConfigs();
    }

    override void deactivate() {
        // Commit the open edit on tool exit (same as the
        // `TransformTool.deactivate` pattern). Spacebar →
        // app.d global handler → `dropActiveTool` → here.
        // Switching tools or closing the panel hits the same path.
        commitNow("");
        if (clickHandle !is null) {
            clickHandle.destroy();
            clickHandle = null;
        }
        // The falloff emitter is owned by the app-level PipeGizmoHost; the
        // tool only references it. Nothing to tear down here.
        baseline.length = 0;
        dirty    = false;
        dragging = false;
        refireDriving_   = false;
        refireCommitted_ = false;
        lastAppliedFalloffs.length = 0;
    }

    /// The P1.0b.4c.2 producer, and NOT dormant since 7844bfee: a tool SWITCH
    /// deactivates the outgoing wrapper through this, from inside `prepareArm`.
    /// That switch is its only production caller — every DROP transition is
    /// owned by `ActivationDoor.legacyDeactivate` and runs `deactivate()` above
    /// instead (task 4053 measured why; the table is
    /// source/tool_activation_ownership.d). The scalar reset the effect
    /// represents is never installed on this path and does not need to be: the
    /// tool is destroyed immediately after, on both doors.
    final PreparedDeactivateEffect prepareDeactivate(
            PreparedRecordContext context, ClickPointResourceOwner clickOwner) {
        if (context is null) return PreparedDeactivateEffect(
            preparedToolStateOwner, PreparedDeactivateKind.CommandWrapper, false, false);
        bool accepted;
        if (!refireCommitted_ && dirty && meshPtr !is null && history !is null &&
            gestureFactory !is null && baseline.length == meshPtr.vertices.length) {
            VertexPositionResult result;
            if (commitResult(result))
                if (auto cmd = carrierFromResult(result, name(), false))
                    accepted = context.prepare(cmd, PreparedHistoryKind.Plain).accepted;
        }
        // Legacy order is commitNow() followed by click-handle destruction.
        if (!context.markHistoryInstall()) {
            context.discard();
            return PreparedDeactivateEffect(preparedToolStateOwner,
                PreparedDeactivateKind.CommandWrapper, false, false);
        }
        bool resourceAccepted = clickHandle is null;
        if (clickHandle !is null) {
            if (clickOwner is null || !clickOwner.owns(clickHandle) ||
                !context.prepareDestroy(clickOwner)) {
                context.discard();
                accepted = false;
            }
            else resourceAccepted = true;
        }
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.CommandWrapper, accepted, resourceAccepted);
    }

    override bool prepareDoorDeactivate(PreparedRecordContext context, Layer,
            ulong threadIdentity, ulong contextIdentity) {
        auto owner = new ClickPointResourceOwner(clickHandle, threadIdentity,
            contextIdentity);
        return prepareDeactivate(context, owner).resourceAccepted;
    }

    // ----- History-coordination hooks (undo/redo migration P0) -------------
    //
    // Commit guard mirror: commitNow() early-returns unless `dirty` (:365), and
    // deactivate() is the only commit site, so `dirty` IS the "would commit now"
    // predicate.
    public override bool hasUncommittedEdit() const { return dirty; }

    // Framework "apply and continue" (task 0461, Shift+click) — task 0678 T7:
    // the wrapper never overrode this, so the base opt-out (`return false`)
    // silently made Shift+apply a no-op for every wrapper tool (XfrmSmooth /
    // XfrmJitter / XfrmQuantize / EdgeSlide) while 16 non-wrapper tools honour
    // the gesture. commitNow() is exactly the in-place finalize the contract
    // asks for — commit + record + rebaseline, no teardown (empty label falls
    // back to name()); the driver follows with resyncSession() to re-arm.
    public override bool commitUncommittedEdit() {
        if (!hasUncommittedEdit()) return false;
        // Forward what commitNow ACTUALLY did. Returning an unconditional
        // `true` broke applyAndContinue's stated contract ("true iff it
        // committed+rearmed") on five early-exit paths — worst of them the
        // consumed refire latch, where the geometry stays in the mesh, the
        // caller consumes the click, resyncSession rolls the change into the
        // new baseline, and no undo entry exists for it (task 0678 T7).
        return commitNow("");
    }

    // Category A cancel — restore the session baseline into the live mesh (the
    // same restore the new-drag LMB-down body does at :207) and clear `dirty`.
    // With dirty cleared, the subsequent deactivate()->commitNow() is a no-op,
    // so nothing is recorded.
    public override void cancelUncommittedEdit() {
        if (!dirty || meshPtr is null) return;
        if (baseline.length == meshPtr.vertices.length)
            meshPtr.vertices[] = baseline[];
        refreshCaches();
        dirty    = false;
        dragging = false;
        clearResultState();
    }

    // Resync after a committed undo/redo moved geometry beneath the active
    // tool (undo/redo migration P1): re-dup the deform baseline from the now-
    // current mesh and clear `dirty`, so the next drag reverts to the post-undo
    // geometry rather than the stale pre-undo snapshot. Only called when there
    // is no open edit (hasUncommittedEdit()==false), so nothing live is lost.
    public override void resyncSession() {
        reinitSession();
    }

    // ----- Refire hooks (undo/redo migration P4) ---------------------------
    //
    // Opt in iff the undo plumbing is wired (history + vertex-edit factory).
    // Tests / older callers that skip setGestureBindings() leave history null
    // and stay on the ordinary preview-then-commit path.
    public override bool wantsRefire() const {
        return history !is null && gestureFactory !is null;
    }

    // Build the MeshVertexEdit representing the CURRENT param state. All four
    // wrapper products use pure sparse-result builders: this method neither
    // edits/restores the live mesh nor refreshes display caches.
    public override Command buildRefireCommand() {
        if (meshPtr is null || history is null || gestureFactory is null)
            return null;
        if (baseline.length != meshPtr.vertices.length) return null;

        // Mark the session driving so the per-frame evaluate()/onParamChanged()
        // preview stays inert while the fired command owns mutation.
        refireDriving_ = true;

        if (!buildPilotResult(false)) return null;
        return cast(Command)carrierFromResult(latestResult_, name());
    }

    // Driver sets this around a param injection so the per-frame preview stays
    // inert while the fired command owns mutation (undo/redo migration P4).
    public override void setRefireDriving(bool on) {
        refireDriving_ = on;
    }

    // Called by the driver (app.d) once a refire session has committed its
    // single entry via refireEnd(). Latches the double-record guard so the
    // subsequent deactivate()->commitNow() skips recording, refreshes the
    // baseline to the now-committed geometry, and clears the driving flag.
    public override void onRefireCommitted() {
        refireDriving_   = false;
        refireCommitted_ = true;
        if (meshPtr !is null && baseline.length == meshPtr.vertices.length)
            baseline = meshPtr.vertices.dup;
        dirty = false;
        clearResultState();
    }

    // ---- drag interaction --------------------------------------------

    // Task 0209 (Quad/Split any-cell input): the projection to hit-test/
    // unproject against arrives WITH the event via SubjectPacket.viewport
    // (app.d's buildToolVts stamps `vpm.inputSnapshot()` — the hovered cell
    // outside a gesture, the drag-origin cell throughout one). Sync it into
    // `cachedVp` as the FIRST statement of every mouse handler, mirroring
    // XfrmTransformTool.syncInputViewport, so the down/motion math below
    // never depends on a stale value left by the last DRAW pass (which only
    // ran for the previous owner cell).
    private void syncInputViewport(ref VectorStack vts) {
        if (auto sp = vts.get!SubjectPacket()) cachedVp = sp.viewport;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        syncInputViewport(vts);
        if (e.button != SDL_BUTTON_LEFT) return false;
        // Skip alt/ctrl chords — camera owns those.
        auto modState = SDL_GetModState();
        if (modState & (KMOD_ALT | KMOD_CTRL)) return false;
        if (meshPtr is null) return false;

        // Falloff endpoint drag takes priority — same precedence move /
        // scale tools give it. Read the FalloffPacket from the dispatcher-
        // built vts (Phase 7), no extra pipeline walk needed.
        if (pipeGizmoHost !is null) {
            FalloffPacket fp;
            if (auto p = vts.get!FalloffPacket()) fp = *p;
            if (pipeGizmoHost.tryClaimDown(e, cachedVp, fp, pipeGizmoHost.ownPool()))
                return true;
        }

        // Restore baseline so this new drag starts from a clean slate
        // (cancels any previous drag's preview).
        meshPtr.vertices[] = baseline[];
        refreshCaches();
        dirty = false;
        latestResult_.clear();
        latestResultValid_ = false;

        dragStartX = e.x;
        dragStartY = e.y;
        dragging = true;

        // Project the click pixel onto the ACTIVE construction plane and put
        // the handle there. Clicking in the 3D viewport sets the tool into
        // interactive mode and draws its handle at the click point. Handle
        // visibility is gated on `dragging`, so it appears here and
        // disappears on LMB-up.
        //
        // This used to read `if (screenToWorkPlane(...)) setPos(hit);` against
        // the fixed world floor (Y = 0). Two defects in one line, task 0661:
        // the floor does not follow the view, so in any horizontal view the
        // click ray is exactly parallel to it and there is no intersection;
        // and the refusal had no `else`, so "could not" became "kept the
        // previous position" — the click looked registered and was not.
        // `screenToConstructionPlane` is TOTAL and the plane follows the view,
        // so there is no boolean left to drop.
        if (viewRef !is null && clickHandle !is null)
            clickHandle.setPos(screenToConstructionPlane(
                cast(float)e.x, cast(float)e.y, cachedVp));
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        syncInputViewport(vts);
        // Falloff endpoint drag — gizmo updates the FalloffStage's
        // attrs via tool.pipe.attr; the subsequent `evaluate()` tick
        // detects the live falloff change and re-applies the preview.
        if (pipeGizmoHost !is null && pipeGizmoHost.isDragging())
            return pipeGizmoHost.routeMotion(e, cachedVp);

        if (!dragging || meshPtr is null) return false;
        int dx = e.x - dragStartX;
        int dy = e.y - dragStartY;
        // Update inner Command's drag-modulated attrs first, then
        // rebuild the sparse result from the restored baseline.
        onDragDelta(dx, dy);
        if (applyWithLivePipeline()) dirty = true;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        syncInputViewport(vts);
        // Release falloff endpoint drag first — it consumes
        // independently of the tool's own drag.
        if (pipeGizmoHost !is null && pipeGizmoHost.routeUp(e))
            return true;
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (!dragging) return false;
        dragging = false;
        // Stay at previewed state — user can Apply, drag again to
        // refine, or Space to commit-and-drop.
        return true;
    }

    // ---- Apply button + draw -----------------------------------------

    override void drawProperties() {
        // Tool Properties panel renders param widgets via the host's
        // PropertyPanel first; this Apply button sits after them.
        // Empty label ⇒ commitNow() falls back to `name()` — the SAME entry
        // label every other commit path uses (Shift+apply, deactivate, Space).
        // Passing "Apply" here made one operation appear in the History panel
        // under two different names depending on which gesture finished it
        // (task 0685 T10); the operation's identity is the tool, the button is
        // just one way to reach it.
        if (ImGui.Button("Apply"))
            commitNow("");
    }

    override void onParamChanged(string name) {
        // While a refire session is driving this tool the fired
        // buildRefireCommand() owns the mutation — don't queue an internal
        // preview (it would double-apply against the same baseline in the same
        // tick). Outside refire this is the ordinary preview path.
        auto prepared = prepareParamChange(name);
        WrapperPreparedParamHandle handle;
        if (validatePreparedParam(prepared, handle)) installLegacyPreparedParam(handle);
    }

    override bool prepareDoorParamChanged(string name, PreparedRecordContext,
            Layer, ulong, ulong) {
        auto prepared = prepareParamChange(name);
        WrapperPreparedParamHandle handle;
        if (!validatePreparedParam(prepared, handle)) return false;
        installLegacyPreparedParam(handle);
        return true;
    }

private:
    PreparedParamDelta prepareParamChange(string) const nothrow @nogc {
        if (refireDriving_) return PreparedParamDelta.none(preparedToolStateOwner);
        return PreparedParamDelta.dirty(preparedToolStateOwner);
    }
    bool validatePreparedParam(ref PreparedParamDelta prepared,
                               out WrapperPreparedParamHandle handle) nothrow @nogc {
        if (prepared.owner != preparedToolStateOwner) return false;
        if (prepared.kind == PreparedParamKind.None) {
            handle = WrapperPreparedParamHandle(false, true); return true;
        }
        if (prepared.kind != PreparedParamKind.DirtyFlag || !prepared.boolValue) return false;
        handle = WrapperPreparedParamHandle(true, true); return true;
    }
    void installLegacyPreparedParam(ref WrapperPreparedParamHandle handle) nothrow @nogc {
        if (!handle.consumable) return;
        handle.consumable = false;
        // A schema widget changed.  The session-owned batch finish calls
        // evaluate() once after all notifications, so a single widget batch
        // with multiple writes still produces one re-apply.
        if (handle.applyDirty) paramsDirty = true;
    }
public:

    override void evaluate() { evaluateChangedParameters(); }

    /// Falloff packets can change without a tool widget event.  This family's
    /// explicit frame capability keeps observing that external input after
    /// blanket PropertyPanel evaluation is removed.
    override void evaluateParameterFrame() { evaluateChangedParameters(); }

private:
    void evaluateChangedParameters() {
        if (meshPtr is null) return;
        // A refire session owns the mutation via fired commands; skip the
        // internal preview re-run so the two paths never both touch the mesh.
        if (refireDriving_) return;
        // Detect a live falloff change — the FalloffStage's panel
        // widgets fire onParamChanged on the stage (not on this
        // Tool), so the wrapper's `paramsDirty` flag stays false on
        // a falloff edit. Without this branch the viewport wouldn't
        // refresh until the next drag or Apply click. Mirrors
        // MoveTool / ScaleTool / RotateTool's update()-time
        // falloffPacketsEqual detection.
        bool falloffChanged = false;
        {
            import toolpipe.pipeline : g_pipeCtx;
            if (g_pipeCtx !is null) {
                // Task 1904 Stage 5: `editMode` stays the hardcoded literal
                // `EditMode.Vertices` (plan §12 Q3 default: freeze, pending
                // owner — the live edit mode is deliberately NOT wired
                // here). `selType` was never set either (one of plan §1.3's
                // seven sites), so it is now frozen at `SelType.Vertex`
                // explicitly, through the funnel.
                import toolpipe.subject : evaluateSubject, SubjectSource;
                SubjectPacket subj;
                VectorStack   vts;
                evaluateSubject(subj, vts,
                    SubjectSource(meshPtr, EditMode.Vertices, SelType.Vertex, cachedVp));
                // SET-aware: compare the per-stage config set, so a tweak to
                // ANY stacked falloff (or an add/remove) refreshes the preview,
                // not just the primary. Single-falloff = 1-element compare.
                falloffChanged = !falloffSetsEqual(currentFalloffConfigs(),
                                                   lastAppliedFalloffs);
            }
        }
        if (!paramsDirty && !falloffChanged) return;
        paramsDirty = false;
        // Same dispatch as drag-motion — Operator path with toolpipe
        // walked once. applyWithLivePipeline handles baseline restore.
        if (applyWithLivePipeline()) dirty = true;
    }

public:

    // Falloff packet equality lives in source/falloff.d — pulled in via
    // the local import alias below. The earlier in-class duplicate was
    // missing lasso fields (would freeze the preview on Lasso edits).

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts,
                       const ref DrawPlan plan, bool visualOnly = false) {
        // Cache the live viewport so pushFalloffToInner has projection
        // matrices ready (Screen / Lasso falloff types need them; the
        // others ignore vp). Task 0206: gate on the interactive (owner-cell)
        // draw only — see Tool.draw's doc comment.
        if (!visualOnly) cachedVp = vp;

        // Passive falloff overlay (gradient lines / sphere wireframe /
        // disc / lasso polygon). Reads the dispatcher-built vts —
        // Phase 7 means no local pipeline.evaluate; same data as
        // every other Tool sees this frame.
        FalloffPacket fp;
        if (auto p = vts.get!FalloffPacket()) fp = *p;
        // CommandWrapper has NO gizmo banks, so the falloff emitter has
        // nothing to co-arbitrate — drive the host's FULL-cycle draw on the
        // host's OWN pool, exactly like the no-tool path (host.draw folds in
        // the fp.enabled gate + the whole begin/register/setHaul/update/draw
        // arbiter cycle for the GL handles; the ImGui ring/sphere overlay is
        // emitted separately, once per cell, from the app.d `Viewport##k`
        // window loop — task 0213). `visualOnly` forwards straight through —
        // PipeGizmoHost.draw skips its own register/update cycle for a
        // foreign-cell replica (see its doc comment); the click-point handle
        // below is world-derived and safe to draw in every cell
        // unconditionally.
        if (pipeGizmoHost !is null)
            pipeGizmoHost.draw(shader, vp, fp, pipeGizmoHost.ownPool(), visualOnly);

        // Click-point handle. Drawn only while LMB is held — appears
        // on first click, disappears on release. World size matches
        // the current attribute magnitude.
        if (!dragging || clickHandle is null) return;
        if (!drawsClickHandle()) return;
        import std.math : abs;
        float sz = abs(handleSize());
        if (sz < 1e-6f) return;          // collapsed to a point; skip
        clickHandle.setWorldSize(sz);
        clickHandle.draw(shader, vp);
    }

    // ---- helpers -----------------------------------------------------

    /// Build a MeshVertexEdit(before=baseline, after=current) and
    /// record on history. Refreshes baseline to current state so the
    /// next drag composes on top. `label` is the human-readable
    /// history entry name; empty defaults to the tool's name().
    /// Returns TRUE only when this call actually recorded a history entry.
    /// Every early exit below is a path where the mesh may still be dirty-ish
    /// but NOTHING landed in history, and the Shift+apply contract
    /// (EditSession.applyAndContinue) keys the caller's "consume the click"
    /// decision on that distinction (task 0678 T7 follow-up).
    private bool commitNow(string label) {
        // Double-record guard (undo/redo migration P4 — the single commit
        // chokepoint). A refire session already landed its single entry via
        // refireEnd(); the deactivate()/Apply commitNow() that follows MUST NOT
        // record a second entry for the same edit. Consume the latch and bail —
        // the baseline was already advanced in onRefireCommitted().
        if (refireCommitted_) {
            refireCommitted_ = false;
            dirty = false;
            return false;
        }
        if (!dirty)              return false;
        if (meshPtr is null)     return false;
        if (history is null)     return false;
        if (gestureFactory is null) return false;
        if (baseline.length != meshPtr.vertices.length) {
            // Topology changed mid-session (shouldn't happen for
            // smooth/jitter/quantize); refuse to commit a malformed
            // diff. Fall back to restoring baseline so the mesh
            // stays consistent.
            baseline.length = 0;
            dirty = false;
            return false;
        }
        VertexPositionResult result;
        if (!commitResult(result)) {
            dirty = false;
            return false;
        }
        debug assert(liveHoldsResult(result),
            "CommandWrapperTool.commitNow: cached result does not match live preview");
        auto cmd = carrierFromResult(result,
            label.length > 0 ? label : name());
        if (cmd is null) return false;
        // THE EIGHTH EARLY EXIT, and it keeps the invariant this method is the
        // model for. `recordGestureEdit` is false only when the seam's belt
        // refused (a carrier with nothing in it) — unreachable from here,
        // because `indices.length == 0` already returned above and
        // `MeshVertexEdit.hasGesturePayload()` is `!isEmpty()` over exactly
        // that array. Unreachable is not the same as absent: answering `true`
        // on a refusal would rebaseline over geometry with no undo entry, which
        // is the precise failure the T7 follow-up below tests for on the refire
        // latch. `dirty` deliberately stays SET on this path — there is still
        // an uncommitted edit.
        if (!recordGestureEdit(cmd, GestureRecordMode.Plain)) return false;

        // Promote post-commit state to the new baseline so subsequent
        // drags compose on top of it. On Apply the current action is
        // fixed into the geometry and future drags start fresh.
        baseline = meshPtr.vertices.dup;
        dirty    = false;
        clearResultState();
        return true;
    }

    // Per-stage falloff CONFIG snapshot for the live-change trigger — one
    // FalloffPacket per ACTIVE falloff stage, in pipe order. Mirrors the R/S
    // sub-tools' set-aware view: a change to ANY stacked instance (or an
    // add/remove) is detected by comparing this set frame-to-frame. With a
    // single active falloff this is a 1-element array (the primary's config),
    // identical to the prior single-packet trigger.
    private FalloffPacket[] currentFalloffConfigs() {
        import toolpipe.pipeline       : g_pipeCtx;
        import toolpipe.stage          : TaskCode;
        import toolpipe.stages.falloff : FalloffStage;
        FalloffPacket[] cfgs;
        if (g_pipeCtx is null) return cfgs;
        foreach (s; g_pipeCtx.pipeline.findAllByTask(TaskCode.Wght))
            if (auto fs = cast(FalloffStage) s)
                cfgs ~= fs.snapshotConfigToPacket();
        return cfgs;
    }

    // Set equality for the live-change trigger: a change fires when the COUNT
    // differs (instance added/removed) or any per-stage config differs.
    private static bool falloffSetsEqual(const FalloffPacket[] a,
                                         const FalloffPacket[] b) {
        import falloff : falloffPacketsEqual;
        if (a.length != b.length) return false;
        foreach (i; 0 .. a.length)
            if (!falloffPacketsEqual(a[i], b[i])) return false;
        return true;
    }

    private void clearResultState() nothrow @nogc {
        latestResult_.clear();
        latestResultValid_ = false;
        resultFalloff_ = FalloffPacket.init;
        resultPipeValid_ = false;
        resultFalloffPresent_ = false;
    }

    /// Build a deterministic inner command's result from the explicit session
    /// baseline. A fresh
    /// pipeline walk is done only while the live mesh is known to hold that
    /// baseline (preview restores it immediately above). Refire after a live
    /// preview reuses the owned cooked falloff packet, so command construction
    /// never needs a temporary live-mesh rollback.
    private bool buildPilotResult(bool freshPipeline) {
        auto builder = resultBuilder();
        // Both halves, and they are not redundant: the assert names the guilty
        // subclass in debug, the `if` is the only one of the two that survives
        // a release build (`--build=release --d-version=ReleaseBuild` in CI cuts
        // asserts, and `builder` is dereferenced below). The language guarantees
        // the override is DECLARED, never that it returns non-null.
        assert(builder !is null,
            "CommandWrapperTool subclass returned no result builder");
        if (builder is null) return false;
        if (meshPtr is null || baseline.length != meshPtr.vertices.length)
            return false;

        SubjectPacket subj;
        VectorStack vts;
        if (freshPipeline || !resultPipeValid_) {
            import toolpipe.subject : evaluateSubject, SubjectSource;
            evaluateSubject(subj, vts,
                SubjectSource(meshPtr, EditMode.Vertices, SelType.Vertex, cachedVp));
            if (auto fp = vts.get!FalloffPacket()) {
                resultFalloff_ = fp.ownedDup();
                resultFalloffPresent_ = true;
            } else {
                resultFalloff_ = FalloffPacket.init;
                resultFalloffPresent_ = false;
            }
            resultPipeValid_ = true;
        } else {
            import toolpipe.subject : fillSubject, SubjectSource;
            fillSubject(subj,
                SubjectSource(meshPtr, EditMode.Vertices, SelType.Vertex, cachedVp));
            vts.put(&subj);
            if (resultFalloffPresent_) vts.put(&resultFalloff_);
        }
        lastAppliedFalloffs = currentFalloffConfigs();

        VertexPositionResult built;
        if (!builder.buildVertexPositionResult(baseline, vts, built)) {
            latestResult_.clear();
            latestResultValid_ = false;
            return false;
        }
        latestResult_ = built;
        latestResultValid_ = true;
        return true;
    }

    private bool liveHoldsResult(ref const VertexPositionResult result) const {
        if (meshPtr is null || baseline.length != meshPtr.vertices.length ||
            result.indices.length != result.before.length ||
            result.indices.length != result.after.length) return false;

        size_t liveDiffs;
        foreach (i; 0 .. meshPtr.vertices.length)
            if (meshPtr.vertices[i] != baseline[i]) ++liveDiffs;
        if (liveDiffs != result.indices.length) return false;

        foreach (i, vi; result.indices) {
            if (vi >= meshPtr.vertices.length || result.before[i] != baseline[vi] ||
                result.after[i] == result.before[i] ||
                meshPtr.vertices[vi] != result.after[i]) return false;
        }
        return true;
    }

    private bool commitResult(out VertexPositionResult result) {
        if (!latestResultValid_ || latestResult_.empty) return false;
        result = latestResult_;
        return true;
    }

    private MeshVertexEdit carrierFromResult(ref VertexPositionResult result,
                                             string label,
                                             bool reportMismatch = true) {
        if (result.empty) return null;
        auto cmd = cast(MeshVertexEdit)gestureFactory();
        if (cmd is null) {
            if (reportMismatch) noteGestureCarrierMismatch();
            return null;
        }
        cmd.setEdit(result.indices, result.before, result.after, label);
        return cmd;
    }

    private void installPilotPreview() {
        import change_bus : MeshEditScope;
        import mesh : MeshEditBatch;
        auto ed = MeshEditBatch.unrecorded(*meshPtr, MeshEditScope.Position);
        ed.setVertexPositions(latestResult_.indices, latestResult_.after);
        ed.commitChange(MeshEditScope.Position);
        ed.close();
    }

    private bool applyWithLivePipeline() {
        if (meshPtr is null) return false;

        // Restore baseline so apply runs against pre-drag state.
        meshPtr.vertices[] = baseline[];

        // Build once from the explicit baseline, then install the sparse
        // preview. The builder itself performs no scene mutation.
        if (!buildPilotResult(true)) return false;
        installPilotPreview();
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplay(meshPtr, gpu);
    }
}


// ---------------------------------------------------------------------------
// Concrete wrappers.
// ---------------------------------------------------------------------------

final class XfrmSmoothTool : CommandWrapperTool {
    private MeshSmooth inner_;
    private float      lastStrn;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu) {
        inner_ = new MeshSmooth(mesh, view, editMode);
        inner  = inner_;
        meshPtr = mesh;
        viewRef = view;
        this.gpu = gpu;
    }

    override string name() const { return "xfrm.smooth"; }

    protected override VertexPositionResultBuilder resultBuilder() { return inner_; }

    protected override void onDragDelta(int dx, int dy) {
        import std.algorithm : clamp;
        import std.math : abs;
        lastStrn = clamp(cast(float)dx * 0.005f, 0.0f, 1.0f);
        int iter  = 1 + abs(dy) / 30;
        inner_.setStrn(lastStrn);
        inner_.setIter(iter);
    }

    protected override float handleSize() const { return lastStrn; }

    // Smooth's strength is a unitless 0..1 blend, not a world-space
    // radius — the sphere-with-rings handle would be misleading, so
    // suppress it.
    protected override bool drawsClickHandle() const { return false; }
}

final class XfrmJitterTool : CommandWrapperTool {
    private MeshJitter inner_;
    private float      lastRange;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu) {
        inner_ = new MeshJitter(mesh, view, editMode);
        inner  = inner_;
        meshPtr = mesh;
        viewRef = view;
        this.gpu = gpu;
    }

    override string name() const { return "xfrm.jitter"; }

    protected override VertexPositionResultBuilder resultBuilder() { return inner_; }

    protected override void onDragDelta(int dx, int dy) {
        // jitter haul is 1-D along the horizontal axis — only
        // X-mouse-motion changes Range. Drag right (dx > 0) grows
        // Range; drag left (dx < 0) gives a negative Range (the random
        // offset is still drawn from [-1, 1) per axis — sign of Range
        // just flips the random pattern but the visual effect is the
        // same distribution).
        // Signed dx also keeps the value monotonic across the click
        // point: no V-shape on cursor return, the value just passes
        // through 0 once.
        lastRange = cast(float)dx * 0.005f;
        inner_.setScale(lastRange, lastRange, lastRange);
    }

    protected override float handleSize() const { return lastRange; }
}

final class XfrmQuantizeTool : CommandWrapperTool {
    private MeshQuantize inner_;
    private float        lastStep;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu) {
        inner_ = new MeshQuantize(mesh, view, editMode);
        inner  = inner_;
        meshPtr = mesh;
        viewRef = view;
        this.gpu = gpu;
    }

    override string name() const { return "xfrm.quantize"; }

    protected override VertexPositionResultBuilder resultBuilder() { return inner_; }

    protected override void onDragDelta(int dx, int dy) {
        import std.algorithm : max;
        import std.math : abs;
        lastStep = max(1e-3f, cast(float)abs(dx) * 0.005f);
        // Uniform across axes; the haul writes all 3 from the primary
        // mouse axis. UI sliders can override per-axis later.
        inner_.setStepXYZ(lastStep, lastStep, lastStep);
    }

    protected override float handleSize() const { return lastStep; }

    // Quantize's step is per-axis, not a world-space radius — there's
    // no meaningful sphere to draw, so suppress the click-point handle.
    protected override bool drawsClickHandle() const { return false; }
}

unittest {
    import mesh : makeCube;
    Mesh m = makeCube();
    View view = new View(0, 0, 800, 600);
    auto tool = new XfrmJitterTool(&m, view, EditMode.Vertices, null);

    tool.paramsDirty = false;
    auto prepared = tool.prepareParamChange("amplitude");
    assert(!tool.paramsDirty && prepared.kind == PreparedParamKind.DirtyFlag);
    WrapperPreparedParamHandle handle;
    assert(tool.validatePreparedParam(prepared, handle));
    tool.installLegacyPreparedParam(handle);
    assert(tool.paramsDirty);
    tool.paramsDirty = false;
    tool.installLegacyPreparedParam(handle);
    assert(!tool.paramsDirty); // one-shot handle cannot replay

    tool.refireDriving_ = true;
    auto suppressed = tool.prepareParamChange("amplitude");
    assert(suppressed.kind == PreparedParamKind.None);
    assert(tool.validatePreparedParam(suppressed, handle));
    tool.installLegacyPreparedParam(handle);
    assert(!tool.paramsDirty);

    import prepared_record_context : PreparedRecordContext;
    import record_observer_hub : RecordObserverHub;
    import handler : ClickPointResourceOwner;
    auto preparedHistory = new CommandHistory();
    auto preparedHub = new RecordObserverHub();
    tool.clickHandle = new ClickPointHandler();
    auto clickOwner = new ClickPointResourceOwner(tool.clickHandle, 7, 11);
    auto context = new PreparedRecordContext(preparedHistory, preparedHub);
    context.setResourceIdentity(7, 11);
    auto deactivation = tool.prepareDeactivate(context, clickOwner);
    assert(deactivation.kind == PreparedDeactivateKind.CommandWrapper);
    assert(deactivation.resourceAccepted && context.validate());
    context.install();
    context.install(); // consumed journal cannot replay
}

static assert(!__traits(compiles, {
    WrapperPreparedParamHandle a; WrapperPreparedParamHandle b = a;
}));

// task 0678 T7 — Shift+apply (task 0461) must work for wrapper tools: a dirty
// session commits IN PLACE (one history entry, baseline advanced, dirty
// cleared) and reports true, so EditSession.applyAndContinue proceeds to
// resyncSession.  Before the fix CommandWrapperTool kept the base opt-out
// (`return false`), silently no-op'ing the gesture for XfrmSmooth /
// XfrmJitter / XfrmQuantize / EdgeSlide while 16 non-wrapper tools honour it.
unittest {
    import mesh : makeCube;
    import command_history : CommandHistory;
    import commands.mesh.vertex_edit : MeshVertexEdit;

    Mesh m = makeCube();
    m.buildLoops();
    View view = new View(0, 0, 800, 600);
    auto hist = new CommandHistory();
    auto t = new XfrmSmoothTool(&m, view, EditMode.Vertices, null);
    t.setGestureBindings(hist, () => new MeshVertexEdit(&m, view, EditMode.Vertices));

    // Count entries through the history's own record hook, throughout. task
    // 0685 T2: `canUndo()` only proves "the stack is non-empty" — it stays
    // green for a commit that recorded two entries, or none of its own on top
    // of an earlier one. The refire-latch half of this test below already
    // counted; this is the same technique applied to the whole test.
    size_t recorded = 0;
    hist.onRecord = (string, uint) { ++recorded; };

    // Idle tool: no open edit — the opt-out contract (nothing recorded).
    assert(!t.commitUncommittedEdit(), "no open edit must return false");
    assert(recorded == 0, "idle commit must not record");
    assert(!hist.canUndo(), "idle commit must leave nothing to undo");

    // Open a session by hand (same module => private access): baseline = the
    // pre-edit geometry, then build/install the deterministic Smooth result —
    // exactly the state a live wrapper drag leaves behind.
    t.baseline = m.vertices.dup;
    foreach (ref p; t.params()) {
        if (p.name == "strn") *p.fptr = 0.8f;
        if (p.name == "iter") *p.iptr = 2;
    }
    assert(t.buildPilotResult(true));
    t.installPilotPreview();
    t.dirty = true;

    assert(t.commitUncommittedEdit(), "dirty wrapper session must commit in place");
    assert(!t.hasUncommittedEdit(), "commit must close the open edit");
    assert(recorded == 1, "in-place commit must record exactly ONE entry");
    assert(hist.canUndo(), "and that entry must be on the undo stack");
    assert(t.baseline.length == m.vertices.length
           && t.baseline[0].x == m.vertices[0].x,
           "baseline must advance to the committed geometry");

    // task 0678 T7 follow-up — the hook must report what commitNow ACTUALLY
    // did, not "I was dirty". The consumed-refire-latch path is the one that
    // bites: it clears `dirty` and records NOTHING, so answering true there
    // makes the caller consume the click and rebaseline over geometry that has
    // no undo entry.
    //
    // THE ORDER OF THE NEXT TWO LINES IS THE WHOLE CELL, and it was WRONG here
    // until task 1905 phase D measured it. This block used to latch the refire
    // AFTER setting `dirty`, and `onRefireCommitted()`'s last statement is
    // `dirty = false`. So `commitUncommittedEdit()` refused at its OWN first
    // guard (`if (!hasUncommittedEdit()) return false;`) and `commitNow` was
    // never entered: the latch branch this cell is named after was not
    // reached, and both assertions below were satisfied by a second, unnamed
    // guard. Proved by mutation, not by reading — turning the latch branch's
    // `return false` into `return true` (the exact defect the comment above
    // describes) left `dub test --config=tests` at 386/386 GREEN.
    //
    // Latching FIRST and re-dirtying after is also the reachable production
    // state, not a contrivance: a refire session commits (latch set, `dirty`
    // cleared), the user drags again (`dirty` true, latch still standing
    // because only `commitNow` consumes it), and Shift+LMB then arrives with
    // BOTH true. That is the one shape in which answering `true` makes
    // `applyAndContinue` consume the click and `resyncSession` rebaseline over
    // an edit with no undo entry.
    recorded = 0;

    t.baseline = m.vertices.dup;
    m.vertices[1] = m.vertices[1] + Vec3(0, 0.25f, 0);
    t.onRefireCommitted();            // latches refireCommitted_, clears dirty
    t.dirty = true;                   // ... and the NEXT drag reopens the session
    assert(t.hasUncommittedEdit(),
           "control: the latch branch is only reachable while the session is "
         ~ "open — without this the assertion below is answered by "
         ~ "commitUncommittedEdit's own !dirty guard and cannot fail");
    assert(!t.commitUncommittedEdit(),
           "a commit that recorded nothing must not report success");
    assert(recorded == 0, "the latched path must not record an entry");
}

// task 1905 criterion 3 — the SAME drill over the other two wrapper tools
// declared in this module. The cell above proves the contract for ONE of the
// four (XfrmSmooth); measured 2026-08-29, `xfrm.jitter` and `xfrm.quantize`
// appear in ZERO tests under `tests/` (`grep -rln 'xfrm.jitter' tests/*.d` is
// empty), so before this block their half of "closed by construction" rested on
// inheritance alone.
//
// Inheritance IS the mechanism and it is asserted exactly, at compile time, in
// `tests/unit/wrapper_shift_apply_inheritance_test.d` — including the case that
// file's own probe showed a single assertion cannot see (the family's override
// deleted, all four falling back to `Tool`'s opt-out TOGETHER). What that
// cannot show is that the inherited body still RUNS to a recorded entry for a
// tool whose `inner` command is a different one, which is what this block adds.
//
// EdgeSlideTool is deliberately absent: it lives in `tools/slice/edge_slide.d`
// and importing it here would close an import cycle. It is covered by the
// compile-time file above, and the gap is named in card 3330 rather than
// pretended away.
unittest {
    import mesh : makeCube;
    import command_history : CommandHistory;
    import commands.mesh.vertex_edit : MeshVertexEdit;
    import std.meta : AliasSeq;

    static foreach (TWrap; AliasSeq!(XfrmJitterTool, XfrmQuantizeTool)) {{
        Mesh m = makeCube();
        m.buildLoops();
        View view = new View(0, 0, 800, 600);
        auto hist = new CommandHistory();
        auto t = new TWrap(&m, view, EditMode.Vertices, null);
        t.setGestureBindings(hist, () => new MeshVertexEdit(&m, view, EditMode.Vertices));

        size_t recorded = 0;
        hist.onRecord = (string, uint) { ++recorded; };

        // Idle: the opt-out contract.
        assert(!t.commitUncommittedEdit(),
            TWrap.stringof ~ ": no open edit must return false");
        assert(recorded == 0,
            TWrap.stringof ~ ": idle commit must not record");

        // A live wrapper drag's leftovers. Both commands enter through their
        // result builders, including EdgeSlide.
        t.baseline = m.vertices.dup;
        static if (is(TWrap == XfrmQuantizeTool)) {
            foreach (ref p; t.params())
                if (p.name == "X" || p.name == "Y" || p.name == "Z")
                    *p.fptr = 0.3f;
            assert(t.buildPilotResult(true));
            t.installPilotPreview();
        } else {
            foreach (ref p; t.params()) {
                if (p.name == "rangeX") *p.fptr = 0.25f;
                if (p.name == "rangeY" || p.name == "rangeZ") *p.fptr = 0.0f;
            }
            assert(t.buildPilotResult(true));
            t.installPilotPreview();
        }
        t.dirty = true;

        assert(t.commitUncommittedEdit(),
            TWrap.stringof ~ ": dirty wrapper session must commit in place");
        assert(recorded == 1,
            TWrap.stringof ~ ": in-place commit must record exactly ONE entry");
        assert(!t.hasUncommittedEdit(),
            TWrap.stringof ~ ": commit must close the open edit");

        // And the invariant, on the path that actually bites. Latch FIRST,
        // re-dirty after — see the long note in the cell above: the other
        // order is refused by `commitUncommittedEdit`'s own `!dirty` guard and
        // never enters `commitNow` at all.
        recorded = 0;
        t.baseline = m.vertices.dup;
        m.vertices[1] = m.vertices[1] + Vec3(0, 0.25f, 0);
        t.onRefireCommitted();
        t.dirty = true;
        assert(t.hasUncommittedEdit(),
            TWrap.stringof ~ ": control — the latch branch needs an open session");
        assert(!t.commitUncommittedEdit(),
            TWrap.stringof ~ ": a commit that recorded nothing must not report success");
        assert(recorded == 0,
            TWrap.stringof ~ ": the latched path must not record an entry");

        // The result-builder arm must never record an `after` image that the
        // live preview did not actually install. This exercises the debug
        // contract at commitNow rather than manufacturing a valid preview.
        static if (is(TWrap == XfrmQuantizeTool)) {
            import core.exception : AssertError;
            import std.exception : assertThrown;
            Mesh divergent = makeCube();
            divergent.buildLoops();
            auto divergentHistory = new CommandHistory();
            auto divergentTool = new XfrmQuantizeTool(
                &divergent, view, EditMode.Vertices, null);
            divergentTool.setGestureBindings(divergentHistory,
                () => new MeshVertexEdit(&divergent, view, EditMode.Vertices));
            divergentTool.baseline = divergent.vertices.dup;
            foreach (ref p; divergentTool.params())
                if (p.name == "X" || p.name == "Y" || p.name == "Z")
                    *p.fptr = 0.3f;
            assert(divergentTool.buildPilotResult(true));
            divergentTool.dirty = true;
            assertThrown!AssertError(divergentTool.commitUncommittedEdit());

            // Task 4590: a panel-closed refire through the cached R6 result
            // path must acknowledge the falloff config it consumed.  The
            // following explicit frame tick must then be a strict no-op: a
            // stale cache would silently publish Position again every frame.
            import change_bus : changeBus;
            import display_sync : activeMeshResolver;
            import edit_session : EditSession;
            import toolpipe.pipeline : g_pipeCtx, ToolPipeContext;
            import toolpipe.stages.falloff : FalloffStage;

            auto savedPipe = g_pipeCtx;
            scope(exit) g_pipeCtx = savedPipe;
            auto savedResolver = activeMeshResolver;
            Mesh offscreenMesh = makeCube();
            activeMeshResolver = () => &offscreenMesh;
            scope(exit) activeMeshResolver = savedResolver;
            Mesh cacheMesh = makeCube();
            cacheMesh.buildLoops();
            Mesh* cacheMeshPtr = &cacheMesh;
            EditMode cacheMode = EditMode.Vertices;
            auto pipe = new ToolPipeContext();
            pipe.pipeline.add(new FalloffStage(() => cacheMeshPtr, &cacheMode));
            g_pipeCtx = pipe;

            auto cacheHistory = new CommandHistory();
            auto cacheTool = new XfrmQuantizeTool(
                cacheMeshPtr, view, cacheMode, null);
            cacheTool.setGestureBindings(cacheHistory,
                () => new MeshVertexEdit(cacheMeshPtr, view, cacheMode));
            cacheTool.activate();
            foreach (ref p; cacheTool.params())
                if (p.name == "X" || p.name == "Y" || p.name == "Z")
                    *p.fptr = 0.3f;
            assert(cacheTool.buildPilotResult(true));
            assert(cacheTool.resultPipeValid_,
                "control: Quantize must hold a reusable cooked pipeline result");
            assert(cacheTool.currentFalloffConfigs().length == 1,
                "control: the cache witness needs one live falloff config");
            cacheTool.lastAppliedFalloffs = null;
            assert(!cacheTool.falloffSetsEqual(cacheTool.lastAppliedFalloffs,
                                               cacheTool.currentFalloffConfigs()),
                "control: the refire must begin with a deliberately stale cache");

            cacheHistory.refireBegin();
            auto cachedRefire = cacheTool.buildRefireCommand();
            assert(cachedRefire !is null,
                "control: cached Quantize refire must build a populated carrier");
            assert(cacheHistory.fire(cachedRefire),
                "control: cached Quantize refire carrier must apply");
            cacheHistory.refireEnd();
            cacheTool.onRefireCommitted();
            assert(cacheTool.falloffSetsEqual(cacheTool.lastAppliedFalloffs,
                                              cacheTool.currentFalloffConfigs()),
                "cached Quantize refire must record the applied falloff config");

            auto session = new EditSession(
                () => cast(Tool)cacheTool, cacheHistory, () {});
            const liveAfterRefire = cacheMesh.vertices.dup;
            const deliveriesAfterRefire = changeBus.deliveryCount;
            const positionsAfterRefire = changeBus.totalPosition;
            session.tickParameterEvaluation();
            assert(cacheMesh.vertices == liveAfterRefire,
                "unchanged frame tick moved the panel-closed Quantize result");
            assert(changeBus.deliveryCount == deliveriesAfterRefire &&
                   changeBus.totalPosition == positionsAfterRefire,
                "unchanged frame tick re-published the panel-closed Quantize result");
        }
    }}
}
