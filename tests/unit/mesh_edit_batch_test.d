// mesh_edit_batch_test — the mesh-edit seam (task 1903 Stage A,
// `doc/mesh_edit_seam_plan.md` §2, §3).
//
// The seam's claim is "closing a batch is the only thing that advances a
// version stamp for the edit". Every block below is a cell that can come out
// differently: each names the mutation that reddens it, and the message it
// reddens with, so a green here is a green over a check that has been seen to
// fail.
//
// WHAT THIS FILE CANNOT SEE, stated up front rather than discovered later.
// `changeBus.unbatchedGeometryCommits` is gated by `mesh.g_isDocumentMesh`,
// which reads UNINSTALLED as "not a document mesh" — the opposite default from
// delivery's, and deliberately so. A headless unit build wires no `Document`,
// so an assertion on that counter WITHOUT installing the predicate is green in
// both directions and is exactly the defect class CLAUDE.md opens with. The
// M-DM block below therefore installs the predicate against its own local mesh
// and carries a POSITIVE control; every other block leaves the counter alone.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT, so a mutation that
// should redden two blocks here only ever proves the first. Run M-C1, M-C2,
// M-B3 and M-L1 in isolation.
module tests.unit.mesh_edit_batch_test;

import mesh;
import mesh_edit_delta : MeshEditTracker, MeshEditScope, MeshEditDelta;
import change_bus      : changeBus;
import math            : Vec3;
import std.format      : format;

// ===========================================================================
// M-C1 / M-C2 — ONE STAMP PER BATCH, AND THE BATCH DOES STAMP.
//
// M-C1: delete `commitChange`'s `if (auto f = currentBatchFrame(&this)) { …
//       return; }` early-out  → "mutationVersion advanced N times inside one
//       batch; expected 1".
// M-C2: make `MeshEditBatch.close()` skip `commitStamps`                →
//       "mutationVersion did not advance across a batch that added 4 faces".
// ===========================================================================

unittest // one stamp per batch, and exactly one
{
    auto m = makeCube();
    m.syncSelection();

    const ulong mvBefore = m.mutationVersion;
    const ulong tvBefore = m.topologyVersion;

    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);
        const uint base = cast(uint)ed.vertices.length;
        ed.vertices ~= Vec3(2, 0, 0);
        ed.vertices ~= Vec3(2, 1, 0);
        ed.vertices ~= Vec3(3, 1, 0);
        ed.vertices ~= Vec3(3, 0, 0);
        ed.syncSelection();
        // Four appends, four `commitChange(Geometry)` calls inside `addFace`.
        ed.addFace([0u, base, base + 1]);
        ed.addFace([base, base + 1, base + 2]);
        ed.addFace([base + 1, base + 2, base + 3]);
        ed.addFace([base + 2, base + 3, base]);

        assert(m.mutationVersion == mvBefore,
            format("mutationVersion advanced %d times inside one batch; "
                 ~ "expected 0 until close()",
                   m.mutationVersion - mvBefore));

        cast(void)ed.close();
    }

    assert(m.mutationVersion == mvBefore + 1,
        format("mutationVersion did not advance across a batch that added 4 "
             ~ "faces (it moved by %d, expected exactly 1)",
               m.mutationVersion - mvBefore));
    assert(m.topologyVersion == tvBefore + 1,
        format("topologyVersion moved by %d across a Geometry batch; "
             ~ "expected exactly 1", m.topologyVersion - tvBefore));
}

unittest // a batch that commits NOTHING stamps nothing
{
    // The dual of the block above, and the reason `close()` stamps
    // `frame.accum` rather than `frame.declared`: `commands/mesh/delete.d` and
    // `remove.d` both open a batch declaring Geometry|Marks, discover
    // `affected == 0`, and return FALSE — the command funnel then records no
    // history entry. A close that stamped the DECLARED scope would advance the
    // version of a refused command, and — since `declared` never went through
    // `noteChange` — trip app.d's missed-publisher guard on the way.
    auto m = makeCube();
    m.syncSelection();
    const ulong mvBefore = m.mutationVersion;

    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
        cast(void)ed.close();
    }

    assert(m.mutationVersion == mvBefore,
        "a batch whose kernel committed nothing advanced mutationVersion — "
      ~ "close() must stamp what was accumulated, not what was declared");
}

