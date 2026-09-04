// Module unittests for `toolpipe.stages.symmetry`, moved verbatim out of source/toolpipe/stages/symmetry.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.toolpipe.stages.symmetry_test;

import std.format : format;
import math    : Vec3, dot;
import mesh    : Mesh;
import editmode : EditMode;
import toolpipe.stage    : Stage, TaskCode, ordSymm;
import toolpipe.packets  : SymmetryPacket, SymmetryConfig;
import operator          : Operator, Task, VectorStack, PacketKind;
import popup_state       : setStatePath;
import symmetry          : rebuildPairing, rebuildPairingTopological;
import params            : Param, IntEnumEntry;
import toolpipe.stages.symmetry;

unittest { // One symmetry config, with one named behaviour-preserving exception.
    const packetDefaults = SymmetryPacket.init.config;
    auto st = new SymmetryStage();

    // `Stage.pipeEnabled` and the config's user toggle are separate storage.
    // This is the alias-this collision that task 0705 exposed for SnapConfig.
    assert(st.pipeEnabled,
        "a freshly constructed symmetry stage is registered in the pipe");
    assert(!st.enabled,
        "a fresh symmetry stage's USER toggle must remain off");
    assert(&st.enabled is &st.config.enabled,
        "SymmetryStage.enabled must resolve to SymmetryConfig's storage");

    // Owner decision still open: packet fallback means "no axis" (-1), while
    // constructing/resetting the stage preserves today's X default (0). Keep
    // the divergence explicit until the owner selects one product behaviour.
    assert(packetDefaults.axisIndex == -1,
        format("axisIndex defaults changed: packet=%s, stage=%s; packet -1 "
             ~ "is the preserved no-axis fallback and stage 0 is preserved X",
               packetDefaults.axisIndex, st.axisIndex));
    assert(st.axisIndex == 0,
        format("axisIndex defaults changed: packet=%s, stage=%s; the stage "
             ~ "must preserve today's X default while the decision is open",
               packetDefaults.axisIndex, st.axisIndex));

    // Apart from that named line, the two effective default sets are equal.
    SymmetryConfig normalizedStage = st.config;
    normalizedStage.axisIndex = packetDefaults.axisIndex;
    assert(normalizedStage == packetDefaults,
        "packet and stage symmetry defaults diverged outside the named "
        ~ "axisIndex placeholder");

    // Snapshot/restore/reset must move the whole config, not another field
    // list that can fall behind the declaration.
    st.enabled      = true;
    st.axisIndex    = 2;
    st.offset       = 3.5f;
    st.useWorkplane = true;
    st.topology     = true;
    st.epsilonWorld = 0.25f;
    st.baseSide     = -1;
    auto saved = st.snapshotConfigToPacket();
    assert(saved.config == st.config,
        "snapshotConfigToPacket must copy the complete SymmetryConfig");

    st.reset();
    SymmetryConfig expectedStage = SymmetryConfig.init;
    expectedStage.axisIndex = 0;
    assert(st.config == expectedStage,
        "reset must restore SymmetryConfig plus the named stage-axis exception");
    assert(st.pipeEnabled,
        "resetting user config must not unregister the stage from the pipe");

    st.restoreConfigFromPacket(saved);
    assert(st.config == saved.config,
        "restoreConfigFromPacket must restore the complete SymmetryConfig");
}

