module commands.mesh.edge_crease;

import command;
import mesh;
import view;
import editmode;
import params : Param;
import mesh_edit_delta : MeshEditDelta, MeshEditScope;

// ---------------------------------------------------------------------------
// Edge-crease (subdivision semi-sharp crease) lifecycle commands — task 1062.
//
// Stores a scalar on the reserved MapKind.creaseWeight edge map
// (source/mesh.d: kCreaseWeightMapName == "crease"). 1.0 == the editor UI's
// 100%; the map value is fed through subpatch_osd.creaseSharpnessFromWeight
// at preview-build time (sharpness = 10 * weight, saturating at 1.0). Two
// commands cover the authoring lifecycle:
//   mesh.edgeCrease.set   {weight} — absolute write to every selected edge
//   mesh.edgeCrease.clear           — writes 0.0 to every selected edge
//
// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L5-d; the whole-mesh
// MeshSnapshot is gone. There is no fork to select between: this file never
// carried `undoTrackerEnabled()`, so the recording batch is unconditional,
// exactly as in commands/mesh/cleanup.d and (since Stage L3-b)
// commands/mesh/delete.d.
//
// THIS IS THE FIRST PRODUCTION EXECUTION OF `owesTopologyBump`'s creaseWeight
// ARM (plan W-K9). `Kind.MapValueDelta` itself is not new and not uncalled —
// it has had five production callers since Stage L1-b — but the arm that asks
// "does this map entry change a CREASE value, and therefore owe a
// topologyVersion bump on replay?" had no production caller until this file,
// and `mesh.setCreaseWeight` bumps `topologyVersion` on the forward for a
// stated reason (a missed crease rebuild presents as "the written weight does
// nothing", task 1062 §3). Without the bump on the way BACK, a crease undo
// leaves the subpatch preview on a stale layout key.
//
// THE OP-LOG IS `MapValueDelta` AND NOTHING ELSE, and that is a hard
// constraint rather than an observation: "a MapValueDelta may never share a
// log with an index-space-moving kind" (mesh_edit_delta.d, enforced twice —
// at the recorder funnel and in the replay loops). Neither command here moves
// an index space; both write ONE Edge-domain map through the post-hoc
// `MeshEditBatch.recordMapValueDiff` door, plus a `MapOp.Create` entry on the
// first write to a mesh that has no crease map yet. Absolute, not
// additive — the fixture's law.storage says the reference's set is
// absolute; an empty edge selection REFUSES (baseRefusal_ + return false)
// rather than silently applying to the whole mesh (a silent whole-mesh
// crease would be the worst possible mis-fire — see edge_weight_plan.md
// §5). Refusing via the house baseRefusal_/return-false mechanism (not a
// thrown Exception) matters here specifically because the button this
// dispatches from (config/buttons.yaml) reaches it through the UI's plain
// runCommand path, which passes throwMsg = null — an uncaught throw there
// unwinds past the args dialog's own popup-close call and leaves the ImGui
// popup stack one deep. The HTTP /api/command path still reports a non-ok
// status: the SCRIPT-origin dispatch adapter raises its OWN Exception off
// refusalReason() (source/http_providers.d, task 1520 — the UI-origin adapter
// raises a notice from the same refusal instead).
// ---------------------------------------------------------------------------

private uint[] selectedEdgeIndices(ref const Mesh mesh) {
    uint[] result;
    foreach (ei; 0 .. mesh.edges.length)
        if (mesh.isEdgeSelected(ei)) result ~= cast(uint) ei;
    return result;
}

class EdgeCreaseSet : Command {
    private float         weight_ = 0.0f;
    private MeshEditDelta delta_;
    private bool          recorded_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.edgeCrease.set"; }
    override string label() const { return "Set Edge Crease"; }

    override Param[] params() {
        return [ Param.float_("weight", "Weight", &weight_, 0.0f) ];
    }

    protected override bool applyImpl() {
        baseRefusal_ = "";
        auto sel = selectedEdgeIndices(*mesh);
        if (sel.length == 0) {
            baseRefusal_ = "no edges selected";
            return false;
        }
        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the write
        // BATCHLESS and keep the FIRST delta rather than record a second one
        // over it.
        if (recorded_) return runCreaseWrites(mesh, sel, weight_, null);

        delta_ = MeshEditDelta.init;
        immutable ok = runCreaseWrites(mesh, sel, weight_, &delta_);
        if (!ok) { baseRefusal_ = "failed to write edge weight"; return false; }
        recorded_ = true;
        return true;
    }

