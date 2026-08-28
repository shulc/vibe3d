module commands.mesh.edge_slice;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import mesh_edit_delta : MeshEditDelta, MeshEditScope, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

// ---------------------------------------------------------------------------
// MeshEdgeSlice — cut a strip of edges through the mesh between two given edges.
//
// Params:
//   edges — two edge indices [edgeA, edgeB] (IntArray, required length == 2)
//   tA    — cut position along edgeA (float, default 0.5; range [0,1])
//   tB    — cut position along edgeB (float, default 0.5; range [0,1])
//
// The shortest dual-graph path from any face incident to edgeA to any face
// incident to edgeB is found by BFS; every face on the path is split into two
// sub-faces by a chord connecting the cut points on its two boundary edges.
// Interior path edges are cut at their midpoint (t=0.5) in v1.
//
// Index-share (no T-junctions): the cut vertex on each interior edge is
// inserted once and referenced by both adjacent path sub-faces by the same
// vertex index, identical to mesh.axisSlice.
//
// ---------------------------------------------------------------------------
// UNDO IS THE OPERATION-LOG DELTA (task 1903 Stage L4-a), not a whole-mesh
// `MeshSnapshot`. The kernel's own publishers do all the work — the family
// built none:
//
//   `Mesh.insertEdgePoint`             AddVerts + ReshapeFaces (Stage L2-c)
//   `Mesh.rebuildFacesWithChordSplits` FaceReindex             (Stage L2-d)
//
// so a recording batch around `edgeSliceEx` comes back with a log that
// `revert()` replays. Two belts sit beside it and both were chosen by
// MEASUREMENT rather than by copying a neighbour — see `revert()`.
//
// THIS CLASS GOES FIRST AMONG THE FAMILY'S MIGRATIONS, and the reason is its
// kernel's THREE outcome arms. It is the only member whose kernel contains its
// OWN rollback, and therefore the only place in the family where "the mesh is
// byte-identical to entry and the delta is NOT empty" is even expressible:
//
//   (i)   `facesSplit > 0`                      — a real chord split.
//   (ii)  `facesSplit == 0`, a vertex ADDED     — KEEP + FINALIZE. Pass 1
//         spliced a real vertex into the incident windings and Pass 2's
//         adjacent-hit guard then split nothing. `meshChanged` is TRUE and the
//         edit must be RECORDED. Op-log `[AddVerts, MeshMapDelta,
//         ReshapeFaces]` — the one place in this family where appends occur
//         with NO `FaceReindex`.
//   (iii) `facesSplit == 0`, no vertex added    — the TRUE no-op. The kernel
//         restores `faces` and `vertices` itself and `meshChanged` is FALSE.
//
// GATE ON `meshChanged`, NEVER ON `facesSplit`, and that is not style. Arm (ii)
// has `facesSplit == 0` and is a successful edit; an `affected = facesSplit`
// would hand `acceptRecordedEdit` a zero over a NON-EMPTY delta, which reads as
// the honest-refusal arm — so the command would answer `false`, revert a real
// edit, and record nothing, on an operand a user reaches with two clicks.
// (Fuzz found this arm once already; it is the same trap from the undo side.)
//
// AND ARM (iii) NEEDS NO UN-RECORD, MEASURED. `mesh.d`'s rollback used to carry
// a note saying a future batched caller "must add a matching un-record here".
// This is that caller. Read under the arm's own guard the hazard cannot happen
// — the arm is entered only when `vertices.length == vertsBeforePass1`, i.e.
// when no `addVertex` ran, and `recordAddVert` fires only from `addVertex`.
// Measured with a RECORDING batch around the kernel at `tA = 0, tB = 1`: the
// op-log is EMPTY and `revert()` answers true. The note in `mesh.d` was
// corrected in the same commit, and `tests/unit/undo_parity_l4_test.d`'s
// refusal block is the standing assertion on it.
// ---------------------------------------------------------------------------
class MeshEdgeSlice : Command, Operator {
    mixin OperatorActrCommon;

    /// The undo entry: the operation-log delta plus the two belts below.
    private MeshEditDelta      delta_;

    /// The three selection domains, their ORDER arrays and the edge selection
    /// keyed by ENDPOINT PAIR. Load-bearing: measured, dropping it leaves
    /// `faceMarks` diverging from what `MeshSnapshot.restore` produced.
    ///
    /// `DenseSelectionUndo` and not a bare `SelectionSnapshot`, which is what
    /// stage L3's two commands hold: the dense image copies the three
    /// selection-ORDER arrays back wholesale after `SelectionSnapshot`'s tail
    /// has re-zeroed the stamps of everything unselected, so an order stamp on
    /// an unselected element survives an undo here. With the bare snapshot
    /// this family would have needed a standing per-plane exception in its
    /// parity reader for `faceSelectionOrder`, exactly as L3 and L5 carry; the
    /// dense image costs one import and removes the licence.
    private DenseSelectionUndo preSel_;

