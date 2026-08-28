module commands.mesh.bridge;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Bridge (mesh.bridge): stitch two equal-length closed vertex loops into a
/// ring of quad faces.  Works in both Polygon and Edge selection modes.
///
/// Polygon mode: requires exactly 2 selected polygons; their ordered vertex
/// rings become the two loops.
///
/// Edge mode: selected edges must form exactly 2 disjoint chains — EITHER
/// both closed simple vertex cycles (each participating vertex has exactly
/// 2 selected-edge neighbours) OR both OPEN rows (task 0395; pairing is by
/// nearest-endpoint proximity, not selection order, with unequal-length
/// rows fanned/triangulated — see `mesh.bridgeOpenRows`). A mix of one open
/// + one closed chain is a no-op (deferred).
///
/// Parameter `flip` (bool, default false): reverse the B-loop pairing
/// direction, overriding the auto nearest-vertex + minimum-distance choice.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L10-e; the whole-mesh
/// `MeshSnapshot` is gone. Two things had to change together for that, and the
/// second is what makes this a group of its own:
///
///   1. THE BATCH GREW OVER THE CAP DELETION (P-L10-4). `bridgeLoops` /
///      `bridgeOpenRows` only APPEND, through `addVertex` / `addFace`; the
///      command then deletes the two cap faces, and until this stage that
///      deletion ran AFTER the batch closed. A delta recorded across the
///      appends alone describes the bridge and says NOTHING about the
///      deletion, so its revert would leave the caps gone.
///      `tests/unit/mesh_ops/bridge_test.d` said so as the caveat on its own
///      green: *"What this does NOT say: that `mesh.bridge`'s undo is a
///      constructor flip … That command deletes the cap faces AFTER the batch
///      closes."* It no longer does.
///   2. The two refusal arms that ran `snap.restore` are §S-6 GIGO rollbacks
///      now: `delta.revert` then discard, `return false`.
///
/// WHAT IS INERT ON THIS PATH: no weld runs here, so the edge-set MERGE record
/// (task 2310) and the Point-domain map payload (task 2330) on
/// `Kind.RemoveVerts` are never exercised, and a green here says nothing about
/// either. `mesh.bridge` also has NO cell in `weld_merge.json` — the stage's
/// stand cannot present two bridgeable loops — so its oracle is
/// `tests/unit/mesh_ops/bridge_test.d`, at the kernel, plus the suite.
class MeshBridge : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    private bool             flip_ = false;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.bridge"; }
    override string label() const { return "Bridge"; }

    override Param[] params() {
        return [
            Param.bool_("flip", "Flip", &flip_, false),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // The dense selection image, taken BEFORE anything opens a batch. On
        // the REDO arm it is NOT re-taken: a second capture would image the
        // POST-op selection, and the first one is the one `revert()` needs.
        if (!undoRecorded()) preSel_.capture(*mesh);

        if (editMode == EditMode.Polygons) {
            // Polygon mode: exactly 2 selected faces supply the vertex rings.
            uint[] selFaces;
            foreach (fi; 0 .. mesh.faces.length)
                if (mesh.isFaceSelected(fi))
                    selFaces ~= cast(uint)fi;
            if (selFaces.length != 2) return false;
            uint fa = selFaces[0], fb = selFaces[1];

            // Capture rings BEFORE any mutation.
            uint[] loopA = mesh.faceVertexRing(fa);
            uint[] loopB = mesh.faceVertexRing(fb);

            // Bridge FIRST: addFace appends, so the cap indices fa/fb stay
            // valid and the new quads reference the original ring vertices.
            //
            // TASK 1903 Stage D3 — the kernel takes `ref MeshEditBatch`, so the
            // batch opens HERE, at the command boundary, and never inside the
            // kernel (plan §4.1). One bridge now bumps its version stamp,
            // re-derives hidden geometry and delivers to the change bus ONCE at
            // `close()` instead of once per `addFace`/`addVertex` the kernel
            // makes on its way through.
            //
            // UNRECORDED, deliberately: undo here is still the whole-mesh
            // `snap` captured just above (plan §5.1 — track 1 is the conversion
            // axis, track 2 is the undo migration, and mixing them in one
            // commit is what §5.1 forbids), so a RECORDING batch would build a
            // full op-log that nothing reads and `close()` would drop.
            //
            // TASK 1903 STAGE L10-e — the batch now SPANS THE CAP DELETION
            // (P-L10-4). D3's comment here said the opposite, and gave the
            // reason it had at the time: both refusal arms ran
            // `snap.restore(*mesh)`, and a wholesale `*mesh = …` inside an
            // open frame would defer the stamps `commitRestored` publishes.
            // Neither arm restores a snapshot any more — they replay the delta
            // backwards AFTER the frame has closed — so the reason is spent,
            // and the deletion has to be inside or the delta cannot invert it.
            //
            // No `scope(failure)`, unlike the older
            // `beginEditBatch`/`endEditBatch` spelling at delete.d / remove.d:
            // that pair has no destructor, this handle does. `MeshEditBatch.~this`
            // pops the frame during unwinding — without asserting, because it runs
            // while an exception is in flight — and ticks `changeBus.batchLeaks`,
            // which the suite asserts stays 0.
            size_t n, removed;
            {
                auto ed = openBatch();
                n = ed.bridgeLoops(loopA, loopB, flip_);
                if (n != 0) {
                    // Delete caps SECOND, INSIDE the same frame.
                    // `deleteFacesByMask` compacts orphans and rebuilds loops
                    // internally, so no explicit `buildLoops` here.
                    auto mask = new bool[](mesh.faces.length);
                    mask[fa] = mask[fb] = true;
                    removed = ed.deleteFacesByMask(mask);
                }
                auto d = ed.close();
                if (!undoRecorded()) delta_ = d;
            }
            // `n == 0` mutated nothing; `removed == 0` mutated and then
            // refused, which is the GIGO arm. `settle` tells them apart.
            if (!settle(n == 0 ? 0 : removed)) return false;
        } else if (editMode == EditMode.Edges) {
            // Edge mode: selected edges must form exactly 2 disjoint chains
            // — either both closed cycles or both OPEN rows (task 0395).
            // extractSelectedEdgeChains generalizes the pre-existing
            // extractSelectedEdgeCycles (closed-only, left untouched) to
            // also recognize open rows.
            auto chains = mesh.extractSelectedEdgeChains();
            if (chains.length != 2) return false;
            immutable bool bothClosed = chains[0].closed && chains[1].closed;
            immutable bool bothOpen   = !chains[0].closed && !chains[1].closed;
            if (!bothClosed && !bothOpen) return false;   // mixed open+closed: no-op, deferred

            // Faces EXACTLY bounded by either bridged loop become interior once
            // the two rims are stitched and must be removed — matching the
            // reference editor's edge.bridge (task 0467: captured two-cap case
            // deletes both caps -> 4f; captured open-tube case, where no single
            // face is bounded by a rim, deletes nothing) and vibe3d's own
            // mesh.bridgeTool. Computed BEFORE bridging: bridgeLoops only
            // APPENDS faces (addFace), so these indices stay valid — the same
            // pre-mutation-capFaces pattern applyBridgeOp uses. Open rows never
            // bound a face, so this stays an empty, safe no-op there (task
            // 0395), preserving the pre-existing open-row behaviour.
            // `(*mesh).`: `facesBoundedByLoop` is a free function over
            // `ref const(Mesh)` since task 1903 Stage D3, and UFCS does not
            // auto-dereference a `Mesh*` the way member lookup did. It is
            // read-only, so it needs no batch — and it must stay OUTSIDE one
            // anyway, since it runs before the snapshot.
            uint[] caps = bothOpen
                ? null
                : (*mesh).facesBoundedByLoop(chains[0].verts)
                  ~ (*mesh).facesBoundedByLoop(chains[1].verts);

            // TASK 1903 STAGE L10-e — same boundary batch as the Polygon
            // branch above, and it now SPANS THE CAP DELETION for the same
            // reason; see that comment.
            //
            // THE OPEN-ROW ARM DELETES NOTHING and that is not a special case
            // to guard: `caps` is null when both chains are open, so the loop
            // below never builds a mask and the `buildLoops` fallback runs
            // instead — inside the frame, where it costs nothing extra.
            size_t n;
            {
                auto ed = openBatch();
                n = bothOpen
                    ? ed.bridgeOpenRows(chains[0].verts, chains[1].verts, flip_, 1u, 0.0f)
                    : ed.bridgeLoops(chains[0].verts, chains[1].verts, flip_);
                if (n != 0) {
                    // deleteFacesByMask compacts orphans + rebuilds loops
                    // internally, so no explicit buildLoops when it runs
                    // (mirrors the Polygon branch). Empty caps (open rows / no
                    // bounding face) -> keep buildLoops.
                    bool removed = false;
                    if (caps.length > 0) {
                        auto mask = new bool[](mesh.faces.length);
                        bool any = false;
                        foreach (fi; caps)
                            if (fi < mask.length) { mask[fi] = true; any = true; }
                        if (any && ed.deleteFacesByMask(mask) > 0)
                            removed = true;
                    }
                    if (!removed) ed.buildLoops();
                }
                auto d = ed.close();
                if (!undoRecorded()) delta_ = d;
            }
            // Unlike the polygon branch, an empty cap set is NOT a refusal
            // here — an open-row bridge bounds no face and deletes none — so
            // the only refusal is the kernel's own.
            if (!settle(n)) return false;
        } else {
            return false;
        }

        mesh.syncSelection();
        noteUndoRecorded();
        return true;
    }

    /// The batch this command opens: RECORDING on the first run, UNRECORDED on
    /// the redo. `CommandHistory.redo` re-runs `apply()`, and a second
    /// recording run would record a second delta over the first; unrecorded,
    /// every tracker hook takes its `editRecorder_ is null` early-out.
    private MeshEditBatch openBatch() {
        if (undoRecorded()) return MeshEditBatch.unrecorded(*mesh, kBridgeEditScope);
        return MeshEditBatch(*mesh, kBridgeEditScope);
    }

    /// THE POST-CLOSE RULING (§S-6, ruling Q-K6), shared by the two branches.
    /// On the REDO arm it is only the kernel's own answer that matters — there
    /// is no delta to accept or discard.
    ///
    ///   * `affected == 0` is the refusal. The kernel may already have
    ///     appended (the polygon branch reaches it with the bridge built and
    ///     the caps un-deletable), so the partial edit is replayed BACKWARDS
    ///     out of the delta and every image dropped — what the deleted
    ///     `snap.restore` did;
    ///   * `affected > 0` with an EMPTY delta ticks
    ///     `changeBus.emptyDeltaOverMutation` and is NOT rolled back: there is
    ///     nothing to replay, and re-imposing the pre-op selection over a mesh
    ///     whose arrays have already moved would resize the mark arrays back
    ///     to the pre-op length.
    private bool settle(size_t affected) {
        if (undoRecorded()) return affected != 0;
        if (acceptRecordedEdit(affected, delta_)) return true;
        if (affected == 0) {
            delta_.revert(*mesh);
            preSel_.restore(*mesh);
        }
        delta_  = MeshEditDelta.init;
        preSel_ = DenseSelectionUndo.init;
        return false;
    }

    protected override void revertImpl() {
        // An instance whose `evaluate` refused holds an empty delta and a
        // nulled selection image; replaying it would run `preSel_` over a mesh
        // it was never sized against. Answering false here is correct ONLY
        // because the funnel records no history entry for a refused forward.
        delta_.revert(*mesh);     // LIFO inverse replay restores geometry
        preSel_.restore(*mesh);   // …then the three selection domains
    }
}
