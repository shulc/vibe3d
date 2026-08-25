module commands.mesh.bridge;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;

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
class MeshBridge : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;
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

            snap = MeshSnapshot.capture(*mesh);

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
            // The batch is scoped to the kernel call ALONE and deliberately
            // does NOT span the cap deletion below: the `n == 0` and
            // `deleteFacesByMask() == 0` arms both `snap.restore(*mesh)`, and a
            // restore inside an open batch would defer the stamps that
            // `commitRestored` exists to publish.
            //
            // No `scope(failure)`, unlike the older
            // `beginEditBatch`/`endEditBatch` spelling at delete.d / remove.d:
            // that pair has no destructor, this handle does. `MeshEditBatch.~this`
            // pops the frame during unwinding — without asserting, because it runs
            // while an exception is in flight — and ticks `changeBus.batchLeaks`,
            // which the suite asserts stays 0.
            size_t n;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kBridgeEditScope);
                n = ed.bridgeLoops(loopA, loopB, flip_);
                ed.close();
            }
            if (n == 0) {
                snap = MeshSnapshot.init;
                return false;
            }

            // Delete caps SECOND.  deleteFacesByMask compacts orphans and
            // rebuilds loops internally, so no explicit buildLoops here.
            auto mask = new bool[](mesh.faces.length);
            mask[fa] = mask[fb] = true;
            if (mesh.deleteFacesByMask(mask) == 0) {
                snap.restore(*mesh);
                snap = MeshSnapshot.init;
                return false;
            }
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

            snap = MeshSnapshot.capture(*mesh);
            // TASK 1903 Stage D3 — same boundary batch as the Polygon branch
            // above, same reasons; see that comment. Scoped to the kernel call
            // alone so the `n == 0` restore below never runs inside it.
            size_t n;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kBridgeEditScope);
                n = bothOpen
                    ? ed.bridgeOpenRows(chains[0].verts, chains[1].verts, flip_, 1u, 0.0f)
                    : ed.bridgeLoops(chains[0].verts, chains[1].verts, flip_);
                ed.close();
            }
            if (n == 0) {
                snap = MeshSnapshot.init;
                return false;
            }

            // deleteFacesByMask compacts orphans + rebuilds loops internally, so
            // no explicit buildLoops when it runs (mirrors the Polygon branch).
            // Empty caps (open rows / no bounding face) -> keep buildLoops.
            bool removed = false;
            if (caps.length > 0) {
                auto mask = new bool[](mesh.faces.length);
                bool any = false;
                foreach (fi; caps)
                    if (fi < mask.length) { mask[fi] = true; any = true; }
                if (any && mesh.deleteFacesByMask(mask) > 0)
                    removed = true;
            }
            if (!removed) mesh.buildLoops();
        } else {
            return false;
        }

        mesh.syncSelection();
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
