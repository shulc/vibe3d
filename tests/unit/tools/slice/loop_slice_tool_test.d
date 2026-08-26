// Module unittests for `tools.slice.loop_slice_tool`, moved verbatim out of source/tools/slice/loop_slice_tool.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.slice.loop_slice_tool_test;

import bindbc.sdl;
import std.json : JSONValue;
import std.algorithm : sort;
import operator : VectorStack;
import tool;
import edit_session : KeepAliveOnCancel;
import mesh;
import math;
import editmode : EditMode;
import params : Param, IntEnumEntry, wireTagForValue;
import hover_state : g_hoveredEdge;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import document : primaryModelSpace;
import tools.slice.loop_slice_tool;

unittest {
    // 0..1 fraction -> percent readout (the ×100 the inline draw used to omit,
    // which printed the bare fraction next to a "%" — "0.13 %" instead of the
    // reference's "13.00 %").
    assert(loopSliceHudLabel(0.13f) == "13.00 %");
    assert(loopSliceHudLabel(0.9f)  == "90.00 %");
    assert(loopSliceHudLabel(0.5f)  == "50.00 %");
    assert(loopSliceHudLabel(0.0f)  == "0.00 %");
    assert(loopSliceHudLabel(1.0f)  == "100.00 %");
}

unittest {
    // Flat is the null-profile sentinel (empty); every non-flat profile has t in
    // (0,1) and at least one positive height (so depth>0 actually cuts).
    assert(profileSamples(LoopProfile.Flat).length == 0);
    foreach (p; [LoopProfile.Round, LoopProfile.Vee, LoopProfile.Step]) {
        auto s = profileSamples(p);
        assert(s.length >= 2, "a non-flat profile needs multiple loops");
        bool anyH = false;
        foreach (smp; s) {
            assert(smp.t > 0.0f && smp.t < 1.0f, "sample t must be in (0,1)");
            if (smp.height > 0.0f) anyH = true;
        }
        assert(anyH, "a non-flat profile must have some positive height");
    }
    // Vee apex is the centre sample at full height.
    auto vee = profileSamples(LoopProfile.Vee);
    assert(vee[1].t == 0.5f && vee[1].height == 1.0f);
}

// ---------------------------------------------------------------------------
// Per-instance isolation of `positions_` (the CI regression this pins).
//
// `positions_` used to be declared `float[] positions_ = [0.5f];`. A field
// initialized with an array LITERAL takes its slice from the class's `.init`
// blob, so every instance aliased ONE static backing store. `scrubPosition`'s
// Count<=1 branch writes `positions_[0] = p` IN PLACE, i.e. straight into that
// shared store — so a single `tool.attr mesh.loopSliceTool position 0.3` at
// Count==1 made 0.3 the starting Position of every LoopSliceTool constructed
// later in the SAME PROCESS, even though the factory builds a brand-new tool
// per activation and `position` is declared `.transient()` precisely so it is
// NOT remembered.
//
// Cross-test symptom (why this was a CI-only flake): the run_test.d worker
// reuses one `vibe3d --test` for its whole slice of test binaries, so whenever
// the LPT scheduler happened to pack `test_fixture_loop_slice_attr` (whose
// fixture scrubs Position to 0.3) ahead of `test_loop_slice_v2` on the same
// worker, V3's `insertAt 0.3` landed on an already-0.3 slot — the kernel's
// coincident-position dedup then collapsed the two cuts into one and V3 saw
// V=12 instead of 16. Ordering is scheduler-dependent, so it looked like a
// flake; the defect was always there.
//
// Appending (`positions_ ~= t`) reallocates, which is why only a Count<=1
// scrub could reach the shared store — and why the poison value stuck at the
// FIRST such scrub rather than tracking later ones.
unittest {
    import std.conv : to;

    static LoopSliceTool build() {
        return new LoopSliceTool(null, null, null, null);
    }

    auto a = build();
    assert(a.positionsArray().length == 1 && a.positionsArray()[0] == 0.5f,
        "a freshly built Loop Slice must start at positions == [0.5]");

    // The exact product write that used to poison the shared store: a Position
    // scrub while Count == 1 (`tool.attr … position 0.3`, or a HUD/mesh drag).
    a.scrubPosition(0.3f);
    assert(a.positionsArray()[0] == 0.3f, "sanity: the scrub must take effect");

    auto b = build();
    assert(b.positionsArray().length == 1 && b.positionsArray()[0] == 0.5f,
        "a Loop Slice built AFTER another instance's Count==1 Position scrub "
        ~ "must still start at 0.5 — got " ~ b.positionsArray()[0].to!string
        ~ "; `positions_` is aliasing the class .init blob again (declare it "
        ~ "WITHOUT an array-literal field initializer and seed it in the ctor)");
    assert(a.positionsArray().ptr !is b.positionsArray().ptr,
        "two Loop Slice instances must never share one positions_ backing store");
    assert(a.positionsArray()[0] == 0.3f,
        "building a second tool must not disturb the first one's positions_");
}

