module commands.mesh.radial_align;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import math : Vec3;
import params : Param;
import change_bus : MeshEditScope;

import std.math : sqrt;

/// Project selected verts onto a sphere centred at their centroid
/// with radius = mean distance from centroid. Each vert keeps its
/// direction from centroid but its distance is rescaled to the
/// average. This is the spherical case of a radial-align tool
/// (a fuller tool could also support cylinder mode + interactive drag
/// handles; spherical is the most common use and the simplest
/// well-defined one-shot command).
class MeshRadialAlign : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
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

    override string name()  const { return "mesh.radial_align"; }
    override string label() const { return "Radial Align"; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
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

        // First pass: compute centroid + sum of distances → radius.
        // Need ≥ 1 vert; ≥ 2 to have a meaningful sphere (a single
        // vert collapses to "stay put").
        size_t count = 0;
        Vec3 sum = Vec3(0, 0, 0);
        foreach (i; 0 .. mesh.vertices.length) {
            if (!vmask[i]) continue;
            ++count;
            sum = sum + mesh.vertices[i];
        }
        if (count == 0) return false;
        Vec3 centroid = sum * (1.0f / cast(float)count);

        // Second pass: mean distance from centroid = sphere radius.
        float distSum = 0.0f;
        foreach (i; 0 .. mesh.vertices.length) {
            if (!vmask[i]) continue;
            auto d = mesh.vertices[i] - centroid;
            distSum += sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        }
        float radius = distSum / cast(float)count;
        if (radius < 1e-9f) return false;  // degenerate — all coincident

        // Third pass: project. Each vert's new pos is centroid + r·dir
        // where dir is its unit-vector direction from centroid. A vert
        // exactly on the centroid has no defined direction — leave it
        // alone.
        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        foreach (i; 0 .. mesh.vertices.length) {
            if (!vmask[i]) continue;
            touchedIdx  ~= cast(uint)i;
            touchedPrev ~= mesh.vertices[i];
            auto d = mesh.vertices[i] - centroid;
            float len = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
            if (len < 1e-9f) continue;     // coincident with centroid → skip
            float s = radius / len;
            mesh.vertices[i].x = centroid.x + d.x * s;
            mesh.vertices[i].y = centroid.y + d.y * s;
            mesh.vertices[i].z = centroid.z + d.z * s;
        }

        mesh.commitChange(MeshEditScope.Position);
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
        mesh.commitChange(MeshEditScope.Position);
        gpu.upload(*mesh);
        vc.invalidate();
        ec.invalidate();
        fc.invalidate();
        return true;
    }
}
