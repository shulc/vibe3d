module commands.mesh.cleanup;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditScope,
                        captureSelectedEdgeEnds, restoreSelectedEdgeEnds,
                        acceptRecordedEdit;
import params : Param;

/// Sequential mesh hygiene sweep: optionally weld coincident vertices, drop
/// degenerate / zero-area faces, remove duplicate-vertex-set faces, remove
/// floating (unreferenced) vertices, and optionally dissolve 2-valent vertices.
/// Operates on the whole active mesh regardless of current selection.
/// Stage toggles and weld distance are exposed as command parameters.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L5-c; the whole-mesh
/// `MeshSnapshot` is gone. There is no fork to select between: this file never
/// carried `undoTrackerEnabled()` — the hatch's other sites are named in
/// `delete.d`, and stage N removed the flag entirely — so the recording batch
/// is unconditional, exactly as in
/// `commands/mesh/delete.d` after Stage L3-b. Redo re-runs the kernel
/// BATCHLESS from the restored pre-op state.
///
/// WHAT THE DELTA CANNOT CARRY, and therefore what the belts below are for.
/// Measured on `makeTaggedGridDirty(3)` after Stages L5-a and L5-b, as the
/// EXACT residual of an armed revert (every unnamed plane came back
/// byte-identical):
///
///   * the SELECT bit of `faceMarks` and `edgeMarks` — the kernel's tails
///     (`setFaceMarksFrom(…, ~Marks.Select)`, `clearFaceSelectionResize`,
///     `clearEdgeSelectionResize`) run AFTER the face rewrite, so no face
///     entry can describe them;
///   * Point-domain `MeshMap` VALUES on re-inserted vertices —
///     `removeVertsReverse` restores a dropped vertex's set membership (Stage
///     L5-b's payload) but still zeroes its map values, by the convention
///     stated at that function.
///
/// AND WHAT IS *NOT* HERE, stated because its absence is a measurement and not
/// an oversight: no `preVertSetMask_` / `preEdgeSetMask_` / `preFaceSetMask_`.
/// The first two are the structural `Kind.RemoveVerts` payload's job as of
/// Stage L5-b — this command is the reason that payload exists rather than a
/// fourth copy of `delete.d`'s belt — and `faceSetMask` was measured to come
/// back on its own, carried by `RemoveFaces.faceSetMsk` and `FaceReindex`'s
/// copy of the same field.
class MeshCleanup : Command, Operator {
    mixin OperatorActrCommon;

    private MeshEditDelta      delta_;
    private SelectionSnapshot  preSel_;       // vertex/face index-keyed
    private uint[]             preEdgeEnds_;  // flat [a,b, a,b, …]
    private uint[]             preMarksWord_; // face Subpatch+Hide, by pre-op index
    private MeshMap[]          preMaps_;      // whole mesh-map set, by value, pre-op

