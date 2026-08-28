module commands.mesh.cut_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import geometry_clipboard : geometryClipboard, GeometryClip;
import mesh_edit_delta : MeshEditDelta, MeshEditScope, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Cut the currently selected faces: fill the clipboard with their geometry,
/// then delete them from the mesh.
///
/// Clipboard semantics on revert: the clipboard KEEPS the cut content after
/// undo — undoing a cut does not wipe the clip (standard cut/undo behavior).
///
/// Clipboard fill ordering (Minor 7): the clip is captured from the
/// pre-delete selection into a local `GeometryClip`, and only committed
/// to `geometryClipboard` after the delete confirms `affected > 0`. This
/// prevents a failed delete from silently overwriting a valid prior clip.
/// In practice the `hasAnySelectedFaces` guard makes 0-affected unreachable,
/// but the ordering makes the invariant local rather than relying on the
/// precondition.
///
/// ---------------------------------------------------------------------------
/// UNDO IS THE OPERATION-LOG DELTA (task 1903 Stage L4-d), not a whole-mesh
/// `MeshSnapshot`.
///
/// THIS CLASS IS IN THE SLICE/CUT ROW AND RUNS `mesh.delete`'S POLYGON KERNEL.
/// §5.5 files it beside `axis_slice` / `screen_slice` / `edge_slice`, but
/// `MeshCut` never touches `cutByPlane`: its kernel is `deleteFacesByMask`
/// plus a clipboard fill, i.e. exactly `MeshDelete`'s Polygons arm. Attribute
/// by the CALLEE, not by the file's position in the table. What follows is
/// therefore `MeshDelete`'s shape and not its neighbours' — and reusing
/// `MeshDelete`'s ordering rule rather than re-deriving it is deliberate:
/// that ordering is a shipped code-review BLOCKER (task 0613) and the second
/// derivation is where it gets got wrong.
///
/// THE OP-LOG, MEASURED on `makeTaggedGridFull(3)` under a recording batch:
///
///   an interior face  [MeshMapDelta RemoveFaces]
///   a CORNER face     [MeshMapDelta RemoveFaces RemoveVerts Reindex]
///
/// — the second because deleting a corner quad of an open sheet leaves its
/// outer vertex face-unreferenced and the kernel compacts. On a closed solid
/// every vertex is shared by three faces, so that half of the kernel is
/// unreachable; both cells are in
/// `tests/fixtures/undo_parity/slice_cut.json` for that reason.
///
/// THE BELTS ARE THE FAMILY'S TWO, NOT `MeshDelete`'S FOUR, and the difference
/// is measured rather than stylistic. Dropping each in turn and diffing
/// against the `MeshSnapshot` oracle on the same forward:
///
///   * `preSel_` (a `DenseSelectionUndo`) is LOAD-BEARING — without it
///     `faceMarks` diverges;
///   * `preMaps_` is INERT on THIS kernel (`RemoveFaces` carries its own
///     per-corner payload) and load-bearing on the four slices, which splice
///     and therefore put the maps out of step. It is carried here for
///     kernel-parity with `MeshDelete`, which holds it over the identical
///     kernel for the identical reason (the carry DECLINES rather than
///     guesses), and the inertness is recorded so nobody reads its presence
///     as evidence that it does work here;
///   * `preMarksWord_` and `preEdgeEnds_` — `MeshDelete`'s other two — are NOT
///     carried. Measured inert: `RemoveFaces` carries the whole face marks
///     word, and `DenseSelectionUndo` carries the edge selection by ENDPOINT
///     pair, which is what `preEdgeEnds_` existed for. A belt runs AFTER
///     `delta_.revert` and OVERWRITES what the replay restored, so an inert
///     belt makes the payload's output on this family UNOBSERVABLE — the
///     reason stage L5-e deleted three of them from `delete.d`.
class MeshCut : Command, Operator {
    mixin OperatorActrCommon;

    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    private MeshMap[]          preMaps_;
    /// Set once `evaluate` has recorded a delta — the redo discriminator and
    /// `revert()`'s guard, the job `snap.filled` used to do.
    private bool               recorded_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.cut"; }
    override string label() const { return "Cut"; }