// ===========================================================================
// M-EB — the OLD spelling stamps too (plan §3.1 B4).
//
// `commands/mesh/delete.d`, `remove.d`, `tools/edit/edge_extend.d` and
// `edge_extrude.d` hold ZERO `commitChange` of their own: their kernels commit
// INSIDE the batch. Under the seam those commits defer into the frame, so an
// `endEditBatch()` that only popped would silently stop `mesh.delete` bumping,
// deriving and delivering.
//
// Mutation: make `endEditBatch()` pop without stamping → this block reddens
// with "mutationVersion did not advance across endEditBatch". The suite-lane
// witness on the real command is in `tests/test_undo_tracker_delete.d`.
// ===========================================================================

unittest // endEditBatch() has close() semantics
{
    auto m = makeCube();
    m.syncSelection();
    const ulong mvBefore = m.mutationVersion;

    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
    assert(m.isRecordingEdits(), "beginEditBatch must install the recorder");

    const uint base = cast(uint)m.vertices.length;
    m.vertices ~= Vec3(2, 0, 0);
    m.vertices ~= Vec3(2, 1, 0);
    m.syncSelection();
    m.addFace([0u, base, base + 1]);

    assert(m.mutationVersion == mvBefore,
        "the kernel's commit inside beginEditBatch must defer to the close");

    auto d = m.endEditBatch();

    assert(!m.isRecordingEdits(), "endEditBatch must detach the recorder");
    assert(m.mutationVersion == mvBefore + 1,
        format("mutationVersion did not advance across endEditBatch "
             ~ "(it moved by %d, expected 1)", m.mutationVersion - mvBefore));
    assert(!d.isEmpty(),
        "the batch recorded an addFace; its delta must not be empty");
}

// ===========================================================================
// M-L1 — A THROW UNDER A BATCH LEAKS THE HANDLE, NOT THE STACK (plan §2.2c).
//
// `source/commands/mesh` holds 66 `enforce`/`throw new` sites. The destructor
// must NOT assert: it runs during unwinding, and an `Error` raised there
// replaces the exception the command funnel is already handling, so the caller
// gets a process exit instead of `status:error`. It must also POP, or every
// later `commitChange` on that mesh defers forever and the app silently stops
// publishing.
//
// Mutation, two forms:
//   * restore `~this() { debug assert(!open_, "batch leaked"); }` → in this
//     `-debug` unit lane the case dies with `AssertError` before reaching its
//     own assertions;
//   * drop the `popLeakedEditFrame` call → the third assertion reddens with
//     "mutationVersion did not advance after a leaked batch — the frame is
//     still on the stack".
// ===========================================================================

unittest // a throw between open and close pops the frame and ticks batchLeaks
{
    auto m = makeCube();
    m.syncSelection();

    const ulong leaksBefore = changeBus.batchLeaks;
    const size_t stackBefore = editBatchStackLength();

    bool caught = false;
    try {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);
        const uint base = cast(uint)ed.vertices.length;
        ed.vertices ~= Vec3(2, 0, 0);
        ed.vertices ~= Vec3(2, 1, 0);
        ed.syncSelection();
        ed.addFace([0u, base, base + 1]);
        throw new Exception("a kernel refused mid-edit");
    } catch (Exception) {
        caught = true;
    }

    assert(caught, "fixture: the Exception must reach the catch, not an Error "
                 ~ "raised by the destructor during unwinding");
    assert(editBatchStackLength() == stackBefore,
        format("the leaked batch left %d frame(s) on g_editBatchStack; "
             ~ "expected %d", editBatchStackLength(), stackBefore));
    assert(changeBus.batchLeaks == leaksBefore + 1,
        format("changeBus.batchLeaks moved by %d across a leaked batch; "
             ~ "expected 1", changeBus.batchLeaks - leaksBefore));

    // The load-bearing consequence: the mesh is publishable again.
    const ulong mvBefore = m.mutationVersion;
    m.commitChange(MeshEditScope.Marks);
    assert(m.mutationVersion == mvBefore + 1,
        "mutationVersion did not advance after a leaked batch — the frame is "
      ~ "still on the stack and every later commit on this mesh defers forever");
}