    override bool revert() {
        if (!recorded_) return false;
        return delta_.revert(*mesh);
    }

    /// Read-only diagnostic for the cells below — `MeshEditDelta.log` is a
    /// public field, so a cell reads the op-log SHAPE through this without
    /// widening any mutator. Same shape `commands/mesh/flip.d` uses.
    version (unittest)
    public ref const(MeshEditDelta) recordedDelta() const return { return delta_; }
}

/// The write half both classes share, in the shape stage L1-b settled for a
/// post-hoc map edit.
///
/// THE BATCH ALSO CARRIES THE AXIS-0 COMMIT SEAM (plan §5.0, stage L5-P0):
/// every `setCreaseWeight` publishes `Material` on its own, so inside the
/// frame the N writes defer to ONE stamp at `close()` instead of N ticks of
/// `changeBus.unbatchedGeometryCommits`. Per ROUND, never per element. The
/// empty-selection refusal stays PRE-FLIGHT at each caller — resolved BEFORE
/// this function is entered — because a refusal from inside the frame either
/// leaks it (`changeBus.batchLeaks`, asserted 0 by the suite) or has to close
/// one it never needed. Three commands shipped that bug (task 2110).
///
/// `outDelta is null` ⇒ the REDO arm: an unrecorded batch, so every tracker
/// hook takes its `editRecorder_ is null` early-out and no second delta is
/// built on top of the first.
///
/// THE GIGO ARM IS §6.5 ITEM 1's, VERBATIM, and it is what replaced the old
/// mid-loop `snap.restore`. `setCreaseWeight` can fail after earlier edges in
/// `sel` have already written, so a partial mutation must be rolled back —
/// through `delta.revert`, then discard, then `return false`. Never "close the
/// batch and record an empty delta", and never a `false` from the command's
/// own `revert()`: that pops the entry off BOTH history stacks and truncates
/// the suffix after it (`command_history.d`, regression 0099).
private bool runCreaseWrites(Mesh* mesh, in uint[] sel, float w,
                             MeshEditDelta* outDelta)
{
    MeshEditDelta d;
    bool ok = true;
    {
        auto ed = outDelta is null
                ? MeshEditBatch.unrecorded(*mesh, MeshEditScope.Material)
                : MeshEditBatch(*mesh, MeshEditScope.Material);
        const bool rec = ed.recording();

        // The map has to EXIST before its pre-image can be taken, and its
        // creation has to be RECORDED or the undo leaves an empty crease map
        // registered where the snapshot arm removed it — a `meshMaps` plane
        // the frozen L5 oracle compares. `setCreaseWeight` creates it lazily
        // on the first write, which is one call too late for `pre`.
        auto mm = ed.mesh.creaseWeightMap();
        if (mm is null) {
            mm = ed.mesh.addMeshMapOfKind(MapKind.creaseWeight);
            if (mm !is null && rec)
                ed.rec.recordMapCreate(kCreaseWeightMapName,
                                       mm.dim, mm.domain, mm.kind);
        }
        if (mm is null) ok = false;

        float[] pre;
        if (mm !is null && rec) pre = mm.data.dup;   // one block dup, recording arm

        if (mm !is null)
            foreach (ei; sel)
                if (!ed.setCreaseWeight(ei, w)) { ok = false; break; }

        // THE POST-HOC DOOR. `setCreaseWeight` has already written; asking the
        // setters to re-announce those values would record nothing useful and
        // re-publish `Material` per element, so the diff against `pre` IS the
        // record. It records NOTHING when no element moved bitwise — writing
        // the weight a map already carries is a real, reachable no-op — which
        // is why each `revert()` above returns `delta_.revert`'s own answer
        // (true on an empty log) rather than `false`.
        //
        // RECORDED ON THE FAILURE PATH TOO, and that is not symmetry for its
        // own sake: the writes have ALREADY LANDED by the time an edge fails,
        // and the delta is now the only thing that can put them back. The
        // snapshot this replaced held the whole pre-op mesh and could roll a
        // half-loop back without recording it; a post-hoc diff cannot. Skip
        // this call on the failure arm and the earlier edges' writes stand
        // permanently, with `apply()` answering false and no history entry to
        // blame — which is exactly the defect the mid-loop `snap.restore` was
        // added for (and the round-trip cell below pins by value).
        if (mm !is null && rec)
            ed.recordMapValueDiff(kCreaseWeightMapName, pre, null,
                                  MeshEditScope.Material);
        d = ed.close();
    }
    if (!ok) {
        // Roll the partial write back OUTSIDE the frame, then discard.
        d.revert(*mesh);
        // …and heal the map LENGTHS, which the delta cannot: an entry restores
        // VALUES at indices, and the only way to reach this arm is a map whose
        // `data` is out of step with its domain (`setCreaseWeight` refuses on
        // `ei >= data.length` and on nothing else). `MeshSnapshot.restore` did
        // this via `resizeAllMeshMaps` for the same reason — the invariant
        // that matters is "every map matches `edges.length`", not the raw
        // length the snapshot happened to hold.
        mesh.resizeAllMeshMaps();
        return false;
    }
    if (outDelta !is null) *outDelta = d;
    return true;
}

