// Task 1906 stage 0, mutation row `0-ORDER` — the ONE thing nothing else in
// the tree can see: WHEN the synchronous delivery fires relative to the
// hide-derive flush.
//
// WHERE THAT ORDER LIVES (review S3 moved it). It used to be a declaration
// order in `Command.apply`: two `scope(exit)` closes, LIFO, delivery pair
// declared first so it closed last. That convention was invisible at the six
// OTHER `beginHideDeriveBatch` call sites in `source/mesh.d`, which opened no
// delivery batch at all. It is now one function's statement order —
// `Mesh.endHideDeriveBatch` runs `flushHideDerivePending()` and THEN
// `endDeliveryBatch()`, having opened that batch in `beginHideDeriveBatch` —
// so `g_hideDeriveDepth > 0` implies `g_deliveryDepth > 0` by construction.
//
// THE MUTATION THIS FILE IS THE RED FOR: in `Mesh.endHideDeriveBatch`, move
// `endDeliveryBatch()` ABOVE `flushHideDerivePending()`. Then:
//
//   * the delivery COUNT is identical — same number of deliveries, different
//     moment. Every counter check, `/api/changes` included, stays green.
//   * every production listener is two ORs that read no mesh state at all, so
//     no existing subscriber can tell the orders apart either.
//
// The only instrument that can is a listener that READS derived state at
// delivery time and records whether it was already current. That is what this
// file's listener does, and it is the sole legitimate reason to break §1.5's
// "a listener does not read the mesh" rule: it measures the ordering rather
// than depending on it (it still mutates nothing and publishes nothing, which
// is what the always-on contract assert enforces).
//
// THE RIG, and each piece of it is doing work:
//
//   * `makeGridPlane(1)` — ONE quad, four vertices, each with exactly one
//     incident face. `refreshHiddenDerived` marks a vertex hidden only when
//     ALL its incident faces are hidden, so on a CUBE (three faces per vertex)
//     hiding one face derives NOTHING and the probe would read the same
//     "nothing hidden" answer under both orders — green on the broken code.
//   * `setFaceHiddenFrom` — the RAW bulk Hide writer: it commits nothing and
//     derives nothing (unlike `setFaceHidden`, which calls
//     `refreshHiddenDerived` itself and would make the planes current before
//     the delivery under either order).
//   * a `Geometry` commit right after it, with the hide-derive batch's
//     deferral still ARMED (nothing was hidden when the batch opened, and only
//     `refreshHiddenDerived` disarms it). That takes path (a) of
//     `Mesh.commitChange` — the derive is DEFERRED to `endHideDeriveBatch`,
//     which is the only path where the two closes can disagree.
//   * an `Operator` command driven through the real `Command.apply`, not a
//     hand-rolled begin/end pair. The ordering itself now lives in `mesh.d`,
//     so a hand-rolled `beginHideDeriveBatch` would reach it — but driving the
//     command additionally proves `Command.apply` still opens the batch at all,
//     which is what makes the production path one delivery per command rather
//     than one per appended face. That second claim needs its OWN clause —
//     `g_deliveredInsideEvaluate` — because removing the anchor leaves the
//     ordering clause GREEN: with no batch open, `commitChange` takes path (b),
//     derives eagerly, and delivers after a current plane. Measured, not
//     reasoned: the anchor mutation passed this file until that clause existed.
//
// The `g_hideDeriveRuns == 1` assertion is the precondition check that the
// rig still exercises path (a). Without it, a future change that makes the
// derive eager would leave both orders producing a current plane and this test
// would pass over a rig that no longer discriminates.
module tests.unit.delivery_after_hide_derive_test;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import change_bus : changeBus, MeshEditScope;

// --- The probe listener's recording state ---------------------------------
// Module scope, and armed explicitly, because v1 has no unsubscribe: the
// registration is undone by restoring `changeBus.meshSubs`, and the arm flag
// makes the listener inert even if some future path leaves it attached.
private bool   g_armed;
private bool   g_sawDelivery;
private bool   g_vertexPlaneCurrentAtDelivery;
private size_t g_deliverySubject;
// Was the delivery already made when `evaluate` returned? In the batched world
// the answer is NO — the commit inside `evaluate` only accumulates and the
// batch close delivers. It is what separates "Command.apply opened a batch"
// from "it did not", which the derive-run count alone CANNOT see: with no
// batch open, `commitChange` takes path (b) and derives EAGERLY, so
// `g_hideDeriveRuns` is 1 either way and the plane is current either way.
private bool   g_deliveredInsideEvaluate;