// ===========================================================================
// M-B3 — THE HIDE DERIVE IS THE ONE THING A BATCH MAY NOT DEFER.
//
// A PORT of task 1330's own REGIME-2 case (`source/mesh.d`, beside
// `anyHideBitSet`), with `beginHideDeriveBatch`/`endHideDeriveBatch` replaced
// by a `MeshEditBatch`. It already discriminates: the observer is
// `selectVertex`, which REFUSES a vertex whose derived Hide bit is set, so a
// kernel that appends geometry and then selects its output silently loses the
// selection if the derive was deferred.
//
// Mutation: delete the `&& !f.deferSafe` arm from `commitChange`'s in-batch
// branch → this block reddens with 1330's own message.
// ===========================================================================

unittest // with something hidden, a batch must derive INLINE
{
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

    {
        auto ed = MeshEditBatch.unrecorded(m, MeshEditScope.Geometry);
        ed.addFace([0u, base, base + 1]);   // v0 gains a VISIBLE face
        ed.selectVertex(0);                 // what a kernel does with its output
        cast(void)ed.close();
    }

    assert(!m.isVertexHidden(0),
           "v0 gained a visible face and must no longer be hidden");
    assert(m.isVertexSelected(0),
           "the select was refused — the derive was deferred while it had "
         ~ "writes to make (task 1330 BLOCKER 2)");
}

unittest // with NOTHING hidden, the batch defers the derive (the perf regime)
{
    // The other half of the same rule, and the reason `deferSafe` is a bit and
    // not a constant `false`: where the derive provably writes nothing, the
    // whole tail defers and one batch costs one derive instead of N.
    auto m = makeCube();
    m.syncSelection();

    g_hideDeriveRuns = 0;
    {
        auto ed = MeshEditBatch.unrecorded(m, MeshEditScope.Geometry);
        const uint base = cast(uint)ed.vertices.length;
        ed.vertices ~= Vec3(2, 0, 0);
        ed.vertices ~= Vec3(2, 1, 0);
        ed.vertices ~= Vec3(3, 1, 0);
        ed.syncSelection();
        ed.addFace([0u, base, base + 1]);
        ed.addFace([base, base + 1, base + 2]);
        assert(g_hideDeriveRuns == 0,
               "hide-derive ran INSIDE a clean batch — the deferral is gone");
        cast(void)ed.close();
    }
    assert(g_hideDeriveRuns == 1, "the batch close must derive exactly once");
}

// ===========================================================================
// THE NESTING REFUSAL (plan §2.3 rule 3).
//
// The three inner/outer pairings are not symmetric. A RECORDING batch opened
// inside an UNRECORDED one is refused, because the alternative is a corrupt
// undo record: the inner delta would be missing everything the outer batch did
// before it, and the caller's whole reason for recording is to install that
// delta as a history entry.
//
// Mutation: let the inner open install its recorder → `recording()` reads true
// and `batchUpgradeRefusals` stays 0, reddening both assertions below.
// ===========================================================================

unittest // recording inside unrecorded is refused, and counted
{
    auto m = makeCube();
    m.syncSelection();

    const ulong refusalsBefore = changeBus.batchUpgradeRefusals;
    const ulong nestedBefore   = changeBus.nestedBatchOpens;

    {
        auto outer = MeshEditBatch.unrecorded(m, MeshEditScope.Geometry);
        {
            auto inner = MeshEditBatch(m, MeshEditScope.Geometry);
            assert(!inner.recording(),
                "a recording batch was opened inside an unrecorded one and was "
              ~ "NOT refused — the outermost batch owns the recording decision");
            assert(inner.close().isEmpty(),
                "a refused inner batch must hand back an empty delta, never a "
              ~ "truncated op-log");
        }
        cast(void)outer.close();
    }

    assert(changeBus.batchUpgradeRefusals == refusalsBefore + 1,
        format("changeBus.batchUpgradeRefusals moved by %d; expected 1 — the "
             ~ "refusal has no witness in a release build without it",
               changeBus.batchUpgradeRefusals - refusalsBefore));
    assert(changeBus.nestedBatchOpens == nestedBefore + 1,
        format("changeBus.nestedBatchOpens moved by %d; expected 1",
               changeBus.nestedBatchOpens - nestedBefore));
}

