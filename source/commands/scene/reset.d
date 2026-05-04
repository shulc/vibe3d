module commands.scene.reset;

import command;
import mesh;
import view;
import editmode;
import viewcache;
// GpuMesh lives in mesh.d, already imported above.
import snapshot : MeshSnapshot;

/// Reset the scene to a chosen primitive (cube/diamond/octahedron/lshape).
/// Replaces the legacy /api/reset direct handler. Snapshots the entire
/// pre-reset mesh so undo brings back whatever was there.
class SceneReset : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private EditMode*        editModePtr;
    private View*            viewPtr;
    private void delegate()  onResetTool;

    private string       primitive;     // "cube" / "diamond" / "octahedron" / "lshape"
    private bool         emptyScene;    // true → reset to empty mesh (no primitive)
    private MeshSnapshot snap;
    private EditMode     prevEditMode;
    private bool         captured;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc,
         EditMode* editModePtr, View* viewPtr,
         void delegate() onResetTool) {
        super(mesh, view, editMode);
        this.gpu         = gpu;
        this.vc          = vc;
        this.ec          = ec;
        this.fc          = fc;
        this.editModePtr = editModePtr;
        this.viewPtr     = viewPtr;
        this.onResetTool = onResetTool;
    }

    override string name() const { return "scene.reset"; }
    override string label() const {
        return emptyScene ? "Reset to empty" : "Reset to " ~ primitive;
    }

    void setPrimitive(string p) { primitive = p; emptyScene = false; }
    void setEmpty(bool b) { emptyScene = b; }

    override bool apply() {
        snap         = MeshSnapshot.capture(*mesh);
        prevEditMode = *editModePtr;
        captured     = true;

        if (emptyScene) {
            *mesh = Mesh.init;
        } else switch (primitive) {
            case "lshape":     *mesh = makeLShape();    break;
            case "diamond":    *mesh = makeDiamond();   break;
            case "octahedron": *mesh = makeOctahedron();break;
            case "":
            case "cube":
            default:           *mesh = makeCube();      break;
        }
        viewPtr.reset();
        mesh.resetSelection();
        *editModePtr = EditMode.Vertices;
        // Reset the workplane along with the scene — it's session state
        // (a tilted / aligned workplane left over from a previous edit
        // changes how subsequent prim.* and BoxTool / SphereTool / ...
        // behave) and a "reset" UX promise should clear it.
        import toolpipe.pipeline       : g_pipeCtx;
        import toolpipe.stages.workplane : WorkplaneStage;
        import toolpipe.stage          : TaskCode;
        if (g_pipeCtx !is null) {
            if (auto wp = cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work))
                wp.reset();
        }
        if (onResetTool !is null) onResetTool();
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (!captured) return false;
        snap.restore(*mesh);
        *editModePtr = prevEditMode;
        // Camera state isn't snapshotted — undoing a reset doesn't restore
        // the camera, only the mesh. Matches MODO's typical behavior where
        // viewport state isn't part of model undo.
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
    }
}
