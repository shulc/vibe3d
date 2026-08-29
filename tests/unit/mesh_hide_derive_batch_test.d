// mesh_hide_derive_batch_test -- the hide-derive deferral: when a batch defers, when it must NOT, and what a dead frame costs.
//
// Tasks 1330 / 1333 / 1361 / 1903. The rows that carry the weight are the
// NEGATIVE ones -- deferral must not fire when the batch writes something,
// must not survive a flush, must not name a frame that has died, and must
// not make the clean case cost more than it did. A deferral that always
// fires is green on every positive row here.
//
// These blocks stood in the body of `struct Mesh` until task 3160 -- step 1
// of `doc/tasks/work/2910-mesh-struct-seams.md`, which took fifty `unittest`
// blocks out of a 16 782-line struct body. They are HERE rather than at
// module scope in `mesh.d` because they compile against `Mesh`'s PUBLIC API
// alone: the criterion `tests/unit/README.md` states and task 0706 set. The
// eighteen blocks that read a `private` name stayed behind under the same
// rule, at module scope in `mesh.d`. Bodies are byte-identical to what stood
// in the struct, dedented by four columns; the only edit is the member enum
// `Marks`, which is spelled `Mesh.Marks` outside the body.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT, so a mutation that
// should redden two blocks here only ever proves the first. Run them in
// isolation.
module tests.unit.mesh_hide_derive_batch_test;

import mesh;
import math : Vec3;
import mesh_edit_delta : MeshEditScope;
import tests.unit.mesh_by_value_gate;

// The seam's compile-time gate: nothing in this module may take a `Mesh` by
// VALUE. `tests/unit/mesh_by_value_gate.d` says why nothing behavioural
// catches that, and carries the gate's own positive control.
private void byValueGateAnchor() {}
mixin MeshByValueGate!(__traits(parent, byValueGateAnchor));

unittest { // task 1330 — deferral fires when, and ONLY when, it writes nothing
    // REGIME 1: nothing hidden. The derive would take its word-OR
    // early-out and write nothing, so the batch may skip it entirely.
    auto m = makeCube();
    m.syncSelection();

    g_hideDeriveRuns = 0;
    m.beginHideDeriveBatch();
    const uint base = cast(uint)m.vertices.length;
    m.vertices ~= Vec3(2, 0, 0);
    m.vertices ~= Vec3(2, 1, 0);
    m.vertices ~= Vec3(3, 1, 0);
    m.syncSelection();
    m.addFace([0, base, base + 1]);      // each append commits on its own
    m.addFace([base, base + 1, base + 2]);
    m.addEdge(base, base + 2);
    const size_t duringBatch = g_hideDeriveRuns;
    m.endHideDeriveBatch();

    // Without the deferral the fix is silently a no-op: the planes would
    // still be right and every command would still be quadratic. So the
    // COUNT is asserted, not only the result.
    assert(duringBatch == 0,
           "hide-derive ran INSIDE the batch — the deferral is gone");
    assert(g_hideDeriveRuns == 1,
           "the batch close must derive exactly once");

    // Settled: what the batch left behind is what a fresh derive computes.
    auto vBefore = m.vertexMarks.dup;
    auto eBefore = m.edgeMarks.dup;
    m.refreshHiddenDerived();
    assert(m.vertexMarks == vBefore, "vertex hide plane was stale after the batch");
    assert(m.edgeMarks   == eBefore, "edge hide plane was stale after the batch");
}

