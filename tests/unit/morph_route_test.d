// The ROUTED symmetry overloads, and the undo record for a routed gesture
// (task 1069, plan Stage 5).
//
// WHY THESE ARE MODULE UNITTESTS RATHER THAN HTTP TESTS. Measured, not
// assumed: with the symmetry stage enabled and one vertex selected, the stage
// adds the mirror PARTNER to the moving set, so the fold kernel routes the
// partner's write directly and the mirror pass never has to. Deleting the
// mirror call outright leaves `tests/test_morph_routing.d`'s symmetry case
// GREEN — verified by running exactly that mutation. So an HTTP test through
// that configuration cannot pin the routed mirror at all, and pretending it
// does would be an inert assertion.
//
// The overloads still matter — for a partner outside the moving set, for the
// topology-symmetry (delta) form, and for the on-plane projection — so they
// are pinned here, directly, where the inputs can be built to order.
module tests.unit.morph_route_test;

import math : Vec3;
import mesh;
import mesh_morph : morphApply;
import toolpipe.packets : SymmetryPacket;
import tools.transform.morph_route;

// ---------------------------------------------------------------------------
// A two-vertex rig: v0 at +X, v1 its mirror at -X, plus a third ON the plane.
// Deliberately NOT a cube — a symmetric closed solid makes the driver's base
// and its mirrored base coincide, which is exactly the degeneracy that lets a
// dead mirror look alive.
// ---------------------------------------------------------------------------
private Mesh rig() {
    Mesh m;
    m.vertices = [Vec3(1, 0.5f, 0.25f),    // 0 — driver, +X side
                  Vec3(-1, 0.5f, 0.25f),   // 1 — its mirror partner
                  Vec3(0, 2, 3)];          // 2 — ON the x = 0 plane
    m.resizeVertexSelection();
    return m;
}

private SymmetryPacket packetX() {
    SymmetryPacket sp;
    sp.enabled     = true;
    sp.axisIndex   = 0;
    sp.planePoint  = Vec3(0, 0, 0);
    sp.planeNormal = Vec3(1, 0, 0);
    sp.pairOf      = [1, 0, -1];
    sp.onPlane     = [false, false, true];
    sp.vertSign    = [+1, -1, 0];
    sp.baseSide    = +1;
    return sp;
}

private MorphRoute routeFor(ref Mesh m, string name, MapKind kind) {
    MorphRoute r;
    r.kind = kind;
    r.name = name;
    // The TRUE base is the live vertex array — the routed path never writes it.
    Vec3[] base;
    base.length = m.vertices.length;
    foreach (i; 0 .. m.vertices.length) base[i] = m.vertices[i];
    // The RUN baseline is base + whatever the map already holds.
    Vec3[] runPos;
    runPos.length = m.vertices.length;
    auto map = m.morphMapForWrite(name);
    foreach (i; 0 .. m.vertices.length)
        runPos[i] = morphApply(base[i],
                               map is null ? defaultStored(base[i], kind)
                                           : map.entryOr(i, defaultStored(base[i], kind)),
                               kind, 1.0f);
    r.base   = base;
    r.runPos = runPos;
    return r;
}

private Vec3 stored(ref Mesh m, string name, size_t vi) {
    Vec3 v;
    assert(m.morphValue(name, vi, v), "vertex has no entry");
    return v;
}

// ---------------------------------------------------------------------------
// The position-copy twin.
// ---------------------------------------------------------------------------

unittest {
    Mesh m = rig();
    m.addMeshMapOfKind(MapKind.morphRelative, "mm");
    auto route = routeFor(m, "mm", MapKind.morphRelative);
    auto sp = packetX();

    // The DRIVER has already been routed by the kernel: it moved +Z by 0.4.
    auto map = m.morphMapForWrite("mm");
    map.setEntry(0, Vec3(0, 0, 0.4f));

    Vec3[] baseBefore = m.vertices.dup;

    bool[] selected = [true, false, false];
    bool[] touched;  touched.length = 3;
    applySymmetryMirrorRouted(&m, sp, selected, touched, route);

    // The partner's stored value is the MIRRORED position expressed as a
    // delta. Mirroring across x=0 maps (1, 0.5, 0.65) -> (-1, 0.5, 0.65),
    // and the partner's base is (-1, 0.5, 0.25), so the delta is (0,0,0.4).
    auto p = stored(m, "mm", 1);
    assert(p.x == 0 && p.y == 0 && (p.z > 0.399f && p.z < 0.401f),
        "the mirror partner must receive the MIRRORED delta");

    // The BUG the routed reads exist to prevent: a mirror that reads the
    // driver's `mesh.vertices` reads the UNMOVED base under routing, mirrors
    // that, and stores (0,0,0) for the partner. Show that the wrong answer is
    // DIFFERENT from the right one, so this assertion discriminates -- and
    // note that "the partner's entry CHANGED" would be true of BOTH, because
    // absent -> present-zero is a change.
    assert(!(p.z == 0.0f),
        "a naive write-only substitution stores zero here and an "
      ~ "'entry changed' assertion cannot tell it from the right answer");

    // Nothing was written to the base, on either side.
    foreach (i; 0 .. m.vertices.length)
        assert(m.vertices[i] == baseBefore[i],
            "a routed mirror must not touch mesh.vertices");
    assert(touched[1], "the partner is reported in outAlsoTouched");
}

