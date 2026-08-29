// gesture_carrier_interface_test — task 3340, item B: the carrier-class door of
// `Tool.setGestureBindings`, and the silent drop it exists to make impossible.
//
// WHAT WAS LATENT. Task 1905's seam requires an undo carrier to implement
// `GesturePayload` (`source/commands/mesh/gesture_payload.d`). Re-measured on
// this branch by walking `EditorApp`'s factory table
// (`X delegate() <name>;` in source/editor_app.d) and the two inline factories
// at their binding sites:
//
//   IMPLEMENT (4)      MeshSessionEdit (24 factory fields), MeshVertexEdit,
//                      MeshVertexNew (bound inline at registration.d),
//                      BoxLiveEditCommand (built from the tool's own state)
//   DO NOT (2)         MeshMorphEdit    via `morphEditFactory`
//                      LayerXformEdit   via `layerXformEditFactory`
//
// Both non-implementers are harmless TODAY because they route only through
// `setUndoBindings` / `setItemUndoFactory`, which never cast to the interface.
// The trap is the next literal step of the migration: someone writes
// `t.setGestureBindings(history, morphEditFactory)`, it COMPILES (delegate
// covariance reaches the base class `Command`), and from then on the gesture
// keeps working while its undo entry disappears. The G7 lane hit exactly that
// and caught it by hand.
//
// THE FOUR THINGS PINNED HERE, and each has its own mutation:
//
//   1. THE FAILURE IS REAL, DEMONSTRATED BEFORE THE GUARD. Block 1 routes a
//      `MeshMorphEdit` through the seam with its static type erased, applies
//      it (the "gesture" works: the morph entry lands on the mesh), and then
//      shows the recorder refusing it — undo stack unmoved, mismatch counter
//      +1. That is the silent drop, made loud.
//        M: delete the `if (payload is null)` arm from
//           `Tool.recordGestureEdit` -> block 1's counter assertion reddens
//           (and the drop stops being COUNTED, which is the worse world).
//
//   2. THE GUARD REFUSES THE TWO REAL NON-IMPLEMENTERS AT COMPILE TIME, by
//      name. `__traits(compiles, …)` over the actual `MeshMorphEdit
//      delegate()` / `LayerXformEdit delegate()` the factory table hands out.
//        M: delete the `static assert` from `Tool.setGestureBindings` ->
//           block 2 reddens on both names.
//
//   3. ANTI-VACUITY: THE GUARD IS NOT "REFUSE EVERYTHING". Block 3 requires
//      every carrier that DOES implement the interface to still bind, plus the
//      deliberate `cast(Command)` erasure the belt's own probe uses. A guard
//      that rejected all four would satisfy block 2 and fail here.
//        M: drop the `is(GestureCarrierOf!F == Command)` arm from
//           `gestureCarrierDeclaresPayload` -> `dub test --config=tests` fails
//           to build. Measured: the FIRST error is the door's own refusal at
//           source/tool.d, raised by `gesture_record_belt_test.d`'s erased
//           binding, which the compiler reaches before this block. That is not
//           a weaker result, it is a stronger one — all four rows here mirror
//           a REAL binding in `source/registration.d` (`bevelEditFactory` and
//           its 23 siblings, `vxEditFactory` at `xfrm.magnet`, the inline
//           `MeshVertexNew` at `mesh.topoPen`, the erasure at the belt probe),
//           so an over-broad door cannot compile the tree at all. The rows
//           stay because they say WHICH carrier and WHY at the place a reader
//           of this seam will look, and dmd reports only its first error.
//
//   4. THE INTERFACE IS ACTUALLY DECLARED, not merely castable-to at a call
//      site. Block 4 asserts the four carriers answer `hasGesturePayload()`
//      through the interface.
//        M: delete `GesturePayload` from `MeshVertexNew`'s base list -> block
//           4 reddens naming it (and block 3 reddens too — run in isolation).
//
// LANE: `dub test --config=tests`.
module tests.unit.gesture_carrier_interface_test;

import change_bus      : changeBus;
import command         : Command;
import command_history : CommandHistory;
import commands.layer.xform_edit    : LayerXformEdit;
import commands.mesh.gesture_payload : GesturePayload;
import commands.mesh.morph_edit     : MeshMorphEdit, MorphEntryEdit;
import commands.mesh.session_edit   : MeshSessionEdit;
import commands.mesh.vertex_edit    : MeshVertexEdit;
import commands.mesh.vertex_new     : MeshVertexNew;
import editmode        : EditMode;
import math            : Vec3;
import mesh;
import mesh_edit_delta : MeshEditScope;
import tool            : Tool, GestureRecordMode;
import view            : View;

import std.conv : to;

/// The smallest possible `Tool` — it exists only to re-expose the `protected`
/// recorder. `recordGestureEdit` below IS the shipped one.
private final class CarrierProbeTool : Tool {
    override string name() const { return "probe.carrier"; }
    bool probeRecord(Command cmd, GestureRecordMode mode) {
        return recordGestureEdit(cmd, mode);
    }
}