unittest { // task 1330 — a kernel that REPLACES the whole struct mid-batch
    // `mesh.subdivide` / `mesh.subdivide_faceted` / `mesh.remesh` do
    // `*mesh = <new mesh>` inside their kernel. With the batch counter
    // stored as a FIELD of Mesh that assignment reset it, and the close
    // then went unbalanced: an assert death in assert-live builds, and a
    // STICKY underflow under -release that left the optimization off
    // forever with no symptom. Both regressions are pinned here.
    auto m = makeCube();
    m.syncSelection();

    m.beginHideDeriveBatch();
    m = makeCube();              // the wholesale replace
    m.syncSelection();
    m.endHideDeriveBatch();      // must not assert, must not underflow

    // The counter must be usable again — this is the -release symptom the
    // assert could never catch, because there the assert is not compiled.
    g_hideDeriveRuns = 0;
    m.beginHideDeriveBatch();
    const uint base = cast(uint)m.vertices.length;
    m.vertices ~= Vec3(2, 0, 0);
    m.vertices ~= Vec3(2, 1, 0);
    m.syncSelection();
    m.addFace([0, base, base + 1]);
    assert(g_hideDeriveRuns == 0,
           "deferral is dead after a wholesale struct replace (sticky underflow)");
    m.endHideDeriveBatch();
    assert(g_hideDeriveRuns == 1, "the batch close must still derive once");
}

unittest { // task 1330 — with something hidden, the batch must NOT defer
    // REGIME 2, and the bug the first cut of this fix shipped: here the
    // derive DOES write, so skipping it is observable. The observer is
    // `selectVertex`, which refuses a vertex whose derived Hide bit is
    // set — so a kernel that appends geometry and then selects its output
    // silently loses the selection if the derive was deferred.
    auto m = makeCube();
    m.syncSelection();
    // Hide every face incident to vertex 0 ⇒ v0 derives hidden.
    foreach (fi, f; m.faces)
        foreach (vi; f)
            if (vi == 0) { m.setFaceHidden(fi, true); break; }
    assert(m.isVertexHidden(0), "fixture: v0 must derive hidden first");

    const uint base = cast(uint)m.vertices.length;
    m.vertices ~= Vec3(2, 0, 0);
    m.vertices ~= Vec3(2, 1, 0);
    m.syncSelection();

    m.beginHideDeriveBatch();
    m.addFace([0, base, base + 1]);   // v0 gains a VISIBLE face ⇒ un-hidden
    m.selectVertex(0);                // what a kernel does with its output
    m.endHideDeriveBatch();

    assert(!m.isVertexHidden(0),
           "v0 gained a visible face and must no longer be hidden");
    assert(m.isVertexSelected(0),
           "the select was refused — the derive was deferred while it had "
           ~ "writes to make (task 1330 BLOCKER 2)");
}