unittest // unrecorded inside recording is ALLOWED, and the inner request is ignored
{
    auto m = makeCube();
    m.syncSelection();

    {
        auto outer = MeshEditBatch(m, MeshEditScope.Geometry);
        {
            auto inner = MeshEditBatch.unrecorded(m, MeshEditScope.Geometry);
            // READ THIS AS A QUERY ON THE MESH, NOT ON THE HANDLE.
            // `recording()` looks the frame up by `m_` and there is at most
            // ONE frame per mesh (a nested open increments its depth rather
            // than pushing a second), so `inner.recording()` reports whether
            // the MESH is being recorded. It is NOT a claim that this handle
            // installed a recorder — it did not, and asking for one is exactly
            // what the inner open ignored.
            assert(inner.recording(),
                "an unrecorded batch inside a recording one must NOT downgrade "
              ~ "the outer batch: those ops are part of the outer edit and "
              ~ "belong in its op-log");
            const uint base = cast(uint)inner.vertices.length;
            inner.vertices ~= Vec3(2, 0, 0);
            inner.vertices ~= Vec3(2, 1, 0);
            inner.syncSelection();
            inner.addFace([0u, base, base + 1]);
            cast(void)inner.close();
        }
        auto d = outer.close();
        assert(!d.isEmpty(),
            "the inner batch's addFace must appear in the OUTER batch's "
          ~ "op-log — the outermost batch owns the recording decision");
    }
}

// ===========================================================================
// M-DM — THE L2 COUNTER'S POSITIVE CONTROL (plan §3.2 L2).
//
// `unbatchedGeometryCommits` is gated by `mesh.g_isDocumentMesh`, and with the
// predicate UNINSTALLED it never ticks. So an `== 0` assertion on it in a
// build that wires no `Document` is green in both directions. This block is
// what makes the zeros elsewhere mean something: it installs the predicate
// against its OWN local mesh and shows the counter moving.
//
// Mutation: uninstall the predicate (delete the install line below) → the
// positive-control assertion reddens with "the document-mesh predicate is
// uninstalled: one deliberate unbatched commit read 0, expected 1 — every
// `== 0` row is vacuous".
// ===========================================================================

unittest // the L2 counter: silent without a predicate, exact with one
{
    auto m = makeCube();
    m.syncSelection();
    Mesh* subject = &m;

    auto savedPredicate = g_isDocumentMesh;
    scope(exit) g_isDocumentMesh = savedPredicate;

    // (a) UNINSTALLED ⇒ not a document mesh. This is the vacuity witness: it
    //     is what every `== 0` assertion on this counter looks like in a build
    //     with no Document.
    g_isDocumentMesh = null;
    changeBus.unbatchedGeometryCommits = 0;
    m.commitChange(MeshEditScope.Geometry);
    assert(changeBus.unbatchedGeometryCommits == 0,
        "with no predicate installed this counter must stay silent — "
      ~ "otherwise every factory temporary in the tree would swamp it");

    // (b) INSTALLED ⇒ one deliberate unbatched Geometry commit reads exactly 1.
    g_isDocumentMesh = (const(Mesh)* q) => q is subject;
    changeBus.unbatchedGeometryCommits = 0;
    m.commitChange(MeshEditScope.Geometry);
    assert(changeBus.unbatchedGeometryCommits == 1,
        format("the document-mesh predicate is uninstalled: one deliberate "
             ~ "unbatched commit read %d, expected 1 — every `== 0` row on "
             ~ "this counter is vacuous",
               changeBus.unbatchedGeometryCommits));

    // (c) A non-Geometry commit is not this counter's business.
    m.commitChange(MeshEditScope.Marks);
    assert(changeBus.unbatchedGeometryCommits == 1,
        "a Marks-only commit ticked the Geometry counter");

    // (d) INSIDE A BATCH ⇒ no tick. This is the whole point of the counter:
    //     as each family migrates behind a batch, its ops stop showing up.
    {
        auto ed = MeshEditBatch.unrecorded(m, MeshEditScope.Geometry);
        ed.commitChange(MeshEditScope.Geometry);
        cast(void)ed.close();
    }
    assert(changeBus.unbatchedGeometryCommits == 1,
        format("a commit INSIDE a batch ticked unbatchedGeometryCommits "
             ~ "(now %d, expected 1) — the counter is meant to see only the "
             ~ "sites that have not moved behind a batch yet",
               changeBus.unbatchedGeometryCommits));

    // (e) `commitRestored` is a legitimate door and must NOT tick it, or the
    //     counter has a baseline that moves on every reset and every undo.
    m.commitRestored(MeshEditScope.Geometry);
    assert(changeBus.unbatchedGeometryCommits == 1,
        format("commitRestored ticked unbatchedGeometryCommits (now %d, "
             ~ "expected 1) — a whole-state restoration is not a mutation "
             ~ "site this seam is closing", changeBus.unbatchedGeometryCommits));

    // …and it publishes exactly as `commitChange` does. A `commitRestored`
    // that forgot `commitStamps` would leave the counter above at 1 and this
    // at 0 — green on the counter the block is about, red only here.
    const ulong mvBefore = m.mutationVersion;
    m.commitRestored(MeshEditScope.Geometry);
    assert(m.mutationVersion == mvBefore + 1,
        "commitRestored did not advance mutationVersion — a restore must "
      ~ "publish exactly as commitChange does; only the counter differs");
}

