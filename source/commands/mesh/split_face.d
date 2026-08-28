module commands.mesh.split_face;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import params : Param;
import selection_product : dropConsumedFaces;
import mesh_edit_delta : MeshEditScope;
import commands.mesh.position_undo  : RecordedUndo;
import commands.mesh.map_edit_undo  : runMapEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// `mesh.splitFace` — split a polygon into two faces along a chord connecting
/// two of its existing, non-adjacent winding vertices.
///
/// Input modes (evaluated in order):
///   1. Explicit params: `a` and `b` are valid vertex indices.  If `face` is
///      also provided, that face is split; otherwise the first face containing
///      both `a` and `b` non-adjacently is used.
///   2. Selection mode: at least two selected vertices; the chord runs between
///      the FIRST TWO IN SELECTION ORDER (`Mesh.vertexSelectionOrder`, the same
///      1-based click counter `mesh.makePolygon` reads its winding from), and
///      the first face containing both non-adjacently is used.
///
///      Task 1200, ledger row 20: with THREE vertices selected on one n-gon the
///      reference cuts exactly ONE chord — between the first two selected — and
///      leaves the third alone. We used to refuse the whole command whenever the
///      count was not exactly two. Frozen in
///      `tests/fixtures/poly_split_first_chord.json`.
///
///      A caveat worth stating because the frozen cell cannot: on that cell the
///      selection order and the ascending index order COINCIDE (verts 0, 2, 4
///      picked in that order), so it does not discriminate "first two selected"
///      from "two lowest indices". Selection order is what the ledger records as
///      the reference's law and what is implemented here; if that is ever
///      measured to be wrong, this is the line to change, and it needs a cell
///      whose click order runs against its index order.
///
/// Winding: the two child faces are `face[i..j+1]` and `face[j..]~face[0..i+1]`
/// (scan order, i < j); the ordering of `a` vs `b` does not affect geometry
/// since `rebuildFacesWithChordSplits` always scans the winding in order.
///
/// Rejections (no-op — no snapshot, no undo entry):
///   - Fewer than 2 selected vertices (selection mode).
///   - Specified / derived verts are the same, out-of-bounds, or absent from
///     the target face winding.
///   - Verts are adjacent in the face winding (chord == existing edge).
///   - No qualifying face can be found.
/// TASK 1903 STAGE L2-d — UNDO IS THE OPERATION-LOG DELTA, and this is the one
/// row of stage L2 whose kind is `Kind.FaceReindex`. `rebuildFacesWithChordSplits`
/// used to install its result with a raw `faces._store = …` plus five
/// hand-rebuilt plane assignments; it now goes through `mesh_planes.rewriteFaces`
/// under an explicit `faceReindexScope()`, so a recording batch comes back with
/// exactly one `FaceReindex` entry (paired with its per-corner payload) instead
/// of an EMPTY log whose `revert()` answered `true` with the split still in.
///
/// WHY NOT `AddFaces` + `ReshapeFaces`, the cheaper-looking route: three of the
/// five per-face planes a chord split rewrites — `faceMaterial`, `facePart`,
/// `faceSetMask` — have no restorer anywhere outside `Kind.RemoveFaces`, and a
/// split renumbers every face after the parent. They would come back shifted by
/// one and no count, no geometry compare and no `opInverse` bit could see it.
class MeshSplitFace : Command, Operator {
    mixin OperatorActrCommon;
    private RecordedUndo     undo_;
    /// The pre-op selection — `dropConsumedFaces` clears the two halves' Select
    /// bits and the op-log has nothing that puts them back. See
    /// `commands/mesh/selection_undo.d`.
    private DenseSelectionUndo preSel_;

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (see `MeshFlip`).
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    private int face_ = -1;
    private int a_    = -1;
    private int b_    = -1;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.splitFace"; }
    override string label() const { return "Split Face"; }

    override MeshEditScope editScope() const { return MeshEditScope.Geometry; }

    /// See `MeshFlip.isOperationInverse` — a cheap tell, not the observable.
    override bool isOperationInverse() const { return undo_.armed(); }

