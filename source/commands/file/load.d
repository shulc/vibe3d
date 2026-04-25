module commands.file.load;

import nfde;

import command;
import mesh;
import view;
import editmode;
import lwo;
import viewcache;

class FileLoad : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private string           explicitPath;  // set via setPath() to skip the dialog

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name() const { return "File Load"; }

    /// Skip the native file dialog and load from the given path.
    /// Used by /api/command params; leave unset for normal user flow.
    void setPath(string p) { explicitPath = p; }

    override bool apply() {
        string path = explicitPath;
        if (path is null) {
            version (Windows)
                auto result = openDialog(path,
                    [FilterItem(cast(const(ushort)*)"LWO"w.ptr, cast(const(ushort)*)"lwo"w.ptr)]);
            else
                auto result = openDialog(path, [FilterItem("LWO", "lwo")]);
            assert(result != Result.error, getError());
            if (path is null) return false;
        }
        if (!importLWO(path, *mesh)) return false;

        // importLWO has already rebuilt the mesh on a fresh struct (Mesh.init)
        // and applied subpatch flags from PTCH chunks; grow selection arrays
        // to match but don't clear isSubpatch.
        mesh.syncSelection();
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
        return true;
    }
}