// ===========================================================================
// M-SP — `setVertexPos` gives `Kind.SetPos` its first publisher (plan §2.5).
//
// A raw coordinate write is the one class of mutation the existing hooks do
// not see. `Kind.SetPos` has had a complete forward+reverse apply in
// `mesh_edit_delta.d` since it was written and ZERO callers, so a delta undo
// of a kernel that moves vertices restored the topology and left the
// coordinates at their post-op values.
//
// Mutation: delete the `recordSetPos` call inside `setVertexPos` → the
// round-trip reddens with "vertex 3 came back at the post-op position".
// ===========================================================================

unittest // setVertexPos round-trips through the op-log
{
    auto m = makeCube();
    m.syncSelection();

    const Vec3 orig = m.vertices[3];
    const Vec3 moved = Vec3(orig.x + 1.0f, orig.y + 2.0f, orig.z + 3.0f);

    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Position);
        ed.setVertexPos(3, moved);
        d = ed.close();
    }

    assert(m.vertices[3] == moved, "setVertexPos did not write the position");
    assert(!d.isEmpty(),
        "setVertexPos recorded nothing — Kind.SetPos still has no publisher");

    cast(void)d.revert(m);
    assert(m.vertices[3] == orig,
        format("vertex 3 came back at the post-op position (%s, %s, %s); "
             ~ "expected (%s, %s, %s)",
               m.vertices[3].x, m.vertices[3].y, m.vertices[3].z,
               orig.x, orig.y, orig.z));
}

unittest // setVertexPositions is the bulk form, and drops the no-op writes
{
    auto m = makeCube();
    m.syncSelection();

    const Vec3 v1 = m.vertices[1];
    const Vec3 v2 = m.vertices[2];
    const Vec3 m1 = Vec3(v1.x + 5.0f, v1.y, v1.z);

    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Position);
        // v2's "new" position is its old one: it must not reach the op-log, or
        // the entry's before/after arrays go out of step with its index array.
        ed.setVertexPositions([1u, 2u], [m1, v2]);
        d = ed.close();
    }

    assert(m.vertices[1] == m1 && m.vertices[2] == v2);
    assert(!d.isEmpty(), "setVertexPositions recorded nothing");

    cast(void)d.revert(m);
    assert(m.vertices[1] == v1,
        "vertex 1 came back at the post-op position");
    assert(m.vertices[2] == v2,
        "vertex 2 moved across a revert it was never recorded into");
}

// ===========================================================================
// The UNRECORDED batch (plan §9) — the interactive preview path.
// ===========================================================================

unittest // an unrecorded batch defers the stamps and records no op-log entry
{
    auto m = makeCube();
    m.syncSelection();

    const ulong mvBefore  = m.mutationVersion;
    const ulong opsBefore = changeBus.opLogEntriesRecorded;

    {
        auto ed = MeshEditBatch.unrecorded(m, MeshEditScope.Geometry);
        assert(!ed.recording(),
            "MeshEditBatch.unrecorded installed a recorder — a recording batch "
          ~ "opened per drag frame builds and throws away a full op-log at 60 Hz");
        const uint base = cast(uint)ed.vertices.length;
        ed.vertices ~= Vec3(2, 0, 0);
        ed.vertices ~= Vec3(2, 1, 0);
        ed.syncSelection();
        ed.addFace([0u, base, base + 1]);
        assert(m.mutationVersion == mvBefore,
            "an unrecorded batch must still defer the stamps");
        assert(ed.close().isEmpty(),
            "an unrecorded batch's close must return an empty delta");
    }

    assert(m.mutationVersion == mvBefore + 1,
        "an unrecorded batch must still stamp once at close");
    assert(changeBus.opLogEntriesRecorded == opsBefore,
        format("an unrecorded batch recorded %d op-log entries; the preview "
             ~ "path must be unrecorded",
               changeBus.opLogEntriesRecorded - opsBefore));
}

