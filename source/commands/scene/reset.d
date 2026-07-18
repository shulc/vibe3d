module commands.scene.reset;

import command;
import mesh;
import view;
import editmode;
import document : Document, Layer, ItemXform;
// GpuMesh lives in mesh.d, already imported above.
import snapshot : MeshSnapshot;
import change_bus : MeshChangeAll;
import io.doc_state : clearCurrentDoc, requestDocRebaseline;

/// Reset the scene to a chosen primitive
/// (cube/diamond/octahedron/lshape/grid/subdivcube). Replaces the legacy
/// /api/reset direct handler. Snapshots the entire pre-reset mesh so undo
/// brings back whatever was there.
class SceneReset : Command {
    private EditMode*        editModePtr;
    private void delegate()  onResetTool;
    // Viewport reset (V3): mirrors onResetTool exactly — an optional,
    // nullable delegate fired at the point the old direct `viewPtr.reset()`
    // used to run. Wired by BOTH the `file.new` and `scene.reset` app
    // factories to `() => vpm.resetToDefault()`, so every dispatch path
    // (menu, keyboard shortcut, HTTP `/api/command`) resets the viewport
    // uniformly with no per-site hook or command-id dispatch logic. Null in
    // headless/unit construction (no-op).
    private void delegate()  onViewportReset;
    // Document handle (layers Stage 2): reset collapses the document to EXACTLY
    // one default layer. Optional — null in unit/headless construction, where
    // the single-layer write-in-place below is already one layer. Undo restores
    // the prior layer list.
    private Document*        document;
    private Layer[]          prevLayers;
    private size_t           prevActiveIndex;
    private bool             docCollapsed;   // true when we replaced the layer list
    // The kept active layer's original metadata (apply overwrites it to the
    // default "Layer 1"/visible; revert restores these). Foreground/background
    // is derived from selection (Stage 2b) — `setActive` re-asserts the kept
    // layer's selected bit on both apply and revert, so there is no stored
    // background flag to snapshot.
    private string           keptPrevName;
    private bool             keptPrevVisible;
    // Channels P4: a reset is a clean slate, so the kept layer's per-item
    // transform returns to identity (default ItemXform). Snapshot the prior
    // value so undo brings the authored transform back.
    private ItemXform        keptPrevXform;
    // Task 0082: snapshot the kept layer's parent ref (-j8 fix: a parent set in
    // one test must not survive into the next via SceneReset).
    private Layer            keptPrevParent;

    private string       primitive;     // "cube" / "diamond" / "octahedron" / "lshape" / "grid" / "subdivcube"
    private bool         emptyScene;    // true → reset to empty mesh (no primitive)
    // Integer parameter for the dense perf meshes: grid side count (n) for
    // "grid", Catmull-Clark depth (levels) for "subdivcube". -1 → use the
    // primitive's default. Ignored by the small fixed primitives.
    private int          primParam = -1;
    private MeshSnapshot snap;
    private EditMode     prevEditMode;
    private bool         captured;
    // Funnel hook: when installed (app factory), apply/revert route the editMode
    // write through promoteGeometryType so selTypeOrder stays in lockstep.
    // Null in headless/unit construction — the raw-pointer fallback is used then.
    private void delegate(EditMode) promoteType;

    this(Mesh* mesh, ref View view, EditMode editMode,
         EditMode* editModePtr,
         void delegate() onResetTool,
         void delegate() onViewportReset = null) {
        super(mesh, view, editMode);
        this.editModePtr     = editModePtr;
        this.onResetTool      = onResetTool;
        this.onViewportReset  = onViewportReset;
    }

    override string name() const { return "scene.reset"; }
    override string label() const {
        return emptyScene ? "Reset to empty" : "Reset to " ~ primitive;
    }

    // Model (geometry changes) + UndoBoundary: the entry is undoable (Ctrl+Z
    // can revert a reset if explicitly navigated to), but the T-SEP cursor scan
    // stops here — a plain geometry undo will not reach across a reset to revert
    // pre-reset edits. The reset is a session boundary, not a regular geometry op.
    override CmdFlags cmdFlags() const {
        return CmdFlags.Model | CmdFlags.UndoBoundary;
    }

    void setPrimitive(string p) { primitive = p; emptyScene = false; }
    void setEmpty(bool b) { emptyScene = b; }
    /// Install the document handle so reset collapses to one default layer.
    /// app.d sets this on the scene.reset / file.new / scene.loadMesh factories.
    void setDocument(Document* d) { document = d; }
    /// Integer arg for the dense perf meshes (grid side / subdiv levels).
    /// Pass -1 (the default) to let the factory pick its own default.
    void setPrimitiveParam(int p) { primParam = p; }
    /// Install the funnel hook so apply/revert route the editMode write through
    /// promoteGeometryType (touches selTypeOrder before the field write). Returns
    /// `this` for chaining. Null (default) = raw-pointer fallback for headless.
    SceneReset setPromoteHook(void delegate(EditMode) hook) {
        this.promoteType = hook;
        return this;
    }

