// Module unittests for `operator`, moved verbatim out of source/operator.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.operator_test;

import math : Viewport;
import toolpipe.packets : SubjectPacket, WorkplanePacket, SymmetryPacket,
                          SnapPacket, ActionCenterPacket, AxisPacket,
                          FalloffPacket, ConstrainPacket, ConstrainHitPacket,
                          PathPacket, SnapHitPacket, GesturePacket, GestureTrack;
import operator;

unittest {
    // Default-constructed vts has no packets.
    VectorStack vts;
    assert(!vts.has!SubjectPacket);
    assert(!vts.has!FalloffPacket);
    assert(vts.get!SubjectPacket is null);
}

unittest {
    // put/get round-trip — pointer identity preserved.
    VectorStack vts;
    SubjectPacket subj;
    vts.put(&subj);
    assert(vts.has!SubjectPacket);
    assert(vts.get!SubjectPacket is &subj);
}

unittest {
    // Multiple packet kinds coexist independently.
    VectorStack vts;
    SubjectPacket subj;
    FalloffPacket fp;
    fp.enabled = true;
    vts.put(&subj);
    vts.put(&fp);
    assert(vts.get!SubjectPacket is &subj);
    assert(vts.get!FalloffPacket.enabled);
    // Replacing one doesn't disturb the other.
    SubjectPacket subj2;
    vts.put(&subj2);
    assert(vts.get!SubjectPacket is &subj2);
    assert(vts.get!FalloffPacket.enabled);
}

unittest {
    // Last writer wins within a slot.
    VectorStack vts;
    FalloffPacket a; a.enabled = true;
    FalloffPacket b; b.enabled = false;
    vts.put(&a);
    vts.put(&b);
    assert(vts.get!FalloffPacket is &b);
    assert(!vts.get!FalloffPacket.enabled);
}

unittest {
    import math : Vec3;
    // ConstrainHitPacket put/get round-trip — pointer identity preserved,
    // and it coexists independently with SubjectPacket + ConstrainPacket
    // (topology-pen P0: CONS publishes its config packet AND its raycast-
    // result packet in the same evaluate() pass).
    VectorStack vts;
    SubjectPacket subj;
    ConstrainPacket cfg;
    ConstrainHitPacket hit;
    hit.hit  = true;
    hit.face = 3;
    hit.point = Vec3(1, 2, 3);
    vts.put(&subj);
    vts.put(&cfg);
    vts.put(&hit);
    assert(vts.has!ConstrainHitPacket);
    auto got = vts.get!ConstrainHitPacket();
    assert(got is &hit);
    assert(got.hit && got.face == 3);
    assert(got.point.x == 1 && got.point.y == 2 && got.point.z == 3);
    // Neighbours untouched.
    assert(vts.get!SubjectPacket() is &subj);
    assert(vts.get!ConstrainPacket() is &cfg);
}

unittest {
    import math : Vec3;
    // PathPacket put/get round-trip — pointer identity preserved.
    VectorStack vts;
    PathPacket pp;
    pp.enabled = true;
    pp.knots   = [Vec3(0, 0, 0), Vec3(1, 0, 0)];
    vts.put(&pp);
    assert(vts.has!PathPacket);
    auto got = vts.get!PathPacket();
    assert(got is &pp);
    assert(got.enabled);
    assert(got.knots.length == 2);
    // PathPacket coexists independently with SubjectPacket.
    SubjectPacket subj;
    vts.put(&subj);
    assert(vts.get!PathPacket() is &pp);
    assert(vts.get!SubjectPacket() is &subj);
}

unittest {
    // S3(a) — the cooked 2D event on the wire.
    //
    // This models `app.d`'s publication exactly as it is written: one slot
    // that outlives the call (VectorStack stores POINTERS, and the caller
    // holds its stack across the dispatch that follows), filled from a
    // trailing parameter that defaults to `GesturePacket.init`. The mouse-
    // event sites pass a cooked packet; every other call site passes
    // nothing and therefore publishes the default.
    //
    // The limit of this test, stated rather than hidden: it models the
    // publication, it does not reach into `app.d`. What it does pin is the
    // part that could silently rot — that the packet has its OWN slot (an
    // aliased PacketKind would make one packet clobber another and would
    // not be caught by any consumer, since nothing consumes this one yet).
    static void publish(ref VectorStack vts, ref GesturePacket slot,
                        GesturePacket gest = GesturePacket.init) {
        slot = gest;
        vts.put(&slot);
    }

    // A non-mouse call site: no gesture argument.
    {
        VectorStack vts;
        GesturePacket slot;
        publish(vts, slot);
        auto got = vts.get!GesturePacket();
        assert(got !is null, "S3: the packet is published on every path");
        assert(!got.valid,
               "S3: a caller that supplies no gesture publishes the invalid "
               ~ "one — the same discipline SubjectPacket.cursorValid carries");
    }

    // A mouse-event call site: the handler's cooked packet, unchanged.
    {
        VectorStack vts;
        GesturePacket slot;
        GestureTrack tr;
        auto cooked = tr.event(GesturePacket.Phase.Down, 64, 32);
        publish(vts, slot, cooked);
        auto got = vts.get!GesturePacket();
        assert(got.valid && got.phase == GesturePacket.Phase.Down);
        assert(got.pressX == 64 && got.pressY == 32);
        assert(got.curX   == 64 && got.curY   == 32);
    }

    // Its own slot: publishing a gesture must not disturb any neighbour,
    // and no neighbour must disturb it.
    {
        VectorStack vts;
        GesturePacket slot;
        SubjectPacket subj;
        SnapPacket    snap;
        vts.put(&subj);
        publish(vts, slot, GestureTrack().event(GesturePacket.Phase.Move, 5, 6));
        vts.put(&snap);
        assert(vts.get!SubjectPacket()  is &subj,
               "S3 slot: the gesture must not land on a neighbour's kind — "
               ~ "an aliased PacketKind clobbers a packet somebody DOES read");
        assert(vts.get!SnapPacket()     is &snap,
               "S3 slot: a later put must not be able to reach the gesture's "
               ~ "slot, nor the gesture reach a later publisher's");
        assert(vts.get!GesturePacket()  is &slot,
               "S3 slot: the gesture reads back as the caller's own storage, "
               ~ "not as whatever last wrote the kind it was mapped onto");
        assert(vts.get!GesturePacket().curX == 5);
    }
}