unittest // a wholesale `*mesh = …` mid-batch does not lose the frame
{
    // The design reason the frame stack is module-level and keyed by ADDRESS
    // (plan §2.2a item 1). `commands/mesh/remesh.d`, `subdivide_faceted.d`,
    // `commands/scene/reset.d` and the loaders all do `*mesh = <new mesh>`
    // inside their kernel. With the depth stored as a FIELD of `Mesh` that
    // assignment resets it, the close finds depth 0, skips `commitStamps`
    // entirely, and the edit never publishes.
    auto m = makeCube();
    m.syncSelection();

    ulong mvAfterReplace;
    {
        auto ed = MeshEditBatch.unrecorded(m, MeshEditScope.Geometry);
        m = makeCube();          // the wholesale replace, at the same address
        m.syncSelection();
        // The fresh value carries its own counters — read the baseline AFTER
        // the replace, or this measures makeCube's per-addFace bumps instead.
        mvAfterReplace = m.mutationVersion;
        ed.commitChange(MeshEditScope.Geometry);
        assert(m.mutationVersion == mvAfterReplace,
            "the commit after a wholesale replace did not defer — the frame "
          ~ "was lost, so this mesh is outside its own batch");
        cast(void)ed.close();
    }

    assert(editBatchStackLength() == 0,
        "the frame did not come off the stack after a wholesale replace");
    assert(m.mutationVersion == mvAfterReplace + 1,
        format("the batch stopped publishing across a wholesale `*mesh = …` "
             ~ "(mutationVersion moved by %d, expected 1)",
               m.mutationVersion - mvAfterReplace));
}

// ===========================================================================
// M-AB — A THROW UNDER THE HANDLE-LESS SPELLING (task 1903 S1).
//
// `MeshEditBatch` pops from `~this`. `Mesh.beginEditBatch`/`endEditBatch` — the
// four callers that predate the handle — have no destructor at all, so before
// S1 an `Exception` escaping between the two calls orphaned the frame FOREVER:
// every later `commitChange` on that mesh found it and deferred, so the app
// kept running and silently stopped bumping, deriving and delivering. Nothing
// showed it, either: `changeBus.batchLeaks` is the DESTRUCTOR's counter, so it
// stayed 0. And the frame's `rec` went on pointing at the caller's stack
// `MeshEditTracker`, dead as soon as the frame it lived in unwound.
//
// `Mesh.abortEditBatch()` is that pair's pop; the four sites spell
// `scope(failure) mesh.abortEditBatch();` right after their open. This block is
// that shape, run for real.
//
// Mutations, and each reddens a different assertion:
//   * empty out `abortEditBatch`'s body (or drop its `popLeakedEditFrame`) →
//     the stack-length and the "publishable again" assertions redden;
//   * remove the `scope(failure)` line from the local fixture → same two;
//   * remove it from one of the FOUR PRODUCTION sites → the roster block in
//     `tests/unit/commit_seam_census_test.d` reddens, naming the file. That
//     is the mutation this block cannot see, and why the census carries it.
// ===========================================================================

