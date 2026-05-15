module commands.mesh.linear_align;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import math : Vec3;
import params : Param;

import std.math : abs, sqrt;

/// Align selected verts onto the line through their centroid along
/// the bounding-box's longest axis. Each vert collapses to (centroid +
/// projection_along_axis · axis), preserving its position along the
/// axis but zeroing the perpendicular components.
///
/// Mirrors the `mode=line + flatten=true` branch of MODO's
/// `xfrm.linearAlign` tool. The full MODO tool also offers a `curve`
/// mode (polynomial fit) and an interactive drag handle for the line
/// direction; this is a one-shot command — drag-style controls land
/// later if needed.
class MeshLinearAlign : Command {
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

    override string name()  const { return "mesh.linear_align"; }
    override string label() const { return "Linear Align"; }

    // No params for now — the algorithm picks centroid + longest-axis
    // automatically. Future: add `axis` (X/Y/Z/auto) override.

    override bool apply() {
        // Affected-vertex mask.
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

        // Need ≥ 2 verts to define a line. If somehow we have 1 (unusual
        // selection state), bail without mutation.
        size_t count = 0;
        Vec3 sum = Vec3(0, 0, 0);
        Vec3 mn  = Vec3( float.infinity,  float.infinity,  float.infinity);
        Vec3 mx  = Vec3(-float.infinity, -float.infinity, -float.infinity);
        foreach (i; 0 .. mesh.vertices.length) {
            if (!vmask[i]) continue;
            ++count;
            auto p = mesh.vertices[i];
            sum = sum + p;
            if (p.x < mn.x) mn.x = p.x;  if (p.x > mx.x) mx.x = p.x;
            if (p.y < mn.y) mn.y = p.y;  if (p.y > mx.y) mx.y = p.y;
            if (p.z < mn.z) mn.z = p.z;  if (p.z > mx.z) mx.z = p.z;
        }
        if (count < 2) return false;
        Vec3 centroid = sum * (1.0f / cast(float)count);

        // Pick the longest bbox axis as the line direction. Ties go to
        // the lexicographically-first axis (X > Y > Z), deterministic.
        float ex = mx.x - mn.x;
        float ey = mx.y - mn.y;
        float ez = mx.z - mn.z;
        Vec3 axis = Vec3(1, 0, 0);
        if (ey > ex && ey >= ez)        axis = Vec3(0, 1, 0);
        else if (ez > ex && ez > ey)    axis = Vec3(0, 0, 1);

        // Snapshot + project. Project p onto the line through centroid
        // along `axis`: new = centroid + dot(p - centroid, axis) * axis.
        // For an axis-aligned `axis` this just keeps the matching
        // component and replaces the other two with the centroid's.
        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        foreach (i; 0 .. mesh.vertices.length) {
            if (!vmask[i]) continue;
            touchedIdx  ~= cast(uint)i;
            touchedPrev ~= mesh.vertices[i];
            auto p = mesh.vertices[i];
            float t = (p.x - centroid.x) * axis.x
                    + (p.y - centroid.y) * axis.y
                    + (p.z - centroid.z) * axis.z;
            mesh.vertices[i].x = centroid.x + t * axis.x;
            mesh.vertices[i].y = centroid.y + t * axis.y;
            mesh.vertices[i].z = centroid.z + t * axis.z;
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
