// Module unittests for `toolpipe.packets`, moved verbatim out of source/toolpipe/packets.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.toolpipe.packets_test;

import math : Vec3, Viewport;
import mesh : Mesh;
import editmode : EditMode;
import seltype : SelType;
import toolpipe.packets;

// The default `selType` is `Vertex`, not `Item`. This is the R4 mitigation
// (doc/item_mode_transform_plan.md, "Owner decisions" Q1 reasons / risk
// table): a subject builder that forgets to set `selType` publishes a
// geometry-mode packet — the pre-existing behaviour — never a spurious item
// write. Every stage's item branch must be reachable ONLY by an explicit
// `selType == SelType.Item`, never by omission.
unittest {
    SubjectPacket subj;
    assert(subj.selType == SelType.Vertex,
           "SubjectPacket.selType must default to Vertex so an omitted "
           ~ "builder degrades to the existing geometry-mode behaviour, "
           ~ "never to a spurious item-mode branch");
}

unittest {
    // The default IS the publication of every non-mouse call site: the
    // per-frame render loop, the key-down dispatch, the overlay-packet
    // builders, any HTTP-thread subject builder. `app.d`'s buildToolVts
    // gives its gesture parameter this exact value, so a consumer that is
    // handed one of those stacks sees this packet and must reject it.
    //
    // If `valid` ever defaults to true, every one of those call sites starts
    // publishing a gesture it never had — a press pixel of (-1,-1) and a
    // cumulative offset measured from it. That is the neutrality break this
    // block exists to catch.
    GesturePacket g;
    assert(!g.valid,
           "S3: the default gesture is the INVALID one — every non-mouse "
           ~ "buildToolVts call site publishes exactly this, so a true "
           ~ "default hands every frame a gesture that never happened");
    assert(g.phase == GesturePacket.Phase.Idle);
    assert(g.pressX == -1 && g.pressY == -1);
    assert(g.curX   == -1 && g.curY   == -1);
    assert(g.prevX  == -1 && g.prevY  == -1);
    assert(!g.anchorValid,
           "S3: no producer sets the world anchor yet; a true default would "
           ~ "read as a measurement");
}

unittest {
    // The stamping rule, over one whole gesture: press at (100,50), two
    // motions, release. This is the sequence `app.d` produces by calling
    // GestureTrack.event once at the top of each of the three mouse
    // handlers.
    GestureTrack tr;

    auto down = tr.event(GesturePacket.Phase.Down, 100, 50);
    assert(down.valid && down.phase == GesturePacket.Phase.Down);
    assert(down.pressX == 100 && down.pressY == 50);
    // A press re-anchors BOTH forms to zero: the gesture has not moved yet.
    assert(down.cumulativeX() == 0 && down.cumulativeY() == 0);
    assert(down.incrementX()  == 0 && down.incrementY()  == 0,
           "S3: the press event's own increment is zero — prev must be "
           ~ "re-anchored at the press, not left over from the last gesture");

    auto m1 = tr.event(GesturePacket.Phase.Move, 110, 47);
    assert(m1.pressX == 100 && m1.pressY == 50,
           "S3: the press anchor survives motion — it is what makes the "
           ~ "cumulative form a different number from the incremental one");
    assert(m1.incrementX()  ==  10 && m1.incrementY()  == -3);
    assert(m1.cumulativeX() ==  10 && m1.cumulativeY() == -3);

    auto m2 = tr.event(GesturePacket.Phase.Move, 106, 60);
    assert(m2.prevX == 110 && m2.prevY == 47,
           "S3: prev is the PREVIOUS EVENT's pixel — if the tracker is not "
           ~ "advanced on every event, this increment silently spans two");
    assert(m2.incrementX()  ==  -4 && m2.incrementY()  == 13);
    assert(m2.cumulativeX() ==   6 && m2.cumulativeY() == 10);

    auto up = tr.event(GesturePacket.Phase.Up, 106, 62);
    assert(up.phase == GesturePacket.Phase.Up);
    assert(up.pressX == 100 && up.pressY == 50,
           "S3: a release does NOT re-anchor — the committed gesture is "
           ~ "measured from where the press was");
    assert(up.incrementX()  == 0 && up.incrementY()  ==  2);
    assert(up.cumulativeX() == 6 && up.cumulativeY() == 12);

    // The migration device, stated as an invariant rather than a comment:
    // over one gesture the cumulative offset is the sum of the increments.
    // That equality is exactly why switching a tool from one form to the
    // other is a REAL behaviour change and not a rename — it holds on the
    // ideal event stream and stops holding the moment anything (a dropped
    // event, a warp, a re-anchor) perturbs it. Keep both forms until the
    // switch is made deliberately.
    assert(down.incrementX() + m1.incrementX() + m2.incrementX()
           + up.incrementX() == up.cumulativeX());
    assert(down.incrementY() + m1.incrementY() + m2.incrementY()
           + up.incrementY() == up.cumulativeY());
}

unittest {
    // A second press re-anchors the gesture. Without this the cumulative
    // form of gesture N+1 would be measured from gesture N's press, which
    // is the single most damaging way to get this wrong: it is invisible on
    // the first drag of a session and wrong on every one after it.
    GestureTrack tr;
    tr.event(GesturePacket.Phase.Down, 10, 10);
    tr.event(GesturePacket.Phase.Move, 40, 10);
    tr.event(GesturePacket.Phase.Up,   40, 10);

    auto d2 = tr.event(GesturePacket.Phase.Down, 200, 200);
    assert(d2.pressX == 200 && d2.pressY == 200);
    assert(d2.cumulativeX() == 0 && d2.cumulativeY() == 0,
           "S3: a new press re-anchors — otherwise the second gesture is "
           ~ "measured from the first one's press pixel");
    auto m = tr.event(GesturePacket.Phase.Move, 205, 200);
    assert(m.cumulativeX() == 5 && m.incrementX() == 5);
}

unittest {
    // Motion with no button held is a Move like any other, and the packet
    // does not pretend otherwise. This is stated as a test because the
    // tempting "fix" — inventing a button-state field the event dispatch
    // does not actually track — would be an invention, not a measurement.
    // A consumer that needs button state reads it from the event it was
    // handed.
    GestureTrack tr;
    auto hover = tr.event(GesturePacket.Phase.Move, 7, 9);
    assert(hover.valid && hover.phase == GesturePacket.Phase.Move);
    assert(hover.pressX == -1 && hover.pressY == -1,
           "S3: a hover before any press has no anchor, and says so");
}
