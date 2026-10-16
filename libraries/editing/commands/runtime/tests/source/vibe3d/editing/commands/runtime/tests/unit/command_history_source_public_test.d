module vibe3d.editing.commands.runtime.tests.unit.command_history_source_public_test;

import vibe3d.editing.commands.runtime.command : Command, CmdFlags;
import vibe3d.editing.commands.runtime.command_history : CommandHistory;

version (unittest) {
    private final class _EpochTestCmd : Command {
        import vibe3d.mesh.core.mesh    : Mesh;
        import vibe3d.viewport.camera.view    : View;
        import vibe3d.editing.contracts.editmode : EditMode;
        private Mesh  _mesh;
        private View  _view = new View(0, 0, 1, 1);
        this() { super(&_mesh, _view, EditMode.Vertices); }
        override string   name()  const { return "test.epoch"; }
        override string   label() const { return "EpochTest"; }
        override CmdFlags cmdFlags() const { return CmdFlags.Model; }
        protected override bool applyImpl()  { return true; }
    }
}


unittest { // record→undo bumps undoEpoch by 1; redo does NOT bump
    auto h = new CommandHistory();
    assert(h.undoEpoch == 0);

    auto cmd = new _EpochTestCmd();
    cmd.apply();
    h.record(cmd);
    assert(h.undoEpoch == 0, "record must not bump epoch");

    assert(h.undo());
    assert(h.undoEpoch == 1, "undo must bump epoch to 1");

    assert(h.redo());
    assert(h.undoEpoch == 1, "redo must NOT bump epoch");

    assert(h.undo());
    assert(h.undoEpoch == 2, "second undo bumps to 2");
}

unittest { // consolidate does NOT bump undoEpoch
    import vibe3d.mesh.core.mesh    : Mesh;
    import vibe3d.viewport.camera.view    : View;
    import vibe3d.editing.contracts.editmode : EditMode;
    import vibe3d.editing.commands.editor.commands.mesh.vertex_edit : MeshVertexEdit;
    import vibe3d.util.math.math : Vec3;

    auto h = new CommandHistory();
    assert(h.undoEpoch == 0);

    // record two in-session entries and consolidate — epoch stays 0
    auto run = h.nextRun();
    Mesh mesh;
    View view = new View(0, 0, 1, 1);

    auto e1 = new MeshVertexEdit(&mesh, view, EditMode.Vertices);
    e1.setEdit([0u], [Vec3(0,0,0)], [Vec3(1,0,0)], "e1");
    h.recordInSession(e1, run);

    auto e2 = new MeshVertexEdit(&mesh, view, EditMode.Vertices);
    e2.setEdit([0u], [Vec3(1,0,0)], [Vec3(2,0,0)], "e2");
    h.recordInSession(e2, run);

    h.consolidate(run);
    assert(h.undoEpoch == 0, "consolidate must not bump epoch");
}
