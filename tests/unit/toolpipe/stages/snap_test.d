// Module unittests for `toolpipe.stages.snap`, moved verbatim out of source/toolpipe/stages/snap.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.toolpipe.stages.snap_test;

import std.format    : format;
import std.conv      : to;
import std.string    : split, strip;
import std.algorithm : canFind;
import toolpipe.stage    : Stage, TaskCode, ordSnap;
import toolpipe.packets  : SnapPacket, SnapConfig, SnapHitPacket, SnapType, SnapMode;
import toolpipe.guide    : SnapGuide, GuideDrawState;
import operator          : Operator, Task, VectorStack, PacketKind;
import popup_state       : setStatePath;
import params            : Param, IntEnumEntry;
import math : Vec3;
import toolpipe.stages.snap;

unittest { // The snap config is ONE declaration — and `enabled` is the
    // USER toggle, not the pipe flag.
    //
    // The previous version of this block compared the stage's seven defaults
    // to `SnapPacket.init`'s seven, field by field, because the two sets were
    // written out twice and had drifted (the packet carried inner 8 against
    // the stage's 24, so the four call sites that serve `SnapPacket.init` as a
    // fallback snapped with a 3x narrower acceptance, silently). Since task
    // 0705 both sides ARE `SnapConfig`, so that comparison would be a
    // tautology — an assertion that can no longer fail is not a guard, it is
    // decoration. What it is replaced with is the one thing the split made
    // fragile, and it is not hypothetical: this test is what caught it.
    auto st = new SnapStage();

    // TWO booleans, and a fresh stage must disagree about them. `pipeEnabled`
    // is `Stage`'s registration flag (default TRUE — the stage is in the pipe);
    // `enabled` is the user's master snap toggle (default FALSE — snapping
    // ships off). They were BOTH spelled `enabled` until task 0705, the
    // derived one shadowing the base one. Embedding the config as a sub-struct
    // then broke it: an `alias this` loses to an inherited member, so every
    // `enabled` in and around this stage silently became the pipe flag, and a
    // fresh stage read as "snapping ON".
    assert(st.pipeEnabled,
        "a freshly constructed stage is registered-and-live in the pipe");
    assert(!st.enabled,
        "...and its USER snap toggle is off. If this fires and pipeEnabled "
        ~ "above passed, `enabled` has stopped resolving to SnapConfig's field "
        ~ "and is reading Stage's pipe flag instead");
    assert(&st.enabled is &st.config.enabled,
        "SnapStage.enabled must BE the config's storage — the panel checkbox "
        ~ "binds to its address");

    // Writing one must not move the other.
    st.enabled = true;
    assert(st.config.enabled && st.pipeEnabled,
        "toggling snapping must not touch the pipe registration flag");
    st.enabled = false;

    // The config round-trip, which is now a property of one struct rather than
    // an agreement between two. Still worth asserting: `snapshotConfigToPacket`
    // and `reset` are the undo/redo and scene-reset paths, and a future edit
    // could reintroduce a hand-written field list in either.
    st.innerRangePx = 1.0f;
    st.outerRangePx = 2.0f;
    st.enabled      = true;
    assert(st.snapshotConfigToPacket() != SnapPacket.init,
        "the rig must actually change the config, or the reset below proves "
        ~ "nothing");
    st.reset();
    assert(st.snapshotConfigToPacket() == SnapPacket.init,
        "SnapStage.reset() must restore exactly the declaration initialisers");
    assert(st.pipeEnabled,
        "and reset() must NOT switch the stage out of the pipe");
}