    override bool apply() {
        snap         = MeshSnapshot.capture(*mesh);
        prevEditMode = *editModePtr;
        captured     = true;

        // Layers Stage 2: a reset collapses the document to EXACTLY one default
        // layer (the "reset yields one layer" invariant every existing test
        // depends on). The SURVIVING layer is the current ACTIVE one, so the
        // fire-time `mesh` pointer stays valid for the `*mesh = ...` write
        // below; the others are dropped (their geometry rides the prevLayers
        // snapshot for undo). With one layer this is already a no-op.
        if (document !is null && document.layers.length > 0) {
            prevLayers      = document.layers.dup;   // shallow: Layer refs kept
            prevActiveIndex = document.activeIndex;
            auto keep       = document.active();     // the layer `mesh` points at
            keptPrevName       = keep.name;
            keptPrevVisible    = keep.visible;
            keptPrevXform      = keep.xform;
            keptPrevParent     = keep.parent;
            keep.name       = "Layer 1";
            keep.visible    = true;
            // Channels P4: reset clears the per-item transform back to identity
            // (render-only field — vertices are untouched either way).
            keep.xform      = ItemXform.init;
            // Task 0082: clear the parent link on reset (-j8 bleed fix).
            keep.parent     = null;
            document.layers      = [ keep ];
            // Stage-0 lockstep: one selected primary layer (the surviving
            // active one) — setActive(0) re-asserts the SET-of-one.
            document.setActive(0);
            docCollapsed    = true;
        }

        if (emptyScene) {
            *mesh = Mesh.init;
        } else switch (primitive) {
            case "lshape":     *mesh = makeLShape();    break;
            case "diamond":    *mesh = makeDiamond();   break;
            case "octahedron": *mesh = makeOctahedron();break;
            case "grid":
                // Dense flat grid for the perf harness. Default 316 → ~100 K
                // quads (316×316), matching the perf-mesh target.
                *mesh = makeGridPlane(primParam > 0 ? primParam : 316);
                break;
            case "subdivcube":
                // Catmull-Clark cube for the perf harness. Default 7 levels
                // → ~98 K faces.
                *mesh = subdivideCube(primParam > 0 ? primParam : 7);
                break;
            case "":
            case "cube":
            default:           *mesh = makeCube();      break;
        }
        if (onViewportReset !is null) onViewportReset();
        mesh.resetSelection();
        if (promoteType) promoteType(EditMode.Vertices);
        else *editModePtr = EditMode.Vertices;
        // Forget the remembered save target: a reset is a clean slate and
        // the prior document path no longer applies. This prevents a later
        // path-less file.save from silently overwriting the pre-reset file.
        // Intentionally NOT restored in revert() — session/UI state, same
        // policy as the camera (see the revert() note below).
        clearCurrentDoc();
        // A reset is a fresh untitled document: start clean (task 0434). The
        // reset's own mesh mutation flushes after this command, so the
        // rebaseline lands on the next syncDocRevision.
        requestDocRebaseline();
        // Reset EVERY toolpipe stage to its declaration-time defaults.
        // Stage state — Snap on, Symmetry plane, Falloff type, ACEN /
        // AXIS modes, Workplane tilt — is session-level UI state, and
        // a "Reset" UX promise should wipe it alongside the mesh.
        // Without this, every test that flips a stage attr corrupts
        // subsequent tests in the same vibe3d process; stages with no
        // mutable state inherit the no-op Stage.reset() and are
        // unaffected.
        import toolpipe.pipeline : g_pipeCtx;
        if (g_pipeCtx !is null) {
            // Drop every stacked extra falloff (`falloff#N`) FIRST so a reset
            // returns the WGHT slot to exactly the single primary stage —
            // matching the pre-stacking baseline (byte-stable). The primary
            // survives and reset()s its config to None below.
            import commands.falloff : removeStackedFalloffs;
            removeStackedFalloffs();
            foreach (s; g_pipeCtx.pipeline.allMut())
                s.reset();
        }
        if (onResetTool !is null) onResetTool();
        // Clear the geometry clipboard so cross-test bleed cannot occur: a
        // copy in one test must not survive into the next test's paste.
        // The clipboard is NOT restored in revert() — it is non-undoable
        // session state, same policy as the camera position.
        import geometry_clipboard : geometryClipboard;
        geometryClipboard.clear();
        // Bulk transition: the whole mesh was REPLACED — every cache must
        // invalidate. noteChange(All) (the `*mesh = ...` above reset the new
        // mesh's pending set + counters to 0, so this must come after it). We use
        // noteChange (not commitChange) because the fresh mesh's version counters
        // start at 0 by design; the bus only needs the All notification.
        mesh.noteChange(MeshChangeAll);
        return true;
    }

    override bool revert() {
        if (!captured) return false;
        // Restore the kept active layer's pre-reset geometry first (the snapshot
        // was captured against `*mesh`, which is the surviving active layer).
        snap.restore(*mesh);
        if (promoteType) promoteType(prevEditMode);
        else *editModePtr = prevEditMode;
        // Then restore the full pre-reset layer list + active index (layers
        // Stage 2). The kept layer object is still in prevLayers (shallow dup),
        // so its just-restored geometry + restored name/flags ride back too.
        if (docCollapsed && document !is null) {
            // Restore the kept layer's original metadata, then the full list.
            auto keep = document.active();
            keep.name       = keptPrevName;
            keep.visible    = keptPrevVisible;
            keep.xform      = keptPrevXform;
            keep.parent     = keptPrevParent;
            document.layers      = prevLayers;
            // Restore primary/selected/activeIndex in lockstep (setActive
            // clamps the index into range).
            document.setActive(prevActiveIndex);
        }
        // Camera/viewport state isn't snapshotted — undoing a reset doesn't
        // restore the camera, only the mesh. The viewport reset is delegated
        // to the app layer (onViewportReset, fired only from apply()) and is
        // not part of model undo, same as before.
        return true;
    }
}