unittest { // task 1333 — the renumbering CONSEQUENCE: a stale SET Hide bit must not outlive rebuildEdges
    import std.algorithm : canFind;
    import std.conv : to;

    // The hazard `rebuildEdges` is famous for, and the one its single
    // commit exists to close: the function hands `edges` a NEW index
    // space and does NOT re-index `edgeMarks`. A stale CLEARED bit is
    // harmless — the next derive sets it. A stale SET bit is not: it now
    // sits on an index holding a VISIBLE edge, and `selectEdge` refuses a
    // Hide-marked index with a bare `return` — silently, and permanently,
    // because nothing ever retries a refused select. That is 1330
    // BLOCKER 2, and until this fixture existed nothing in the tree pinned
    // it: the count test above measures the collapse, not its consequence,
    // and the frozen HTTP oracle (tests/test_hide_bevel_selection_product.d)
    // is protected from the same mutation by `deferSafe` rather than by
    // this commit, so it stays green under it.
    //
    // Reproducing the consequence needs the REMOVAL to sit before the
    // HIDDEN face in the FACE ARRAY, not merely somewhere in the mesh. A
    // shrink only ever moves edge indices DOWN, so a stale SET index gets
    // re-occupied by a visible edge exactly when the hidden face's edges
    // sat ABOVE the removed face's. Dropping the LAST face — the shape the
    // count test uses — renumbers nothing at all.
    //
    //   6---0---1---2      f0 = [0,1,4,3]  visible, REMOVED below
    //   |f2 |f0 |f1 |      f1 = [1,2,5,4]  HIDDEN (v2/v5 are private to it)
    //   7---3---4---5      f2 = [6,0,3,7]  visible, the survivor
    //
    // Face-array order is f0, f1, f2, so the 10 edges come out
    //   0=(0,1) 1=(1,4) 2=(4,3) 3=(3,0) | 4=(1,2) 5=(2,5) 6=(5,4) | 7=(6,0) 8=(3,7) 9=(7,6)
    // and f1's three private edges — the hidden ones — are 4,5,6. Remove
    // f0 and f2's edges slide down onto exactly those indices.
    Mesh m;
    m.addVertex(Vec3( 0, 0, 0));   // 0
    m.addVertex(Vec3( 1, 0, 0));   // 1
    m.addVertex(Vec3( 2, 0, 0));   // 2
    m.addVertex(Vec3( 0, 0, 1));   // 3
    m.addVertex(Vec3( 1, 0, 1));   // 4
    m.addVertex(Vec3( 2, 0, 1));   // 5
    m.addVertex(Vec3(-1, 0, 0));   // 6
    m.addVertex(Vec3(-1, 0, 1));   // 7
    m.addFace([0u, 1u, 4u, 3u]);   // f0
    m.addFace([1u, 2u, 5u, 4u]);   // f1
    m.addFace([6u, 0u, 3u, 7u]);   // f2
    m.buildLoops();
    m.syncSelection();

    m.setFaceHidden(1, true);
    assert(m.isVertexHidden(2) && m.isVertexHidden(5),
           "fixture: hiding f1 must hide the two vertices private to it");

    size_t[] setBefore;
    foreach (ei; 0 .. m.edgeMarks.length)
        if (m.edgeMarks[ei] & Mesh.Marks.Hide) setBefore ~= ei;
    assert(setBefore.length == 3,
           "fixture: exactly f1's three private edges must carry a SET Hide "
           ~ "bit, got " ~ setBefore.length.to!string);

    // Remove f0 — the FIRST face — the way a face-removing kernel does it:
    // compact `faces` and `faceMarks` in lock-step, so the hidden face
    // keeps its Hide bit as it slides from index 1 to index 0. The dead
    // tail entry is zeroed because `anyHideBitSet()` scans the WHOLE marks
    // array, not just `0 .. faces.length`. `edgeMarks` is deliberately NOT
    // touched — that is the whole point, and it is also what every real
    // caller does (`rebuildEdges` "does NOT touch selection arrays; the
    // caller owns those").
    foreach (i; 0 .. m.faces.length - 1) {
        m.faces[i]     = m.faces[i + 1];
        m.faceMarks[i] = m.faceMarks[i + 1];
    }
    m.faces.length     = m.faces.length - 1;
    m.faceMarks[$ - 1] = 0;
    assert(m.isFaceHidden(0),
           "fixture: f1 must still be hidden after the compaction");

    m.rebuildEdges();

    // The probe: an edge of the still-VISIBLE f2 that the re-derive placed
    // on an index which carried a stale SET Hide bit. Looked up by its
    // endpoints rather than hardcoded, and its membership in `setBefore`
    // is ASSERTED — if the edge ordering ever moves, this fixture says so
    // instead of going quietly vacuous.
    const uint probe = m.edgeIndex(6, 0);
    assert(probe != ~0u, "fixture: edge (6,0) must exist after the re-derive");
    assert(setBefore.canFind(cast(size_t)probe),
           "fixture is not exercising the hazard: the visible survivor edge "
           ~ "landed on index " ~ probe.to!string ~ ", which carried no stale "
           ~ "SET Hide bit");

    assert(!m.isEdgeHidden(probe),
           "index " ~ probe.to!string ~ " kept the Hide bit of the edge that "
           ~ "USED to live there — rebuildEdges renumbered `edges` without "
           ~ "re-deriving, and `edgeMarks` is not re-indexed (task 1333)");
    m.selectEdge(cast(int)probe);
    assert(m.isEdgeSelected(probe),
           "selectEdge refused a VISIBLE edge: the stale SET Hide bit the "
           ~ "renumbering left on its index outlived rebuildEdges. Silent "
           ~ "and permanent — exactly the 1330 BLOCKER-2 symptom the single "
           ~ "commit inside rebuildEdges exists to prevent (task 1333)");

    // Control — same mesh, same gesture, an index that never carried the
    // bit. It must select whether or not the derive ran, so a red above
    // cannot be read as "selectEdge is simply broken here".
    const uint control = m.edgeIndex(7, 6);
    assert(control != ~0u && !setBefore.canFind(cast(size_t)control),
           "fixture: the control edge must sit on an index with no stale bit");
    m.selectEdge(cast(int)control);
    assert(m.isEdgeSelected(control),
           "control: a visible edge on a clean index must select regardless");
}