version (unittest) {
    private View freshView() { return new View(0, 0, 1, 1); }
}

// Empty selection REFUSES (baseRefusal_ + return false) rather than
// silently applying to the whole mesh (§ module doc) — and rather than
// throwing out of the UI dispatch frame, which is what this test pinned
// before the SHOULD-FIX 1 rewrite (task 1062 review). Mutation: drop the
// `sel.length == 0` guard on either command → apply() succeeds against zero
// edges and both assertions below redden (the return value AND the reason).
unittest {
    auto m = new Mesh;
    *m = makeCube();
    View v = freshView();

    auto setCmd = new EdgeCreaseSet(m, v, EditMode.Edges);
    assert(!setCmd.apply(),
        "mesh.edgeCrease.set must refuse (not throw) on an empty edge selection");
    assert(setCmd.refusalReason().length > 0,
        "a refusal without a reason renders as a SILENT no-op "
      ~ "(ui/command_notice.d) — the empty-selection case must say why");

    auto clearCmd = new EdgeCreaseClear(m, v, EditMode.Edges);
    assert(!clearCmd.apply(),
        "mesh.edgeCrease.clear must refuse (not throw) on an empty edge selection");
    assert(clearCmd.refusalReason().length > 0);
}

// Absolute set + undo round-trip: apply() writes to every selected edge
// (not just the first), revert() restores the PRIOR map exactly (including
// "the map did not exist before this call" — a snapshot taken before the
// map was ever created must restore to "no map").
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.buildLoops();
    m.syncSelection();
    // Two of the cube's 12 edges, by cage-vert pair (matches makeCube()'s
    // own vertex numbering — see mesh.d's makeCube doc).
    immutable uint e67 = m.edgeIndex(6, 7);
    immutable uint e23 = m.edgeIndex(2, 3);
    assert(e67 != ~0u && e23 != ~0u);
    m.selectEdge(cast(int) e67);
    m.selectEdge(cast(int) e23);

    View v = freshView();
    auto c = new EdgeCreaseSet(m, v, EditMode.Edges);
    c.weight_ = 0.3f;
    assert(c.apply());
    assert(m.creaseWeightMap() !is null,
        "apply() must create the reserved crease map on first use");
    assert(m.edgeCreaseWeight(e67) == 0.3f, "weight not written to edge 67");
    assert(m.edgeCreaseWeight(e23) == 0.3f, "weight not written to edge 23"
        ~ " — apply() must write EVERY selected edge, not just the first");
    // Unselected edges are untouched (stay at the zero-fill default).
    immutable uint eOther = m.edgeIndex(0, 1);
    assert(m.edgeCreaseWeight(eOther) == 0.0f);

    assert(c.revert());
    assert(m.creaseWeightMap() is null,
        "revert() must restore 'no crease map ever existed' — the snapshot "
      ~ "was captured before EdgeCreaseSet created the map");
}

