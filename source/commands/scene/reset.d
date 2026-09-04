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
import params : Param, wireArgs;

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
    // Task 0654: the item selection was EMPTY at fire time and apply() re-homed
    // a primary so it had a mesh to write. revert() owes the empty state back.
    /// TASK 0671 — the exact prior item-selection state (both lists, the
    /// order, the focus). Replaces the `prevActiveIndex` + `prevSelectionEmpty`
    /// pair, which recorded a DERIVED index plus a flag for the one case that
    /// index could not express; neither could express a latched target, and
    /// the `clearItemSelection()` used to restore the empty case now LATCHES
    /// rather than empties.
    private Document.ItemSelectionState prevSelection;
    /// Whether the document had NO edit target at fire time, which `apply()`
    /// repairs by re-homing one so it has a mesh to write. Kept beside the
    /// snapshot rather than derived from it: the snapshot is opaque by design,
    /// and this flag gates a MUTATION in `apply()`, not a restore.
    private bool             prevSelectionEmpty;
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
    // can revert a reset if explicitly navigated to), but undo traversal stops
    // here — a plain undo will not reach across a reset to revert
    // pre-reset edits. The reset is a session boundary, not a regular geometry op.
    override CmdFlags cmdFlags() const {
        return CmdFlags.Model | CmdFlags.UndoBoundary;
    }

    // Task 1521: a reset (File → New, or a bare `scene.reset`) throws the
    // whole document away. The GUARD it triggers is not on this class — it is
    // on the single UI dispatch point (`runUiCommand`), so `/api/reset`, which
    // calls `apply()` directly, is unaffected and stays promptless.
    override bool discardsUnsavedWork() const { return true; }

    // TASK 4062 — THE ARGUMENTS, DECLARED.
    //
    // These three reached the command through a hand-written injector in the
    // HTTP dispatcher (`injectRetiredWrapperArgs`, itself the descendant of the
    // retired `/api/reset` route). Declaring them puts them where every other
    // command's arguments are, and it is what makes the id-vs-class hazard that
    // injector was written to fix UNREPRESENTABLE rather than guarded: this
    // class is registered TWICE, as `scene.reset` and as `file.new`, and the
    // block keyed on the CLASS therefore fired on both. `file.new`'s factory
    // calls `setEmpty(true)`; a declared parameter is only written when the
    // payload SUPPLIES it, so an argument-less `file.new` keeps that `true`
    // where the injector's else-arm used to call `setPrimitive("")` — whose
    // side effect is `emptyScene = false` — and hand back the default cube
    // under a `status:ok`.
    //
    // `empty` is declared LAST but read FIRST: `applyImpl` tests `emptyScene`
    // before the primitive switch, so `{"empty":true,"type":"grid"}` is an
    // empty scene, which is what the injector's `if (empty) … else …` did.
    // ORDER IS THE POSITIONAL LAW, so `type` leads the two a human would ever
    // type — `scene.reset grid 100` — and `empty` sits behind them where no
    // positional caller can reach it by accident.
    //
    // `levels` is an ALIAS of `n`, not a second slot: the injector took the
    // first of `["n", "levels"]` the payload carried, and both spellings are
    // live in the suite (`{"type":"grid","n":100}`,
    // `{"type":"subdivcube","levels":2}`).
    override Param[] params() {
        return wireArgs(
            Param.string_("type",  "Primitive", &primitive,  ""),
            Param.int_   ("n",     "Parameter", &primParam,  -1).aliases(["levels"]),
            Param.bool_  ("empty", "Empty",     &emptyScene, false),
        );
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

    protected override bool applyImpl() {
        // TASK 0654 — a reset from an EMPTY item selection.
        //
        // This command (and `file.new`, which is the same class) is the "start
        // over" verb, so refusing it for want of an edit target would leave a
        // user who clicked empty space with no way to clear the scene. Its
        // defined post-state is one selected layer, so re-establishing a
        // primary is not a substitution — it is the operation.
        //
        // It must happen BEFORE `MeshSnapshot.capture(*mesh)`: the fire-time
        // `mesh` pointer aliases `document.noEditTargetMesh` while the
        // selection is empty, and both the snapshot and the `*mesh = …` write
        // below would otherwise land in the read-only stand-in — the one write
        // this task promises never arrives there.
        //
        // `rehomePrimary(0)` is the document's own promotion algorithm for
        // "find a layer that can be the edit target", the same one a structural
        // mutation runs; null from it means a document with no `canBePrimary`
        // item at all, which is unrepresentable, so that one really does refuse.
        // Task 0671: capture BEFORE the rehome below, so an undo puts back the
        // no-target state rather than the one this command manufactured to
        // have somewhere to write.
        if (document !is null) prevSelection = document.captureItemSelection();
        prevSelectionEmpty = document !is null && document.layers.length > 0
                          && !document.hasEditTarget();
        if (prevSelectionEmpty) {
            auto rehomed = document.rehomePrimary(0);
            if (rehomed is null) return false;
            document.setPrimary(rehomed);
            mesh = document.activeMesh();
        }
        // TASK 3130 — DISARM AND DROP THE ACTIVE TOOL, HERE, BEFORE ANYTHING
        // ELSE READS OR WRITES THE MESH.
        //
        // The reset used to leave this to `onResetTool()` at the bottom of
        // this function, which is 24 lines AFTER `*mesh = makeCube()` — so the
        // tool's `deactivate()`, which for a session tool is its commit point,
        // ran its kernel against the fresh document. Measured: a reset with an
        // engaged `mesh.mirrorTool` handed back a cube of 12 faces instead of
        // 6, plus a "Mirror" undo entry for an edit nobody confirmed. See
        // `source/tool_disarm.d` for the full measurement and the two layers.
        //
        // AND IT IS BEFORE THE SNAPSHOT ON PURPOSE. `snap` is what undoing
        // this reset restores. An uncommitted gesture is, by definition, not
        // part of what the user has: capturing AFTER the cancel means undo
        // brings back the last COMMITTED state, where before it brought back
        // whatever a live-writing tool (topology pen's live move, a transform
        // drag) happened to have on the mesh mid-gesture.
        //
        // Placed after the `prevSelectionEmpty` rehome above only so `mesh`
        // already points at a real edit target; a tool cannot in fact be armed
        // with no edit target (`tool.set` refuses — TASK 0654 above), so the
        // two orderings are equivalent today and this one stays true if that
        // refusal is ever relaxed.
        {
            import tool_disarm : DisarmMode,
                disarmActiveToolBeforeDocumentReplace;
            disarmActiveToolBeforeDocumentReplace(DisarmMode.cancelAndDrop);
        }
        snap         = MeshSnapshot.capture(*mesh);
        noteUndoRecorded();   // task 2500 — the flag and the image, one statement apart
        prevEditMode = *editModePtr;

        // Layers Stage 2: a reset collapses the document to EXACTLY one default
        // layer (the "reset yields one layer" invariant every existing test
        // depends on). The SURVIVING layer is the current ACTIVE one, so the
        // fire-time `mesh` pointer stays valid for the `*mesh = ...` write
        // below; the others are dropped (their geometry rides the prevLayers
        // snapshot for undo). With one layer this is already a no-op.
        if (document !is null && document.layers.length > 0) {
            prevLayers      = document.layers.dup;   // shallow: Layer refs kept
            prevActiveIndex = document.activeIndex;
            // Task 0615 (§R4): explicitly `document.primary`, not
            // `document.active()` — this is the MESH EDIT TARGET the fire-time
            // `mesh` pointer aliases and the `*mesh = …` write below lands in
            // (today the two are the same object, but the name says which role
            // this is; `focusedItem` would be the wrong pointer to survive a
            // reset targeting the edit surface).
            auto keep       = document.primary;
            keptPrevName       = keep.name;
            keptPrevVisible    = keep.visible;
            keptPrevXform      = keep.xform;
            keptPrevParent     = keep.parent;
            keep.name       = "Layer 1";
            keep.visible    = true;
            // Task 0615 (review round 3, S1): deliberately NOT writing
            // `keep.kind` here. `keep` is `document.primary`, which the
            // document invariant (§Q2) guarantees is always mesh-kind — so a
            // `keep.kind = ItemKind.Mesh` write here is provably a no-op
            // today. It is also UNSNAPSHOTTED, unlike its four siblings
            // above/below: an undoable command that writes state it cannot
            // restore is a defect waiting for the one state that makes the
            // write non-trivial — a non-mesh primary — which is exactly the
            // state Stage 6+ (not started; out of scope here) would have to
            // define the semantics for. Adding snapshot/restore now would be
            // building undo support for a state this task must not create.
            // Channels P4: reset clears the per-item transform back to identity
            // (render-only field — vertices are untouched either way).
            keep.xform      = ItemXform.init;
            // Task 0082: clear the parent link on reset (-j8 bleed fix).
            keep.parent     = null;
            document.layers      = [ keep ];
            document.noteLayerListChanged();
            // Task 0671: the item-selection state still names the layers this
            // collapse just dropped — forget it wholesale before re-selecting,
            // rather than leaving them reachable from a history bucket.
            document.resetSelectionState();
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
        // Same clean-slate rule for the morph ROUTING TARGET (task 1073,
        // review B2). It is an app-global NAME, so without this it survived a
        // File → New into a document that no longer has that map — and,
        // because `/api/reset` fires this command, it survived from one HTTP
        // test into the next in the shared `--test` process, which is a
        // cross-test bleed vector rather than merely a stale binding.
        // Not restored in revert(), same policy as the doc path above.
        {
            import morph_target : clearMorphTarget;
            clearMorphTarget();
        }
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
        // And the Coordinate Rounding setting, for exactly the reason the
        // stage loop above gives: it is session-level UI state, and without
        // this one test that switches the rounding off corrupts every later
        // test sharing the same vibe3d process (the runner reuses one per
        // worker). Same policy as the camera / clipboard: NOT restored in
        // revert() — undoing a reset restores geometry, not settings.
        import coord_rounding : resetCoordRounding;
        resetCoordRounding();
        if (onResetTool !is null) onResetTool();
        // Clear the geometry clipboard so cross-test bleed cannot occur: a
        // copy in one test must not survive into the next test's paste.
        // The clipboard is NOT restored in revert() — it is non-undoable
        // session state, same policy as the camera position.
        import geometry_clipboard : geometryClipboard;
        geometryClipboard.clear();
        // Bulk transition: the whole mesh was REPLACED — every cache must
        // invalidate. The All class is published after the `*mesh = ...` above
        // (which reset the new mesh's pending set + counters to 0), and
        // WITHOUT a version bump — the fresh mesh's counters start at 0 by
        // design; the bus class is the notification consumers key on.
        // TASK 1906 STAGE 2 PRECONDITION — `publishChange`, not `noteChange`.
        // `noteChange` accumulates and NEVER delivers (that is its contract:
        // safe inside loops, safe mid-drag), so a command whose LAST mesh
        // publisher is a note delivers only if some EARLIER call happened to
        // register the mesh with the open delivery batch — incidental, not
        // structural. Stage 2a moved the display family off the frame-drain
        // pull and onto the bus, and a wholesale replace that delivers nothing
        // would leave the mid-batch pull guard (`ensureDisplayCurrent`) with
        // no reason to re-upload before the next VBO reader. `publishChange`
        // accumulates identically and delivers at depth 0 / at the batch
        // close, so the delivery COUNT per command is unchanged (one) while
        // the delivery itself is now guaranteed.
        mesh.publishChange(MeshChangeAll);
        return true;
    }

    protected override void revertImpl() {
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
            document.noteLayerListChanged();
            // TASK 0671 — one exact restore. `apply()` re-homed a target onto a
            // document that had none so it had somewhere to write; undo owes
            // that back, and the snapshot is what owes it — the
            // `setActive` + `clearItemSelection` pair this replaces would now
            // put the re-homed item into a history bucket instead of forgetting
            // it, i.e. hand back a target the user never had.
            document.resetSelectionState();
            document.restoreItemSelection(prevSelection);
        }
        // Camera/viewport state isn't snapshotted — undoing a reset doesn't
        // restore the camera, only the mesh. The viewport reset is delegated
        // to the app layer (onViewportReset, fired only from apply()) and is
        // not part of model undo, same as before.
    }
}