    /// Geometry (faces removed, orphan verts compacted) + Marks (the kernel
    /// clears and re-derives the selection). The same pair `MeshDelete`
    /// declares, and NOT `kCutEditScope` — this kernel moves no vertex, so a
    /// `Position` bit here would be an over-declaration copied from a
    /// neighbour rather than read off the callee.
    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry | MeshEditScope.Marks;
    }

    override bool isOperationInverse() const { return recorded_; }

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded op-log, for the KIND
        /// SEQUENCE assertions in `tests/unit/l4_slice_cut_delta_test.d`.
        /// A LENGTH is satisfied by a broken log: stage J made the
        /// `[MeshMapDelta, <face entry>]` ADJACENCY contractual, and an
        /// interposed entry unpairs the corner restore SILENTLY while the
        /// geometry still round-trips.
        public ref const(MeshEditDelta) recordedDelta() const return {
            return delta_;
        }
    }

    override EditMode[] supportedModes() const {
        return [EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons) return false;
        if (!mesh.hasAnySelectedFaces())   return false;

        // Capture the clip from the pre-delete selection first (Minor 7):
        // build into a local and commit only after the delete succeeds.
        auto localClip = GeometryClip.fromSelectedFaces(*mesh);

        // REDO: re-run the kernel in an UNRECORDED batch from the restored
        // pre-op state. `revert()` put the selection back, so the mask below
        // is the same one the first run used, and the clipboard already holds
        // this content — re-committing the identical clip is a no-op the
        // ordering above makes harmless.
        if (recorded_) {
            size_t ra;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, editScope());
                ra = ed.deleteFacesByMask(ed.selectedFaces);
                ed.close();
            }
            if (ra == 0) return false;
            geometryClipboard = localClip;
            return true;
        }

        preSel_.capture(*mesh);
        preMaps_ = new MeshMap[](mesh.meshMaps.length);
        foreach (i, ref m; mesh.meshMaps) preMaps_[i] = m.dup;

        size_t affected;
        {
            auto ed = MeshEditBatch(*mesh, editScope());   // RECORDING
            affected = ed.deleteFacesByMask(ed.selectedFaces);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING, shared with `mesh.delete` / `mesh.remove` /
        // `mesh.cleanup` / `mesh.bevel` (Stage L3-a, ruling Q-K6). Two arms
        // and they are NOT the same event:
        //
        //   * `affected == 0` — the honest refusal. UNREACHABLE here, because
        //     `hasAnySelectedFaces` above already guaranteed a non-empty mask
        //     and `deleteFacesByMask` removes every face the mask names. The
        //     arm is written out rather than inherited from that reasoning:
        //     if the precondition ever moves, this rolls the mesh back instead
        //     of leaving a mutated document behind.
        //   * `affected > 0` over an EMPTY delta — the contradiction.
        //     `acceptRecordedEdit` refuses it and ticks
        //     `changeBus.emptyDeltaOverMutation`. Nothing rolls back there,
        //     deliberately: there is nothing to replay, and re-imposing the
        //     pre-op selection over a mesh whose arrays have already moved
        //     would resize the mark arrays back to the pre-op length. The live
        //     defect is documented at that counter's declaration.
        //
        // The clipboard is NOT committed on either arm — the whole point of
        // building into a local first.
        if (!acceptRecordedEdit(affected, delta_)) {
            if (affected == 0) {
                delta_.revert(*mesh);
                preSel_.restore(*mesh);
            }
            delta_   = MeshEditDelta.init;
            preSel_  = DenseSelectionUndo.init;
            preMaps_ = null;
            return false;
        }
        // Delete succeeded — now commit to the global clipboard.
        geometryClipboard = localClip;
        recorded_ = true;
        return true;
    }

    override bool revert() {
        if (!recorded_) return false;
        // The delta replay restores geometry; the clipboard intentionally
        // KEEPS its content — undoing a cut does not wipe the clip. That
        // contract is unchanged by the migration and is asserted, because a
        // migration that starts reverting the clipboard is a behaviour change
        // nobody asked for.
        delta_.revert(*mesh);
        if (preMaps_.length) {
            mesh.meshMaps.length = preMaps_.length;
            foreach (i, ref m; preMaps_) mesh.meshMaps[i] = m.dup;
        }
        preSel_.restore(*mesh);
        return true;
    }
}
