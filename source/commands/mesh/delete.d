module commands.mesh.delete_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditTracker, MeshEditScope,
                        captureSelectedEdgeEnds, restoreSelectedEdgeEnds,
                        acceptRecordedEdit;

/// Tier 1.1: delete the current selection. Dispatches by edit mode:
///   - Vertices: delete every face incident to a selected vert
///   - Edges:    delete every face incident to a selected edge
///   - Polygons: delete the selected faces directly
/// In all cases this funnels through Mesh.deleteFacesByMask, which
/// re-derives edges from the surviving faces and drops orphan verts.
///
/// Revert: the kernel run is wrapped in a Mesh edit batch and the resulting
/// operation-log MeshEditDelta drives undo (O(Δ) — see
/// doc/undo_change_tracker_plan.md Phase 3); redo re-runs the kernel batchless
/// from the restored pre-op state (the bulk-op forward replay is not used for
/// delete/dissolve, so the kernel is the forward authority and the delta
/// inverts undo only).
///
/// THE `VIBE3D_UNDO_TRACKER` FORK IS GONE (task 1903 stage L3-b). This class
/// held a second, whole-mesh `MeshSnapshot` arm reachable by one env var; it
/// was deleted together with `mesh.remove`'s, leaving fifteen
/// `undoTrackerEnabled()` branch sites in the tree (the two edge tools plus
/// thirteen commands whose fork is a DIFFERENT shape — it selects between a
/// recording and an `unrecorded` batch and holds no snapshot at all). What the
/// deleted arm was FOR is now a frozen fixture: `tests/fixtures/undo_parity/
/// delete_remove.json`, captured under both arms while they still existed and
/// read by `tests/unit/undo_parity_l3_test`, which compares the delta path's
/// undo against the snapshot path's on every plane the burn-in class covers —
/// materials, parts, mark words, selection order, set masks and mesh maps —
/// none of which the geometry-only gate this replaced could see.
class MeshDelete : Command, Operator {
    mixin OperatorActrCommon;

