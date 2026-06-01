module commands.scene.reset;

import command;
import mesh;
import view;
import editmode;
import viewcache;
// GpuMesh lives in mesh.d, already imported above.
import snapshot : MeshSnapshot;

/// Reset the scene to a chosen primitive
/// (cube/diamond/octahedron/lshape/grid/subdivcube). Replaces the legacy
/// /api/reset direct handler. Snapshots the entire pre-reset mesh so undo
/// brings back whatever was there.
class SceneReset : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private EditMode*        editModePtr;
    private View*            viewPtr;
    private void delegate()  onResetTool;

    private string       primitive;     // "cube" / "diamond" / "octahedron" / "lshape" / "grid" / "subdivcube"
    private bool         emptyScene;    // true → reset to empty mesh (no primitive)
    // Integer parameter for the dense perf meshes: grid side count (n) for
    // "grid", Catmull-Clark depth (levels) for "subdivcube". -1 → use the
    // primitive's default. Ignored by the small fixed primitives.
    private int          primParam = -1;
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
    /// Integer arg for the dense perf meshes (grid side / subdiv levels).
    /// Pass -1 (the default) to let the factory pick its own default.
    void setPrimitiveParam(int p) { primParam = p; }

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
            case "grid":
                // Dense flat grid for the perf harness. Default 316 → ~100 K
                // quads (316×316), matching the perf-mesh target.
                *mesh = makeGridPlane(primParam > 0 ? primParam : 316);
                break;
            case "subdivcube":
                // Catmull-Clark cube for the perf harness. Default 7 levels
                // → ~98 K faces.
                *mesh = subdivideCube(primParam > 0 ? primParam : 7);
                break;
            case "":
            case "cube":
            default:           *mesh = makeCube();      break;
        }
        viewPtr.reset();
        mesh.resetSelection();
        *editModePtr = EditMode.Vertices;
        // Reset EVERY toolpipe stage to its declaration-time defaults.
        // Stage state — Snap on, Symmetry plane, Falloff type, ACEN /
        // AXIS modes, Workplane tilt — is session-level UI state, and
        // a "Reset" UX promise should wipe it alongside the mesh.
        // Without this, every test that flips a stage attr corrupts
        // subsequent tests in the same vibe3d process; stages with no
        // mutable state inherit the no-op Stage.reset() and are
        // unaffected.
        import toolpipe.pipeline : g_pipeCtx;
        if (g_pipeCtx !is null) {
            foreach (s; g_pipeCtx.pipeline.allMut())
                s.reset();
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
        // the camera, only the mesh. Viewport state isn't part of model
        // undo.
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