// ---------------------------------------------------------------------------
// S2 (a) of doc/toolpipe_architecture_plan.md — the SNAP stage publishes the
// snap RESULT, not only the snap CONFIG.
//
// Phase (a) is an UNREAD publication: the packet goes onto the stack and
// nothing in the tree reads it, so the neutrality argument is a grep, not a
// test. What a test can prove — and what this block proves — is that the
// thing published is the thing the query already returns, and that it is
// published under exactly the gate that keeps it off the HTTP threads:
//
//   1. GATE. No packet without `SubjectPacket.cursorValid`, and none while the
//      stage is disabled. This is the property that keeps the process-global
//      candidate grids a main-thread affair; a publication that ignored the
//      flag would be a thread-safety change dressed as a packet.
//   2. EQUIVALENCE. Field for field, the published packet is what a direct
//      `snapCursor` at the same pixel with the same config returns. A packet
//      that dropped or crossed a field would pass a "packet exists" test and
//      fails this one.
//   3. DERIVATION. `screenX`/`screenY`/`distPx` are the WINNER's own pixel and
//      its distance from the cursor — checked against an independently
//      computed projection, so projecting the wrong point is caught.
//   4. CONTRACT. On a highlight-without-snap, and on an outright miss, the
//      position-shaped fields stay at their documented defaults. The stage
//      supplies no meaningful query seed, and this is what stops that seed
//      from being published as if it were a measurement.
//
// The fixture is three collinear vertices with NO faces (so `needVis` is false
// and ranking is pure screen distance) and a single enabled type, so the whole
// packet is decided by one candidate walk with no grid / workplane traffic.
// ---------------------------------------------------------------------------
unittest {
    import math             : Vec3, Viewport, ModelSpace, lookAt, perspectiveMatrix,
                              projectToWindowFull;
    import mesh             : Mesh;
    import toolpipe.packets : SubjectPacket;
    import snap             : snapCursor, SnapResult, invalidateSnapGrids;
    import editmode         : EditMode;
    import std.math         : PI, round, sqrt;

    // snap.d's global candidate grids are keyed by (mesh address, mutation
    // version, viewport); a fresh stack Mesh can land on a recycled address
    // with the same zero version, so drop them rather than trust the key.
    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    Mesh m;
    // Deliberately OFF the world origin. A fixture whose winning vertex sits
    // at (0,0,0) makes every "the packet published no position" assertion
    // agree with every "the packet published the winner's position" one, and
    // a producer that dropped a position field would pass both. The offset is
    // in Y only, so the collinear X spacing — and every distance below — is
    // unchanged.
    m.vertices = [
        Vec3(0.00f, 0.25f, 0),   // 0 — directly under the cursor pixel
        Vec3(0.50f, 0.25f, 0),   // 1 — inside the gather range, outside acceptance
        Vec3(3.00f, 0.25f, 0),   // 2 — outside the gather range entirely
    ];

    float pixDist(Vec3 w, int sx, int sy) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every candidate must project on-screen");
        immutable float dx = qx - cast(float)sx;
        immutable float dy = qy - cast(float)sy;
        return sqrt(dx * dx + dy * dy);
    }

    // Cursor A: vertex 0's own pixel — a snap. Cursor B: 50 px to its LEFT,
    // away from the other two — inside the gather range, outside acceptance,
    // i.e. a highlight without a snap.
    float p0x, p0y, p0z;
    assert(projectToWindowFull(m.vertices[0], vp, p0x, p0y, p0z));
    immutable int ax = cast(int)round(p0x), ay = cast(int)round(p0y);
    immutable int bx = ax - 50,             by = ay;

    auto st = new SnapStage();
    st.enabled      = true;
    st.enabledTypes = SnapType.Vertex;   // one type: no grid / workplane traffic
    st.innerRangePx = 20.0f;
    st.outerRangePx = 120.0f;
    // This block is the stage's own consumer, so it says so. Everything below
    // describes what a DEMANDED publication does; the undemanded case has its
    // own block (0, further down) and its own assertion.
    st.demandHit();

    // Fixture premises, stated rather than assumed.
    assert(pixDist(m.vertices[0], ax, ay) < st.innerRangePx,
        "fixture: vertex 0 must be inside acceptance at cursor A");
    assert(pixDist(m.vertices[1], ax, ay) > st.innerRangePx,
        "fixture: vertex 1 must not be able to snap at cursor A");
    assert(pixDist(m.vertices[2], ax, ay) > st.outerRangePx,
        "fixture: vertex 2 must be out of the gather range");
    assert(pixDist(m.vertices[0], bx, by) > st.innerRangePx
        && pixDist(m.vertices[0], bx, by) < st.outerRangePx,
        "fixture: at cursor B vertex 0 must highlight but not snap");
    assert(pixDist(m.vertices[1], bx, by) > pixDist(m.vertices[0], bx, by),
        "fixture: cursor B must leave vertex 0 the winner");

    // Build the stack the mouse-event dispatch builds, minus the cursor flag.
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.editMode = EditMode.Vertices;
    subj.viewport = vp;

    // --- 1. GATE: no cursor, no packet --------------------------------------
    {
        VectorStack vts;
        vts.put(&subj);              // cursorValid stays false
        assert(st.evaluate(vts), "the stage is enabled, so it must publish its config");
        assert(vts.get!SnapPacket() !is null, "the CONFIG packet is unconditional");
        assert(vts.get!SnapHitPacket() is null,
            "S2 gate: without `cursorValid` the stage must not run the query — "
            ~ "that flag is what keeps the process-global candidate grids on "
            ~ "the main thread");
    }

    subj.cursorX     = ax;
    subj.cursorY     = ay;
    subj.cursorValid = true;

    // --- 0. DEMAND: a cursor-valid evaluation with no consumer runs nothing --
    // The cursor gate above bounds WHEN the query may run; this one bounds
    // WHETHER it runs at all. Without it the stage spent a full element-class
    // candidate walk on every mouse-motion event that reached an armed tool,
    // for a packet with no reader (task 0526's measurement, task 0531's fix).
    {
        assert(st.releaseHit(), "the block raised a demand above, so it holds one");
        assert(!st.hitDemanded && st.hitDemandCount == 0);
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts), "the stage is enabled: the CONFIG still ships");
        assert(vts.get!SnapPacket() !is null,
            "the demand gate is on the RESULT only — the config packet is what "
            ~ "the six existing snap consumers read, and it is unconditional");
        assert(vts.get!SnapHitPacket() is null,
            "S2 demand gate: with no consumer asking, the stage must publish no "
            ~ "result — and, the point of the gate, must not run the query to "
            ~ "produce one");
        st.demandHit();
        assert(st.hitDemanded && st.hitDemandCount == 1);
    }

    // --- ...and no packet at all while the stage is disabled ----------------
    {
        st.enabled = false;
        VectorStack vts;
        vts.put(&subj);
        assert(!st.evaluate(vts), "a disabled stage publishes nothing");
        assert(vts.get!SnapHitPacket() is null,
            "S2 gate: a disabled SNAP stage must not publish a result either");
        st.enabled = true;
    }

    // --- 2. EQUIVALENCE: the packet IS the query's own answer ---------------
    invalidateSnapGrids();
    SnapHitPacket hit;
    SnapPacket    cfg;
    {
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts));
        auto p = vts.get!SnapHitPacket();
        assert(p !is null, "S2: a cursor-valid evaluation must publish the result");
        hit = *p;
        cfg = *vts.get!SnapPacket();
    }

    // The reference: the same query every existing consumer runs for itself,
    // with the config the stage just published. The seed is deliberately a
    // position no candidate sits at — if the packet ever started reporting the
    // seed, the assertions below would see it.
    invalidateSnapGrids();
    immutable Vec3 probeSeed = Vec3(7.5f, -3.25f, 1.125f);
    SnapResult ref_ = snapCursor(probeSeed, ax, ay, vp, m, ModelSpace.world(), cfg);
    assert(ref_.snapped && ref_.targetIndex == 0 && ref_.targetType == SnapType.Vertex,
        "fixture: the reference query must snap to vertex 0, else the "
        ~ "equivalence below is vacuous");

    assert(hit.snapped      == ref_.snapped,      "snapped diverged");
    assert(hit.highlighted  == ref_.highlighted,  "highlighted diverged");
    assert(hit.targetType   == ref_.targetType,   "targetType diverged");
    assert(hit.targetIndex  == ref_.targetIndex,  "targetIndex diverged");
    assert(hit.targetSource == ref_.targetSource, "targetSource diverged");
    assert(hit.constraintType == ref_.constraintType, "constraintType diverged");
    assert(hit.worldPos.x == ref_.worldPos.x
        && hit.worldPos.y == ref_.worldPos.y
        && hit.worldPos.z == ref_.worldPos.z,
        "S2 equivalence: the published position must be the query's own, "
        ~ "bit for bit — not a re-derivation of it");
    assert(hit.highlightPos.x == ref_.highlightPos.x
        && hit.highlightPos.y == ref_.highlightPos.y
        && hit.highlightPos.z == ref_.highlightPos.z,
        "S2 equivalence: `highlightPos` is the query's own too — it is a "
        ~ "SEPARATE point from `worldPos` whenever a constraint placed the "
        ~ "position, and the pre-snap ring is drawn at it");
    assert(hit.layer == -1,
        "the winner came from the active mesh (slot 0), whose Document-layer "
        ~ "index the snap service does not hold");
    assert(hit.guideCount == 0,
        "S2 provenance: no guide is registered on this stage, so the walk "
        ~ "ranked by nearest pixel — the same ranking a tool-side snapCursor "
        ~ "would have produced, which is what makes the packet substitutable "
        ~ "for it");

    // --- 3. DERIVATION: the screen point is the WINNER's own pixel ----------
    float wx, wy, wz;
    assert(projectToWindowFull(m.vertices[0], vp, wx, wy, wz));
    assert(hit.screenX == wx && hit.screenY == wy,
        "S2: screenX/screenY are the snapped point's projection, so they must "
        ~ "equal an independent projection of the winning vertex");
    assert(hit.distPx == pixDist(m.vertices[0], ax, ay),
        "S2: distPx is that projection's distance from the cursor pixel — the "
        ~ "very number the candidate walk ranked by");
    assert(hit.distPx <= cfg.innerRangePx,
        "a snap by definition landed inside acceptance");

    // --- 4. CONTRACT: highlight without snap publishes no position ----------
    // Cursor B is inside the gather range of vertex 0 and outside acceptance:
    // the element is still named, the position-shaped fields are not.
    subj.cursorX = bx;
    subj.cursorY = by;
    invalidateSnapGrids();
    {
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts));
        auto p = vts.get!SnapHitPacket();
        assert(p !is null,
            "S2: publication is gated on the CURSOR, not on the outcome — a "
            ~ "query that only highlighted still ran, and still publishes");
        assert(!p.snapped && p.highlighted,
            "fixture: cursor B must highlight vertex 0 without snapping to it");
        assert(p.targetIndex == 0 && p.targetType == SnapType.Vertex,
            "a highlight still names its element");
        assert(p.worldPos.x == 0 && p.worldPos.y == 0 && p.worldPos.z == 0,
            "S2 contract: nothing snapped, so no position is published — the "
            ~ "stage's query seed must never reach the wire");
        assert(p.distPx == float.infinity && p.screenX == 0 && p.screenY == 0,
            "S2 contract: the screen fields are paired with `snapped`");
        // ...but the HIGHLIGHT point is published, because it is paired with
        // `highlighted`, not with `snapped`. This is the one field that makes
        // the packet usable by the overlay renderer at all: the pre-snap ring
        // is drawn HERE, at the candidate, not at the cursor.
        assert(p.highlightPos.x == m.vertices[0].x
            && p.highlightPos.y == m.vertices[0].y
            && p.highlightPos.z == m.vertices[0].z,
            "S2 contract: a highlight publishes its own point — this is the "
            ~ "pixel `snap_render.drawCursorMarker` draws the pre-snap ring "
            ~ "at, and `worldPos` (still default here) is not it");
    }

    // --- ...and an outright miss is the packet's own `.init` -----------------
    subj.cursorX = 5;
    subj.cursorY = 5;      // a corner pixel: every candidate is far away
    invalidateSnapGrids();
    {
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts));
        auto p = vts.get!SnapHitPacket();
        assert(p !is null,
            "a miss still publishes: an ABSENT packet means the query did not "
            ~ "run, a published one with `snapped == false` means it found "
            ~ "nothing, and downstream must be able to tell those apart");
        assert(*p == SnapHitPacket.init,
            "S2 contract: a miss is the packet's own defaults, field for field");
    }

    invalidateSnapGrids();
}