    // The undo entry is the operation-log delta + a lightweight pre-op
    // selection capture (the kernel clears selection, so revert must re-overlay
    // it).
    //
    // Vertex/face selection is captured by INDEX (the delta revert restores the
    // exact pre-op vertex/face index space, so the index-keyed SelectionSnapshot
    // re-aligns). Edge selection is captured by ENDPOINT PAIR — edges are
    // re-derived by rebuildEdges on revert and their ORDER is not guaranteed to
    // match the pre-op array, so an index-keyed restore would select the wrong
    // edges (doc §1.3, the same reason extrude uses EdgeSelByEnds).
    //
    // SUBPATCH (POL_TYPE) + HIDE (task 0613) planes are ALSO captured by face
    // index and re-overlaid on revert. The op-log delta's RemoveFaces only
    // carries the subpatch bit for the faces it DROPS; surviving-but-shifted
    // faces have their marks scrambled by the face re-insertion
    // (faces.insertInPlace shifts `faces` but not the faceMarks word — the
    // exact same class of bug fixed at deleteFacesByMask's own compaction in
    // task 0613 Stage 1, here on the REVERSE/undo side instead of the
    // forward side). The snapshot path restores the whole faceMarks word
    // (Select+Subpatch+Hide together) and so never had this gap. Capturing
    // the full pre-op word here, index-keyed (the delta revert restores the
    // exact pre-op face index space), re-establishes it bit-identically —
    // mirroring how preSel_ re-overlays the Select plane. (Found by the
    // Phase 4 burn-in gate: test_marks_authority B4 failed only under the
    // delta path.)
    private MeshEditDelta      delta_;
    private SelectionSnapshot  preSel_;     // vertex/face index-keyed
    private uint[]             preEdgeEnds_; // flat [a,b, a,b, …] for edge mode
    private uint[]             preMarksWord_; // face Subpatch+Hide plane, by pre-op face index
    private MeshMap[]          preMaps_;      // whole mesh-map set, by value, pre-op
    // THE THREE SELECTION-SET BELTS WERE DELETED AT TASK 1903 STAGE L5-e, and
    // the vacancy is written down rather than left as a silence.
    //
    // Task 2280 added a `preVertSetMask` / `preEdgeSetMask` / `preFaceSetMask`
    // belt here because a delta undo lost `vertexSetMask` and `edgeSetMask` on
    // every cell that compacts a vertex — a named selection set vanishing on
    // Ctrl+Z, on the shipped default path. That is now the STRUCTURAL payload
    // on `MeshOpEntry.Kind.RemoveVerts` (`vertSetMaskBefore` /
    // `edgeSetKeyDropped` / `edgeSetWordDropped`, Stage L5-b), captured at the
    // one publisher, `Mesh.compactUnreferenced`.
    //
    // WHY THE BELTS COULD NOT SIMPLY BE LEFT IN PLACE AS A SECOND LINE. A belt
    // runs AFTER `delta_.revert` and OVERWRITES what the replay restored, so
    // while both existed the payload's output on THIS family was never
    // observed: `tests/unit/undo_parity_l3_test` could not tell a working
    // payload from a broken one here, permanently. That is the "a second,
    // unnamed guard refuses first" shape, inverted.
    //
    // THE DELETION WAS RUN AS A CONTROL BEFORE IT WAS TAKEN, both ways, in
    // isolation (2026-08-28):
    //   * belt deleted, payload live      -> `undo_parity_l3_test` GREEN;
    //   * belt deleted, AND the payload's capture at `Mesh.compactUnreferenced`
    //     also deleted -> RED, `[mesh.delete/vertices/postUndo]: plane
    //     'vertexSetMask' differs from the frozen capture`, frozen
    //     `[1,0,0,0,0,1,...]` against `[1,0,0,0,0,0,...]`.
    // The first alone would only have shown that nothing looks; the pair shows
    // the payload does the work. `undo_parity_l3_test` is the standing gate on
    // it from here on.
    //
    // `faceSetMask` had no observed loss and was carried only so the third
    // plane's absence would not read as a decision; it goes with the other two.
    // The delta carries it through `RemoveFaces.faceSetMsk` and `FaceReindex`'s
    // copy of the same field — measured on `makeTaggedGridDirty(3)`, where it
    // comes back byte-identical with no belt of any kind.
    // Set once `evaluate` has recorded a delta. It is NOT the old
    // `useDelta_` under a new name doing the same job: with the fork gone
    // there is no other path to select, and what this flag now discriminates
    // is FIRST RUN from REDO — `evaluate` is called again on redo and must
    // re-run the kernel BATCHLESS, or the second run records a second delta
    // on top of the first. It is also `revert()`'s guard: an instance whose
    // `evaluate` refused holds an empty delta and must not replay it, which
    // is exactly what the deleted arm's `if (!snap.filled) return false;`
    // did.
    private bool               recorded_;

