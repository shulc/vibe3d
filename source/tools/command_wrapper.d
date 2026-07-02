module tools.command_wrapper;

import bindbc.sdl;

import command : Command;
import mesh    : Mesh, GpuMesh;
import view    : View;
import editmode : EditMode;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;
import tool   : Tool;
import params : Param;
import math   : Vec3, Viewport, screenToWorkPlane;
import shader : Shader;
import handler : ClickPointHandler;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import tools.transform : VertexEditFactory;
import toolpipe.packets : FalloffPacket, SubjectPacket;
import operator        : Operator, Task, VectorStack, PacketKind;
import pipe_gizmo_host : PipeGizmoHost;

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
///    inner Command's attrs → `inner.apply()` re-mutates the mesh
///    for a live preview.
///  - LMB-up ends the drag session; mesh stays at preview.
///  - Subsequent LMB-down on the same active tool resets the baseline
///    again so the new drag composes on top of the previous preview
///    (post-Apply state when Apply ran, or the pre-activation state
///    otherwise).
///
/// Commit semantics (matching `TransformTool.deactivate` →
/// `commitEdit("Move")` pattern in source/tools/move.d:120):
///  - `setUndoBindings(history, vxEditFactory)` injects the undo
///    plumbing at construction time. The factory builds a fresh
///    `MeshVertexEdit` pre-wired to the same gpu/caches the inner
///    Command mutates.
///  - `deactivate()` builds a `MeshVertexEdit(before=baseline,
///    after=current)` and records it on history. Spacebar →
///    `setActiveTool(null)` → here. Tool switches and tab close hit
///    the same path.
///  - The "Apply" button in `drawProperties()` runs the same commit
///    path then refreshes the baseline so further drags compose on
///    top of the now-committed state. Tool stays active.
abstract class CommandWrapperTool : Tool {
    protected Command inner;
    protected Mesh*   meshPtr;
    protected GpuMesh*        gpu;
    protected VertexCache*    vc;
    protected EdgeCache*      ec;
    protected FaceBoundsCache* fc;
    protected View             viewRef;

    // Undo plumbing — same shape as TransformTool. Optional: tests /
    // older callers can leave these null and skip history recording.
    private CommandHistory     history;
    private VertexEditFactory  vertexEditFactory;

    // Drag bookkeeping.
    private bool   dragging;
    private int    dragStartX, dragStartY;
    // Set by `onParamChanged` when the Tool Properties panel edits a
    // slider; consumed by `evaluate()` to re-run the preview against
    // the current baseline. Same flow other tools use (BoxTool /
    // SphereTool's evaluate path) — without this hook, slider edits
    // update the inner Command's stored attrs but the mesh stays at
    // the old preview state until the next drag or Apply.
    private bool   paramsDirty;

    // Baseline = mesh.vertices.dup at the moment the current edit
    // session started (activation or last Apply). `dirty` flips on
    // the first motion event after a new baseline; nothing commits
    // when the user activates / deactivates without any drag.
    private Vec3[] baseline;
    private bool   dirty;

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

