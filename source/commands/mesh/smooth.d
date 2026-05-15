module commands.mesh.smooth;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import math : Vec3;
import params : Param;

/// Laplacian vertex smoothing. Each iteration: new_pos = old_pos +
/// strength * (avg_of_edge_neighbors - old_pos). Selection-aware
/// (same mask as MeshTransform); empty selection ⇒ whole mesh.
///
/// Mirrors MODO's `xfrm.smooth` tool's `strn` (strength) and `iter`
/// (iterations) attrs, exposed as a one-shot command rather than a
/// drag-tool. Cross-engine reference: a fixed cube + strn/iter pair
/// converges toward the centroid analytically (see
/// tests/test_mesh_smooth.d). MODO's xfrm.smooth runs through the
/// xfrm.transform doApply path which is GPU-aware and harder to
/// drive headlessly — analytical reference is the practical check.
class MeshSmooth : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private float            strn_ = 0.5f;   // matches MODO's `strn` attr
    private int              iter_ = 1;      // matches MODO's `iter` attr
    private uint[] touchedIdx;
    private Vec3[] touchedPrev;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.smooth"; }
    override string label() const { return "Smooth"; }

    override Param[] params() {
        return [
            Param.float_("strn", "Strength",   &strn_, 0.5f).min(0.0f).max(1.0f),
            Param.int_  ("iter", "Iterations", &iter_, 1).min(0),
        ];
    }

    override bool apply() {
        if (iter_ <= 0 || strn_ <= 0.0f) return true;  // no-op apply

        // Affected-vertex mask (selection-aware).
        bool[] vmask = new bool[](mesh.vertices.length);
        bool any = false;
        if (editMode == EditMode.Vertices) {
            foreach (i; 0 .. mesh.selectedVertices.length)
                if (mesh.selectedVertices[i]) { vmask[i] = true; any = true; }
        } else if (editMode == EditMode.Edges) {
            foreach (i; 0 .. mesh.selectedEdges.length)
                if (mesh.selectedEdges[i])
                    foreach (vi; mesh.edges[i]) { vmask[vi] = true; any = true; }
        } else {
            foreach (i; 0 .. mesh.selectedFaces.length)
                if (mesh.selectedFaces[i])
                    foreach (vi; mesh.faces[i]) { vmask[vi] = true; any = true; }
        }
        if (!any)
            foreach (i; 0 .. mesh.vertices.length) vmask[i] = true;

        // Neighbour lists, built once from mesh.edges. Each adjacency
        // is recorded both ways (a→b AND b→a) so the per-iter loop
        // doesn't need to re-walk the edge array.
        uint[][] neighbors = new uint[][](mesh.vertices.length);
        foreach (e; mesh.edges) {
            neighbors[e[0]] ~= e[1];
            neighbors[e[1]] ~= e[0];
        }

        // Snapshot pre-apply positions of every vert we plan to touch.
        // We touch ALL masked verts (even those without neighbors —
        // their Laplacian contribution is zero, but we still snapshot
        // them so revert can restore unconditionally).
        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        foreach (i; 0 .. mesh.vertices.length) {
            if (!vmask[i]) continue;
            touchedIdx  ~= cast(uint)i;
            touchedPrev ~= mesh.vertices[i];
        }

        // Laplacian iteration. Each pass reads from a `prev` snapshot
        // (so neighbour averaging sees the previous iteration's
        // positions, not partially updated ones), then commits.
        Vec3[] prev = mesh.vertices.dup;
        Vec3[] cur  = mesh.vertices.dup;
        foreach (_; 0 .. iter_) {
            foreach (vi; 0 .. mesh.vertices.length) {
                if (!vmask[vi]) continue;
                auto nbrs = neighbors[vi];
                if (nbrs.length == 0) continue;
                Vec3 sum = Vec3(0, 0, 0);
                foreach (nb; nbrs) sum = sum + prev[nb];
                Vec3 avg = sum * (1.0f / cast(float)nbrs.length);
                cur[vi].x = prev[vi].x + strn_ * (avg.x - prev[vi].x);
                cur[vi].y = prev[vi].y + strn_ * (avg.y - prev[vi].y);
                cur[vi].z = prev[vi].z + strn_ * (avg.z - prev[vi].z);
            }
            // Promote `cur` → `prev` for the next iteration via swap;
            // copying would alloc each pass at large mesh sizes.
            auto tmp = prev; prev = cur; cur = tmp;
        }
        // After the loop, `prev` holds the final state (last swap).
        mesh.vertices = prev;

        ++mesh.mutationVersion;
        gpu.upload(*mesh);
        vc.invalidate();
        ec.invalidate();
        fc.invalidate();
        return true;
    }

    override bool revert() {
        if (touchedIdx.length == 0) return false;
        foreach (i, vi; touchedIdx)
            if (vi < mesh.vertices.length) mesh.vertices[vi] = touchedPrev[i];
        ++mesh.mutationVersion;
        gpu.upload(*mesh);
        vc.invalidate();
        ec.invalidate();
        fc.invalidate();
        return true;
    }
}
