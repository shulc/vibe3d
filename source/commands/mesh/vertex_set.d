module commands.mesh.vertex_set;

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
        import toolpipe.packets : SubjectPacket;
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
        if (undoTrackerEnabled()) {
            auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, comp);
            undo_.arm(ed.close());
            if (!ok) { undo_.disarm(); return false; }
            return true;
        }
        // Legacy path — the SAME kernel through an UNRECORDED batch, so this
        // file's raw-write census row is 0 on BOTH paths.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed, comp);
        ed.close();
        return ok;
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

    override bool revert() {
        if (undo_.armed()) return undo_.revert(*mesh);
        // The tracker-off oracle (W-d3c). Its empty arm answers FALSE and is
        // UNREACHABLE with a history entry: the forward already refuses on
        // `!hasAnySelectedVertices()` (task 2110 §R2.1 row 8).
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

// ---------------------------------------------------------------------------
// Unit tests (task 1052). The reference-parity numbers are frozen in
// tests/fixtures/set_position_axis.json; what is pinned here is the property
// the parity fixture cannot state as sharply — that the OTHER two coordinates
// are not touched, and that `all` still collapses.
// ---------------------------------------------------------------------------
version (unittest) {
    import operator : VectorStack;
    import toolpipe.packets : SubjectPacket;

    private Vec3[] runSetPosition(string axis, float value, Vec3 pos,
                                  int[] selectVerts) {
        auto m = new Mesh;
        *m = makeCube();
        m.syncSelection();
        foreach (vi; selectVerts) m.selectVertex(vi);

        View v = new View(0, 0, 1, 1);
        auto c = new MeshSetPosition(m, v, EditMode.Vertices);
        foreach (ref p; c.params()) {
            if (p.name == "axis")  *p.sptr = axis;
            if (p.name == "value") *p.fptr = value;
            if (p.name == "pos")   *p.vptr = pos;
        }
        VectorStack vts;
        SubjectPacket subj;
        vts.put(&subj);
        c.evaluate(vts);
        return m.vertices.dup;
    }
}

// A single axis writes ONE coordinate. The mutation this catches: writing the
// whole vector (the pre-task behaviour), which would zero Y and Z as well.
unittest {
    auto before = makeCube().vertices.dup;
    auto after  = runSetPosition("x", 0.0f, Vec3(0, 0, 0), [0, 1, 2, 3]);
    foreach (vi; [0, 1, 2, 3]) {
        assert(after[vi].x == 0.0f, "x must be written");
        assert(after[vi].y == before[vi].y, "y must be left alone");
        assert(after[vi].z == before[vi].z, "z must be left alone");
    }
    foreach (vi; [4, 5, 6, 7])
        assert(after[vi] == before[vi], "unselected vertices must not move");
}

// y and z arms, with a NON-ZERO value — a rule that merely projected onto the
// axis plane would pass the value-0 case above and fail this one.
unittest {
    auto before = makeCube().vertices.dup;
    auto ay = runSetPosition("y", 0.25f, Vec3(0, 0, 0), [0, 1]);
    assert(ay[0].y == 0.25f && ay[1].y == 0.25f);
    assert(ay[0].x == before[0].x && ay[0].z == before[0].z);

    auto az = runSetPosition("z", -0.25f, Vec3(0, 0, 0), [0, 1]);
    assert(az[0].z == -0.25f && az[1].z == -0.25f);
    assert(az[0].x == before[0].x && az[0].y == before[0].y);
}

// The default arm is unchanged: `all` still collapses the selection onto one
// point. This is the back-compat assertion — the axis parameter must not have
// changed what a caller that never mentions it sees.
unittest {
    auto after = runSetPosition("all", 0.0f, Vec3(1, 2, 3), [0, 1, 2]);
    foreach (vi; [0, 1, 2])
        assert(after[vi] == Vec3(1, 2, 3),
            "axis:all must still write the whole pos vector");
}

// An unknown axis throws BEFORE moving anything.
unittest {
    import std.exception : collectExceptionMsg;
    import std.algorithm : canFind;
    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();
    m.selectVertex(0);
    auto before = m.vertices.dup;

    View v = new View(0, 0, 1, 1);
    auto c = new MeshSetPosition(m, v, EditMode.Vertices);
    foreach (ref p; c.params()) if (p.name == "axis") *p.sptr = "w";
    VectorStack vts;
    SubjectPacket subj;
    vts.put(&subj);
    auto msg = collectExceptionMsg(c.evaluate(vts));
    assert(msg.canFind("axis"), "the reject must name the axis: " ~ msg);
    assert(m.vertices == before, "nothing may have moved before the throw");
}
