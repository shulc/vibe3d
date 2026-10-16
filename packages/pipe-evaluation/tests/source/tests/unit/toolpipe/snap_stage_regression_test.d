module tests.unit.toolpipe.snap_stage_regression_test;

import toolpipe.stages.snap : SnapStage;
import toolpipe.guide : SnapGuide;
import toolpipe.packets : SnapPacket, SnapType, SnapMode, SnapHitPacket;
import operator : VectorStack;


// ---------------------------------------------------------------------------
// The DEMAND gate on the per-cursor RESULT — task 0531, closing the cost that
// task 0526 measured.
//
// The block above pins WHAT is published. This one pins that the publication
// does not HAPPEN unasked, and it pins it the only way that is worth pinning:
// by counting candidate enumerations, not packets. "No packet" would still
// pass if the stage ran the whole query and then threw the answer away, and
// the whole point of the gate is the query — an element-class walk over every
// vertex, edge centre and polygon centre near the cursor, on every mouse-
// motion event that reaches an armed tool.
//
// The counter is a registered guide, used as an instrument rather than as a
// ranking policy: `RecordingGuide.proximity` is called once per candidate that
// survives the gather range, and it counts. It admits nothing, so it cannot
// influence what the block asserts about publication.
//
//   1. UNASKED. No demand — no candidate is enumerated, and no packet exists.
//   2. ASKED. One demand — candidates are enumerated and the packet appears.
//   3. COUNTER. Two consumers need two releases; one leaving does not starve
//      the other. This is S2 phase (b)'s shape: six consumers migrate one
//      commit at a time, so overlapping demands are the normal case.
//   4. UNPAIRED RELEASE. Reported, not wrapped past zero.
//   5. RESET. A scene reset does NOT withdraw a demand — see the contract at
//      `demandHit`. This assertion exists because the neighbouring registry
//      IS cleared there, and the difference has to be deliberate.
// ---------------------------------------------------------------------------
unittest {
    import math : Vec3, lookAt, perspectiveMatrix;
import vibe3d.util.spatial.spatial : Viewport, projectToWindowFull;
    import mesh             : Mesh;
    import toolpipe.packets : SubjectPacket;
    import snap             : invalidateSnapGrids;
    import vibe3d.editing.contracts.editmode         : EditMode;
    import std.math         : PI, round;

    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    Mesh m;
    m.vertices = [Vec3(0, 0, 0)];      // one candidate, right under the cursor

    float p0x, p0y, p0z;
    assert(projectToWindowFull(m.vertices[0], vp, p0x, p0y, p0z));

    auto st = new SnapStage();
    st.enabled      = true;
    st.enabledTypes = SnapType.Vertex;   // one type: one candidate walk
    st.innerRangePx = 20.0f;
    st.outerRangePx = 120.0f;

    auto probe = new RecordingGuide();
    st.addGuide(probe);

    SubjectPacket subj;
    subj.mesh        = &m;
    subj.editMode    = EditMode.Vertices;
    subj.viewport    = vp;
    subj.cursorX     = cast(int)round(p0x);
    subj.cursorY     = cast(int)round(p0y);
    subj.cursorValid = true;            // the cursor gate is WIDE OPEN here

    size_t evaluateOnce() {
        invalidateSnapGrids();
        immutable size_t before = probe.queries;
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts), "an enabled stage always publishes its config");
        assert(vts.get!SnapPacket() !is null,
            "the demand gate governs the RESULT only; the CONFIG is what every "
            ~ "existing consumer reads and it must keep shipping");
        immutable bool published = vts.get!SnapHitPacket() !is null;
        immutable size_t walked  = probe.queries - before;
        assert(published == (walked > 0),
            "the packet and the walk are the same event: a published packet "
            ~ "means the query ran, an absent one means it did not");
        return walked;
    }

    // --- 1. UNASKED ---------------------------------------------------------
    assert(st.hitDemandCount == 0, "a fresh stage has no consumer");
    assert(evaluateOnce() == 0,
        "0531: with no consumer asking, a cursor-valid evaluation must not "
        ~ "enumerate a single candidate — that walk, once per mouse-motion "
        ~ "event, is the whole of the cost measured in task 0526");

    // --- 2. ASKED -----------------------------------------------------------
    st.demandHit();
    assert(st.hitDemanded && st.hitDemandCount == 1);
    assert(evaluateOnce() == 1,
        "one consumer, one candidate in range, one enumeration — the gate "
        ~ "withholds the query, it does not break it");

    // --- 3. COUNTER: two consumers, two releases ----------------------------
    st.demandHit();
    assert(st.hitDemandCount == 2);
    assert(st.releaseHit() && st.hitDemandCount == 1);
    assert(evaluateOnce() == 1,
        "one consumer leaving must not starve the one still reading — S2 "
        ~ "phase (b) migrates six of them one commit at a time, so two live "
        ~ "demands is the ordinary state, not an edge case");
    assert(st.releaseHit() && st.hitDemandCount == 0);
    assert(evaluateOnce() == 0, "the last consumer leaving closes the gate again");

    // --- 4. UNPAIRED RELEASE ------------------------------------------------
    assert(!st.releaseHit(),
        "a release with no matching demand is a caller bug and is reported as "
        ~ "one");
    assert(st.hitDemandCount == 0,
        "...and it must not go negative: a demand counter that wrapped would "
        ~ "wedge the gate open for the life of the process");

    // --- 5. RESET leaves the demand alone -----------------------------------
    st.demandHit();
    st.reset();
    assert(st.hitDemandCount == 1,
        "a demand is scoped to a CONSUMER, not to a gesture or a scene: "
        ~ "`scene.reset` resets the scene, and a consumer that is still alive "
        ~ "is still reading. The guide registry beside it IS cleared there, "
        ~ "for the opposite reason (a guide IS gesture-scoped), and this "
        ~ "assertion is what keeps the two from being confused for each other");
    assert(st.guideCount == 0, "...while the registry did clear, as it must");

    invalidateSnapGrids();
}

