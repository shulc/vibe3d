module commands.mesh.jitter;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import math : Vec3;
import params : Param;

import std.random : Mt19937, uniform01;
import std.math   : sqrt, cos, sin, PI;

/// Random per-vertex displacement, weighted independently per axis.
/// Selection-aware (same mask as MeshTransform / MeshQuantize); empty
/// selection ⇒ whole mesh.
///
/// Determinism: a fixed `seed` produces a fixed displacement pattern
/// for the SAME vertex enumeration order. Because vibe3d's vert
/// indices are stable across `scene.reset` + selection edits (no
/// reorder happens until topology mutates), the same script twice
/// gives the same output. MODO has no analogous `vert.jitter`
/// command; this is a vibe3d-original deformer.
class MeshJitter : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private float            sclX_   = 0.1f;
    private float            sclY_   = 0.1f;
    private float            sclZ_   = 0.1f;
    private int              seed_   = 0;
    // Snapshot for revert.
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

    override string name()  const { return "mesh.jitter"; }
    override string label() const { return "Jitter"; }

    override Param[] params() {
        return [
            Param.float_("sclX", "Scale X", &sclX_, 0.1f),
            Param.float_("sclY", "Scale Y", &sclY_, 0.1f),
            Param.float_("sclZ", "Scale Z", &sclZ_, 0.1f),
            Param.int_  ("seed", "Seed",    &seed_, 0),
        ];
    }

    override bool apply() {
        // Build affected-vertex mask the same way MeshTransform / MeshQuantize do.
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

        // Mt19937 with a fixed seed gives identical sequences across
        // runs and platforms — the test relies on this. uniform01
        // returns [0, 1); we map to [-1, 1) for centred displacement.
        Mt19937 rng;
        rng.seed(cast(uint)seed_);

        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        foreach (i; 0 .. mesh.vertices.length) {
            // Drain THREE rolls per vert regardless of mask so the seed
            // sequence stays stable when the user changes selection
            // between runs (otherwise selecting vert 5 vs vert 3 would
            // give it a different random vector). The skipped rolls
            // are cheap.
            float u = uniform01!float(rng) * 2.0f - 1.0f;
            float v = uniform01!float(rng) * 2.0f - 1.0f;
            float w = uniform01!float(rng) * 2.0f - 1.0f;
            if (!vmask[i]) continue;
            touchedIdx  ~= cast(uint)i;
            touchedPrev ~= mesh.vertices[i];
            mesh.vertices[i].x += u * sclX_;
            mesh.vertices[i].y += v * sclY_;
            mesh.vertices[i].z += w * sclZ_;
        }

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