unittest { // the ON-PLANE branch projects the DRAWN point and stores it -- it
           // does NOT move the base, which is what a naive substitution here
           // would do (it writes the driver's own position).
           //
           // THE STORED VALUE MUST VARY OFF THE PLANE NORMAL. This block used
           // to store (0.7, 0, 0) and assert only `p.x == 0` -- and the
           // projection kills x, so the right answer and the naive
           // `projectOnPlane(sp, route.base[i])` BOTH produce x == 0. The
           // mutation came back green (task 1073, review SF4), while the live
           // cost of the bug it failed to see is severe: an on-plane vertex
           // dragged WITHIN the plane has its whole stored delta zeroed on
           // every apply, so it never moves at all. The displacement below
           // therefore carries an IN-PLANE component (z) that must SURVIVE
           // the projection, alongside the off-plane one (x) that must not.
    Mesh m = rig();
    m.addMeshMapOfKind(MapKind.morphRelative, "mm");
    auto route = routeFor(m, "mm", MapKind.morphRelative);
    auto sp = packetX();
    auto map = m.morphMapForWrite("mm");

    // Vertex 2 sits ON the x=0 plane and the kernel has pushed it off the
    // plane by +0.7 in x AND along it by +0.5 in z.
    map.setEntry(2, Vec3(0.7f, 0, 0.5f));
    Vec3[] baseBefore = m.vertices.dup;

    bool[] selected = [false, false, true];
    bool[] touched;  touched.length = 3;
    applySymmetryMirrorRouted(&m, sp, selected, touched, route);

    // Drawn point = base (0,2,3) + (0.7,0,0.5) = (0.7, 2, 3.5).
    // Projected onto x = 0 -> (0, 2, 3.5). Stored as a delta from the base:
    // (0, 0, 0.5) -- x flattened, z untouched.
    auto p = stored(m, "mm", 2);
    assert(p.x == 0.0f && p.y == 0.0f,
        "an on-plane driver must be projected back onto the plane IN THE MAP "
      ~ "-- the 'centre stays on the plane' contract");
    assert(p.z > 0.499f && p.z < 0.501f,
        "...and the IN-PLANE half of the displacement must SURVIVE. A "
      ~ "projection applied to the wrong point flattens this to zero and the "
      ~ "vertex never moves");

    // House discriminator: compute the rejected form in this test's own
    // arithmetic and show it gives a DIFFERENT answer here. The naive
    // substitution projects the BASE rather than the drawn point, so it
    // stores the base's own projection -- a zero delta -- for any
    // displacement whatsoever.
    {
        import symmetry     : projectOnPlane;
        import mesh_morph   : morphRoutedStore;
        const Vec3 naive = morphRoutedStore(route.base[2],
                                            projectOnPlane(sp, route.base[2]),
                                            MapKind.morphRelative);
        assert(naive.z == 0.0f && p.z != naive.z,
            "the naive `projectOnPlane(base)` form must differ from the "
          ~ "correct one HERE -- a fixture where they agree cannot fail when "
          ~ "the branch regresses, which is exactly what the (0.7,0,0) "
          ~ "displacement this test used to carry produced");
    }

    foreach (i; 0 .. m.vertices.length)
        assert(m.vertices[i] == baseBefore[i],
            "the on-plane branch must not write the BASE -- left unrouted it "
          ~ "is the one place a routed gesture still moves geometry");
}