// mesh.edgeCrease.clear writes 0.0 (a real stored value that behaves as no
// crease) rather than removing the map entirely — the map registration
// itself is undo-visible state, not something clear() should discard.
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.buildLoops();
    m.syncSelection();
    immutable uint e67 = m.edgeIndex(6, 7);
    m.selectEdge(cast(int) e67);

    View v = freshView();
    auto setCmd = new EdgeCreaseSet(m, v, EditMode.Edges);
    setCmd.weight_ = 0.8f;
    assert(setCmd.apply());
    assert(m.edgeCreaseWeight(e67) == 0.8f);

    m.clearEdgeSelection();
    m.selectEdge(cast(int) e67);
    auto clearCmd = new EdgeCreaseClear(m, v, EditMode.Edges);
    assert(clearCmd.apply());
    assert(m.creaseWeightMap() !is null,
        "clear() must NOT remove the reserved map, only zero the value");
    assert(m.edgeCreaseWeight(e67) == 0.0f);
}

// Partial-mutation safety: when a LATER edge in the selection fails to
// write, apply() must restore the mesh from the pre-apply snapshot before
// returning — not just discard the snapshot and leave the EARLIER edges'
// already-landed writes standing with no way back (SHOULD-FIX 2, task 1062
// review). `setCreaseWeight` only fails on an out-of-bounds map index, which
// cannot happen through normal use (the resize hook keeps the map's length
// in lock-step with `edges.length`) — so this test corrupts the map's
// length directly to force a deterministic mid-loop failure on the SECOND
// selected edge. Mutation: delete the `snap.restore(*mesh)` call ahead of
// `snap = MeshSnapshot.init` → e23's write stays at 0.3 after the failed
// apply() instead of reverting to 0.0, and this reddens on the
// `edgeCreaseWeight(e23)` assertion below (verified 2026-08-17).
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.buildLoops();
    m.syncSelection();
    immutable uint e67 = m.edgeIndex(6, 7);   // ascending edge index 6
    immutable uint e23 = m.edgeIndex(2, 3);   // ascending edge index 1
    assert(e67 != ~0u && e23 != ~0u);
    assert(e23 < e67,
        "fixture assumption: e23 is processed before e67 by "
      ~ "selectedEdgeIndices' ascending scan");
    m.selectEdge(cast(int) e67);
    m.selectEdge(cast(int) e23);

    // Pre-create the crease map, then truncate its data array so the FIRST
    // selected edge (e23) is still in bounds but the SECOND (e67) is not.
    auto map = m.addMeshMapOfKind(MapKind.creaseWeight);
    assert(map !is null);
    map.data.length = e67;   // in range for e23 (< e67), out of range for e67

    View v = freshView();
    auto c = new EdgeCreaseSet(m, v, EditMode.Edges);
    c.weight_ = 0.3f;
    assert(!c.apply(),
        "apply() must refuse when a selected edge's write fails mid-loop");
    assert(c.refusalReason().length > 0);

    // The mesh must be back to a sound PRE-apply state — not left with
    // e23's write standing and the snapshot thrown away. (The map's length
    // comes back at `edges.length`, not the corrupted length used to force
    // the failure: `MeshSnapshot.restore` heals map lengths via
    // `resizeAllMeshMaps` rather than trusting the snapshot's raw length —
    // the invariant that matters is "every map matches `edges.length`",
    // which the corrupted setup above deliberately violated.)
    assert(m.creaseWeightMap().data.length == m.edges.length,
        "a restored map must match edges.length, healed by resizeAllMeshMaps");
    assert(m.edgeCreaseWeight(e23) == 0.0f,
        "e23's write (which succeeded before e67 failed) must be rolled "
      ~ "back by restoring the snapshot, not left standing with the "
      ~ "snapshot discarded and no way to undo it");
}

class EdgeCreaseClear : Command {
    private MeshEditDelta delta_;
    private bool          recorded_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.edgeCrease.clear"; }
    override string label() const { return "Clear Edge Crease"; }

    override Param[] params() { return []; }

    protected override bool applyImpl() {
        baseRefusal_ = "";
        auto sel = selectedEdgeIndices(*mesh);
        if (sel.length == 0) {
            baseRefusal_ = "no edges selected";
            return false;
        }
        // 0.0 is a real stored value that behaves as no crease (fixture
        // law.storage) — this is NOT the same code path as removeMeshMap; the
        // reserved map stays registered. Same write half as `EdgeCreaseSet`,
        // with the weight pinned; see `runCreaseWrites` for the GIGO arm and
        // for the redo arm.
        if (recorded_) return runCreaseWrites(mesh, sel, 0.0f, null);

        delta_ = MeshEditDelta.init;
        immutable ok = runCreaseWrites(mesh, sel, 0.0f, &delta_);
        if (!ok) { baseRefusal_ = "failed to clear edge weight"; return false; }
        recorded_ = true;
        return true;
    }

