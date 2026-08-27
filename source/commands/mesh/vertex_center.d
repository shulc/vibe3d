module commands.mesh.vertex_center;

import std.array : uninitializedArray;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import math : Vec3;
import params : Param;
import change_bus : MeshEditScope;
import mesh_edit_delta : undoTrackerEnabled;
import commands.mesh.position_undo : PositionUndo;

/// Zero the chosen axis component(s) of every selected vertex to the origin.
///
/// axis ∈ {x, y, z, all}
///
/// This is a "zero to origin" operation — NOT a centroid collapse (that is
/// mesh.collapse). Vertex count and topology are unchanged; verts that were
/// distinct before the call remain distinct after (even if they now share a
/// coordinate value). No welding occurs.
///
/// No-op (returns false) when nothing is selected or when an unknown axis
/// string is supplied.
///
/// Undo uses a lightweight per-index position restore (no topology change
/// requires the heavier MeshSnapshot path).
class MeshCenterVertices : Command, Operator {
    mixin OperatorActrCommon;

    private string axis_ = "all";

    // Position-restore undo state (lightweight — no topology change).
    private uint[] idxs;
    private Vec3[] orig;
    // Recorded `Kind.SetPos` undo (task 1903 L0-d4).
    private PositionUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 1903 §L0-d,
        /// witness W-d3a). The op-log SHAPE is not derivable from the outside:
        /// a command that records nothing falls back to its legacy revert and
        /// restores the right positions anyway, so every result-shaped
        /// assertion — the plane diff, the redo cell, the parity cell — is
        /// GREEN over a deleted recorder. Only reading the log itself is not.
        /// `version (unittest)`, so this is not a door in a shipped build; both
        /// gate lanes compile the sources with `-unittest`. `public` on the
        /// declaration and NOT a `public:` section — a section marker here
        /// would silently change the protection of every member below it.
        public ref const(PositionUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.centerVertices"; }
    override string label() const { return "Center Vertices"; }

    override Param[] params() {
        return [
            Param.enum_("axis", "Axis", &axis_,
                [["x","X"],["y","Y"],["z","Z"],["all","All"]], "all"),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null)      return false;
        if (!mesh.hasAnySelectedVertices())        return false;

        // Determine which axis components to zero.
        bool zx, zy, zz;
        if      (axis_ == "x")   { zx = true; }
        else if (axis_ == "y")   { zy = true; }
        else if (axis_ == "z")   { zz = true; }
        else if (axis_ == "all") { zx = zy = zz = true; }
        else return false;   // unknown axis string — guard against HTTP injection

        // §2.4 — the selection guard and the axis reject are BOTH resolved
        // before this point, so the batch opens clean. A `return` out of an
        // open batch leaves `~MeshEditBatch` to pop the frame and tick
        // `changeBus.batchLeaks`, asserted 0 by the suite.

        // REDO: re-run the kernel UNRECORDED and keep the first delta.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, zx, zy, zz);
            ed.close();
            return ok;
        }
        if (undoTrackerEnabled()) {
            auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, zx, zy, zz);
            undo_.arm(ed.close());
            if (!ok) { undo_.disarm(); return false; }
            return true;
        }
        // Legacy path — the SAME kernel through an UNRECORDED batch, so this
        // file's raw-write census row is 0 on BOTH paths.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed, zx, zy, zz);
        ed.close();
        return ok;
    }

    private bool applyKernel(ref MeshEditBatch ed, bool zx, bool zy, bool zz) {
        // Read the selection mask ONCE into a local (selectedVertices allocates a
        // fresh bool[] every call — re-calling it inside the loop wastes GC and
        // would be O(n²) for large meshes).
        auto sel = mesh.selectedVertices;

        // Task 1903 L0-d4 — local accumulate + ONE `ed.setVertexPositions`.
        idxs = [];
        orig = [];
        // PRE-SIZED, NOT APPEND-GROWN (task 2160) — see the note in
        // `MeshEditBatch.setVertexPositions`: `~=` is a runtime call per
        // element, and this array exists only to be handed to that setter and
        // dropped. The ceiling is exact (at most one entry per visited
        // vertex) and the unwritten tail is sliced off at the call.
        auto newPos = uninitializedArray!(Vec3[])(sel.length);
        size_t nNew = 0;
        foreach (i; 0 .. sel.length) {
            if (!sel[i]) continue;
            idxs ~= cast(uint)i;
            orig ~= mesh.vertices[i];
            Vec3 v = mesh.vertices[i];
            if (zx) v.x = 0;
            if (zy) v.y = 0;
            if (zz) v.z = 0;
            newPos[nNew++] = v;
        }

        ed.setVertexPositions(idxs, newPos[0 .. nNew]);
        ed.commitChange(MeshEditScope.Position);
        return true;
    }

    override bool revert() {
        if (undo_.armed()) return undo_.revert(*mesh);
        // The tracker-off oracle (W-d3c). Its empty arm answers FALSE and is
        // UNREACHABLE with a history entry: the forward already refuses on
        // `!hasAnySelectedVertices()`, the same predicate (task 2110 §R2.1
        // row 7).
        if (idxs.length == 0) return false;
        // TASK 1903 L0-d — THE LEGACY REVERT WRITES THROUGH THE BATCH TOO.
        // The plan's §2.5 template left this loop "untouched"; that is
        // incompatible with its own §1/§3/W-d1, which require this file to read
        // `countRawPositionWrites == 0` — §1's measured table counts THIS LOOP
        // among the file's raw writes. Resolved the way §2.5 already resolved
        // the forward: the same write, through the same primitive, on an
        // UNRECORDED batch. It stays a genuine oracle for W-d3c because it
        // restores from the command's own stored pre-op array while the delta
        // path replays the op-log's `posBefore` — two independent data paths
        // that share only the write primitive, which is what a mutation of the
        // RECORDING has to be measured against. Byte-identical to the loop it
        // replaces: `setVertexPositions` skips only writes whose new value is
        // BIT-identical to the current one, and writing identical bits back was
        // what the loop did there; the bounds guard is the same `continue`.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        ed.setVertexPositions(idxs, orig);
        ed.commitChange(MeshEditScope.Position);
        ed.close();
        return true;
    }
}
