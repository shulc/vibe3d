module commands.mesh.array_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math    : Vec3;
import params  : Param;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Linear array — insert `count-1` shifted copies of the selected
/// faces (or the whole mesh when nothing is selected). `count`
/// includes the original. `weld > 0` folds
/// coincident verts and drops duplicate seam polygons (same dedup
/// pipeline as `mesh.mirror`).
///
/// Per-step rotate / scale are deferred to a follow-up — see
/// doc/duplicate_plan.md. The `*.Radial Array` tool (PR-4) carries
/// the rotation pivot/axis schema so it's the natural home for those
/// modes.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L6-b; the whole-mesh
/// `MeshSnapshot` is gone.
///
/// THIS IS THE MEMBER WITH TWO APPEND ROUNDS AND THE FAMILY'S ONLY WINDING
/// INSTALL. With `detachSubsetSource` on and a strict-subset selection,
/// `Mesh.arrayFaces` duplicates the source faces' verts at offset 0 and
/// REPOINTS the source faces at the duplicates (the captured array-tool copy
/// model). Those repoints used to be indexed writes reaching no hook — the
/// forward was fine and the revert left every detached source face pointing at
/// its duplicate, with V/F/E and every mark word round-tripping, so ONLY a
/// per-winding compare could see it. Stage L6-b routes them through
/// `Mesh.setFaceWindings`, one BULK call for the round, and the two vertex
/// rounds are recorded either side of it so the LIFO reverse restores the
/// windings BEFORE truncating the duplicates away.
///
/// The op-log on the detach path with a firing weld, measured on
/// `makeTaggedGridFull(3)`: `[AddVerts, MeshMapDelta, ReshapeFaces, AddVerts,
/// AddFaces, MeshMapDelta, FaceReindex, RemoveVerts, Reindex]`. The
/// `FaceReindex` is stage L5-a's arming of `Mesh.applyVertexRemap`, INHERITED
/// through the weld — this stage arms nothing of its own.
///
/// WHAT IS INERT ON THIS PATH, said so a green is not read as coverage: the
/// two `Kind.RemoveVerts` payloads (the set-mask half, stage L5-b; the
/// Point-domain map-value half, task 2330) never carry anything here.
/// Measured: this family's weld only ever merges a CLONE into an ORIGINAL, so
/// `compactUnreferenced` drops only APPENDED slots, and an appended slot was
/// never in a named set and never carried a Point-map value.
class MeshArray : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;

    private int   count_  = 2;
    private Vec3  offset_ = Vec3(1, 0, 0);
    private float weld_   = 0.001f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.array"; }
    override string label() const { return "Array"; }

    // Edit-mode-orthogonal — same as mesh.mirror. The operation reads
    // the face selection (or whole mesh if empty), independent of
    // which selection mode the user is currently in.

    override MeshEditScope editScope() const {
        return cast(MeshEditScope) kDuplicateEditScope;
    }

    /// True iff this instance actually stored an operation-log delta — see
    /// `MeshDelete.isOperationInverse` for why this is not `return true;`.
    override bool isOperationInverse() const { return undoRecorded(); }

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded op-log. The cells assert a
        /// KIND SEQUENCE and never a length: stage J made the
        /// `[MeshMapDelta, <face entry>]` adjacency contractual, and an
        /// interposed entry unpairs the corner carry SILENTLY while the
        /// geometry still round-trips — a length check cannot see that.
        public ref const(MeshEditDelta) recordedDelta() const return {
            return delta_;
        }
    }

    override Param[] params() {
        return [
            // `.max(256).enforceBounds()` matches Mesh.arrayFaces'
            // internal `MAX_ARRAY_COUNT` cap — `.min()`/`.max()` alone are
            // UI-only hints and do not clamp a raw HTTP
            // `tool.attr`/`/api/command` write, so the Param bound is
            // added to agree with the kernel backstop (defense-in-depth).
            Param.int_  ("count",  "Count",  &count_,  2).min(1).max(256).enforceBounds(),
            Param.vec3_ ("offset", "Offset", &offset_, Vec3(1, 0, 0)),
            Param.float_("weld",   "Weld Distance", &weld_, 0.001f).min(0.0f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;
        if (count_ <= 1)            return false;

        // Build face mask (empty user selection ⇒ whole mesh, same
        // convention as mesh.mirror / mesh.smooth).
        // L1 funnel (task 0613, S5): selected faces, else every VISIBLE face.
        bool[] mask = mesh.operandFaceMask();

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS and keep the FIRST delta rather than record a second one
        // over it.
        if (undoRecorded()) {
            size_t ri;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kDuplicateEditScope);
                ri = ed.arrayFaces(mask, count_, offset_, weld_, true);
                ed.close();
            }
            return ri != 0;
        }

        preSel_.capture(*mesh);

        // detachSubsetSource: reference parity for a PARTIAL selection — the
        // the captured array behavior replaces each source poly with `count` fresh
        // copies (seam verts duplicated) rather than keeping the source and
        // appending count-1 (seam verts shared). No-op for a whole-mesh array.
        // The interactive Clone tool/command deliberately leave this off.
        size_t inserted;
        {
            auto ed = MeshEditBatch(*mesh, kDuplicateEditScope);
            inserted = ed.arrayFaces(mask, count_, offset_, weld_, true);
            delta_ = ed.close();
        }
        if (!acceptRecordedEdit(inserted, delta_)) {
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        noteUndoRecorded();
        return true;
    }

    protected override void revertImpl() {
        delta_.revert(*mesh);     // LIFO inverse replay restores geometry
        preSel_.restore(*mesh);   // …then the three selection domains
    }
}
