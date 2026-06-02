module commands.scene.load_mesh;

import command;
import math : Vec3;
import mesh;
import view;
import editmode;
import viewcache;
// GpuMesh lives in mesh.d, already imported above.
import snapshot : MeshSnapshot;

/// Replace the current mesh with a caller-supplied raw mesh (test-only,
/// driven by `POST /api/load-mesh`). Mirrors `SceneReset`: snapshots the
/// pre-load mesh for undo, swaps in the new geometry, rebuilds every
/// derived structure (edges, half-edge loops, selection/mark/material
/// arrays), clears the selection, and refreshes the GPU + screen-space
/// caches — i.e. the same consistent post-load state `/api/reset` leaves
/// behind, just with a caller-supplied mesh instead of a primitive.
///
/// Validation (degree >= 3, indices in range) happens in `apply()` BEFORE
/// the live mesh is touched, so a bad payload leaves the scene untouched.
class MeshLoadRaw : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private EditMode*        editModePtr;
    private View*            viewPtr;
    private void delegate()  onResetTool;

    private Vec3[]   newVerts;
    private uint[][] newFaces;

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

    override string name() const { return "scene.loadMesh"; }
    override string label() const { return "Load mesh"; }

    /// Supply the raw geometry to load. Caller owns/builds these arrays;
    /// they are validated against each other (index range) in apply().
    void setData(Vec3[] verts, uint[][] faces) {
        this.newVerts = verts;
        this.newFaces = faces;
    }

    override bool apply() {
        // ---- Validate BEFORE mutating any live state ----
        immutable uint vcount = cast(uint)newVerts.length;
        foreach (fi, ref f; newFaces) {
            if (f.length < 3)
                throw new Exception("face " ~ itoa(fi) ~
                    " has fewer than 3 vertices");
            foreach (vi; f)
                if (vi >= vcount)
                    throw new Exception("face " ~ itoa(fi) ~
                        " references vertex index " ~ itoa(vi) ~
                        " out of range (vertexCount=" ~ itoa(vcount) ~ ")");
        }

        // ---- Snapshot for undo, then swap geometry in ----
        snap         = MeshSnapshot.capture(*mesh);
        prevEditMode = *editModePtr;
        captured     = true;

        Mesh m;
        m.vertices = newVerts.dup;
        // FaceList.alias-this accepts a uint[][]; dup so the command owns
        // independent storage from the caller's parsed arrays.
        uint[][] facesCopy = new uint[][](newFaces.length);
        foreach (i, ref f; newFaces) facesCopy[i] = f.dup;
        m.faces = facesCopy;
        // Same finalization the mesh factories (makeCube etc.) use:
        // buildLoops() rebuilds the half-edge structure and the
        // deduplicated edge list; resetSelection() (re)sizes + clears the
        // per-element selection / mark / subpatch / material arrays.
        m.rebuildEdgesFromFaces();
        m.buildLoops();
        m.resetSelection();
        *mesh = m;

        viewPtr.reset();
        mesh.resetSelection();
        *editModePtr = EditMode.Vertices;
        if (onResetTool !is null) onResetTool();
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (!captured) return false;
        snap.restore(*mesh);
        *editModePtr = prevEditMode;
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

    // Tiny @safe int-to-string for error messages without dragging
    // std.conv into the hot path of this test-only command.
    private static string itoa(T)(T v) {
        import std.conv : to;
        return to!string(v);
    }
}
