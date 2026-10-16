module commands.mesh.vertex_set;

import std.array : uninitializedArray;
import command;
import vibe3d.editing.pipeline.contracts.operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode;
import shader;
import math : Vec3;
import vibe3d.editing.params.params : Param;
import vibe3d.mesh.change.change_bus : MeshEditScope;
import commands.mesh.position_undo : PositionUndo;

/// Set the position of every selected vertex — either all three coordinates
/// at once (`axis: all`, the default) or ONE of them (`axis: x|y|z`, leaving
/// the other two where they are).
///
/// This is an absolute-coordinate operation — distinct from mesh.move_vertex
/// (which identifies a vertex by its current coordinates and moves it by
/// from→to). Vertex count and topology are unchanged; no welding occurs even
/// when multiple selected vertices land on the same point.
///
/// No-op (returns false) when nothing is selected.
///
/// Undo uses lightweight per-index position restore.
///
/// ---------------------------------------------------------------------------
/// The single-axis arm, and what it is for (task 1052)
/// ---------------------------------------------------------------------------
/// `axis: x, value: 0` flattens the selection onto the X = 0 plane without
/// disturbing Y or Z — the "centre a loop of vertices for a mirror operation"
/// gesture, which the `pos` arm cannot express at all: writing a whole Vec3
/// collapses the loop to a single point.
///
/// Measured on the reference engine — its own Set Position command, driven
/// headlessly once per case with an axis token and a value:
///   * exactly one coordinate is written; the other two are left untouched.
///   * the default frame is WORLD — asking the reference explicitly for world
///     space produced a byte-identical result to the bare command.
///   * no welding: three vertices set to the same Z landed on top of each
///     other and stayed three vertices (8 verts / 12 edges before and after),
///     which is also what the `pos` arm has always done.
///
/// `all` is OURS, not the reference's — its axis argument offers exactly
/// x / y / z. It is the default so the pre-existing `pos` behaviour and its
/// callers are untouched, and it is named rather than implied so nobody reads
/// this command as a full port of the reference's four arguments.
///
/// NOT ported: the reference's Work Plane / World Space pair. Not an
/// oversight — `Command.apply()` builds a fresh `VectorStack` carrying exactly
/// one packet (`SubjectPacket`, see source/command.d), so an operator-command
/// reached through `/api/command` or through history CANNOT see a
/// `WorkplanePacket` at all. Offering the argument would mean threading the
/// WORK stage into the command path first; that is its own task.
class MeshSetPosition : Command, Operator {
    mixin OperatorActrCommon;

    private Vec3   pos_   = Vec3(0, 0, 0);
    private string axis_  = "all";
    private float  value_ = 0.0f;

    // Position-restore undo state.
    private uint[] idxs;
    private Vec3[] orig;
    // Recorded `Kind.SetPos` undo (task 1903 L0-d4).
    private PositionUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 1903 §L0-d,
        /// witness W-d3a). The op-log SHAPE is not derivable from the outside:
        /// a command that records nothing answers `true` from the BASE
        /// `Command.revert` (task 2500) and the mesh is already where the undo
        /// wants it, so every result-shaped assertion — the plane diff, the
        /// redo cell, the parity cell — is GREEN over a deleted recorder. Only
        /// reading the log itself is not.
        /// `version (unittest)`, so this is not a door in a shipped build; both
        /// gate lanes compile the sources with `-unittest`. `public` on the
        /// declaration and NOT a `public:` section — a section marker here
        /// would silently change the protection of every member below it.
        public ref const(PositionUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.setPosition"; }
    override string label() const { return "Set Position"; }

    override Param[] params() {
        return [
            Param.vec3_("pos", "Position", &pos_, Vec3(0, 0, 0)),
            Param.enum_("axis", "Axis", &axis_,
                        [["all", "All"], ["x", "X"], ["y", "Y"], ["z", "Z"]],
                        "all"),
            Param.float_("value", "Value", &value_, 0.0f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import vibe3d.editing.pipeline.contracts.toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null)  return false;
        if (!mesh.hasAnySelectedVertices())   return false;

        // Resolve the axis ONCE, outside the loop, and reject an unknown token
        // before a single vertex has moved — a half-applied edit would leave
        // the mesh in a state `revert()` describes only partially.
        //
        // §2.4, AND THIS IS THE CONCRETE SITE THE RULE WAS WRITTEN FOR. The
        // `throw` below must be resolved BEFORE the batch is opened. An
        // exception escaping an open batch unwinds through `~MeshEditBatch`,
        // which pops the leaked frame and ticks `changeBus.batchLeaks` — a
        // counter the suite asserts is 0. It cannot assert instead: that
        // destructor runs DURING unwinding, so an `Error` raised there would
        // replace the exception the command funnel is already handling and the
        // caller would get a process exit instead of `status:error`.
        int comp;   // -1 = write the whole Vec3
        switch (axis_) {
            case "all": comp = -1; break;
            case "x":   comp =  0; break;
            case "y":   comp =  1; break;
            case "z":   comp =  2; break;
            default:
                throw new Exception(
                    "mesh.setPosition: unknown axis '" ~ axis_
                    ~ "' — expected all, x, y or z");
        }

        // REDO: re-run the kernel UNRECORDED and keep the first delta.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, comp);
            ed.close();
            return ok;
        }
        auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed, comp);
        undo_.arm(this, ed.close());
        if (!ok) { undo_.disarm(this); return false; }
        return true;
    }

    private bool applyKernel(ref MeshEditBatch ed, int comp) {
        // Read the selection mask ONCE (selectedVertices allocates a fresh bool[]
        // each call — re-calling inside the loop would be O(n²)).
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
            if (comp < 0) {
                newPos[nNew++] = pos_;
            } else {
                // One coordinate, world space; the other two keep their value.
                Vec3 p = mesh.vertices[i];
                if      (comp == 0) p.x = value_;
                else if (comp == 1) p.y = value_;
                else                p.z = value_;
                newPos[nNew++] = p;
            }
        }

        ed.setVertexPositions(idxs, newPos[0 .. nNew]);
        ed.commitChange(MeshEditScope.Position);
        return true;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `RecordedUndo.arm` raises the flag
        // only for a NON-EMPTY delta, and `Command.revert` answers both the
        // empty-edit case and the never-applied case before this body runs. The
        // hand-rolled `setVertexPositions(touchedIdx, touchedPrev)` fallback that
        // used to sit under this line was reachable ONLY on `!armed()`, so it is
        // gone with the predicate that reached it.
        undo_.revert(*mesh);
    }
}

