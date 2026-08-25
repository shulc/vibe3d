// Task 1906 stage 0b, mutation row `0-ANCHOR` — the delivery batch is opened
// for EVERY command, not only for the `Operator` ones.
//
// WHAT THIS FILE IS THE RED FOR, in both of its arms:
//
//   * make `Command.apply` non-`final` and let this file's double override
//     `apply()` instead of `applyImpl()` — i.e. the world before stage 0b,
//     where a command's kernel replaced the base method and reached no batch.
//   * keep the split but delete `beginDeliveryBatchGlobal()` from the
//     `final apply()` wrapper.
//   * put a `mesh is null` test back on that pair — the third block below.
//
// Under either of the first two, the two commits become TWO deliveries and both
// clauses redden. Nothing else in the tree can see it:
// `tests/unit/delivery_after_hide_derive_test.d` drives an `Operator`, which
// reached the batch through the `Operator` branch's `beginHideDeriveBatch`
// already and is green with or without the wrapper.
//
// WHY A TEST DOUBLE AND NOT A REAL COMMAND. The gap stage 0b closes is
// STRUCTURAL, not live: of the 148 commands in `source/` that implement their
// kernel as an `override`, none commits more than once per apply today, and that is
// incidental rather than guaranteed. A real command can therefore only witness
// "still exactly one delivery" (which `tests/test_bus_delivery_subject.d`'s
// `/api/reset` block does, over the real `SceneReset` — an override-`apply`
// command — and which stays green either way, because one commit is one
// delivery under both anchors). Only a command that LOOP-COMMITS separates
// "the wrapper coalesced them" from "there was no batch", and the honest way to
// have one is to write it here.
//
// THE DISCRIMINATOR IS THE FLAG UNION, NOT ONLY THE COUNT. The two commits
// carry DIFFERENT classes on purpose. With one delivery, `lastDeliveryFlags`
// carries both. With two, the first delivery zeroes the accumulator, so the
// last one names only `Polygons` and the `Position` clause reddens even if some
// future change made the count agree by accident.
module tests.unit.command_apply_anchor_test;

import command;
import operator : Operator;
import mesh;
import view;
import editmode;
import change_bus : changeBus, MeshEditScope;

// A NON-`Operator` command whose kernel is an `override applyImpl()` — the
// exact shape stage 0's anchor could not reach — committing twice.
private class LoopCommitProbe : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "test.loopCommit"; }
    override string label() const { return "Loop-commit probe"; }

    protected override bool applyImpl() {
        if (mesh is null) return false;
        mesh.commitChange(MeshEditScope.Position);
        mesh.commitChange(MeshEditScope.Polygons);
        return true;
    }
}

unittest {
    Mesh m = makeCube();
    m.syncSelection();
    m.commitChange(MeshEditScope.Marks);   // drain whatever the fixture left

    View v = new View(0, 0, 800, 600);
    auto cmd = new LoopCommitProbe(&m, v, EditMode.Polygons);

    // THE PRECONDITION THE WHOLE FILE RESTS ON. An `Operator` would reach a
    // delivery batch through the `Operator` branch's `beginHideDeriveBatch`
    // (task 1906 review S3) and would pass every clause below with the wrapper
    // deleted — the rig would measure the OTHER anchor and never know.
    assert((cast(Operator)cmd) is null,
        "the probe must NOT be an Operator: an Operator reaches a delivery "
      ~ "batch through Command.apply's Operator branch, so it cannot witness "
      ~ "the wrapper that covers the override-applyImpl commands");

    const before = changeBus.deliveryCount;
    assert(cmd.apply(), "the probe must actually run — a refusal would make "
                      ~ "every assertion below vacuous");

    assert(changeBus.deliveryCount == before + 1,
        "an override-applyImpl command that commits twice must deliver ONCE: "
      ~ "Command.apply is final and opens the delivery batch for every "
      ~ "command, not only for the Operator ones");

    assert((changeBus.lastDeliveryFlags & MeshEditScope.Position) != 0
        && (changeBus.lastDeliveryFlags & MeshEditScope.Polygons) != 0,
        "the one delivery carries the UNION of the command's commits — two "
      ~ "deliveries would have zeroed the accumulator at the first, leaving "
      ~ "the last naming only Polygons");
    assert(changeBus.lastDeliverySubject == cast(size_t)&m,
        "...and it names the mesh the command wrote");
}

