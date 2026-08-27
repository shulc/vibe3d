module commands.mesh.split_edge;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import snapshot : MeshSnapshot;

/// Split the (first) currently selected edge at its midpoint, inserting a
/// new vertex and updating every incident face. Edges are re-derived from
/// faces afterwards. The selection is reset on success.
///
/// The split itself is `Mesh.addEdgePoint(ei, 0.5)` — the same primitive
/// `mesh.addPoint` drives, at a fixed parameter. See `evaluate` for why this
/// command stopped carrying its own copy of the splice (task 1903 §L2-P0).
class MeshSplitEdge : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "mesh.split_edge"; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Edges) return false;
        if (!mesh.hasAnySelectedEdges()) return false;

        int ei = -1;
        foreach (i, sel; mesh.selectedEdges)
            if (sel) { ei = cast(int)i; break; }
        if (ei < 0 || ei >= cast(int)mesh.edges.length) return false;

        // Snapshot before mutation. split_edge inserts a new vert and
        // reshuffles many faces — full mesh snapshot is the simplest
        // correct revert. Cheap enough at typical mesh sizes.
        snap = MeshSnapshot.capture(*mesh);

        // THE MIDPOINT SPLIT IS `Mesh.addEdgePoint(ei, 0.5)` — not a private
        // copy of it (task 1903 Stage L2-P0).
        //
        // This command used to splice the new corner into every incident
        // winding with its own loop right here, and then call
        // `rebuildEdges()` / `buildLoops()` by hand. `mesh.addPoint` already
        // reached the same splice through `addEdgePoint`, so the tree carried
        // the same edit twice, and only one of the two copies was correct:
        //
        //   * the splice changes the mesh's TOTAL corner count, and the copy
        //     here opened no corner rewrite at all, so `buildLoops`'s
        //     `resizePolyVertexMaps` fell through to the length insurance and
        //     ZEROED every PolyVertex map WHOLE — a point added on one edge
        //     cost the entire mesh its UVs, on the FORWARD; and
        //   * in a `-debug` build (which is what the module-unittest lane is)
        //     that same fall-through trips `mesh.d`'s
        //     `debug assert(false, "corner provenance: a face rewrite reached
        //     buildLoops without declaring what became of the corners…")`,
        //     so the command ABORTED the process on any map-carrying mesh
        //     rather than merely losing the plane.
        //
        // `addEdgePoint` is the sanctioned home: it wraps the identical
        // `insertEdgePoint` splice in the `beginCornerRewrite()` /
        // `declareCornerProvenance()` pair (mesh.d), carrying each new corner
        // as the per-FACE blend of its two endpoint corners, and then runs the
        // same `rebuildEdges()` / `buildLoops()` tail. Nothing about the
        // geometry changes: one vertex at the midpoint, spliced between the
        // endpoints in every incident winding.
        //
        // Two deliberate consequences, neither an accident:
        //   * the midpoint is now `a + 0.5·(b − a)` rather than `(a + b)·0.5`,
        //     which can differ by one ulp on coordinates that are not exactly
        //     representable. It is the SAME arithmetic `mesh.addPoint` has
        //     always used at t = 0.5, and one spelling of a midpoint in the
        //     tree is worth more than a bit-for-bit freeze of the other; and
        //   * `resetSelection()` stays HERE. `addEdgePoint` deliberately
        //     leaves the selection alone (the loop-insert family does too);
        //     this command's contract is that the selection is reset on
        //     success, and that is this line, not the primitive's.
        uint vm = mesh.addEdgePoint(cast(uint)ei, 0.5f);
        if (vm == uint.max) {
            // Unreachable on today's guards — `addEdgePoint` refuses only an
            // out-of-range edge (checked above) and a t outside (0,1) (a
            // literal here). Kept so that a later parameterisation of the
            // split position cannot silently mutate nothing and report
            // success; a refusal here has changed nothing, so the snapshot is
            // dropped with it.
            snap = MeshSnapshot.init;
            return false;
        }

        mesh.resetSelection();

        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