private Mesh makeTri() {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1u, 2u]);
    m.buildLoops();
    return m;
}

private string s(T)(T n) { return n.to!string; }

// ---------------------------------------------------------------------------
// 1. THE SILENT DROP, DRIVEN. A real non-implementing carrier goes through the
//    seam with its static type erased: the edit lands on the mesh and the undo
//    entry does not land on the stack.
// ---------------------------------------------------------------------------
unittest {
    enum string kMap = "probeMorph";

    auto m = makeTri();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();
    auto t = new CarrierProbeTool();

    assert(m.addMeshMapOfKind(MapKind.morphRelative, kMap) !is null,
        "CONTROL: could not register the morph map this block edits — with no "
      ~ "map, `MeshMorphEdit.applyImpl` writes nothing and the 'the gesture "
      ~ "still works' half below would be vacuous");

    // The erased binding is what a caller must write to get an unchecked
    // carrier past the compile-time door (block 2). It is here to prove the
    // RUNTIME half still refuses when someone does.
    t.setGestureBindings(h, () => cast(Command) new MeshMorphEdit(&m, v, EditMode.Vertices));

    auto cmd = new MeshMorphEdit(&m, v, EditMode.Vertices);
    cmd.setEdit(kMap, [MorphEntryEdit(1u, Vec3(0, 0, 0), false, Vec3(0, 0.25f, 0), true)], "Probe");
    assert(!cmd.isEmpty() && cmd.changed(),
        "CONTROL: the carrier was filled with an entry that changes nothing, so "
      ~ "'the gesture worked' cannot be observed below");

    // --- the gesture itself ---
    assert(cmd.apply(),
        "CONTROL: applying the morph edit failed; this block then measures a "
      ~ "gesture that never happened");
    Vec3 got;
    assert(m.morphValue(kMap, 1, got) && got.y == 0.25f,
        "CONTROL: the morph entry did not land on the mesh, so the point of "
      ~ "this block — an edit that SURVIVES while its undo entry does not — "
      ~ "is not being made");

    // --- and the undo entry that is NOT recorded for it ---
    immutable ulong mismatch0 = changeBus.gestureCarrierMismatch;
    immutable size_t depth0   = h.undoEntriesVisible().length;

    assert((cast(GesturePayload) cmd) is null,
        "CONTROL: `MeshMorphEdit` implements `GesturePayload` after all. Good "
      ~ "news — but then this block drives the SUCCESS path and every "
      ~ "assertion below is vacuous. Retire the row and the compile-time cell "
      ~ "for it in block 2");

    assert(!t.probeRecord(cmd, GestureRecordMode.Plain),
        "the recorder ACCEPTED a carrier that does not implement "
      ~ "`GesturePayload` — the cast cannot have been checked at all");
    assert(h.undoEntriesVisible().length == depth0,
        "the mis-bound carrier moved the undo stack by "
      ~ s(h.undoEntriesVisible().length - depth0) ~ ", expected 0");
    assert(changeBus.gestureCarrierMismatch == mismatch0 + 1,
        "the mis-bound carrier was dropped SILENTLY: the mismatch counter "
      ~ "moved by " ~ s(changeBus.gestureCarrierMismatch - mismatch0)
      ~ ", expected 1. A silent drop here is a mutated mesh with nothing on "
      ~ "the stack and nothing that says so");

    // The edit is STILL on the mesh after the refusal — that is the whole
    // shape of the trap, and it is asserted rather than implied.
    Vec3 after;
    assert(m.morphValue(kMap, 1, after) && after.y == 0.25f,
        "the refusal rolled the edit back. It does not, and must not: by the "
      ~ "time the recorder runs, only the TOOL still holds the pre-image");
}

// ---------------------------------------------------------------------------
// 2. THE COMPILE-TIME DOOR — the two real non-implementers cannot be bound.
//    These are the exact delegate types `EditorApp` hands out
//    (`MeshMorphEdit delegate()` / `LayerXformEdit delegate()`), not stand-ins.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeTri();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();
    auto t = new CarrierProbeTool();

    MeshMorphEdit  delegate() morphEditFactory      = () => new MeshMorphEdit(&m, v, EditMode.Vertices);
    LayerXformEdit delegate() layerXformEditFactory = () => new LayerXformEdit(&m, v, EditMode.Vertices);

    static assert(!__traits(compiles, t.setGestureBindings(h, morphEditFactory)),
        "`setGestureBindings(history, morphEditFactory)` COMPILES. That is the "
      ~ "literal next step of the 1905 migration and it must not: "
      ~ "`MeshMorphEdit` does not implement `GesturePayload`, so every routed "
      ~ "gesture would stop recording while it kept working (block 1 drives "
      ~ "that failure). Restore the `static assert` in "
      ~ "`Tool.setGestureBindings`");
    static assert(!__traits(compiles, t.setGestureBindings(h, layerXformEditFactory)),
        "`setGestureBindings(history, layerXformEditFactory)` COMPILES. Same "
      ~ "defect as the morph row above, one class over: `LayerXformEdit` does "
      ~ "not implement `GesturePayload`");

    // Keep the two factories LIVE so this block cannot pass over dead code —
    // a factory the compiler eliminated is not the factory the door judged.
    assert(morphEditFactory() !is null && layerXformEditFactory() !is null,
        "a factory built a null carrier; the compile-time cells above then "
      ~ "judged a type nothing produces");
}

