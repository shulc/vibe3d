module tools.transform;
import tool;
import mesh;
import editmode;
import math : Vec3, Viewport;

class TransformTool : Tool {
public:
    // app.d reads this every frame and sets u_model accordingly.
    // Reset to identity when not in a whole-mesh drag.
    float[16] gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];

protected:
    bool          active;

    Mesh*     mesh;
    GpuMesh*  gpu;
    EditMode* editMode;

    int      dragAxis = -1;      // 0/1/2=X/Y/Z axis, -1=none (exact meaning varies per tool)
    int      lastMX, lastMY;     // mouse position at last motion event
    Viewport cachedVp;           // viewport captured in draw(), reused in event handlers
    bool     centerManual;       // true = update() must not recompute handler center
    Vec3     cachedCenter;       // gizmo center, recomputed when selection hash changes
    bool     needsGpuUpdate;     // deferred GPU upload flag, flushed in draw()

    // Whole-mesh GPU bypass (Rotate + Scale use these; Move uses gpuOffset instead)
    bool   wholeMeshDrag;
    bool   propsDragging;
    Vec3[] dragStartVertices;

    // Vertex index cache — rebuilt once per selection change, reused every event.
    int[]  vertexIndicesToProcess;
    bool[] toProcess;
    int    vertexProcessCount;
    bool   vertexCacheDirty = true;
    int    lastSelectionHash;

    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        this.mesh     = mesh;
        this.gpu      = gpu;
        this.editMode = editMode;
    }

    override void activate() {
        active = true;
        vertexCacheDirty = true;
        lastSelectionHash = uint.max;
        needsGpuUpdate = false;
        centerManual = false;
        wholeMeshDrag = false;
        propsDragging = false;
        dragAxis = -1;
        gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    }

    override void deactivate() {
        if (wholeMeshDrag || propsDragging) {
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            wholeMeshDrag = false;
            propsDragging = false;
        } else if (needsGpuUpdate) {
            gpu.upload(*mesh);
            needsGpuUpdate = false;
        }
        dragAxis = -1;
        centerManual = false;
        active = false;
    }
    
    uint computeSelectionHash() {
        if (*editMode == EditMode.Vertices) return mesh.selectionHashVertices();
        if (*editMode == EditMode.Edges)    return mesh.selectionHashEdges();
        if (*editMode == EditMode.Polygons) return mesh.selectionHashFaces();
        return 0;
    }

    void buildVertexCacheIfNeeded() {
        if (!vertexCacheDirty) return;

        int[] indices;
        if (*editMode == EditMode.Vertices)      indices = mesh.selectedVertexIndicesVertices();
        else if (*editMode == EditMode.Edges)    indices = mesh.selectedVertexIndicesEdges();
        else if (*editMode == EditMode.Polygons) indices = mesh.selectedVertexIndicesFaces();

        vertexIndicesToProcess = indices;
        vertexProcessCount = cast(int)indices.length;
        vertexCacheDirty = false;

        if (toProcess.length != mesh.vertices.length)
            toProcess.length = mesh.vertices.length;
        toProcess[] = false;
        foreach (vi; vertexIndicesToProcess)
            toProcess[vi] = true;
    }

    void uploadToGpu() {
        if (vertexProcessCount <= 0) return;
        if (vertexProcessCount < cast(int)(mesh.vertices.length * 0.8))
            gpu.uploadSelectedVertices(*mesh, toProcess);
        else
            gpu.upload(*mesh);
    }

    // Identical in Rotate and Scale — upload a vertex snapshot to GPU without
    // modifying mesh.vertices (used once at props-drag start to set the GPU base).
    void uploadPropsBase(Vec3[] base) {
        Vec3[] saved = mesh.vertices;
        mesh.vertices = base;
        gpu.upload(*mesh);
        mesh.vertices = saved;
    }

    // Extract camera origin from the cached view matrix (inverse of view rotation/translation).
    Vec3 viewCamOrigin() {
        const ref float[16] v = cachedVp.view;
        return Vec3(
            -(v[0]*v[12] + v[1]*v[13] + v[2]*v[14]),
            -(v[4]*v[12] + v[5]*v[13] + v[6]*v[14]),
            -(v[8]*v[12] + v[9]*v[13] + v[10]*v[14]),
        );
    }
}