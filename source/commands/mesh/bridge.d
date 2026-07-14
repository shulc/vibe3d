module commands.mesh.bridge;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import params : Param;
import snapshot : MeshSnapshot;

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
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;
    private bool             flip_ = false;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
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
            size_t n = mesh.bridgeLoops(loopA, loopB, flip_);
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

            snap = MeshSnapshot.capture(*mesh);
            size_t n = bothOpen
                ? mesh.bridgeOpenRows(chains[0].verts, chains[1].verts, flip_, 1u, 0.0f)
                : mesh.bridgeLoops(chains[0].verts, chains[1].verts, flip_);
            if (n == 0) {
                snap = MeshSnapshot.init;
                return false;
            }
            mesh.buildLoops();
        } else {
            return false;
        }

        mesh.syncSelection();
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