// ---------------------------------------------------------------------------
// STARTUP ARMING — `pushEnabled` / `popEnabled`.
//
// The reference's tool-activation command carries a "snap state at startup"
// argument; supplying it saves the previous master enable under the activating
// preset's NAME, writes the new one, and the drop restores it. This is that
// pair. The four properties that make it safe to arm a global from a tool:
//
//   1. SAVE AND RESTORE, both polarities. Arming from OFF hands back OFF;
//      arming from ON (a user who already had snapping on) hands back ON, not
//      the armed value. A restore that always wrote `false` would silently
//      switch snapping off for that user on every tool drop.
//   2. THE POP IS NAME-KEYED. A pop from something that never pushed is inert.
//      Without this an unbalanced drop writes a stale value into a global
//      nobody armed.
//   3. RESET CLEARS THE SLOT. `reset()` is the `/api/reset` clean slate and it
//      runs BEFORE the tool drop the same reset triggers, so the drop's pop
//      arrives afterwards; if the slot survived, it would write the pre-reset
//      value back over the clean slate. This is the cross-test-bleed shape.
//   4. RE-PUSH RE-KEYS. Two arms in a row leave exactly one outstanding, the
//      newer one — the reference's single slot, not a stack.
// ---------------------------------------------------------------------------
unittest {
    // --- 1. save/restore, both polarities ----------------------------------
    {
        auto st = new SnapStage();
        assert(!st.enabled, "setup: the stage still ships snapping OFF");
        st.pushEnabled("tool.a", true);
        assert(st.enabled, "arming must set the master enable");
        assert(st.hasPushedEnabled("tool.a"));
        st.popEnabled("tool.a");
        assert(!st.enabled, "the drop must hand back the OFF it was given");
        assert(!st.hasPushedEnabled("tool.a"), "a balanced pop empties the slot");
    }
    {
        auto st = new SnapStage();
        st.enabled = true;                       // the user turned snapping on
        st.pushEnabled("tool.a", true);
        assert(st.enabled);
        st.popEnabled("tool.a");
        assert(st.enabled,
            "a user who had snapping ON before the tool must still have it ON "
            ~ "after the drop — the restore writes the SAVED value, never a "
            ~ "constant");
    }

    // --- 2. the pop is name-keyed ------------------------------------------
    {
        auto st = new SnapStage();
        st.enabled = true;
        st.popEnabled("tool.a");
        assert(st.enabled,
            "a pop from something that never pushed must be inert — it must "
            ~ "not write the zero-initialised saved value into the global");
        st.pushEnabled("tool.a", true);
        st.enabled = false;                      // as if the user toggled it off
        st.popEnabled("tool.b");
        assert(!st.enabled,
            "a pop keyed to a different owner must leave the global alone");
        assert(st.hasPushedEnabled("tool.a"),
            "and must leave the real owner's push outstanding");
    }

    // --- 3. reset clears the slot ------------------------------------------
    {
        auto st = new SnapStage();
        st.enabled = true;                       // user had snapping on ...
        st.pushEnabled("tool.a", true);          // ... then armed a tool
        st.reset();                              // /api/reset: clean slate
        assert(!st.enabled, "reset() still lands on the shipped default");
        assert(!st.hasPushedEnabled("tool.a"),
            "reset() must drop the outstanding push");
        st.popEnabled("tool.a");                 // the tool drop reset triggers
        assert(!st.enabled,
            "the tool drop that follows a reset must NOT resurrect the "
            ~ "pre-reset value — that is snapping left armed across a reset "
            ~ "and bleeding into the next test in the same process");
    }

    // --- 4. re-push re-keys a single slot ----------------------------------
    {
        auto st = new SnapStage();
        st.pushEnabled("tool.a", true);
        st.pushEnabled("tool.b", true);
        assert(!st.hasPushedEnabled("tool.a") && st.hasPushedEnabled("tool.b"),
            "one slot, re-keyed — not a stack");
        st.popEnabled("tool.a");
        assert(st.enabled, "the displaced owner's pop is inert");
        st.popEnabled("tool.b");
        assert(st.enabled,
            "and tool.b saved the value tool.a had already armed, so the "
            ~ "restore is that armed value");
    }

    // An empty owner is never a key — it is the 'nothing outstanding' marker.
    {
        auto st = new SnapStage();
        st.pushEnabled("", true);
        assert(!st.enabled && !st.hasPushedEnabled(""),
            "an empty owner must not arm and must not claim the slot");
    }
}

