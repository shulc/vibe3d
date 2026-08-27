// accept_recorded_edit_test — the witnesses for `acceptRecordedEdit` and for
// the fifth invariant counter it ticks (task 1903 stage L3-a, ruling Q-K6).
//
// WHY THIS FILE IS THE DISCRIMINATING PIECE OF THE STAGE, stated first,
// because it is the argument for it existing at all.
//
// The branch under test produces a mutated mesh with NO history entry and an
// `error` status. Every instrument the repo already has reads clean on it:
//
//   * a geometry compare cannot see it — the suite's assertion on an errored
//     command is that it errored;
//   * a frozen plane dump cannot see it — no undo runs;
//   * `/api/history`'s `opInverse` cannot see it — `isOperationInverse()`
//     answers `false` on that path, correctly and uselessly;
//   * `batchLeaks`, `nestedBatchOpens`, `batchUpgradeRefusals` and
//     `missedPublishers` are all ZERO on it, because the batch opened and
//     closed cleanly and the close stamped.
//
// So the counter is the first instrument that CAN see it, and this file is the
// only cell in the repository that reaches the branch: the arm's natural
// reachability on the delete / remove paths is nil, because every kernel there
// has an explicit publisher (`compactUnreferenced` →
// `recordRemoveVerts` + `recordReindex`; `deleteFacesByMask` →
// `recordPolyVertexPayload` + `recordRemoveFaces`; `dissolveVerticesByMask` →
// `recordReshapeFaces` + `recordPolyVertexPayload` + `recordRemoveFaces`;
// `removeEdgesByMask` → `recordRemoveFaces`). That is why the cells drive the
// SHIPPED function directly rather than trying to provoke it through a
// command: the alternative is a cell that cannot be built, and the branch then
// ships with no witness at all.
//
// THE COUNTER IS READ AS A DELTA ACROSS THE CALL, NEVER AS AN ABSOLUTE. It is
// process-cumulative and druntime runs every unittest module in ONE process,
// so an absolute assertion here would be a statement about whatever ran first.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — score the mutations
// below one at a time.
module tests.unit.accept_recorded_edit_test;

import std.format : format;

import change_bus     : changeBus;
import mesh_edit_delta : MeshEditDelta, MeshOpEntry, acceptRecordedEdit;

/// A delta with one entry in its log — the shape a healthy kernel produces.
/// The entry's KIND does not matter to `acceptRecordedEdit`, which reads only
/// `isEmpty`; what matters is that the log is non-empty, so this cell can tell
/// "refused because empty" from "refuses always".
private MeshEditDelta nonEmptyDelta()
{
    MeshEditDelta d;
    MeshOpEntry e;
    d.log ~= e;
    assert(!d.isEmpty, "the control delta is empty — this file's positive "
                     ~ "cell would then measure nothing");
    return d;
}

unittest // W-3-a1: a mutating kernel over an EMPTY delta refuses AND is counted
{
    // MUTATION: delete the `++changeBus.emptyDeltaOverMutation;` line in
    // `acceptRecordedEdit`, keeping the `return false`. The return stays green
    // — it always was, and that is precisely the point — and ONLY the counter
    // reddens. A cell that asserted the return alone would be satisfied by the
    // broken code, which is the defect class this whole task pays for.
    immutable before = changeBus.emptyDeltaOverMutation;

    MeshEditDelta empty;
    assert(empty.isEmpty, "MeshEditDelta.init is not empty — this cell is not "
                        ~ "on the branch it names");

    immutable accepted = acceptRecordedEdit(3, empty);

    assert(!accepted,
        "acceptRecordedEdit(3, <empty>) returned TRUE. Recording an empty "
      ~ "delta as an undo entry corrupts both directions: revert() runs its "
      ~ "map, marks and selection belts over a still-post-op mesh (the marks "
      ~ "belt's length assertion FIRES), and the redo arm re-runs the kernel "
      ~ "on the un-restored mesh");

    immutable delta = changeBus.emptyDeltaOverMutation - before;
    assert(delta == 1,
        format("changeBus.emptyDeltaOverMutation moved by %d across a "
             ~ "mutating-kernel-over-empty-delta call, expected exactly 1. "
             ~ "The command still refuses either way, so this counter is the "
             ~ "ONLY thing that separates a silent contradiction from a "
             ~ "reported one", delta));
}

unittest // W-3-a2: an HONEST refusal is not counted
{
    // MUTATION: fold the two arms of `acceptRecordedEdit` back into one
    // `if (affected == 0 || delta.isEmpty)` that ticks. W-3-a1 above stays
    // GREEN under that (both arms then tick), and only this cell reddens —
    // which is what keeps the counter answering the one question it is asked:
    // did the kernel do something that nobody recorded?
    immutable before = changeBus.emptyDeltaOverMutation;

    MeshEditDelta empty;
    immutable accepted = acceptRecordedEdit(0, empty);

    assert(!accepted,
        "acceptRecordedEdit(0, <empty>) returned TRUE — a kernel that "
      ~ "affected nothing must refuse, which is also what the snapshot arm "
      ~ "does for the same condition");

    immutable delta = changeBus.emptyDeltaOverMutation - before;
    assert(delta == 0,
        format("changeBus.emptyDeltaOverMutation moved by %d across an HONEST "
             ~ "refusal (affected == 0), expected 0. The number stops "
             ~ "separating `the kernel did nothing` from `the kernel did "
             ~ "something and nobody recorded it`, and every zero-assertion "
             ~ "on it elsewhere becomes unreadable", delta));
}

unittest // the positive control: the function CAN return true, and is silent
{
    // Without this the two cells above are satisfied by `return false;` with
    // a tick in it — a function that refuses everything. This is also the
    // shape the shipped commands actually take on every successful run.
    immutable before = changeBus.emptyDeltaOverMutation;

    auto d = nonEmptyDelta();
    assert(acceptRecordedEdit(3, d),
        "acceptRecordedEdit(3, <non-empty>) refused. Then `mesh.delete` and "
      ~ "`mesh.remove` record nothing on their SUCCESSFUL path either, and "
      ~ "the two refusal cells above are green over a function that always "
      ~ "says no");

    assert(changeBus.emptyDeltaOverMutation - before == 0,
        "the healthy path ticked emptyDeltaOverMutation — the counter is then "
      ~ "non-zero on every ordinary delete and its zero-assertions say "
      ~ "nothing");

    // `affected == 1` is the boundary between the two arms, and it belongs to
    // the accepting side. A `>` / `>=` slip in the first arm would leave a
    // single-element edit unrecorded.
    assert(acceptRecordedEdit(1, d),
        "acceptRecordedEdit(1, <non-empty>) refused — a one-element edit is a "
      ~ "real edit and the `affected == 0` arm must not swallow it");
}