unittest // a throw between beginEditBatch and endEditBatch pops the frame
{
    auto m = makeCube();
    m.syncSelection();

    const ulong  leaksBefore = changeBus.batchLeaks;
    const size_t stackBefore = editBatchStackLength();

    // The production shape, verbatim: a STACK-allocated tracker (which is
    // exactly what makes the orphaned frame's `rec` dangle), the open, the
    // guard, then a kernel that refuses.
    static void legacySiteThatThrows(ref Mesh mm) {
        auto rec = MeshEditTracker();
        mm.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
        scope(failure) mm.abortEditBatch();
        const uint base = cast(uint)mm.vertices.length;
        mm.vertices ~= Vec3(2, 0, 0);
        mm.vertices ~= Vec3(2, 1, 0);
        mm.syncSelection();
        mm.addFace([0u, base, base + 1]);
        throw new Exception("a kernel refused mid-edit");
    }

    bool caught = false;
    try { legacySiteThatThrows(m); }
    catch (Exception) { caught = true; }

    assert(caught,
        "fixture: the Exception must reach the catch — abortEditBatch must "
      ~ "never assert, for the same reason the destructor must not");
    assert(editBatchStackLength() == stackBefore,
        format("the aborted batch left %d frame(s) on g_editBatchStack; "
             ~ "expected %d — an unguarded beginEditBatch orphans its frame "
             ~ "and every later commitChange on this mesh defers forever",
               editBatchStackLength(), stackBefore));
    assert(changeBus.batchLeaks == leaksBefore + 1,
        format("changeBus.batchLeaks moved by %d across an aborted batch; "
             ~ "expected 1 — the handle-less spelling needs its own tick or "
             ~ "the leak has no witness at all",
               changeBus.batchLeaks - leaksBefore));

    // The load-bearing consequence, same as the handle's leak case: the mesh
    // publishes again.
    const ulong mvBefore = m.mutationVersion;
    m.commitChange(MeshEditScope.Marks);
    assert(m.mutationVersion == mvBefore + 1,
        "mutationVersion did not advance after an aborted batch — the frame "
      ~ "is still on the stack and every later commit on this mesh defers "
      ~ "forever");
}

unittest // the guard stays armed past a CLEAN close, and must not invent a leak
{
    // Why `abortEditBatch` early-outs on "no frame", rather than popping and
    // ticking unconditionally. `scope(failure)` is armed for the REST of the
    // enclosing scope, i.e. past a successful `endEditBatch`; three of the
    // four production sites have throwing statements after their close
    // (`refreshCaches()`, `history.record(cmd)`). Without the early-out one of
    // those throws would tick `batchLeaks` for a batch that closed cleanly —
    // and the suite asserts that counter is 0.
    //
    // Mutation: delete the `if (currentBatchFrame(&this) is null) return;`
    // line → the leak assertion below reddens with 1 instead of 0.
    auto m = makeCube();
    m.syncSelection();

    const ulong leaksBefore = changeBus.batchLeaks;
    const ulong mvBefore    = m.mutationVersion;

    static void legacySiteThatThrowsAfterClosing(ref Mesh mm) {
        auto rec = MeshEditTracker();
        mm.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
        scope(failure) mm.abortEditBatch();
        const uint base = cast(uint)mm.vertices.length;
        mm.vertices ~= Vec3(2, 0, 0);
        mm.vertices ~= Vec3(2, 1, 0);
        mm.syncSelection();
        mm.addFace([0u, base, base + 1]);
        cast(void)mm.endEditBatch();          // a CLEAN close…
        throw new Exception("history.record refused");   // …and only then a throw
    }

    bool caught = false;
    try { legacySiteThatThrowsAfterClosing(m); }
    catch (Exception) { caught = true; }

    assert(caught, "fixture: the Exception must reach the catch");
    assert(editBatchStackLength() == 0,
        "the clean close left a frame behind");
    assert(changeBus.batchLeaks == leaksBefore,
        format("changeBus.batchLeaks moved by %d across a batch that closed "
             ~ "CLEANLY before the throw; expected 0 — scope(failure) stays "
             ~ "armed past the close, so abortEditBatch must no-op once its "
             ~ "frame is gone", changeBus.batchLeaks - leaksBefore));
    assert(m.mutationVersion == mvBefore + 1,
        format("the clean close did not stamp (mutationVersion moved by %d, "
             ~ "expected 1) — the abort ran over a frame it did not own",
               m.mutationVersion - mvBefore));
}