// ---------------------------------------------------------------------------
// THIS SECTION'S LABELS ARE DISTINCT — FOR THE READER, NOT FOR ImGui
// (task 0638, re-founded by task 0640).
//
// The original reason was mechanical: the panel pushed no id scope anywhere,
// so this section's title and every one of its rows hashed against ONE seed
// and two equal strings were two widgets being one widget — the click landed
// on whichever drew first and the other was unreachable. The master toggle
// shipped labelled "Snapping", the same text as the title, and that was the
// owner-reported defect.
//
// That reason no longer holds. `PropertyPanel` now opens an id scope per
// section (around the header as well as the body) and per row, keyed on the
// stage id and the parameter's WIRE NAME — so identical labels are legal
// anywhere in the column, and proving that is what
// `tests/test_property_panel_id_scope.d` does against the live ids.
//
// What survives is a LEGIBILITY rule, and only for this one stage: a section
// titled "Snapping" holding a row also labelled "Snapping", or two type
// toggles both reading "Grid", is a control the user cannot name — a UI
// defect, not an identity one. Do NOT read this as a rule about the column:
// generalising it back is exactly the trap 0640 removed.
//
// The wire name is pinned in the same breath, in the opposite direction: the
// LABEL had to move and the NAME must not, because `enabled` is the HTTP key
// (`tool.pipe.attr snap enabled …`) and the status-line state path. A "fix"
// that renamed the param would break both while making this file look tidier.
// ---------------------------------------------------------------------------
unittest {
    auto st = new SnapStage();

    // The title is the shared constant — the section header and the tab entry
    // both read it, so pinning rows against it pins rows against both.
    assert(st.displayName() == kSnapDisplayName,
        format("the section title must be the single-sourced constant, got %s",
               st.displayName()));

    auto ps = st.params();
    assert(ps.length > 1, "setup: the stage must expose a schema to collide with");

    // --- 1. No row repeats the title it is drawn under. --------------------
    foreach (ref p; ps)
        assert(p.label != kSnapDisplayName,
            format("row '%s' is labelled \"%s\", the same text as the title "
                 ~ "above it — legal to ImGui since task 0640, but the user "
                 ~ "then has two controls with one name and no way to say "
                 ~ "which is which", p.name, p.label));

    // --- 2. No two rows repeat each other either. --------------------------
    foreach (i, ref a; ps)
        foreach (ref b; ps[i + 1 .. $])
            assert(a.label != b.label,
                format("rows '%s' and '%s' share the label \"%s\" — same "
                     ~ "unreadable pair, one row deeper", a.name, b.name,
                       a.label));

    // --- 3. The wire name did NOT move with the label. ---------------------
    bool sawEnabled = false;
    foreach (ref p; ps) {
        if (p.name != "enabled") continue;
        sawEnabled = true;
        assert(p.kind == Param.Kind.Bool,
            "the master toggle stays a bool on the wire");
        assert(p.label != "enabled" && p.label.length > 0,
            "and it keeps a human label, not its own wire key");
    }
    assert(sawEnabled,
        "the master toggle's wire key must still be `enabled` — it is the "
        ~ "HTTP surface and the status-line state path, and only the LABEL "
        ~ "was ever in question");
}
