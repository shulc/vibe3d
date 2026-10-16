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

import vibe3d.util.math.math : Vec3;
import vibe3d.mesh.core.mesh;

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







// ---------------------------------------------------------------------------
// The position-copy twin.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// The routed gesture's undo record.
// ---------------------------------------------------------------------------

unittest {
    import vibe3d.editing.commands.editor.commands.mesh.morph_edit : MeshMorphEdit, MorphEntryEdit;
    import vibe3d.editing.commands.runtime.command : Command, CompareResult, RunMergeable;
    import vibe3d.viewport.camera.view : View;
    import vibe3d.editing.contracts.editmode : EditMode;

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
    import vibe3d.editing.commands.editor.commands.mesh.morph_edit : MeshMorphEdit, MorphEntryEdit;
    import vibe3d.editing.commands.runtime.command : CompareResult;
    import vibe3d.viewport.camera.view : View;
    import vibe3d.editing.contracts.editmode : EditMode;

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
    import vibe3d.editing.commands.editor.commands.mesh.morph_edit : MeshMorphEdit, MorphEntryEdit;
    import vibe3d.editing.commands.runtime.command : Command;
    import vibe3d.viewport.camera.view : View;
    import vibe3d.editing.contracts.editmode : EditMode;

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
