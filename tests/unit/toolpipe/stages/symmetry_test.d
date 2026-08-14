// Module unittests for `toolpipe.stages.symmetry`, moved verbatim out of source/toolpipe/stages/symmetry.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.toolpipe.stages.symmetry_test;

import std.format : format;
import math    : Vec3, dot;
import mesh    : Mesh;
import editmode : EditMode;
import toolpipe.stage    : Stage, TaskCode, ordSymm;
import toolpipe.packets  : SymmetryPacket;
import operator          : Operator, Task, VectorStack, PacketKind;
import popup_state       : setStatePath;
import symmetry          : rebuildPairing, rebuildPairingTopological;
import params            : Param, IntEnumEntry;
import toolpipe.stages.symmetry;

// ---------------------------------------------------------------------------
// Task 0401 — the pairing cache (`pairOf` / `onPlane` / `vertSign`) must not
// serve a stale pre-edit snapshot after a VERSION-SILENT position edit. An
// interactive gizmo Move/Rotate/Scale mutates vertex positions via
// `mesh.noteChange(Position)` WITHOUT ever bumping `mutationVersion` — both
// on drag AND on commit (see the warning above SubpatchPreview.deactivate()
// in mesh.d for why that is deliberate) — so evaluate()'s
// (addr, mutationVersion, plane, epsilon) key alone cannot see the edit.
// Drives `evaluate()` directly (no g_pipeCtx/pipeline needed — SymmetryStage
// only reads a WorkplanePacket off the stack when useWorkplane is set, which
// this test leaves off) and reproduces the version-silent path exactly, not
// the scripted `/api/transform` path (which DOES bump mutationVersion).
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import change_bus : MeshEditScope;
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

    // Version-silent edit — exactly what an interactive gizmo drag/commit
    // does: push the vertex across the mirror plane, note the Position
    // change class, never bump mutationVersion.
    cube.vertices[vi] = Vec3(cube.vertices[vi].x + 5.0f,
                              cube.vertices[vi].y, cube.vertices[vi].z);
    cube.noteChange(MeshEditScope.Position);
    assert(cube.mutationVersion == mutVerBefore,
        "test setup must stay version-silent to mirror the gizmo path");

    // OLD behaviour: evaluate()'s cache keys purely on mutationVersion
    // (unchanged), so vertSign stays stale at -1 even though the vertex is
    // now firmly on the +X side. Asserting this first proves the repro is
    // real.
    VectorStack vts2;
    assert(sym.evaluate(vts2));
    auto pkt2 = vts2.get!SymmetryPacket();
    assert(pkt2.vertSign[vi] == -1,
        "sanity: without invalidatePairingCache() the pairing cache must "
        ~ "reproduce the historical stale-after-position-edit bug");

    // NEW behaviour: app.d's bus flush calls invalidatePairingCache()
    // whenever meshChangedFlags carries Position this frame (task 0401) —
    // simulate that call directly.
    sym.invalidatePairingCache();
    VectorStack vts3;
    assert(sym.evaluate(vts3));
    auto pkt3 = vts3.get!SymmetryPacket();
    assert(pkt3.vertSign[vi] == +1,
        "task 0401: invalidatePairingCache() must force a rebuild against "
        ~ "the moved vertex");

    assert(cube.mutationVersion == mutVerBefore,
        "invalidatePairingCache()/evaluate() must never mutate the mesh's "
        ~ "mutationVersion (that counter's version-silence on a position "
        ~ "edit is the intentional contract this fix works around, not "
        ~ "papers over)");
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