// ---------------------------------------------------------------------------
// Task 0833 — the settled-mesh precondition on `toolStateJson()` is LIVE,
// i.e. it CAN fail.
//
// This site is the deliberate COPY of app.d's `rebuildLoopHoverMask` (the
// loops-family walk plus the ring → edge-index resolve through edgeIndexMap),
// and 0724 made the precondition travel with the copy. app.d's original is a
// function nested inside `main()`, so no unit test can reach it; this twin is
// a plain method on a tool a test can build, which makes it the only place the
// shared precondition is demonstrable at all.
//
// The legal sequence: `addVertex` ×4 (Points-class, bumps no structVersion)
// then `addFace` — a plain public face append that maintains edgeIndexMap
// through `addEdge` but does NOT rebuild loops, leaving (loops STALE, edgeMap
// VALID). Nothing here touches a private field.
//
// Only the `assertLoopsValid` half is demonstrated: the mirror state (loops
// valid, edgeMap stale) has no producer on this tree — and, since task 0790
// deleted `buildLoops`'s `rebuildEdgeIndexMap` parameter (the one arm that
// would once have produced it), that is now true BY CONSTRUCTION, not just
// unobserved. So the `assertEdgeMapValid` on the next line can only fire
// where the line above it already threw. See case 7 of the stamp trace table
// in `tests/unit/mesh_test.d` for that measurement.
//
// `debug`-wrapped because both are `debug assert` — live in dub test / dub
// build, stripped from the shipped `-release` binary. This block says the
// guard works where it exists; it does not claim the release binary has one.
// ---------------------------------------------------------------------------
unittest {
    debug {
        import core.exception : AssertError;
        import std.exception  : assertThrown;
        import math : Vec3;

        Mesh m = makeCube();
        EditMode em = EditMode.Edges;
        g_hoveredEdge = -1;      // no hover: the ring branch stays empty

        const uint a = m.addVertex(Vec3(2, 0, 0));
        const uint b = m.addVertex(Vec3(3, 0, 0));
        const uint c = m.addVertex(Vec3(3, 0, 1));
        const uint d = m.addVertex(Vec3(2, 0, 1));
        m.addFace([a, b, c, d]);
        assert(!m.loopsValid(),
            "setup: a face append without a terminal buildLoops must leave the "
            ~ "loops family stale");

        auto tool = new LoopSliceTool(() => &m, null, &em, null);
        assertThrown!AssertError(tool.toolStateJson(),
            "toolStateJson must refuse a mesh whose loops family was never "
            ~ "rebuilt -- if this stops throwing, the precondition has become "
            ~ "decoration");

        // ...and the SAME read serves once the mesh is settled, so the
        // precondition discriminates between two states rather than refusing
        // the endpoint outright.
        m.buildLoops();
        m.resetSelection();
        assert(m.loopsValid() && m.edgeMapUsable(),
            "setup: buildLoops must settle both stamps");
        auto js = tool.toolStateJson();
        assert(js["tool"].str == "loopSlice",
            "a settled mesh must produce the ordinary tool-state payload");
    }
}