// ---------------------------------------------------------------------------
// Task 0401 / task 1906 stage 2c — the pairing cache (`pairOf` / `onPlane` /
// `vertSign`) must not serve a stale pre-edit snapshot after a VERSION-SILENT
// position edit. An interactive gizmo Move/Rotate/Scale mutates vertex
// positions WITHOUT ever bumping `mutationVersion` — both on drag AND on
// commit (see the warning above SubpatchPreview.deactivate() in mesh.d for why
// that is deliberate) — so an `(addr, mutationVersion, plane, epsilon)` key
// cannot see the edit at all.
//
// TWO PINS, AND EACH ANSWERS A DIFFERENT MUTATION:
//
//   B. a bare `mutationVersion++` over moved geometry must NOT rebuild the
//      pair table. Putting `cachedMutationVersion_ != mesh_.mutationVersion`
//      back into `evaluate`'s `meshChanged` turns this into a rebuild, and
//      this line is where that shows up.
//   C. `mesh_dirty.noteMeshChange(&cube, Position)` — the listener body — MUST
//      rebuild it. Dropping the `(address, g_geomEpochs)` term turns this into
//      a stale read.
//
// The class is delivered by calling the listener BODY directly, exactly as
// `tests/unit/bvh_pick_test.d` does and for the same reason: a stack `Mesh`
// belongs to no `Layer`, so `publishChange` would be refused by the subject
// filter in `Mesh.deliverPending` and this block would pass vacuously.
//
// Drives `evaluate()` directly (no g_pipeCtx/pipeline needed — SymmetryStage
// only reads a WorkplanePacket off the stack when useWorkplane is set, which
// this test leaves off) and reproduces the version-silent path exactly, not
// the scripted `/api/transform` path (which DOES bump mutationVersion).
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import change_bus : MeshEditScope;
    import mesh_dirty : noteMeshChange;
    import operator : VectorStack;

    Mesh cube = makeCube();
    Mesh* meshPtr = &cube;
    EditMode em = EditMode.Vertices;
    auto sym = new SymmetryStage(() => meshPtr, &em);
    sym.enabled   = true;
    sym.axisIndex = 0;   // mirror plane: X = 0

    // makeCube's corners sit at x == ±0.5 — grab one on the -X side.
    size_t vi = size_t.max;
    foreach (i, v; cube.vertices) if (v.x < 0) { vi = i; break; }
    assert(vi != size_t.max, "expected at least one -X cube corner");

    VectorStack vts1;
    assert(sym.evaluate(vts1));
    auto pkt1 = vts1.get!SymmetryPacket();
    assert(pkt1 !is null);
    assert(pkt1.vertSign[vi] == -1,
        "corner starting on the -X side should read vertSign == -1");

    ulong mutVerBefore = cube.mutationVersion;

    // --- B. the version counter is OUT of the key ---------------------------
    // Version-silent edit — exactly what an interactive gizmo drag/commit
    // does: push the vertex across the mirror plane, note the Position
    // change class, never bump mutationVersion. Then bump the counter BY HAND.
    // A bare `++` is what CLAUDE.md forbids on a LIVE mesh
    // (`changeBus.missedPublishers`); this is a stack scratch no `Layer` owns,
    // and the bump IS the mutation probe — it must move nothing.
    cube.vertices[vi] = Vec3(cube.vertices[vi].x + 5.0f,
                              cube.vertices[vi].y, cube.vertices[vi].z);
    cube.noteChange(MeshEditScope.Position);   // accumulate-only: never delivers
    assert(cube.mutationVersion == mutVerBefore,
        "test setup must stay version-silent to mirror the gizmo path");
    ++cube.mutationVersion;

    VectorStack vts2;
    assert(sym.evaluate(vts2));
    auto pkt2 = vts2.get!SymmetryPacket();
    assert(pkt2.vertSign[vi] == -1,
        "task 1906 stage 2c: `mutationVersion` is NO LONGER a pairing-cache "
        ~ "key term. The counter was bumped by hand over MOVED geometry and "
        ~ "nobody told the change bus, so the pair table must still describe "
        ~ "the pre-edit mesh and vertSign must still read -1. A +1 here means "
        ~ "the version compare is back in evaluate() — and that compare is "
        ~ "blind to the gesture users make most");

    // --- C. the change-bus epoch IS the key ---------------------------------
    noteMeshChange(cast(size_t)meshPtr, MeshEditScope.Position);
    VectorStack vts3;
    assert(sym.evaluate(vts3));
    auto pkt3 = vts3.get!SymmetryPacket();
    assert(pkt3.vertSign[vi] == +1,
        "task 1906 stage 2c: a delivered Position class must force the pair "
        ~ "table to rebuild against the moved vertex. A -1 here means the "
        ~ "(address, g_geomEpochs) term is gone from evaluate()'s meshChanged "
        ~ "and the mirror pairing serves the pre-drag geometry for the rest "
        ~ "of the session");

    assert(cube.mutationVersion == mutVerBefore + 1,
        "evaluate() must never mutate the mesh's mutationVersion (that "
        ~ "counter's version-silence on a position edit is the intentional "
        ~ "contract this fix works around, not papers over)");
}

// task 0678 P4 — the attr universe must be visible even when the stage is
// OFF: params() is a visibility filter (empty when disabled), and before the
// fix knownAttrs() derived from it — so a disabled symmetry stage reported an
// EMPTY universe and the forms-engine startup-strict validator rejected
// every symmetry attr, while an enabled one under-reported 4 of the 6 names
// applySetAttr accepts (stage.d's fullParams contract forbids both).
unittest {
    import toolpipe.stage : assertRejectsUndeclaredAttrs;
    auto st = new SymmetryStage();
    assert(!st.enabled, "fixture assumes the default-constructed stage is off");

    auto names = st.knownAttrs();
    assert(names.length == 6,
           "disabled symmetry must still report its full 6-name universe");

    // listAttrs is the read surface for the same six writable names, plus the
    // deliberate read-only baseSide row. Check the writable universe before
    // the count so a removed row reports its name rather than only "6 != 7".
    auto listed = st.listAttrs();
    foreach (n; names) {
        bool found;
        foreach (row; listed) if (row[0] == n) { found = true; break; }
        assert(found, "symmetry listAttrs is missing writable attr '" ~ n ~ "'");
    }
    assert(listed.length == names.length + 1,
        "symmetry listAttrs must be fullParams/knownAttrs plus read-only baseSide");
    bool foundBaseSide;
    foreach (row; listed) if (row[0] == "baseSide") { foundBaseSide = true; break; }
    assert(foundBaseSide, "symmetry listAttrs lost its read-only baseSide row");

    string[string] sample = [
        "enabled": "true", "axis": "x", "offset": "0.5",
        "useWorkplane": "false", "topology": "true", "epsilon": "0.001",
    ];
    foreach (n; names) {
        assert((n in sample) !is null,
               "no sample value for symmetry attr '" ~ n ~ "' — extend the test");
        assert(st.setAttr(n, sample[n]),
               "symmetry knownAttrs name '" ~ n ~ "' rejected by setAttr");
    }

    // The panel filter is a strict subset of the universe, and hides the
    // status-bar-owned toggles.
    st.setAttr("enabled", "true");
    foreach (p; st.params()) {
        bool known = false;
        foreach (n; st.knownAttrs()) if (n == p.name) known = true;
        assert(known, "panel param '" ~ p.name ~ "' missing from knownAttrs");
        assert(p.name != "enabled" && p.name != "topology",
               "status-bar-owned toggles must not appear in the panel");
    }

    // task 0685 T1 — and the COMPLEMENT: the mirror must not be one-way.
    // Everything above proves `knownAttrs ⊆ accepted`; the defect 0678 P4
    // fixed was the other inclusion (a `case` with no declaration), which
    // every assertion above stays green through. `baseSide` is the deliberate
    // read-only exception and is absent from BOTH sides, so it needs no arm
    // here. See `assertRejectsUndeclaredAttrs`.
    assertRejectsUndeclaredAttrs(new SymmetryStage(), "symmetry");
}