// ===========================================================================
// M-XF — `close(extraFlags)` PUBLISHES those flags, it does not merely stamp
// them (task 1903 S2).
//
// `extraFlags` was the ONE way into `commitStamps` that skipped `noteChange`.
// Every deferred `commitChange` in a batch went through it (that is where
// `pendingChanges_`, `undeliveredChanges_` and `marksVersion` are written);
// the closer's own flags did not. Three consequences, all asserted below:
// `deliverPending` shipped `undeliveredChanges_` WITHOUT them, so no listener
// heard the class the closer was declaring; `marksVersion` missed a
// marks-affecting flag; and with `accum == 0` the stamp bumped
// `mutationVersion` against `pendingChanges_ == 0`, which is exactly the shape
// app.d's per-frame shadow check latches as `changeBus.missedPublishers` — a
// counter the DoD requires to stay 0.
//
// Mutation: delete `if (extraFlags) m.noteChange(extraFlags);` from
// `closeEditFrame` → the pending-word assertion reddens first, then
// marksVersion, then the delivery. The `accum == 0` fixture is the
// discriminating one: with a non-empty batch the accumulated flags would cover
// for the missing note and every assertion here would pass on the broken code.
// ===========================================================================

unittest // close(extraFlags) routes them through noteChange
{
    auto m = makeCube();
    m.syncSelection();

    // Zero the frame-drain word: `makeCube` itself commits per face, so
    // without this the "did the extra flag arrive" test reads a bit that was
    // already set and cannot come out differently.
    m.pendingChanges_ = 0;

    const ulong mvBefore    = m.mutationVersion;
    const ulong marksBefore = m.marksVersion;
    const ulong dcBefore    = changeBus.deliveryCount;

    {
        // DELIBERATELY EMPTY: `accum` stays 0, so `extraFlags` is the only
        // thing the close has to stamp AND the only thing it has to publish.
        auto ed = MeshEditBatch.unrecorded(m, MeshEditScope.Geometry);
        cast(void)ed.close(MeshEditScope.Marks);
    }

    assert(m.mutationVersion == mvBefore + 1,
        format("close(extraFlags) did not stamp (mutationVersion moved by %d, "
             ~ "expected 1)", m.mutationVersion - mvBefore));
    assert((m.pendingChanges_ & MeshEditScope.Marks) != 0,
        format("close(extraFlags) advanced mutationVersion but left "
             ~ "pendingChanges_ at 0x%x — that is precisely the state app.d's "
             ~ "per-frame guard latches as changeBus.missedPublishers, which "
             ~ "the DoD requires to stay 0", m.pendingChanges_));
    assert(m.marksVersion == marksBefore + 1,
        format("marksVersion moved by %d across close(Marks); expected 1 — a "
             ~ "marks-affecting extra flag that skips noteChange never reaches "
             ~ "selectionSignature's consumers", m.marksVersion - marksBefore));
    assert(changeBus.deliveryCount == dcBefore + 1,
        format("close(extraFlags) delivered %d times; expected 1 — with "
             ~ "undeliveredChanges_ still 0, deliverPending returns before it "
             ~ "reaches the bus at all",
               changeBus.deliveryCount - dcBefore));
    assert((changeBus.lastDeliveryFlags & MeshEditScope.Marks) != 0,
        format("the delivery carried flags 0x%x, without the Marks the close "
             ~ "declared", changeBus.lastDeliveryFlags));
}

unittest // a NESTED close's extra flags are published too
{
    // The same rule on the other branch: `noteChange` sits ABOVE the depth
    // check, so an inner `close(extra)` — which only ORs into the outer
    // frame's `accum` — still puts its flags in the pending words. Without
    // that placement the inner declaration would reach the STAMP (through
    // `accum`) but never the delivery.
    auto m = makeCube();
    m.syncSelection();
    m.pendingChanges_ = 0;

    const ulong mvBefore = m.mutationVersion;

    {
        auto outer = MeshEditBatch.unrecorded(m, MeshEditScope.Geometry);
        {
            auto inner = MeshEditBatch.unrecorded(m, MeshEditScope.Geometry);
            cast(void)inner.close(MeshEditScope.Marks);
        }
        assert(m.mutationVersion == mvBefore,
            "a nested close stamped — only the outermost close may");
        cast(void)outer.close();
    }

    assert((m.pendingChanges_ & MeshEditScope.Marks) != 0,
        format("a nested close(Marks) left pendingChanges_ at 0x%x — its "
             ~ "flags reached the outer frame's accum but never noteChange",
               m.pendingChanges_));
    assert(m.mutationVersion == mvBefore + 1,
        "the outermost close must stamp the inner close's extra flags once");
}