    // Stable label: captured once in runKernel() after effectiveDeleteMode
    // resolves the actual target type. Initialized to editMode at construction
    // so a label() read before apply() is still valid (returns the raw mode in
    // that case, consistent with pre-redirect behaviour). After apply() it
    // reflects exactly what ran — even for a cross-mode redirect.
    private EditMode appliedMode_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
        this.appliedMode_ = editMode;   // stable default before apply() runs
    }

    override string name()  const { return "mesh.delete"; }

    // Change-scope metadata (Phase 4 §b). Delete touches topology (faces removed,
    // verts dropped via compaction) + marks (selection cleared/re-derived).
    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry | MeshEditScope.Marks;
    }
    // True iff this instance actually stored an operation-log delta.
    //
    // NOT spelled `return true;`, and that is a deviation from the stage plan
    // taken deliberately. The plan expected `useDelta_` to collapse to a
    // constant once the fork went; it does not, because the field is
    // load-bearing for the redo arm (see `recorded_`). And a constant `true`
    // would be a claim about instances the class can genuinely be in —
    // constructed-but-not-applied, or refused — where no delta exists. The
    // field is the honest value and it IS `true` for every instance that
    // reaches the history stack, since `acceptRecordedEdit` guarantees a
    // non-empty delta before it is set.
    override bool isOperationInverse() const { return recorded_; }

    override string label() const {
        final switch (appliedMode_) {
            case EditMode.Vertices: return "Delete Vertices";
            case EditMode.Edges:    return "Delete Edges";
            case EditMode.Polygons: return "Delete Polygons";
        }
    }

    // The kernel mutation, shared by the first run and the redo re-run.
    // Returns the number of affected elements. Selection is read live (after
    // undo the SelectionSnapshot has restored it, so the redo mask matches).
    //
    // effectiveDeleteMode is used instead of the raw editMode so that a
    // selection that lives in a DIFFERENT element type from the active mode is
    // honoured. Without the redirect, nothingSelected(current) fires true and
    // the whole-mesh all-true mask wipes the mesh even though a selection
    // exists elsewhere (task 0110).
    private size_t runKernel() {
        const mode = mesh.effectiveDeleteMode(editMode);
        appliedMode_ = mode;   // freeze for label() — stable after apply()
        const all  = mesh.nothingSelected(mode);
        final switch (mode) {
            case EditMode.Vertices:
                // keepOrphans (measured, task delete-remove-dissolve): a vertex
                // dissolve removes EXACTLY the selected verts; other verts left
                // unreferenced because their faces degenerated stay as loose
                // points (the reference editor keeps these on non-cube geometry).
                return mesh.dissolveVerticesByMask(
                    mesh.operandVertexMask(EditMode.Vertices),
                    /*keepOrphans=*/true);
            case EditMode.Edges:
                auto n = mesh.removeEdgesByMask(mesh.operandEdgeMask());
                // Scope the 2-valent cleanup to the deleted edges' endpoints
                // (task 0474): a pre-existing 2-valent vertex the delete did not
                // touch — a 90° corner, a straight-through midpoint elsewhere —
                // must survive (reference-editor parity). keepOrphans keeps
                // collateral orphans the merge/cleanup leaves behind (task
                // delete-remove-dissolve).
                if (n > 0) mesh.dissolveDegree2Verts(mesh.edgeDeleteRegion(),
                                                     /*keepOrphans=*/true);
                return n;
            case EditMode.Polygons:
                return mesh.deleteFacesByMask(mesh.operandFaceMask());
        }
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        // Redo path: the delta already recorded the first run; re-run the
        // kernel BATCHLESS (no batch open ⇒ Ph1 hooks inert ⇒ no double
        // record) from the restored pre-op selection.
        if (recorded_) {
            const affected = runKernel();
            if (affected == 0) return false;
            return true;
        }

        // Empty selection ⇒ operate on the whole mesh (mesh.nothingSelected
        // is the single source of truth for the "everything is selected"
        // convention; runKernel feeds an all-true mask in that case).
        {
            // Capture the pre-op selection, then run the kernel inside a Mesh
            // edit batch so it self-records an operation-log delta.
            preSel_       = SelectionSnapshot.capture(*mesh);
            preEdgeEnds_  = captureSelectedEdgeEnds(*mesh);
            preMarksWord_ = mesh.faceMarks.dup;   // full marks word, by face index
            // Mesh maps, deep-copied by value (task 0693). This is a BELT over
            // the delta's own braces, and it is kept deliberately (owner's
            // call, task 0689): since 0689 the replay carries the per-corner
            // plane itself — relocating survivors and restoring the removed
            // faces' corners from the `MeshMapDelta` payload — so a delta undo
            // no longer comes back zeroed. But the carry DECLINES rather than
            // guesses whenever it cannot verify itself (maps out of step with
            // `faces`, provenance self-check), and this command holds the exact
            // pre-op state for one dup of a plane it is about to invalidate
            // anyway. On the paths where both act, they agree; where the carry
            // declines, this is what the user gets back instead of a zeroed
            // map. Redo needs no "after" copy because it re-runs the kernel
            // (see the `recorded_` redo branch above), which carries the map itself.
            preMaps_ = new MeshMap[](mesh.meshMaps.length);
            foreach (i, ref m; mesh.meshMaps) preMaps_[i] = m.dup;
            auto rec = MeshEditTracker();
            mesh.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
            // TASK 1903 S1 — the unwind path for the handle-less spelling.
            // The kernel below holds `enforce`/`throw new` sites; without this
            // an escaping `Exception` would leave the frame on
            // `g_editBatchStack` forever and every later `commitChange` on
            // this mesh would defer silently. `abortEditBatch` pops WITHOUT
            // stamping and no-ops once the frame is gone, which matters
            // because `scope(failure)` stays armed past the close.
            scope(failure) mesh.abortEditBatch();
            const affected = runKernel();
            delta_ = mesh.endEditBatch();
            // THE POST-CLOSE RULING lives in `mesh_edit_delta` and is
            // shared with `mesh.remove`, whose copy of these eight lines was
            // byte-identical (task 1903 stage L3-a). What it does has not
            // changed: BOTH arms refuse, the images below are still cleared,
            // and the command still answers `false`. What is new is that the
            // second arm — `affected > 0` with an EMPTY delta, a kernel that
            // mutated and recorded nothing — now ticks
            // `changeBus.emptyDeltaOverMutation` instead of passing silently.
            //
            // IT IS NOT A FIX. That arm is still a live defect: nothing rolls
            // the mesh back (`scope (failure)` does not fire on a plain
            // `return`, and no `MeshSnapshot` is captured on this path), so
            // the user gets a mutated mesh, `status:error` and NO history
            // entry, with the previous entry describing a state that no
            // longer exists. The counter converts an unattributable event
            // into a number; the ruling, and the two remedies refuted on the
            // tree, are at that counter's declaration in `change_bus.d`.
            //
            // Not reachable from the map-value seam: that seam's record door
            // DETECTS and appends, never withholds, precisely so it cannot
            // manufacture an empty delta out of a mutating kernel
            // (`MeshEditTracker.append`).
            if (!acceptRecordedEdit(affected, delta_)) {
                delta_        = MeshEditDelta.init;
                preSel_       = SelectionSnapshot.init;
                preEdgeEnds_  = null;
                preMarksWord_ = null;
                preMaps_      = null;
                return false;
            }
            recorded_ = true;
            return true;
        }
    }

    override bool revert() {
        // An instance whose `evaluate` refused holds an empty delta and every
        // pre-image nulled; replaying it would run the belts below over a
        // mesh they were never sized against. This refusal is what the
        // deleted snapshot arm's `if (!snap.filled) return false;` did.
        if (!recorded_) return false;
        {
            delta_.revert(*mesh);     // LIFO inverse replay restores geometry
            // Re-overlay the Subpatch + Hide (task 0613) planes FIRST: the
            // delta revert restored the pre-op face index space, so the
            // index-keyed capture re-aligns. `setFaceMarksFrom` is a FULL-WORD
            // ASSIGN, not a merge (`faceMarks[i] = w & keepMask`) — it must
            // therefore run BEFORE the selection restore below, or it
            // clobbers the Select bits that restore just wrote (code review
            // BLOCKER, task 0613: the old order zeroed every face's Select
            // bit two statements after preSel_ set it, and the comment here
            // claimed the opposite). `~Marks.Select` drops the Select bit
            // from the captured word so this write can never itself
            // resurrect a stale Select bit ahead of the restore below.
            // Mesh maps: put back the pre-op planes wholesale (task 0693).
            // The delta replay drops PolyVertex values whenever it renumbers
            // corners — an honest drop, but on the way BACK the pre-op state
            // is exactly what "undo" promises, and we hold it. Restored AFTER
            // the geometry replay (the maps are sized against it) and BEFORE
            // the selection restore, which does not touch maps. Empty capture
            // (mesh had no maps) restores nothing, which is also correct.
            if (preMaps_.length) {
                mesh.meshMaps.length = preMaps_.length;
                foreach (i, ref m; preMaps_) mesh.meshMaps[i] = m.dup;
            }
            if (preMarksWord_.length) {
                assert(preMarksWord_.length == mesh.faces.length,
                    "MeshDelete.revert: preMarksWord_ length != restored face "
                    ~ "count — the delta revert did not land on the exact "
                    ~ "pre-op face index space this capture assumes");
                mesh.setFaceMarksFrom(preMarksWord_, ~Mesh.Marks.Select);
            }
            // Re-overlay the pre-op selection on the restored geometry. Vertex/
            // face selection re-aligns by index. preSel_ also restores edge
            // selection by INDEX, but the re-derived edge order is not index-
            // stable across rebuildEdges, so OVERRIDE the edge selection with
            // the endpoint-keyed capture (clear the index-keyed edges first,
            // then re-resolve the recorded endpoints through edgeIndexMap).
            // setFacesSelectedFrom (called inside restore(), mesh.d) touches
            // ONLY the Select bit — it is safe to run AFTER the full-word
            // overwrite above without disturbing the Subpatch/Hide bits that
            // write just landed.
            preSel_.restore(*mesh);
            mesh.clearEdgeSelection();
            restoreSelectedEdgeEnds(*mesh, preEdgeEnds_);
            return true;
        }
    }
}