// ---------------------------------------------------------------------------
// S4(a) of doc/toolpipe_architecture_plan.md — the guide REGISTRY.
//
// The equivalence of the two ranking paths is pinned in `source/snap.d`. What
// belongs here is the registry's own contract, and the first clause of it is
// the neutrality claim itself:
//
//   1. EMPTY. A fresh stage holds no guide, and nothing in this tree registers
//      one. That is what makes the arbitration branch in `snapCursor`
//      unreachable, and it is the whole of phase (a)'s neutrality argument.
//      The assertion is cheap; its value is that a later commit which
//      registers a guide from inside the stage cannot do so silently.
//   2. LIFECYCLE (MEASURED). Add, remove, and add-is-idempotent — a guide
//      registered twice is one guide, not two votes in the arbitration.
//      `reset()` empties the registry, because a guide is scoped to a gesture
//      and a scene reset ends every gesture there was.
//   3. RANGES PUSHED IN (MEASURED direction). Registration hands the guide the
//      stage's current pair, and a later evaluation hands it the pair again,
//      so a range changed mid-gesture reaches a guide already registered. The
//      guide never sources the pair for itself.
// ---------------------------------------------------------------------------
version (unittest) {
    private class RecordingGuide : SnapGuide {
        import math : Vec3;
        float  innerPx = -1, outerPx = -1;
        int    pushes;
        size_t queries;

        override void limits(float i, float o) { innerPx = i; outerPx = o; ++pushes; }
        override bool proximity(Vec3 candWorld, SnapType type, int idx, int slot,
                       ref float distPx, ref int priority)
        {
            ++queries;
            return false;   // admits nothing: this guide is here to be counted
        }
    }
}

unittest {
    auto st = new SnapStage();

    // --- 1. EMPTY -----------------------------------------------------------
    assert(st.guideCount == 0,
        "S4(a): a fresh SNAP stage registers no guide, and neither does any "
        ~ "tool in this tree — that emptiness is what keeps the arbitration "
        ~ "path in snapCursor unreachable, which is the entire neutrality "
        ~ "argument for this stage");

    // --- 3. RANGES PUSHED IN, at registration -------------------------------
    auto g = new RecordingGuide();
    st.innerRangePx = 11.0f;
    st.outerRangePx = 22.0f;
    st.addGuide(g);
    assert(st.guideCount == 1);
    assert(g.pushes == 1 && g.innerPx == 11.0f && g.outerPx == 22.0f,
        "the environment's ranges are pushed IN when a guide registers — the "
        ~ "guide does not source the pair for itself");

    // --- 2. LIFECYCLE -------------------------------------------------------
    st.addGuide(g);
    assert(st.guideCount == 1,
        "registering the same guide twice must be a no-op, not a second vote "
        ~ "in the arbitration");
    st.addGuide(null);
    assert(st.guideCount == 1, "a null guide is not a guide");

    auto h = new RecordingGuide();
    st.addGuide(h);
    assert(st.guideCount == 2 && st.guides[0] is g && st.guides[1] is h,
        "the registry keeps registration order — the arbitration settles "
        ~ "equal priorities by it");

    assert(st.removeGuide(g) && st.guideCount == 1 && st.guides[0] is h,
        "remove takes out the named guide and leaves the rest in order");
    assert(!st.removeGuide(g),
        "removing a guide that is not registered reports so rather than "
        ~ "corrupting the registry");

    // --- 3. ...and again on every evaluation --------------------------------
    // A mid-gesture range change must reach a guide that is already
    // registered, so the push is not a registration-time courtesy.
    st.innerRangePx = 33.0f;
    st.outerRangePx = 44.0f;
    st.enabled      = true;
    {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;               // cursorValid stays false: no query
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts));
    }
    assert(h.innerPx == 33.0f && h.outerPx == 44.0f,
        "an evaluation re-pushes the current ranges, so a pair changed "
        ~ "mid-gesture reaches a guide that registered before the change");
    assert(h.queries == 0,
        "and it does so WITHOUT running the query — the cursor gate still "
        ~ "governs whether any candidate is enumerated at all");

    // --- 2. reset() empties the registry ------------------------------------
    st.reset();
    assert(st.guideCount == 0,
        "a scene reset ends every gesture there was, so it can leave no guide "
        ~ "registered — a guide outliving the tool that owns it is the one "
        ~ "lifecycle error the measured add/remove pair rules out");
}