unittest { // the DELTA twin (topological symmetry) preserves the partner's
           // OWN pre-existing morph and mirrors only this gesture's delta.
    Mesh m = rig();
    m.addMeshMapOfKind(MapKind.morphRelative, "mm");
    auto map = m.morphMapForWrite("mm");
    // The partner already carries a morph from an earlier gesture.
    map.setEntry(1, Vec3(0, 0.25f, 0));
    // Build the route AFTER that, so runPos carries the partner's deformation.
    auto route = routeFor(m, "mm", MapKind.morphRelative);
    auto sp = packetX();
    sp.topology = true;

    // Now the kernel routes the driver: +Z by 0.4 this gesture.
    map.setEntry(0, Vec3(0, 0, 0.4f));
    Vec3[] baseBefore = m.vertices.dup;

    bool[] selected = [true, false, false];
    bool[] touched;  touched.length = 3;
    Vec3[] baseline = m.vertices.dup;   // the unrouted twin's parameter
    applySymmetryMirrorDeltaRouted(&m, sp, baseline, selected, touched, route);

    // Partner target = its RUN position + the mirrored delta.
    //   run position = (-1, 0.75, 0.25);  mirrored delta = (0,0,0.4)
    //   target       = (-1, 0.75, 0.65);  base = (-1, 0.5, 0.25)
    //   stored delta = (0, 0.25, 0.4)
    auto p = stored(m, "mm", 1);
    assert(p.x == 0.0f, "x");
    assert(p.y > 0.249f && p.y < 0.251f,
        "the partner's PRE-EXISTING morph must survive -- the delta twin "
      ~ "mirrors only this gesture's displacement");
    assert(p.z > 0.399f && p.z < 0.401f, "the mirrored delta lands in z");

    // The failure a naive substitution produces: it computes
    // `delta = mesh.vertices[i] - baseline[i]`, which under routing is ZERO
    // for every vertex, so the partner would be written back to its run
    // position and this gesture's mirror would vanish.
    assert(!(p.z == 0.0f),
        "a delta twin reading mesh.vertices computes delta == 0 under routing "
      ~ "and the mirror silently does nothing");

    foreach (i; 0 .. m.vertices.length)
        assert(m.vertices[i] == baseBefore[i],
            "the delta twin must not touch mesh.vertices either");
}

unittest { // with no target bound the routed overloads ARE the unrouted ones
           // -- one behaviour for the no-target case, and it is the existing
           // code path.
    Mesh m = rig();
    auto sp = packetX();
    MorphRoute inert;                       // .init == no routing
    assert(!inert.active());
    assert(!inert.covers(m.vertices.length));

    // Move the driver in the BASE, the way an unrouted gesture would.
    m.vertices[0] = Vec3(1, 0.5f, 0.65f);
    bool[] selected = [true, false, false];
    bool[] touched;  touched.length = 3;
    applySymmetryMirrorRouted(&m, sp, selected, touched, inert);

    assert(m.vertices[1].x == -1.0f && m.vertices[1].z == 0.65f,
        "with no route the overload must tail-call the unrouted twin and "
      ~ "mirror in the BASE exactly as before");
}

unittest { // a short / mis-sized route is refused rather than indexed into
    Mesh m = rig();
    m.addMeshMapOfKind(MapKind.morphRelative, "mm");
    MorphRoute r;
    r.kind = MapKind.morphRelative;
    r.name = "mm";
    r.base   = [Vec3(0, 0, 0)];             // too short
    r.runPos = [Vec3(0, 0, 0)];
    assert(r.active(), "the kind alone says routing is intended");
    assert(!r.covers(m.vertices.length),
        "...but `covers` is what every consumer gates on, and a short array "
      ~ "must not pass it");
}

// ---------------------------------------------------------------------------
// The routed gesture's undo record.
// ---------------------------------------------------------------------------

