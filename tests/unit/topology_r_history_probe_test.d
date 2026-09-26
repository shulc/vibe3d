// Task 7980: executable R primitive probe. This deliberately does not claim
// production wiring; the Edge release/close witness is recorded in the card.
module tests.unit.topology_r_history_probe_test;

import command_history : CommandHistory, HistoryFlags;
import commands.mesh.session_edit : MeshSessionEdit;
import editmode : EditMode;
import math : Vec3;
import mesh : Mesh, makeCube;
import snapshot : MeshSnapshot;
import view : View;

private void probe(bool inSession) {
    Mesh m = makeCube();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();
    const run = inSession ? h.nextRun() : 0;
    // The first row is an 8→8 zero step; the last changes only selection.
    // Counts alone cannot certify either history transition.
    const wanted = [8, 8, 10, 28, 42, 42];
    MeshSessionEdit[] rows;
    MeshSnapshot[] states = [MeshSnapshot.capture(m)];

    foreach (i; 1 .. wanted.length) {
        auto before = MeshSnapshot.capture(m);
        while (m.vertices.length < wanted[i])
            m.addVertex(Vec3(cast(float)m.vertices.length, cast(float)i, 0));
        if (wanted[i] != wanted[i - 1]) m.syncSelection();
        if (i > 1) {
            m.clearVertexSelection();
            m.selectVertex(cast(int)i);
        }
        auto after = MeshSnapshot.capture(m);
        if (i == 1) assert(before.matches(after),
            "R probe: 8→8 row must be an identical full image");
        if (i == 5) assert(!before.matches(after) &&
            before.vertices.length == after.vertices.length,
            "R probe: selection-only row must differ with equal vertex count");
        states ~= after;
        auto cmd = new MeshSessionEdit(&m, v, EditMode.Vertices,
            "probe.topology_step", "Topology step");
        cmd.setSnapshots(before, after, "Topology step");
        rows ~= cmd;
        if (inSession) h.recordInSession(cmd, run);
        else h.record(cmd);
        assert(h.undoEntries().length == i);
        assert(h.undoEntries()[$ - 1].cmd is cmd);
        assert(m.vertices.length == wanted[i] && states[i].matches(m),
            "R probe: fixture step did not produce its full mesh/selection image");
    }

    assert(h.runOpen() == inSession);
    if (inSession) h.consolidate(run);
    assert(!h.runOpen());
    assert(h.undoEntries().length == 5,
        "R probe: consolidate merged or dropped distinct MeshSessionEdit rows");
    foreach (i, entry; h.undoEntries()) {
        assert(entry.cmd is rows[i], "R probe: a step row lost identity/order");
        assert(entry.runId == (inSession ? run : 0));
        assert(!!(entry.flags & HistoryFlags.InSession) == inSession,
            "R probe: a closed InSession MeshSessionEdit retains its tag");
    }
    foreach_reverse (i; 1 .. wanted.length) {
        assert(h.undo());
        assert(m.vertices.length == wanted[i - 1] && states[i - 1].matches(m),
            "R probe: undo skipped an exact mesh/selection step, including zero");
    }
    assert(h.redoEntries().length == 5);
    foreach (i; 1 .. wanted.length) {
        assert(h.redo());
        assert(m.vertices.length == wanted[i] && states[i].matches(m),
            "R probe: redo skipped an exact mesh/selection step");
    }
}

unittest { probe(false); }
unittest { probe(true); }
