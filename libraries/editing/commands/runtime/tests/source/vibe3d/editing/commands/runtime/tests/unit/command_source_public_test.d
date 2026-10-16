module vibe3d.editing.commands.runtime.tests.unit.command_source_public_test;

import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.viewport.camera.view : View;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.util.spatial.spatial : Viewport;

// ---------------------------------------------------------------------------
// Task 0619 — the packet `Command.applyImpl()` builds carries a REAL camera.
//
// `SubjectPacket.viewport` is the only camera an `Operator`'s `evaluate` can
// see, and four operator commands (`mesh.jitter`, `mesh.quantize`,
// `mesh.smooth`, `MeshMagnet`) now read it through `aimSpace`. The toolpipe
// path fills it (app.d's `buildToolVts`); this path used to leave it
// default-constructed, so the same operator saw a real camera or an all-NaN
// one depending on who fired it.
//
// VERIFIED BY MUTATION, twice:
//   * replacing `Command.applyImpl`'s
//     `Viewport vp = (view !is null) ? effectiveViewport() : Viewport.init;`
//     ternary with an unconditional `Viewport vp = Viewport.init;` — i.e.
//     the code as it behaved before this fix — gives "Command.apply() must
//     publish the live camera onto the subject packet: got width=0, want
//     width=800";
//   * dropping only the `view !is null` guard in front of it (always taking
//     the `effectiveViewport()` branch) kills the process with SIGSEGV
//     (exit 139) on the second case below, which is why that case exists:
//     without it the guard is dead weight nobody reaches.
// ---------------------------------------------------------------------------


version (unittest) {
    import vibe3d.editing.pipeline.contracts.operator         : Operator, VectorStack, OperatorActrCommon,
                              Task, PacketKind;
    import vibe3d.editing.pipeline.contracts.toolpipe.packets : SubjectPacket;

    /// A terminal Operator that mutates nothing and reports the packet the
    /// base `applyImpl()` handed it.
    private class SubjectEchoOp : Command, Operator {
        SubjectPacket seen;
        bool          sawSubject;

        this(Mesh* mesh, ref View view, EditMode editMode) {
            super(mesh, view, editMode);
        }
        override string name() const { return "test.subjectEcho"; }

        mixin OperatorActrCommon;
        bool evaluate(ref VectorStack vts) {
            if (auto s = vts.get!SubjectPacket()) {
                seen = *s;
                sawSubject = true;
            }
            return true;
        }
    }
}

unittest {
    import vibe3d.viewport.camera.view       : View;
    import vibe3d.util.math.math       : Vec3, lookAt, perspectiveMatrix;
    import std.math   : PI, isNaN;
    import std.format : format;

    Mesh m;
    auto v = new View(0, 0, 800, 600);
    auto op = new SubjectEchoOp(&m, v, EditMode.Vertices);

    // The camera the app would resolve for this command. Deliberately not the
    // default: a default-constructed Viewport has NaN matrices and width 0,
    // which is what the unplumbed code published.
    Viewport want;
    immutable Vec3 eye = Vec3(4.0f, 3.0f, 9.0f);
    want.view   = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    want.proj   = perspectiveMatrix(45.0f * PI / 180.0f, 800.0f / 600.0f,
                                    0.01f, 100.0f);
    want.width  = 800; want.height = 600;
    want.eye    = eye; want.focus  = Vec3(0, 0, 0);
    op.setResolvedVpProvider(() => want);

    // Vacuity guard: the fixture camera must differ from the default in the
    // fields asserted below, or the case could not distinguish the two.
    assert(want.width != Viewport.init.width,
        "vacuous fixture: the probe camera's width equals the default's");
    assert(isNaN(Viewport.init.view[0]),
        "vacuous fixture: a default Viewport's matrix is expected to be "
        ~ "uninitialised (float.init), so a plumbed one is unmistakable");

    assert(op.apply(), "the echo operator applies");
    assert(op.sawSubject, "apply() must have dispatched through evaluate()");

    assert(op.seen.viewport.width == want.width
        && op.seen.viewport.height == want.height,
        format("Command.apply() must publish the live camera onto the "
               ~ "subject packet: got width=%d, want width=%d",
               op.seen.viewport.width, want.width));
    foreach (i; 0 .. 16)
        assert(op.seen.viewport.view[i] == want.view[i],
            format("subject packet view matrix element %d diverged: got %f, "
                   ~ "want %f", i, op.seen.viewport.view[i], want.view[i]));
}

unittest { // ...and a command with no View does not crash trying.
    // `effectiveViewport()`'s no-provider fallback dereferences `view`. A
    // headless/direct construction may leave it null (see
    // commands/test_undo_flags.d, which does exactly that), so the plumb is
    // guarded — and the packet then keeps the documented default rather than
    // taking down the process.
    import std.math : isNaN;

    Mesh m;
    View nullView;
    auto op = new SubjectEchoOp(&m, nullView, EditMode.Vertices);

    assert(op.apply(), "a View-less operator command still applies");
    assert(op.sawSubject, "apply() must still dispatch through evaluate()");
    assert(op.seen.viewport.width == 0 && isNaN(op.seen.viewport.view[0]),
        "with no View and no provider the packet keeps its documented "
        ~ "default, which every viewport-dependent stage already refuses");
}