    /// The mesh-map set, deep-copied by value. ALSO load-bearing, and this one
    /// is the family's own finding rather than an inherited belt.
    ///
    /// The plane cuts are in the documented per-corner DROP set
    /// (`Mesh.addEdgePoint`'s comment). A splice changes the mesh's TOTAL
    /// corner count while the PolyVertex maps are still the pre-op ones, so
    /// after the FIRST splice `recordPolyVertexPayload` finds the maps out of
    /// step with `faces` and DECLINES for the rest of the batch — visible in
    /// the op-log as one `MeshMapDelta` on the first face entry and none on
    /// the later ones. The FORWARD then zeroes the whole UV plane (measured:
    /// 96 values, 0 non-zero after one cut) and a bare delta replay cannot
    /// invent it back. `MeshSnapshot` restored it, so without this belt the
    /// migration would be a REGRESSION against the shipped path rather than a
    /// gap. Redo needs no "after" copy: it re-runs the kernel, which carries
    /// the map itself.
    private MeshMap[]          preMaps_;


    private uint[] edges_; // IntArray: the two edge indices
    private float  tA_   = 0.5f;
    private float  tB_   = 0.5f;

    this(Mesh* mesh, ref View view, EditMode editMode)
    {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.edgeSlice"; }
    override string label() const { return "Edge Slice"; }

    /// Geometry (vertices spliced in, faces chord-split) + Marks (the kernel
    /// re-derives the selection planes). NOT `kCutEditScope`'s `Position`:
    /// `edgeSliceEx` moves no existing vertex — only `cutByPlaneEx`'s Gap
    /// option does, and this class cannot reach it.
    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry | MeshEditScope.Marks;
    }

    override bool isOperationInverse() const { return undoRecorded(); }

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

    override Param[] params() {
        return [
            Param.intArray_("edges", "Edges", &edges_),
            Param.float_("tA", "t on Edge A", &tA_, 0.5f).min(0.0f).max(1.0f),
            Param.float_("tB", "t on Edge B", &tB_, 0.5f).min(0.0f).max(1.0f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (edges_.length != 2) return false;

        // REDO: the delta already recorded the first run; re-run the kernel
        // inside an UNRECORDED batch (Ph1 hooks take their
        // `editRecorder_ is null` first line, so nothing is recorded twice)
        // from the restored pre-op state. The batch itself is kept because
        // stage L4-P0 measured what it is worth: without it this kernel makes
        // FOUR unbatched geometry commits per run.
        if (undoRecorded()) {
            Mesh.EdgeSliceResult rr;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, editScope());
                rr = ed.edgeSliceEx(edges_[0], edges_[1], tA_, tB_);
                ed.close();
            }
            return rr.meshChanged;
        }

        preSel_.capture(*mesh);
        preMaps_ = new MeshMap[](mesh.meshMaps.length);
        foreach (i, ref m; mesh.meshMaps) preMaps_[i] = m.dup;

        Mesh.EdgeSliceResult r;
        {
            auto ed = MeshEditBatch(*mesh, editScope());   // RECORDING
            r = ed.edgeSliceEx(edges_[0], edges_[1], tA_, tB_);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING, shared with `mesh.delete` / `mesh.remove` /
        // `mesh.cleanup` / `mesh.bevel` (Stage L3-a, ruling Q-K6). The
        // `affected` count is `meshChanged`, NOT `facesSplit` — see the class
        // comment's arm (ii).
        //
        // `!r.meshChanged` is the kernel's TRUE no-op arm, and it has ALREADY
        // put `faces` and `vertices` back itself. The delta is empty there
        // (measured), so `delta_.revert` is a BELT over nothing; the belt that
        // is NOT redundant is `preSel_.restore`, because the kernel's rollback
        // does not touch the selection planes and `clearFaceSelectionResize` /
        // `syncSelection` may have run on the way in. Where the pre-flight
        // could not be done — the outcome is only known after the kernel — the
        // L2/L8 pre-flight-atomic rule's second branch applies: revert the
        // delta explicitly and answer `false`. Never `snap.restore` (there is
        // no snapshot any more) and never a `false` out of `revert()`, which
        // would pop the entry off BOTH history stacks.
        if (!acceptRecordedEdit(r.meshChanged ? 1 : 0, delta_)) {
            if (!r.meshChanged) {
                delta_.revert(*mesh);
                preSel_.restore(*mesh);
            }
            delta_   = MeshEditDelta.init;
            preSel_  = DenseSelectionUndo.init;
            preMaps_ = null;
            return false;
        }
        noteUndoRecorded();
        return true;
    }

    protected override void revertImpl() {
        // An instance whose `evaluate` refused holds an empty delta and every
        // pre-image cleared, and replaying it would run the belts over a mesh
        // they were never sized against. Nothing guards that HERE any more:
        // the refusal never raised the flag, so `Command.revert` answers
        // before this body is entered (task 2500). That is the job the
        // pre-migration `if (!snap.filled) return false;` did, and the job
        // `if (!recorded_) return false;` did after it.
        delta_.revert(*mesh);     // LIFO inverse replay restores geometry
        // Then the maps, sized against the restored geometry…
        if (preMaps_.length) {
            mesh.meshMaps.length = preMaps_.length;
            foreach (i, ref m; preMaps_) mesh.meshMaps[i] = m.dup;
        }
        // …and last the selection, which touches no map.
        preSel_.restore(*mesh);
    }
}
