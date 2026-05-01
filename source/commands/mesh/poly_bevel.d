module commands.mesh.poly_bevel;

import command;
import mesh;
import view;
import editmode;
import shader;
import viewcache;
import poly_bevel : runPolyBevel, PolyBevelResult;
import snapshot : MeshSnapshot;

/// Non-interactive polygon "bevel" — face inset + extrude on the currently
/// selected faces (or all faces if nothing is selected).
///
/// Parameters (set via setInsert/setShift/setGroup before apply()):
///   insert — perpendicular distance each face boundary edge moves inward
///            in the face plane (0 = identity, > 0 = inset, < 0 = outset).
///            MODO Bevel "Inset" / Blender `bmesh.ops.inset.thickness`.
///   shift  — translation along face normal (positive = extrude outward).
///   group  — when true, adjacent selected faces share new vertices on
///            shared boundaries and their internal edges are dropped (one
///            connected inset patch). Default false (each face inset
///            independently with its own side-wall ring).
class MeshPolyBevel : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private float            insert = 0.0f;
    private float            shift  = 0.0f;
    private bool             group  = false;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name() const { return "mesh.poly_bevel"; }

    void setInsert(float v) { insert = v; }   // negative → outset, allowed
    void setShift(float v)  { shift  = v; }
    void setGroup(bool b)   { group  = b; }

    override bool apply() {
        if (editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0)        return false;

        // Snapshot before mutation. runPolyBevel modifies verts, edges,
        // faces, selection arrays — full snapshot is the simplest revert.
        snap = MeshSnapshot.capture(*mesh);

        auto r = runPolyBevel(mesh, insert, shift, group);
        if (!r.success) {
            snap = MeshSnapshot.init;
            return false;
        }

        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length); vc.invalidate();
        ec.resize(mesh.edges.length);    ec.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length); vc.invalidate();
        ec.resize(mesh.edges.length);    ec.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        return true;
    }
}