    override Param[] params() {
        return [
            Param.int_("face", "Face",     &face_, -1),
            Param.int_("a",    "Vertex A", &a_,    -1),
            Param.int_("b",    "Vertex B", &b_,    -1),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        import std.algorithm : canFind;

        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        uint faceIdx = uint.max;
        uint vA      = uint.max;
        uint vB      = uint.max;

        if (a_ >= 0 && b_ >= 0) {
            // ----- Explicit params mode -----
            vA = cast(uint)a_;
            vB = cast(uint)b_;
            if (face_ >= 0) {
                faceIdx = cast(uint)face_;
            } else {
                // Derive the first face containing both vA and vB non-adjacently.
                faceIdx = findQualifyingFace(*mesh, vA, vB, uint.max);
            }
        } else {
            // ----- Selection mode -----
            if (!mesh.hasAnySelectedVertices()) return false;

            // Order by the click counter, exactly as mesh.makePolygon does:
            // click-ordered verts first by ascending counter, then any that were
            // selected through a bulk path (order == 0, e.g. select.all / box /
            // lasso) by ascending index. Two entries is all this command needs,
            // but the SORT has to see the whole selection to know which two come
            // first.
            const sv = mesh.selectedVertices;
            const so = mesh.vertexSelectionOrder;
            struct VOrderPair { uint vi; int order; }
            VOrderPair[] sel;
            foreach (vi; 0 .. sv.length) {
                if (!sv[vi]) continue;
                sel ~= VOrderPair(cast(uint)vi, (vi < so.length) ? so[vi] : 0);
            }

            if (sel.length < 2) return false;
            import std.algorithm : sort;
            sort!((x, y) {
                int ox = (x.order > 0) ? x.order : int.max;
                int oy = (y.order > 0) ? y.order : int.max;
                if (ox != oy) return ox < oy;
                return x.vi < y.vi;
            })(sel);
            // The first two SELECTED, and only they — a third selected vertex is
            // not a second chord and not a fallback pair to try if this one does
            // not qualify (ledger row 20: ONE chord).
            vA = sel[0].vi;
            vB = sel[1].vi;

            faceIdx = findQualifyingFace(*mesh, vA, vB, uint.max);
        }

        if (faceIdx == uint.max) return false;
        if (vA == uint.max || vB == uint.max) return false;

        // THE REFUSAL IS PRE-FLIGHT AND ATOMIC — VERIFIED, NOT ASSUMED, which is
        // what the L8 rule asks of the four commands that used to
        // `snap.restore` on a kernel refusal (plan §L2.4). Every one of
        // `splitFaceByVertices`' seven refusal conditions is answered before
        // its first write, and `rebuildFacesWithChordSplits` returns 0 on
        // `nSplit == 0` BEFORE it installs anything. So the `snap.restore` this
        // replaces was rolling back a mutation that could not have happened,
        // and the kernel below may simply answer false from inside the batch:
        // `runMapEdit` closes it, disarms the empty delta, and `applyImpl`
        // lands no history entry. Under a delta the old shape would be
        // unavailable anyway — `MeshEditDelta` carries no pre-image of the face
        // array, so nothing downstream could detect a half-revert.
        // Task 1180: the split face's own selection does not survive it. The
        // kernel (`rebuildFacesWithChordSplits`) copies the Select bit onto
        // BOTH halves, and the reference selects neither — so the two children,
        // and only they, are dropped. `rebuildFacesWithChordSplits` emits faces
        // in index order and splits exactly one face here, so the halves are
        // `faceIdx` and `faceIdx + 1`; everything before keeps its index and
        // everything after shifts by one, carrying its own selection with it.
        //
        // Until 1180 this never showed: nothing upstream left a polygon
        // selected, so the split's target was never selected in the first
        // place. `mesh.mergeFaces` now re-points at the merged face, and a
        // merge-then-split carried that face's selection into both halves.
        //
        // The narrowness is measured, not cautious — `dropConsumedFaces` names
        // the two frozen cases that kill the two wider rules (carry the bit
        // down; clear the whole polygon layer). The second of them also says
        // the reference does NOT clear the polygon layer on a vertex-mode
        // select, which is why this lives here and not in the select path.
        const bool applied_ = runMapEdit(this, mesh, undo_, MeshEditScope.Geometry,
                              (ref MeshEditBatch ed) => runKernel(ed, faceIdx, vA, vB));
        return applied_;
    }

    /// The one mutating body, under whichever arm `runMapEdit` chose.
    private bool runKernel(ref MeshEditBatch ed, uint faceIdx, uint vA, uint vB) {
        // Recording arm only — the redo arm keeps the first capture, the hatch
        // has the snapshot.
        if (ed.recording() && !preSel_.filled()) preSel_.capture(ed.mesh);

        if (ed.mesh.splitFaceByVertices(faceIdx, vA, vB) == 0) return false;

        // Task 1180: the split face's own selection does not survive it. The
        // kernel (`rebuildFacesWithChordSplits`) copies the Select bit onto
        // BOTH halves, and the reference selects neither — so the two children,
        // and only they, are dropped. `rebuildFacesWithChordSplits` emits faces
        // in index order and splits exactly one face here, so the halves are
        // `faceIdx` and `faceIdx + 1`; everything before keeps its index and
        // everything after shifts by one, carrying its own selection with it.
        //
        // Until 1180 this never showed: nothing upstream left a polygon
        // selected, so the split's target was never selected in the first
        // place. `mesh.mergeFaces` now re-points at the merged face, and a
        // merge-then-split carried that face's selection into both halves.
        //
        // The narrowness is measured, not cautious — `dropConsumedFaces` names
        // the two frozen cases that kill the two wider rules (carry the bit
        // down; clear the whole polygon layer). The second of them also says
        // the reference does NOT clear the polygon layer on a vertex-mode
        // select, which is why this lives here and not in the select path.
        dropConsumedFaces(&ed.mesh(), [faceIdx, faceIdx + 1]);
        return true;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
        preSel_.restore(*mesh);
    }
}

// ---------------------------------------------------------------------------
// Helper: scan faces to find the first one that contains both vA and vB at
// non-adjacent winding positions.  `preferFace` is checked first when valid.
// Returns uint.max when no qualifying face exists.
// ---------------------------------------------------------------------------
private uint findQualifyingFace(ref const(Mesh) m, uint vA, uint vB, uint preferFace)
{
    if (vA >= m.vertices.length || vB >= m.vertices.length) return uint.max;
    if (vA == vB) return uint.max;

    // Inner helper: check a single face index.
    bool qualifies(uint fi) {
        if (fi >= m.faces.length) return false;
        const face = m.faces[fi];
        size_t posA = size_t.max, posB = size_t.max;
        foreach (k; 0 .. face.length) {
            if (face[k] == vA) posA = k;
            if (face[k] == vB) posB = k;
        }
        if (posA == size_t.max || posB == size_t.max) return false;
        // Adjacency check (same as rebuildFacesWithChordSplits:7741).
        size_t i = posA < posB ? posA : posB;
        size_t j = posA < posB ? posB : posA;
        bool adj = (j == i + 1) || (i == 0 && j == face.length - 1);
        return !adj;
    }

    if (preferFace != uint.max && qualifies(preferFace)) return preferFace;

    foreach (fi; 0 .. cast(uint)m.faces.length)
        if (qualifies(fi)) return fi;

    return uint.max;
}
