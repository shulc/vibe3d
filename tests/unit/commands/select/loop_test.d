// Task 0833 — the settled-mesh precondition on `SelectLoop.apply()` is LIVE,
// i.e. it CAN fail. Nothing else in this module's test surface existed before;
// this file exists for that one question.
module tests.unit.commands.select.loop_test;

import mesh;
import math : Vec3;
import view;
import editmode : EditMode;
import commands.select.loop : SelectLoop;

// ---------------------------------------------------------------------------
// `select.loop` opens with a PAIR of preconditions:
//
//     mesh.assertLoopsValid();
//     mesh.assertEdgeMapValid();
//
// Task 0724 measured that no caller can trip either today: the dispatcher runs
// one Command.apply() to completion — including a prior topology mutator's
// terminal buildLoops() — before starting the next, so the mesh is always
// settled by the time this apply() begins. That is an invariant held by call
// ORDER, and a check that cannot fail is indistinguishable from one that is
// absent. This block constructs the state the dispatcher never hands over.
//
// The legal sequence: `addVertex` ×4 (Points-class, bumps no structVersion)
// then `addFace` — a plain public face append. `addFace` maintains
// edgeIndexMap through `addEdge` and re-stamps it Valid at the new
// structVersion, but does NOT rebuild loops. The result is (loops STALE,
// edgeMap VALID): exactly one of the two preconditions is violated, and it is
// the FIRST one.
//
// **Which half this can and cannot demonstrate — stated, not glossed.** Only
// `assertLoopsValid` is demonstrated here. The mirror state (loops valid,
// edgeMap stale) has no producer on this tree — every primitive that leaves
// the map Stale bumps structVersion and takes the loops stamp down with it,
// and `buildLoops(false)`, the one arm that would validate loops while
// deliberately emptying the map, has zero callers (backlog 0790). So
// `assertEdgeMapValid` here can only ever fire in a state where the line above
// it has already thrown. The measurement behind that claim is case 7 of the
// stamp trace table in `tests/unit/mesh_test.d`; if a future mutator gives the
// mirror state a producer, this comment is what should be revisited.
//
// Wrapped in `debug` because both are `debug assert`: under `-release` there
// is nothing to throw. This proves the guard is live in the builds that CARRY
// it (dub test / dub build) — it is NOT a runtime guarantee in the shipped
// release binary, which has no such check at all.
// ---------------------------------------------------------------------------
unittest {
    debug {
        import core.exception : AssertError;
        import std.exception  : assertThrown;

        auto m = makeCube();
        assert(m.loopsValid() && m.edgeMapUsable(),
            "setup: makeCube must start settled");

        const uint a = m.addVertex(Vec3(2, 0, 0));
        const uint b = m.addVertex(Vec3(3, 0, 0));
        const uint c = m.addVertex(Vec3(3, 0, 1));
        const uint d = m.addVertex(Vec3(2, 0, 1));
        m.addFace([a, b, c, d]);
        assert(!m.loopsValid(),
            "setup: a face append without a terminal buildLoops must leave the "
            ~ "loops family stale");

        View view = new View(0, 0, 800, 600);
        auto cmd = new SelectLoop(&m, view, EditMode.Edges);
        assertThrown!AssertError(cmd.apply(),
            "select.loop must refuse a mesh whose loops family was never "
            ~ "rebuilt -- if this stops throwing, the precondition has become "
            ~ "decoration");

        // ...and the SAME command runs once the mesh is settled, so the
        // precondition discriminates between two states rather than refusing
        // the command outright.
        m.buildLoops();
        m.resetSelection();
        assert(m.loopsValid() && m.edgeMapUsable(),
            "setup: buildLoops must settle both stamps");
        auto cmd2 = new SelectLoop(&m, view, EditMode.Edges);
        assert(cmd2.apply(),
            "select.loop must succeed on a settled mesh");
    }
}