// The negative control for the clause above: the SAME two commits with no
// command around them are TWO deliveries. Without this, a `deliverPending`
// that had stopped delivering at all would satisfy "exactly one" by being
// short by one, and the union clause would ride the leftover accumulator.
unittest {
    Mesh m = makeCube();
    m.syncSelection();
    m.commitChange(MeshEditScope.Marks);

    const before = changeBus.deliveryCount;
    m.commitChange(MeshEditScope.Position);
    m.commitChange(MeshEditScope.Polygons);
    assert(changeBus.deliveryCount == before + 2,
        "control: outside any command, two commits are two deliveries — so "
      ~ "the block above measures the batch and not a broken publisher");
    assert((changeBus.lastDeliveryFlags & MeshEditScope.Position) == 0,
        "control: the second delivery names only its own class, which is what "
      ~ "makes the union clause above discriminating");
}

// ---------------------------------------------------------------------------
// TASK 1906 review S1 — THE NULL-`mesh` ARM IS NOT DEAD.
//
// The wrapper's first cut guarded both batch calls with
// `if (deliveryBatchMesh !is null)`, reading the command's protected `mesh`.
// That looked free because "a command with no mesh cannot mutate one" — and it
// is false twice over:
//
//   * `Command.mesh` is null for a SHIPPED command. `tools/create/box.d ::
//     BoxLiveEditCommand` is constructed `super(null, …)` and does its work
//     through the `BoxTool` it holds. (Its behaviour does not change either
//     way — `restoreLiveEdit` writes only the tool's private `previewMesh`,
//     which `g_isDocumentMesh` rejects before delivery — so it cannot be the
//     witness, and this double is written to be the shape it proves is
//     reachable.)
//   * nothing ties the mesh a command WRITES to the one it was CONSTRUCTED
//     with. An `applyImpl()` that reaches a mesh through a tool, a Document
//     layer or an inner command commits on it whatever `this.mesh` holds.
//
// And the guard buys nothing: `mesh.g_deliveryDepth` is module state, and
// neither `beginDeliveryBatchGlobal` nor `endDeliveryBatchGlobal` reads a
// receiver. This block is the red for putting the test back.
private class NullMeshLoopCommitProbe : Command {
    private Mesh* target_;

    this(Mesh* target, ref View view, EditMode editMode) {
        target_ = target;
        super(null, view, editMode);      // the BoxLiveEditCommand shape
    }

    override string name()  const { return "test.nullMeshLoopCommit"; }
    override string label() const { return "Null-mesh loop-commit probe"; }

    protected override bool applyImpl() {
        if (target_ is null) return false;
        target_.commitChange(MeshEditScope.Position);
        target_.commitChange(MeshEditScope.Polygons);
        return true;
    }
}

unittest {
    Mesh m = makeCube();
    m.syncSelection();
    m.commitChange(MeshEditScope.Marks);   // drain whatever the fixture left

    View v = new View(0, 0, 800, 600);
    auto cmd = new NullMeshLoopCommitProbe(&m, v, EditMode.Polygons);

    // THE PRECONDITION, asserted rather than assumed. If the probe's own mesh
    // were non-null this block would be the first one again and would stay
    // green under the very mutation it exists to catch.
    assert(cmd.meshPtr() is null,
        "the probe's OWN mesh must be null — that is the arm under test; a "
      ~ "non-null one is the previous block, which passes with or without a "
      ~ "`mesh is null` guard on the wrapper's batch");
    assert((cast(Operator)cmd) is null,
        "the probe must NOT be an Operator: an Operator reaches a delivery "
      ~ "batch through Command.apply's Operator branch");

    const before = changeBus.deliveryCount;
    assert(cmd.apply(), "the probe must actually run — a refusal would make "
                      ~ "every assertion below vacuous");

    assert(changeBus.deliveryCount == before + 1,
        "a command whose own mesh is null still gets a delivery batch: it "
      ~ "commits twice on a mesh it reached some other way and that must be "
      ~ "ONE delivery. A `mesh is null` guard on Command.apply's batch makes "
      ~ "it two — and BoxLiveEditCommand is the shipped command with that "
      ~ "exact shape");

    assert((changeBus.lastDeliveryFlags & MeshEditScope.Position) != 0
        && (changeBus.lastDeliveryFlags & MeshEditScope.Polygons) != 0,
        "the one delivery carries the UNION of the command's commits — two "
      ~ "deliveries would have zeroed the accumulator at the first");
    assert(changeBus.lastDeliverySubject == cast(size_t)&m,
        "...and it names the mesh the command wrote, not the null one it holds");
}