unittest { // task 1333 — removing the batch pair must not cost 1330's clean case
    // `rebuildEdges` no longer opens a hide-derive batch of its own. Inside
    // an OUTER batch with nothing hidden its single commit must still be
    // deferred to the batch close, i.e. derive zero times in the loop —
    // otherwise this task would have paid for the hidden case by giving
    // back the clean one.
    auto c = makeCube();
    c.syncSelection();

    // Everything measured inside the batch is STASHED and asserted after
    // the close. An assert that fires mid-batch skips
    // `endHideDeriveBatch`, which leaks `g_hideDeriveDepth` at 1 and — the
    // part that actually bites — leaves `g_hideDerivePendingMeshes`, a
    // GC-scanned module global, holding a `Mesh*` into this function's
    // unwound stack frame. Same shape the 1330 batch test above uses.
    c.beginHideDeriveBatch();
    g_hideDeriveRuns = 0;
    c.rebuildEdges();
    const size_t duringBatch = g_hideDeriveRuns;
    c.endHideDeriveBatch();

    assert(duringBatch == 0,
           "rebuildEdges must defer its one commit inside a clean batch");
    assert(g_hideDeriveRuns == 1, "the batch close must derive exactly once");
}

unittest { // task 1903 gate — the pending set may not name a DEAD FRAME
    // THE DEFECT, measured 2026-08-25 on the 1903 lane's first full gate.
    // `Command.applyImpl` opens a hide-derive batch on the document mesh;
    // `commands/mesh/subdivide.d` then runs
    // `Mesh sub = catmullClarkOsd(*mesh, …)` (and that kernel its own
    // `Mesh result;`). Those temporaries commit while the batch is open, so
    // `commitStamps`' path (a) appended a STACK address to
    // `g_hideDerivePendingMeshes`. The frame unwound at `*mesh = sub;` and
    // `endHideDeriveBatch` then derived it: SIGSEGV inside
    // `refreshHiddenDerived` at `hasFace[] = false` with `this` garbage,
    // on `test_subdivide_smooth` and `test_subdivide_undo_redo`. The defect
    // is LATENT ON MAIN — the same three stack addresses reach the set
    // there and the derive happens to survive reading them.
    //
    // THE FIXTURE MUST INSTALL `g_isDocumentMesh`, or it is green in BOTH
    // directions: uninstalled means "defer" (`hideDeriveDeferralAccepted`),
    // which is exactly what keeps every OTHER unit case in this file on its
    // measured derive counts. The resolver here recognises one heap
    // address and nothing else.
    auto owned = new Mesh;          // heap ⇒ a stable address, like a Layer's
    *owned = makeCube();
    owned.syncSelection();

    auto prevResolver = g_isDocumentMesh;
    scope(exit) g_isDocumentMesh = prevResolver;
    const(void)* ownedAddr = cast(const(void)*)owned;
    g_isDocumentMesh = (const(Mesh)* q) => cast(const(void)*)q is ownedAddr;

    // Stash-then-assert, for the reason the two tests above spell out: an
    // assert that fires mid-batch skips `endHideDeriveBatch`, leaks
    // `g_hideDeriveDepth` into every later test in this binary and — the
    // part that bites HERE — strands the very pointer this test is about.
    const(void)* tmpAddr;
    bool   sawOwned, sawTemp;
    size_t duringTemp, pendingLen;

    owned.beginHideDeriveBatch();
    {
        // A `Mesh` whose scope ENDS while the batch is still open — the
        // shape of `Mesh sub = …` in a command kernel. Built by direct
        // field writes, and with NO marks arrays, so (i) the only commit is
        // the explicit one below and the derive count means what it says,
        // and (ii) on the broken tree the close's derive of this dead frame
        // takes `refreshHiddenDerived`'s word-OR early-out and reports the
        // failure as an assert message instead of a second SIGSEGV.
        Mesh tmp;
        tmp.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0)];
        tmp.faces    = [[0u, 1u, 2u]];
        tmpAddr = cast(const(void)*)&tmp;

        g_hideDeriveRuns = 0;
        tmp.commitChange(MeshEditScope.Geometry);
        duringTemp = g_hideDeriveRuns;

        sawOwned   = hideDerivePendingSetContains(ownedAddr);
        sawTemp    = hideDerivePendingSetContains(tmpAddr);
        pendingLen = hideDerivePendingSetLength();
    }
    // `tmpAddr` now names a frame that is gone.
    g_hideDeriveRuns = 0;
    owned.endHideDeriveBatch();
    const size_t closeRuns = g_hideDeriveRuns;

    assert(sawOwned,
           "fixture: beginHideDeriveBatch must register the batch's OWN "
         ~ "mesh — over an empty set this test cannot tell a filtered "
         ~ "temporary from a set nothing ever reached");
    assert(!sawTemp,
           "a mesh no Layer owns was deferred into "
         ~ "g_hideDerivePendingMeshes — that array is drained at the batch "
         ~ "close, so it may only hold addresses that OUTLIVE the batch; a "
         ~ "kernel's `Mesh sub = …` unwinds first and the close derives a "
         ~ "dead frame (SIGSEGV in refreshHiddenDerived at "
         ~ "`hasFace[] = false`)");
    assert(pendingLen == 1,
           "the pending set grew past the batch's own mesh while a "
         ~ "temporary was committing — every extra entry is one more "
         ~ "address the close dereferences after its frame is gone");
    assert(duringTemp == 1,
           "the refused mesh did not derive INLINE — it must fall through "
         ~ "to path (b) and derive exactly as it would with no batch open, "
         ~ "not lose its derive altogether");
    assert(closeRuns == 1,
           "the close derived more than the batch's own mesh — a second "
         ~ "run here is the deferred temporary being derived after its "
         ~ "frame died");
}