    override bool revert() {
        if (!recorded_) return false;
        return delta_.revert(*mesh);
    }

    version (unittest)
    public ref const(MeshEditDelta) recordedDelta() const return { return delta_; }
}

// ---------------------------------------------------------------------------
// TASK 1903 STAGE L5-d — the op-log SHAPE, and `owesTopologyBump`'s crease arm
// driven by a PRODUCTION caller for the first time.
//
// W-K9 pinned that arm on HAND-BUILT entries (`tests/unit/map_value_delta_test.d`),
// which proves the dispatch and says nothing about whether any command ever
// produces the shape it dispatches on. These two cells close that: the entries
// below come out of `mesh.edgeCrease.set` / `.clear` themselves.
//
// MUTATION 1: delete the `creaseWeight` arm of `owesTopologyBump`
// (`mesh_edit_delta.d`) -> the `topologyVersion` assert reddens naming +0
// where +1 is owed, and a crease undo leaves the subpatch preview on a stale
// layout key. The ROW THAT MUST STAY GREEN UNDER IT is the third one here —
// a write of the value the map already carries records nothing and must bump
// NOTHING — without which the cell is satisfied by "everything bumps".
//
// MUTATION 2: drop the `ed.rec.recordMapCreate(...)` call in
// `runCreaseWrites` -> the FIRST cell's `MapOp` sequence assert reddens, and
// (separately) the frozen L5 parity fixture reddens on `meshMaps`, because the
// undo then leaves an empty crease map registered on a mesh that had none.
// ---------------------------------------------------------------------------
version (unittest) private Mesh creaseCell_(out uint eA, out uint eB) {
    Mesh m = makeCube();
    m.buildLoops();
    m.syncSelection();
    eA = m.edgeIndex(6, 7);
    eB = m.edgeIndex(2, 3);
    assert(eA != ~0u && eB != ~0u, "the cube stand lost an edge");
    m.selectEdge(cast(int) eA);
    m.selectEdge(cast(int) eB);
    return m;
}

unittest { // set: [Create, Values], and the crease arm bumps topologyVersion
    import std.conv : to;
    import mesh_edit_delta : MeshOpEntry;

    uint eA, eB;
    auto m = new Mesh;
    *m = creaseCell_(eA, eB);
    assert(m.creaseWeightMap() is null,
        "the cube stand already carries a crease map — the Create half of the "
      ~ "op-log below would then be absent and this cell would be measuring "
      ~ "the OTHER shape");

    View v = freshView();
    auto c = new EdgeCreaseSet(m, v, EditMode.Edges);
    c.weight_ = 0.4f;
    assert(c.apply(), "mesh.edgeCrease.set must apply on two selected edges");

    // ---- the KIND set, asserted NEGATIVELY as well as positively. The hard
    // constraint is "a MapValueDelta may never share a log with an
    // index-space-moving kind" (mesh_edit_delta.d, enforced at the recorder
    // AND in the replay loops); this command moves no index space, so the log
    // must be MapValueDelta and nothing else. Asserted as a SEQUENCE of
    // `mapOp`s and not as a count, so an interposed entry is visible.
    string kinds, ops;
    foreach (i, ref e; c.recordedDelta().log) {
        if (i) { kinds ~= ", "; ops ~= ", "; }
        kinds ~= e.kind.to!string;
        ops   ~= e.mapOp.to!string;
    }
    assert(kinds == "MapValueDelta, MapValueDelta",
        "mesh.edgeCrease.set's op-log kinds are [" ~ kinds ~ "], expected "
      ~ "[MapValueDelta, MapValueDelta]. Any other kind here is an "
      ~ "index-space-moving entry sharing a log with a map value, which the "
      ~ "replay REFUSES wholesale — the map edit is then silently dropped");
    assert(ops == "Create, Values",
        "mesh.edgeCrease.set's op-log MapOps are [" ~ ops ~ "], expected "
      ~ "[Create, Values]. Without the Create the undo leaves an empty crease "
      ~ "map registered on a mesh that had none — a `meshMaps` plane the "
      ~ "frozen L5 parity fixture compares");

    assert(m.edgeCreaseWeight(eA) == 0.4f && m.edgeCreaseWeight(eB) == 0.4f,
        "both selected edges must carry the written weight — a cell where only "
      ~ "one did would be green under a loop that stops at the first edge");

    // ---- the crease arm: +1 across the REVERT.
    immutable ulong tvBefore = m.topologyVersion;
    assert(c.revert(), "the undo must succeed");
    assert(m.topologyVersion == tvBefore + 1,
        "topologyVersion moved by " ~ (m.topologyVersion - tvBefore).to!string
      ~ " across a crease UNDO, expected exactly 1. `owesTopologyBump`'s "
      ~ "creaseWeight arm is what asks for it, and without the bump the "
      ~ "subpatch preview keeps serving the pre-undo crease layout — the "
      ~ "'the written weight does nothing' symptom, in reverse");
    assert(m.creaseWeightMap() is null,
        "the undo left a crease map registered on a mesh that had none before "
      ~ "the command — the Create entry's reverse did not unregister it");
}