unittest {
    import commands.mesh.morph_edit : MeshMorphEdit, MorphEntryEdit;
    import command : Command, CompareResult, RunMergeable;
    import view : View;
    import editmode : EditMode;

    Mesh m = rig();
    m.addMeshMapOfKind(MapKind.morphRelative, "mm");
    View v = new View(0, 0, 1, 1);

    // Vertex 0 went from ABSENT to (0,0,0.4); vertex 1 from (0,0.25,0) to
    // (0,0.25,0.4). Presence is part of the payload: undo has to be able to
    // return an entry to ABSENT, and writing a zero instead leaves a PRESENT
    // zero -- a different state on the wire, and for the absolute kind a
    // different position.
    auto cmd = new MeshMorphEdit(&m, v, EditMode.Vertices);
    cmd.setEdit("mm", [
        MorphEntryEdit(0, Vec3(0, 0, 0),      false, Vec3(0, 0, 0.4f),      true),
        MorphEntryEdit(1, Vec3(0, 0.25f, 0),  true,  Vec3(0, 0.25f, 0.4f),  true),
    ], "Move");
    assert(cmd.changed());

    assert(cmd.apply());
    Vec3 got;
    assert(m.morphValue("mm", 0, got) && got.z > 0.399f);
    assert(m.morphValue("mm", 1, got) && got.y > 0.249f && got.z > 0.399f);

    assert(cmd.revert());
    assert(!m.morphValue("mm", 0, got),
        "revert must return vertex 0 to ABSENT, not to a present zero");
    assert(m.morphValue("mm", 1, got) && got.z == 0.0f && got.y > 0.249f,
        "vertex 1 was present before and returns to its earlier VALUE");

    // A gesture that changed nothing must not reach the stack.
    auto inert = new MeshMorphEdit(&m, v, EditMode.Vertices);
    inert.setEdit("mm", [MorphEntryEdit(0, Vec3(1, 1, 1), true, Vec3(1, 1, 1), true)]);
    assert(!inert.changed());
    // ...but a PRESENCE-only difference IS a change (a zero-magnitude move
    // still creates an entry).
    auto presenceOnly = new MeshMorphEdit(&m, v, EditMode.Vertices);
    presenceOnly.setEdit("mm",
        [MorphEntryEdit(0, Vec3(0, 0, 0), false, Vec3(0, 0, 0), true)]);
    assert(presenceOnly.changed(),
        "absent -> present-zero is a real change and must be undoable");
}

unittest { // compareOp must compare the MAP NAME
    import commands.mesh.morph_edit : MeshMorphEdit, MorphEntryEdit;
    import command : CompareResult;
    import view : View;
    import editmode : EditMode;

    Mesh m = rig();
    m.addMeshMapOfKind(MapKind.morphRelative, "a");
    m.addMeshMapOfKind(MapKind.morphRelative, "b");
    View v = new View(0, 0, 1, 1);

    auto mk(string map) {
        auto c = new MeshMorphEdit(&m, v, EditMode.Vertices);
        c.setEdit(map, [MorphEntryEdit(0, Vec3(0,0,0), false, Vec3(0,0,1), true)], "Move");
        return c;
    }
    assert(mk("a").compareOp(mk("a")) == CompareResult.Compatible);
    assert(mk("b").compareOp(mk("a")) == CompareResult.Different,
        "two edits into DIFFERENT morphs must not coalesce -- one undo entry "
      ~ "could then only restore one of the two maps");
}

unittest { // mergeRunTail: first-touch BEFORE, latest AFTER, union by vertex
    import commands.mesh.morph_edit : MeshMorphEdit, MorphEntryEdit;
    import command : Command;
    import view : View;
    import editmode : EditMode;

    Mesh m = rig();
    m.addMeshMapOfKind(MapKind.morphRelative, "mm");
    View v = new View(0, 0, 1, 1);

    auto c1 = new MeshMorphEdit(&m, v, EditMode.Vertices);
    c1.setEdit("mm", [MorphEntryEdit(0, Vec3(0,0,0), false, Vec3(0,0,1), true)], "Move");
    auto c2 = new MeshMorphEdit(&m, v, EditMode.Vertices);
    c2.setEdit("mm", [MorphEntryEdit(0, Vec3(0,0,1), true, Vec3(0,0,2), true),
                      MorphEntryEdit(1, Vec3(0,0,0), false, Vec3(0,0,5), true)], "Move");

    auto merged = cast(MeshMorphEdit) c1.mergeRunTail([cast(Command) c2]);
    assert(merged !is null, "a same-map run must merge");
    assert(merged.entries.length == 2, "union by vertex id");
    foreach (ref e; merged.entries) {
        if (e.vert == 0) {
            assert(!e.beforePresent && e.before.z == 0,
                "vertex 0 keeps the run-START before (first touch)");
            assert(e.after.z == 2, "and adopts the run-END after");
        } else {
            assert(e.vert == 1 && !e.beforePresent && e.after.z == 5,
                "a vertex first touched by a LATER gesture keeps its OWN before");
        }
    }

    // A run that switched target mid-way must DECLINE rather than fold into
    // one entry that can restore only one of the two maps.
    m.addMeshMapOfKind(MapKind.morphRelative, "other");
    auto c3 = new MeshMorphEdit(&m, v, EditMode.Vertices);
    c3.setEdit("other", [MorphEntryEdit(0, Vec3(0,0,0), false, Vec3(0,0,9), true)], "Move");
    assert(c1.mergeRunTail([cast(Command) c3]) is null,
        "a run spanning two different morphs must not consolidate");
}
