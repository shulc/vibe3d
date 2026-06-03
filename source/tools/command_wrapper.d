module tools.command_wrapper;

import bindbc.sdl;

import command : Command;
import mesh    : Mesh, GpuMesh;
import view    : View;
import editmode : EditMode;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import tool   : Tool;
import params : Param;
import math   : Vec3, Viewport, screenToWorkPlane;
import shader : Shader;
import handler : ClickPointHandler, ToolHandles;
import eventlog : queryMouse;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import tools.transform : VertexEditFactory;
import toolpipe.packets : FalloffPacket, SubjectPacket;
import operator        : Operator, Task, VectorStack, PacketKind;
import falloff_render : drawFalloffOverlay;
import falloff_handles : FalloffGizmo;

import commands.mesh.smooth   : MeshSmooth;
import commands.mesh.jitter   : MeshJitter;
import commands.mesh.quantize : MeshQuantize;

import ImGui = d_imgui;

private enum int FALLOFF_BASE = 100;

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

    // Last falloff packet seen by `pushFalloffToInner` — used by
    // `evaluate()` to detect live changes (the FalloffStage's panel
    // widgets fire onParamChanged on the stage, not on this Tool, so
    // the wrapper's own `paramsDirty` flag misses falloff edits and
    // the viewport doesn't refresh). Same pattern as MoveTool /
    // ScaleTool / RotateTool `falloffPacketsEqual`-based detection.
    private FalloffPacket lastAppliedFalloff;

    // Lazy-built endpoint gizmo for draggable handles (linear start /
    // end, radial center + 6 size handles). Mirrors transform tools'
    // FalloffGizmo usage. Null when no falloff is active in the
    // tool's lifetime.
    private FalloffGizmo  falloffGizmo;
    private ToolHandles   toolHandles;

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
        baseline = meshPtr.vertices.dup;
        dirty    = false;
        clickHandle = new ClickPointHandler();
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
        if (falloffGizmo !is null) {
            falloffGizmo.destroy();
            falloffGizmo = null;
        }
        toolHandles = null;
        baseline.length = 0;
        dirty    = false;
        dragging = false;
        lastAppliedFalloff = FalloffPacket.init;
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

    // ---- drag interaction --------------------------------------------

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        // Skip alt/ctrl chords — camera owns those.
        auto modState = SDL_GetModState();
        if (modState & (KMOD_ALT | KMOD_CTRL)) return false;
        if (meshPtr is null) return false;

        // Falloff endpoint drag takes priority — same precedence move /
        // scale tools give it. Read the FalloffPacket from the dispatcher-
        // built vts (Phase 7), no extra pipeline walk needed.
        if (falloffGizmo !is null) {
            FalloffPacket fp;
            if (auto p = vts.get!FalloffPacket()) fp = *p;
            if (falloffGizmo.onMouseButtonDown(e, cachedVp, fp))
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
            auto vp = viewRef.viewport();
            Vec3 hit;
            if (screenToWorkPlane(cast(float)e.x, cast(float)e.y, vp, hit))
                clickHandle.setPos(hit);
        }
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        // Falloff endpoint drag — gizmo updates the FalloffStage's
        // attrs via tool.pipe.attr; the subsequent `evaluate()` tick
        // detects the live falloff change and re-applies the preview.
        if (falloffGizmo !is null && falloffGizmo.isDragging())
            return falloffGizmo.onMouseMotion(e, cachedVp);

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
        // Release falloff endpoint drag first — it consumes
        // independently of the tool's own drag.
        if (falloffGizmo !is null && falloffGizmo.onMouseButtonUp(e))
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
        // A schema widget changed — `evaluate()` will re-run the
        // preview next frame. Don't apply directly here: PropertyPanel
        // calls onParamChanged per-widget per-frame, evaluate() once
        // at the end, so a single frame with multiple slider tweaks
        // produces a single re-apply.
        paramsDirty = true;
    }

    override void evaluate() {
        if (meshPtr is null) return;
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
                import falloff : falloffPacketsEqual;
                FalloffPacket fp;
                if (auto p = vts.get!FalloffPacket()) fp = *p;
                falloffChanged = !falloffPacketsEqual(fp, lastAppliedFalloff);
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

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts) {
        // Cache the live viewport so pushFalloffToInner has projection
        // matrices ready (Screen / Lasso falloff types need them; the
        // others ignore vp).
        cachedVp = vp;

        // Passive falloff overlay (gradient lines / sphere wireframe /
        // disc / lasso polygon). Reads the dispatcher-built vts —
        // Phase 7 means no local pipeline.evaluate; same data as
        // every other Tool sees this frame.
        FalloffPacket fp;
        if (auto p = vts.get!FalloffPacket()) fp = *p;
        drawFalloffOverlay(fp, vp);
        if (fp.enabled) {
            if (falloffGizmo is null) falloffGizmo = new FalloffGizmo();
            if (toolHandles  is null) toolHandles  = new ToolHandles();
            // Host arbiter (MODO tmod_Test -> tmod_Draw): register the
            // falloff handles, resolve one hot/captured part, then render.
            // CommandWrapper has no gizmo bank, so falloff is the only
            // emitter — this unifies the previously per-endpoint self-hover
            // into a single winner across all falloff handles.
            toolHandles.begin();
            falloffGizmo.registerHandles(toolHandles, FALLOFF_BASE, fp);
            toolHandles.setHaul(falloffGizmo.isDragging()
                                ? falloffGizmo.capturedPart(FALLOFF_BASE) : -1);
            int hmx, hmy;
            queryMouse(hmx, hmy);
            toolHandles.update(hmx, hmy, vp);
            falloffGizmo.draw(shader, vp, fp);
        }

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

        // Snapshot the applied falloff for the change-detection branch
        // in evaluate(). Pointer-equality on the slot isn't enough
        // because the pipe rewrites the same _publishedPacket every
        // walk; copy-by-value semantics keep the comparison meaningful.
        if (auto fp = vts.get!FalloffPacket())
            lastAppliedFalloff = *fp;
        else
            lastAppliedFalloff = FalloffPacket.init;

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
        if (gpu !is null && meshPtr !is null) gpu.upload(*meshPtr);
        if (vc  !is null) { vc.resize(meshPtr.vertices.length); vc.invalidate(); }
        if (ec  !is null) { ec.resize(meshPtr.edges.length);    ec.invalidate(); }
        if (fc  !is null) { fc.resize(meshPtr.vertices.length,
                                      meshPtr.faces.length); fc.invalidate(); }
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