// ---------------------------------------------------------------------------
// 3. ANTI-VACUITY — the door is not "refuse everything". Every carrier that
//    DOES declare the interface still binds, and so does the deliberate
//    `cast(Command)` erasure the belt's own probe uses.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeTri();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();
    auto t = new CarrierProbeTool();

    MeshSessionEdit delegate() sessionFactory =
        () => new MeshSessionEdit(&m, v, EditMode.Vertices,
                                  "probe.session_edit", "Probe",
                                  MeshEditScope.Geometry);
    MeshVertexEdit  delegate() vxEditFactory  = () => new MeshVertexEdit(&m, v, EditMode.Vertices);
    MeshVertexNew   delegate() vxNewFactory   = () => new MeshVertexNew(&m, v, EditMode.Vertices);
    Command         delegate() erasedFactory  = () => cast(Command) new MeshMorphEdit(&m, v, EditMode.Vertices);

    static assert(__traits(compiles, t.setGestureBindings(h, sessionFactory)),
        "the door REFUSED `MeshSessionEdit`, the carrier 24 of the factory "
      ~ "table's fields hand out. A door that refuses everything satisfies "
      ~ "block 2 and is worth nothing");
    static assert(__traits(compiles, t.setGestureBindings(h, vxEditFactory)),
        "the door REFUSED `MeshVertexEdit`, which implements `GesturePayload`");
    static assert(__traits(compiles, t.setGestureBindings(h, vxNewFactory)),
        "the door REFUSED `MeshVertexNew`, which implements `GesturePayload`");
    static assert(__traits(compiles, t.setGestureBindings(h, erasedFactory)),
        "the door REFUSED a factory whose static type is exactly `Command`. "
      ~ "That erasure is the belt's own probe binding "
      ~ "(tests/unit/gesture_record_belt_test.d) and the ONLY sanctioned way "
      ~ "to bind an unchecked carrier — the runtime belt still counts it");

    // Bind them for real, so the cells above are not judging an expression the
    // compiler never had to accept.
    t.setGestureBindings(h, sessionFactory);
    t.setGestureBindings(h, vxEditFactory);
    t.setGestureBindings(h, vxNewFactory);
    t.setGestureBindings(h, erasedFactory);
}

// ---------------------------------------------------------------------------
// 4. THE INTERFACE IS DECLARED BY THE FOUR — read through the interface, not
//    through the concrete class, so a method that merely shares the NAME does
//    not satisfy this.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeTri();
    auto v = new View(0, 0, 800, 600);

    Command[] carriers = [
        cast(Command) new MeshSessionEdit(&m, v, EditMode.Vertices,
                                          "probe.session_edit", "Probe",
                                          MeshEditScope.Geometry),
        cast(Command) new MeshVertexEdit(&m, v, EditMode.Vertices),
        cast(Command) new MeshVertexNew(&m, v, EditMode.Vertices),
    ];
    immutable string[] names = ["MeshSessionEdit", "MeshVertexEdit", "MeshVertexNew"];

    foreach (i, c; carriers) {
        auto p = cast(GesturePayload) c;
        assert(p !is null,
            "`" ~ names[i] ~ "` no longer implements `GesturePayload`. Every "
          ~ "gesture routed through `Tool.recordGestureEdit` with this carrier "
          ~ "now stops recording while it keeps working");
        // An unfilled carrier answers false — asserted so this block cannot be
        // satisfied by an interface whose method is never actually called.
        assert(!p.hasGesturePayload(),
            "`" ~ names[i] ~ "` was constructed and never filled, yet answers "
          ~ "`hasGesturePayload() == true`. The belt then cannot tell a filled "
          ~ "carrier from an empty one");
    }

    // The other side of the same census, and it is what makes the rows in
    // block 2 honest: these two are the non-implementers, by name.
    assert((cast(GesturePayload) new MeshMorphEdit(&m, v, EditMode.Vertices)) is null,
        "`MeshMorphEdit` now implements `GesturePayload` — good news. Delete "
      ~ "its row here and its compile-time cell in block 2, and move it to the "
      ~ "list above");
    assert((cast(GesturePayload) new LayerXformEdit(&m, v, EditMode.Vertices)) is null,
        "`LayerXformEdit` now implements `GesturePayload` — good news. Delete "
      ~ "its row here and its compile-time cell in block 2, and move it to the "
      ~ "list above");
}
