module commands.mesh.vertex_set;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import math : Vec3;
import params : Param;
import change_bus : MeshEditScope;

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
    private int[]  idxs;
    private Vec3[] orig;

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

        // Read the selection mask ONCE (selectedVertices allocates a fresh bool[]
        // each call — re-calling inside the loop would be O(n²)).
        auto sel = mesh.selectedVertices;

        // Resolve the axis ONCE, outside the loop, and reject an unknown token
        // before a single vertex has moved — a half-applied edit would leave
        // the mesh in a state `revert()` describes only partially.
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

        idxs = [];
        orig = [];
        foreach (i; 0 .. sel.length) {
            if (!sel[i]) continue;
            idxs ~= cast(int)i;
            orig ~= mesh.vertices[i];
            if (comp < 0) {
                mesh.vertices[i] = pos_;
            } else {
                // One coordinate, world space; the other two keep their value.
                Vec3 p = mesh.vertices[i];
                if      (comp == 0) p.x = value_;
                else if (comp == 1) p.y = value_;
                else                p.z = value_;
                mesh.vertices[i] = p;
            }
        }

        mesh.commitChange(MeshEditScope.Position);
        return true;
    }

    override bool revert() {
        if (idxs.length == 0) return false;
        foreach (k; 0 .. idxs.length)
            mesh.vertices[idxs[k]] = orig[k];
        mesh.commitChange(MeshEditScope.Position);
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