private void probeListener(size_t subjectAddr, uint flags) nothrow {
    if (!g_armed) return;
    g_sawDelivery     = true;
    g_deliverySubject = subjectAddr;
    auto mp = cast(Mesh*)subjectAddr;
    if (mp is null) return;
    bool anyVertexHidden = false;
    foreach (w; mp.vertexMarks)
        if (w & Mesh.Marks.Hide) { anyVertexHidden = true; break; }
    g_vertexPlaneCurrentAtDelivery = anyVertexHidden;
}

// --- The command under the two batches ------------------------------------
// An `Operator`, so it reaches `Command.apply`'s batch gate — the branch whose
// declaration order this test exists to pin.
private class HideThenCommitGeometryProbe : Command, Operator {
    mixin OperatorActrCommon;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "test.hideThenCommitGeometry"; }
    override string label() const { return "Hide then commit Geometry"; }

    bool evaluate(ref VectorStack vts) {
        if (mesh is null || mesh.faces.length == 0) return false;
        auto hide = new bool[mesh.faces.length];
        hide[0] = true;
        mesh.setFaceHiddenFrom(hide);                 // raw: no commit, no derive
        mesh.commitChange(MeshEditScope.Polygons);    // Geometry ⇒ path (a)
        g_deliveredInsideEvaluate = g_sawDelivery;
        return true;
    }
}

unittest {
    Mesh m = makeGridPlane(1);
    m.syncSelection();
    assert(m.faces.length == 1 && m.vertices.length == 4,
        "fixture: one quad, four vertices — each vertex has exactly ONE "
      ~ "incident face, which is what makes a single face hide derive a "
      ~ "hidden VERTEX at all");

    bool anyHiddenBefore = false;
    foreach (w; m.vertexMarks) if (w & Mesh.Marks.Hide) anyHiddenBefore = true;
    assert(!anyHiddenBefore,
        "fixture: nothing hidden at the start — this is also what arms the "
      ~ "hide-derive deferral, i.e. what makes path (a) reachable");

    View v = new View(0, 0, 800, 600);
    auto cmd = new HideThenCommitGeometryProbe(&m, v, EditMode.Polygons);

    auto saved = changeBus.meshSubs;
    scope (exit) { changeBus.meshSubs = saved; g_armed = false; }
    // A delegate literal, not `&probeListener`: the channel is a delegate and
    // a module-level function has no context pointer to convert from.
    changeBus.onMeshChanged((size_t addr, uint f) { probeListener(addr, f); });

    g_armed                        = true;
    g_sawDelivery                  = false;
    g_vertexPlaneCurrentAtDelivery = false;
    g_deliveredInsideEvaluate      = false;
    g_deliverySubject              = 0;
    g_hideDeriveRuns               = 0;

    const bool applied = cmd.apply();
    assert(applied, "the probe command must actually run — a refusal would "
                  ~ "make every assertion below vacuous");

    // THE BATCH EXISTS AT ALL. Asserted before the ordering clause because a
    // command with no batch open delivers eagerly and correctly-ordered — it
    // would pass the clause below while producing one delivery per commit
    // instead of one per command, which is the whole point of the anchor in
    // `Command.apply`.
    assert(!g_deliveredInsideEvaluate,
        "the command delivered INSIDE evaluate: Command.apply opened no "
      ~ "delivery batch, so one command that appends 400 faces is 400 "
      ~ "deliveries. The batch is opened by beginHideDeriveBatch, whose call "
      ~ "in Command.apply's Operator branch is the anchor");

    assert(g_hideDeriveRuns == 1,
        "the rig must take path (a): exactly ONE derive, run by the batch "
      ~ "close. More than one means the commit derived eagerly and the two "
      ~ "batch closes can no longer disagree, so this test would no longer "
      ~ "discriminate");

    assert(g_sawDelivery,
        "the command must produce a synchronous delivery at its batch close");
    assert(g_deliverySubject == cast(size_t)&m,
        "the delivery names the mesh that changed");

    // THE CLAUSE.
    assert(g_vertexPlaneCurrentAtDelivery,
        "delivery fired BEFORE the hide-derive flush: the derived "
      ~ "hidden-vertex plane still described the mesh before the edit. "
      ~ "Mesh.endHideDeriveBatch must call flushHideDerivePending() and THEN "
      ~ "endDeliveryBatch(), never the other way round");

    // The negative half: after the apply the plane IS current, so the
    // assertion above is about ORDERING and not about the derive being broken
    // outright.
    bool anyHiddenAfter = false;
    foreach (w; m.vertexMarks) if (w & Mesh.Marks.Hide) anyHiddenAfter = true;
    assert(anyHiddenAfter,
        "control: the derive does run by the end of the apply — so a red "
      ~ "clause above means the delivery was EARLY, not that hiding is broken");
}
