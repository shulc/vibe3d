module vibe3d.editing.commands.editor.tests.unit.commands.mesh.vertex_set_source_public_test;

import vibe3d.editing.commands.editor.commands.mesh.vertex_set;

import std.array : uninitializedArray;
import vibe3d.editing.commands.runtime.command;
import vibe3d.editing.pipeline.contracts.operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode;
import vibe3d.viewport.gpu.shader;
import vibe3d.util.math.math : Vec3;
import vibe3d.editing.params.params : Param;
import vibe3d.mesh.change.change_bus : MeshEditScope;
import vibe3d.editing.commands.editor.commands.mesh.position_undo : PositionUndo;

// ---------------------------------------------------------------------------
// Unit tests (task 1052). The reference-parity numbers are frozen in
// tests/fixtures/set_position_axis.json; what is pinned here is the property
// the parity fixture cannot state as sharply — that the OTHER two coordinates
// are not touched, and that `all` still collapses.
// ---------------------------------------------------------------------------
version (unittest) {
    import vibe3d.editing.pipeline.contracts.operator : VectorStack;
    import vibe3d.editing.pipeline.contracts.toolpipe.packets : SubjectPacket;

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