    // Parameter backing fields — defaults match CleanupOptions.init.
    private bool  dropDegenerate_  = true;
    private bool  unify_           = true;
    private bool  removeOrphans_   = true;
    private bool  dissolve2Valent_ = false;
    private bool  mergeVerts_      = true;
    private float dist_            = 1e-5f;  // linear weld distance

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.cleanup"; }
    override string label() const { return "Mesh Cleanup"; }

    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry;
    }

    override Param[] params() {
        return [
            Param.bool_("dropDegenerate",  "Remove Degenerate Faces",    &dropDegenerate_,  true),
            Param.bool_("unify",           "Unify Duplicate Faces",      &unify_,           true),
            Param.bool_("removeOrphans",   "Remove Floating Vertices",   &removeOrphans_,   true),
            Param.bool_("dissolve2Valent", "Dissolve 2-Valent Vertices", &dissolve2Valent_, false),
            Param.bool_("mergeVerts",      "Merge Coincident Vertices",  &mergeVerts_,      true),
            Param.float_("dist", "Merge Distance", &dist_, 1e-5f)
                 .min(1e-7f).max(10.0f).fmt("%.5f"),
        ];
    }

    override bool paramEnabled(string name) const {
        if (name == "dist") return mergeVerts_;
        return true;
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        CleanupOptions opts;
        opts.dropDegenerate  = dropDegenerate_;
        opts.unify           = unify_;
        opts.removeOrphans   = removeOrphans_;
        opts.dissolve2Valent = dissolve2Valent_;
        opts.mergeVerts      = mergeVerts_;
        opts.weldEpsSq       = cast(double)dist_ * cast(double)dist_;

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS — no batch open means every tracker hook takes its
        // `editRecorder_ is null` early-out — and keep the FIRST delta rather
        // than record a second one over it.
        if (undoRecorded()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, kCleanupEditScope);
            const rr = ed.cleanupMesh(opts);
            ed.close();
            return rr.anyAffected();
        }

        // TASK 1903 Stage E1 — the kernel takes `ref MeshEditBatch`, so the
        // batch opens HERE, at the command boundary, and never inside the
        // kernel (plan §4.1). This is the caller with the most to gain: a
        // default sweep runs SIX stages, each of which commits at least once
        // on its own (weld → Geometry, degenerate → Geometry, unify →
        // Geometry + Points, two compactions → Points each). Inside the batch
        // they defer and stamp once at `close()`.
        //
        // TASK 1903 Stage L5-c — and it is RECORDING now. The belts are
        // captured first, in `MeshDelete`'s shape and for the residual named
        // at this class's doc comment.
        preSel_       = SelectionSnapshot.capture(*mesh);
        preEdgeEnds_  = captureSelectedEdgeEnds(*mesh);
        preMarksWord_ = mesh.faceMarks.dup;
        preMaps_ = new MeshMap[](mesh.meshMaps.length);
        foreach (i, ref mm; mesh.meshMaps) preMaps_[i] = mm.dup;

        // THE RAII HANDLE, not `beginEditBatch`/`endEditBatch` + a
        // `scope(failure)`: `cleanupMesh` takes `ref MeshEditBatch` (Stage E1),
        // so the handle is the only spelling that can call it, and mixing the
        // two spellings on one edit is what `MeshEditBatch.close`'s own assert
        // exists to catch. The unwind path is then the destructor's: it pops
        // the frame WITHOUT stamping and ticks `changeBus.batchLeaks`, which
        // the suite asserts is 0 — the same exposure the UNRECORDED batch this
        // line replaces already had.
        CleanupResult r;
        {
            auto ed = MeshEditBatch(*mesh, kCleanupEditScope);   // RECORDING
            r = ed.cleanupMesh(opts);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING, shared with `mesh.delete` / `mesh.remove`
        // (task 1903 Stage L3-a, ruling Q-K6). `affected == 0` is the HONEST
        // refusal this command has always made — `anyAffected() == false` means
        // no stage mutated anything, so the mesh is byte-identical to entry and
        // `tests/unit/undo_parity_l5_test.d`'s refusal block asserts exactly
        // that. `affected > 0` with an EMPTY delta is the contradiction, and it
        // ticks `changeBus.emptyDeltaOverMutation` instead of passing silently;
        // before Stage L5-a that arm was REACHABLE here — a weld-only sweep
        // closed with an empty op-log over a real mutation — which is why the
        // arming commit came first.
        //
        // §6.5 item 1: the refusal returns `false` and drops every image. It
        // is NOT spelled as a `false` from `revert()`: that pops the entry off
        // BOTH history stacks and truncates the suffix after it
        // (`command_history.d`, regression 0099).
        immutable size_t affected = r.welded + r.degenerate + r.unified
                                  + r.orphans + r.dissolved + r.finalOrphans;
        if (!acceptRecordedEdit(affected, delta_)) {
            delta_        = MeshEditDelta.init;
            preSel_       = SelectionSnapshot.init;
            preEdgeEnds_  = null;
            preMarksWord_ = null;
            preMaps_      = null;
            return false;
        }
        noteUndoRecorded();
        return true;
    }

    protected override void revertImpl() {
        // An instance whose `evaluate` refused holds an empty delta and every
        // pre-image nulled; replaying it would run the belts below over a mesh
        // they were never sized against.

        delta_.revert(*mesh);     // LIFO inverse replay restores geometry

        // THE ORDER IS `delete.d:309`–`:322`'s AND IT IS LOAD-BEARING: maps →
        // marks word → selection. `setFaceMarksFrom` is a FULL-WORD ASSIGN,
        // not a merge, so it must run BEFORE the selection restore or it
        // clobbers the Select bits that restore just wrote — the old order did
        // exactly that and it is a code-review BLOCKER note in `delete.d`.
        // `~Marks.Select` drops the Select bit from the captured word so this
        // write can never itself resurrect a stale one.
        //
        // Maps first: they are sized against the geometry the replay just
        // restored, and the selection restore does not touch them. An empty
        // capture restores nothing, which is also correct.
        if (preMaps_.length) {
            mesh.meshMaps.length = preMaps_.length;
            foreach (i, ref mm; preMaps_) mesh.meshMaps[i] = mm.dup;
        }
        if (preMarksWord_.length) {
            assert(preMarksWord_.length == mesh.faces.length,
                "MeshCleanup.revert: preMarksWord_ length != restored face "
              ~ "count — the delta revert did not land on the exact pre-op "
              ~ "face index space this capture assumes");
            mesh.setFaceMarksFrom(preMarksWord_, ~Mesh.Marks.Select);
        }
        // Vertex/face selection re-aligns by index. `preSel_` also restores
        // edge selection by INDEX, but the re-derived edge order is not
        // index-stable across `rebuildEdges`, so OVERRIDE the edge selection
        // with the endpoint-keyed capture.
        preSel_.restore(*mesh);
        mesh.clearEdgeSelection();
        restoreSelectedEdgeEnds(*mesh, preEdgeEnds_);
    }
}