unittest { // task 1361 — the collapse must not cost 1330's clean case either
    // `addFace` still opens no hide-derive batch of its own. Inside an
    // OUTER batch with nothing hidden its one remaining commit must still
    // be deferred to the batch close — i.e. derive zero times during the
    // append — so this task cannot have paid for the hidden case by giving
    // back the clean one.
    //
    // Stash-then-assert: an assert that fires mid-batch skips
    // `endHideDeriveBatch`, leaking `g_hideDeriveDepth` and stranding a
    // `Mesh*` into this unwound frame inside `g_hideDerivePendingMeshes`
    // (a GC-scanned module global). Same shape as the 1330/1333 batch
    // tests above.
    auto m = makeCube();
    m.syncSelection();
    const uint base = cast(uint)m.vertices.length;
    m.vertices ~= Vec3(2, 0, 0);
    m.vertices ~= Vec3(2, 1, 0);
    m.syncSelection();

    m.beginHideDeriveBatch();
    g_hideDeriveRuns = 0;
    m.addFace([0, base, base + 1]);
    const size_t duringBatch = g_hideDeriveRuns;
    m.endHideDeriveBatch();

    assert(duringBatch == 0,
           "addFace must defer its one commit inside a clean batch");
    assert(g_hideDeriveRuns == 1, "the batch close must derive exactly once");
}