unittest { // clear: [Values] alone, and a NO-OP write bumps NOTHING
    import std.conv : to;

    uint eA, eB;
    auto m = new Mesh;
    *m = creaseCell_(eA, eB);
    // Pre-existing map with a real value on both selected edges, written
    // OUTSIDE the command so this cell measures the clear alone.
    assert(m.setCreaseWeight(eA, 0.75f) && m.setCreaseWeight(eB, 0.75f));

    View v = freshView();
    auto c = new EdgeCreaseClear(m, v, EditMode.Edges);
    assert(c.apply(), "mesh.edgeCrease.clear must apply");
    string ops;
    foreach (i, ref e; c.recordedDelta().log) {
        if (i) ops ~= ", ";
        ops ~= e.mapOp.to!string;
    }
    assert(ops == "Values",
        "mesh.edgeCrease.clear's op-log MapOps are [" ~ ops ~ "], expected "
      ~ "[Values] — the map already existed, so there is no Create to record "
      ~ "and an extra one would unregister a map the user had");
    assert(m.edgeCreaseWeight(eA) == 0.0f && m.edgeCreaseWeight(eB) == 0.0f);

    immutable ulong tv0 = m.topologyVersion;
    assert(c.revert(), "the undo must succeed");
    assert(m.topologyVersion == tv0 + 1,
        "topologyVersion moved by " ~ (m.topologyVersion - tv0).to!string
      ~ " across a crease-clear UNDO, expected exactly 1");
    assert(m.edgeCreaseWeight(eA) == 0.75f && m.edgeCreaseWeight(eB) == 0.75f,
        "the undo did not put the cleared weights back");

    // ---- THE ROW THAT KEEPS THE TWO ABOVE HONEST. A clear over a map that is
    // ALREADY all zeroes moves no value, so `recordMapValueDiff` records
    // NOTHING and the replay has nothing to bump on. Without this row a
    // mutation that made `owesTopologyBump` answer `true` unconditionally
    // would leave both asserts above green.
    auto n = new Mesh;
    uint fA, fB;
    *n = creaseCell_(fA, fB);
    assert(n.addMeshMapOfKind(MapKind.creaseWeight) !is null);
    auto c2 = new EdgeCreaseClear(n, v, EditMode.Edges);
    assert(c2.apply(), "a clear over an all-zero crease map still SUCCEEDS — "
                     ~ "it is a real no-op edit, not a refusal");
    assert(c2.recordedDelta().log.length == 0,
        "clearing an already-zero crease map recorded "
      ~ c2.recordedDelta().log.length.to!string ~ " entr(ies); the post-hoc "
      ~ "door records nothing when no element moved bitwise, and an entry here "
      ~ "would carry before == after");
    immutable ulong tv1 = n.topologyVersion;
    assert(c2.revert(),
        "an empty delta's revert must answer TRUE — a false pops the entry off "
      ~ "BOTH history stacks and truncates the suffix after it");
    assert(n.topologyVersion == tv1,
        "topologyVersion moved by " ~ (n.topologyVersion - tv1).to!string
      ~ " across an EMPTY crease delta, expected 0. This row is what stops the "
      ~ "two +1 asserts above from being satisfied by 'everything bumps'");
}