    /// Wire undo plumbing. Called by app.d after construction so the
    /// factory delegate captures the right gpu / caches. No-op if
    /// either argument is null — tools without history support can
    /// skip recording.
    public void setUndoBindings(CommandHistory h, VertexEditFactory f) {
        this.history           = h;
        this.vertexEditFactory = f;
    }

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
        dirty    = false;
        refireDriving_   = false;
        refireCommitted_ = false;
    }

    override void deactivate() {
        // Commit the open edit on tool exit (same as the
        // `TransformTool.deactivate` pattern). Spacebar →
        // app.d global handler → `setActiveTool(null)` → here.
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

    // ----- History-coordination hooks (undo/redo migration P0) -------------
    //
    // Commit guard mirror: commitNow() early-returns unless `dirty` (:365), and
    // deactivate() is the only commit site, so `dirty` IS the "would commit now"
    // predicate.
    public override bool hasUncommittedEdit() const { return dirty; }

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
    // Tests / older callers that skip setUndoBindings() leave history null and
    // fall back to the legacy preview-then-commit path.
    public override bool wantsRefire() const {
        return history !is null && vertexEditFactory !is null;
    }

    // Build the MeshVertexEdit representing the CURRENT param state. Re-runs the
    // deform against the session baseline, captures the per-vertex before/after
    // diff, and returns a fresh (unrecorded) command. The history's fire() then
    // owns its apply()/revert() lifecycle: each fire reverts the previous live
    // command back to `baseline`, then applies this one — so the mesh always
    // walks baseline -> latest-params with no accumulation, and refireEnd lands
    // the LAST one as a single entry. Returns null when the params produce a
    // no-op (empty diff) so the driver skips the fire() for that tick.
    public override Command buildRefireCommand() {
        if (meshPtr is null || history is null || vertexEditFactory is null)
            return null;
        if (baseline.length != meshPtr.vertices.length) return null;

        // Mark the session driving so the per-frame evaluate()/onParamChanged()
        // preview stays inert while the fired command owns mutation.
        refireDriving_ = true;

        // Run the deform from the clean baseline using the inner Command's
        // current attrs (same dispatch the drag/preview path uses). This leaves
        // the mesh holding the post-deform positions; we snapshot the diff, then
        // restore the baseline so fire()'s own apply() lays it down cleanly.
        if (!applyWithLivePipeline()) {
            meshPtr.vertices[] = baseline[];
            refreshCaches();
            return null;
        }

        uint[] indices;
        Vec3[] before;
        Vec3[] after_;
        size_t n = meshPtr.vertices.length;
        foreach (i; 0 .. n) {
            auto a = baseline[i], b = meshPtr.vertices[i];
            if (a.x == b.x && a.y == b.y && a.z == b.z) continue;
            indices ~= cast(uint)i;
            before  ~= a;
            after_  ~= b;
        }

        // Restore baseline — fire() applies the returned command itself.
        meshPtr.vertices[] = baseline[];
        refreshCaches();

        if (indices.length == 0) return null;

        auto cmd = vertexEditFactory();
        cmd.setEdit(indices, before, after_, name());
        return cast(Command)cmd;
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

        dragStartX = e.x;
        dragStartY = e.y;
        dragging = true;

        // Project click pixel onto workplane (Y=0) and place the
        // handle there. Clicking in the 3D viewport sets the tool into
        // interactive mode and draws its handle at the click point.
        // Handle visibility is gated on `dragging`, so it appears here
        // and disappears on LMB-up.
        if (viewRef !is null && clickHandle !is null) {
            Vec3 hit;
            if (screenToWorkPlane(cast(float)e.x, cast(float)e.y, cachedVp, hit))
                clickHandle.setPos(hit);
        }
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
        // dispatch through the Operator path (baseline-restore +
        // toolpipe walk + evaluate are folded into one call).
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
        if (ImGui.Button("Apply"))
            commitNow("Apply");
    }

    override void onParamChanged(string name) {
        // While a refire session is driving this tool the fired
        // buildRefireCommand() owns the mutation — don't queue an internal
        // preview (it would double-apply against the same baseline in the same
        // tick). Outside refire this is the legacy preview path.
        if (refireDriving_) return;
        // A schema widget changed — `evaluate()` will re-run the
        // preview next frame. Don't apply directly here: PropertyPanel
        // calls onParamChanged per-widget per-frame, evaluate() once
        // at the end, so a single frame with multiple slider tweaks
        // produces a single re-apply.
        paramsDirty = true;
    }

    override void evaluate() {
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
                SubjectPacket subj;
                subj.mesh             = meshPtr;
                subj.editMode         = EditMode.Vertices;
                subj.viewport         = cachedVp;
                VectorStack vts;
                vts.put(&subj);
                g_pipeCtx.pipeline.evaluate(vts);
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

    // Falloff packet equality lives in source/falloff.d — pulled in via
    // the local import alias below. The earlier in-class duplicate was
    // missing lasso fields (would freeze the preview on Lasso edits).

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
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
    private void commitNow(string label) {
        // Double-record guard (undo/redo migration P4 — the single commit
        // chokepoint). A refire session already landed its single entry via
        // refireEnd(); the deactivate()/Apply commitNow() that follows MUST NOT
        // record a second entry for the same edit. Consume the latch and bail —
        // the baseline was already advanced in onRefireCommitted().
        if (refireCommitted_) {
            refireCommitted_ = false;
            dirty = false;
            return;
        }
        if (!dirty)              return;
        if (meshPtr is null)     return;
        if (history is null)     return;
        if (vertexEditFactory is null) return;
        // Build the diff: only verts whose position actually changed.
        // For Smooth/Jitter/Quantize the inner Command can touch every
        // vert (with empty selection = whole mesh), so scanning is
        // O(n) — cheap for any reasonable mesh.
        uint[] indices;
        Vec3[] before;
        Vec3[] after_;
        size_t n = meshPtr.vertices.length;
        if (baseline.length != n) {
            // Topology changed mid-session (shouldn't happen for
            // smooth/jitter/quantize); refuse to commit a malformed
            // diff. Fall back to restoring baseline so the mesh
            // stays consistent.
            baseline.length = 0;
            dirty = false;
            return;
        }
        foreach (i; 0 .. n) {
            auto a = baseline[i], b = meshPtr.vertices[i];
            if (a.x == b.x && a.y == b.y && a.z == b.z) continue;
            indices ~= cast(uint)i;
            before  ~= a;
            after_  ~= b;
        }
        if (indices.length == 0) {
            dirty = false;
            return;
        }
        auto cmd = vertexEditFactory();
        cmd.setEdit(indices, before, after_,
                    label.length > 0 ? label : name());
        history.record(cmd);

        // Promote post-commit state to the new baseline so subsequent
        // drags compose on top of it. On Apply the current action is
        // fixed into the geometry and future drags start fresh.
        baseline = meshPtr.vertices.dup;
        dirty    = false;
    }

    /// Build a VectorStack from the live toolpipe + mesh subject and
    /// dispatch `inner.evaluate(vts)` (Operator path). Replaces the
    /// previous cast-chain pushFalloffToInner approach — the Operator
    /// pulls its own packets from vts, so no per-Command knowledge
    /// stays here. Phase 3 of doc/operator_refactor_plan.md.
    ///
    /// Falls back to the legacy `inner.apply()` if the inner Command
    /// doesn't implement Operator (defensive — every convolve command
    /// post-Phase-2 implements it).
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

    private bool applyWithLivePipeline() {
        import toolpipe.pipeline : g_pipeCtx;
        if (meshPtr is null) return false;

        // Restore baseline so apply runs against pre-drag state.
        meshPtr.vertices[] = baseline[];

        SubjectPacket subj;
        subj.mesh             = meshPtr;
        subj.editMode         = EditMode.Vertices;
        subj.viewport         = cachedVp;

        VectorStack vts;
        vts.put(&subj);

        if (g_pipeCtx !is null)
            g_pipeCtx.pipeline.evaluate(vts);   // populate upstream packets

        // Snapshot the applied falloff SET for the change-detection branch
        // in evaluate(). Per-stage config copies (by value) keep the
        // comparison meaningful — the pipe rewrites the same _publishedPacket
        // every walk, so a value snapshot of each stage's config is what makes
        // the frame-to-frame compare detect a real change.
        lastAppliedFalloffs = currentFalloffConfigs();

        // Dispatch through the Operator interface. evaluate(vts) returns
        // bool — true on a meaningful effect, false on a no-op rejection.
        // The inner Command is guaranteed to be Operator post-Phase-2 for
        // the three convolve wrappers; the cast keeps the door open for
        // future wrappers that may carry a non-Operator command.
        bool ok;
        if (auto op = cast(Operator)inner)
            ok = op.evaluate(vts);
        else
            ok = inner.apply();

        refreshCaches();
        return ok;
    }

    private void refreshCaches() {
        refreshDisplay(meshPtr, gpu, vc, ec, fc);
    }
}


// ---------------------------------------------------------------------------
// Concrete wrappers.
// ---------------------------------------------------------------------------

final class XfrmSmoothTool : CommandWrapperTool {
    private MeshSmooth inner_;
    private float      lastStrn;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        inner_ = new MeshSmooth(mesh, view, editMode, gpu, vc, ec, fc);
        inner  = inner_;
        meshPtr = mesh;
        viewRef = view;
        this.gpu = gpu; this.vc = vc; this.ec = ec; this.fc = fc;
    }

    override string name() const { return "xfrm.smooth"; }

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
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        inner_ = new MeshJitter(mesh, view, editMode, gpu, vc, ec, fc);
        inner  = inner_;
        meshPtr = mesh;
        viewRef = view;
        this.gpu = gpu; this.vc = vc; this.ec = ec; this.fc = fc;
    }

    override string name() const { return "xfrm.jitter"; }

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
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        inner_ = new MeshQuantize(mesh, view, editMode, gpu, vc, ec, fc);
        inner  = inner_;
        meshPtr = mesh;
        viewRef = view;
        this.gpu = gpu; this.vc = vc; this.ec = ec; this.fc = fc;
    }

    override string name() const { return "xfrm.quantize"; }

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
