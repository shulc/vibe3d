module commands.mesh.transform;

import std.json;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import math : Vec3, Vec4, mulMV, pivotRotationMatrix, pivotScaleMatrix;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.packets  : SubjectPacket, SymmetryPacket;
import toolpipe.stage    : TaskCode;
import toolpipe.stages.symmetry : SymmetryStage;
import symmetry          : applySymmetryMirror, projectOnPlane;
// GpuMesh lives in mesh.d, already imported above.

/// Transform the selected vertices by translate / rotate / scale. Replaces
/// the legacy /api/transform direct handler. Selection-aware: in Vertices
/// mode transforms selected verts; in Edges/Polygons modes transforms the
/// verts of the selected edges/faces.
///
/// Revert: snapshots the affected vertex positions before mutation.
class MeshTransform : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;

    private string kind;          // "translate" / "rotate" / "scale"
    private Vec3   delta;         // for translate
    private Vec3   axis;          // for rotate
    private float  angle;         // for rotate
    private Vec3   factor;        // for scale
    private Vec3   pivot;

    // Snapshot for revert: indices + their pre-apply positions.
    private uint[] touchedIdx;
    private Vec3[] touchedPrev;
    private bool   captured;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
        this.delta  = Vec3(0, 0, 0);
        this.axis   = Vec3(0, 1, 0);
        this.factor = Vec3(1, 1, 1);
        this.pivot  = Vec3(0, 0, 0);
        this.angle  = 0.0f;
    }

    override string name() const { return "mesh.transform"; }
    override string label() const { return "Transform " ~ kind; }

    void setKind(string k)    { kind   = k; }
    void setDelta(Vec3 d)     { delta  = d; }
    void setAxis(Vec3 a)      { axis   = a; }
    void setAngle(float a)    { angle  = a; }
    void setFactor(Vec3 f)    { factor = f; }
    void setPivot(Vec3 p)     { pivot  = p; }

    override bool apply() {
        // Build affected-vertex mask from selection + edit mode (matches
        // the original transformHandler in app.d).
        bool[] vmask = new bool[](mesh.vertices.length);
        if (editMode == EditMode.Vertices) {
            foreach (i; 0 .. mesh.selectedVertices.length)
                if (mesh.selectedVertices[i]) vmask[i] = true;
        } else if (editMode == EditMode.Edges) {
            foreach (i; 0 .. mesh.selectedEdges.length)
                if (mesh.selectedEdges[i])
                    foreach (vi; mesh.edges[i]) vmask[vi] = true;
        } else if (editMode == EditMode.Polygons) {
            foreach (i; 0 .. mesh.selectedFaces.length)
                if (mesh.selectedFaces[i])
                    foreach (vi; mesh.faces[i]) vmask[vi] = true;
        }

        // Phase 7.6b: snapshot the symmetry packet BEFORE the transform
        // mutates the mesh — the pair table is built from
        // `mesh.vertices`, so the moment we touch a selected vertex the
        // SymmetryStage's cache would get invalidated against a
        // half-mutated mesh and rebuild against the wrong positions.
        // Capturing the slice header here keeps `pairOf` / `onPlane`
        // anchored to the symmetric pre-mutation mesh.
        //
        // We only fire pipeline.evaluate when the SymmetryStage is
        // actually enabled — pipeline.evaluate has cross-stage side
        // effects (FalloffStage caches the upstream workplane normal
        // every evaluate; firing it from a transform path that never
        // touched symmetry would leak workplane state into the
        // falloff stage's auto-size cache, breaking subsequent
        // auto-size operations that expect a freshly-set workplane).
        SymmetryPacket symm;
        bool           symmActive = false;
        if (kind == "translate" && g_pipeCtx !is null) {
            auto symStage = cast(SymmetryStage)
                            g_pipeCtx.pipeline.findByTask(TaskCode.Symm);
            if (symStage !is null && symStage.enabled) {
                SubjectPacket subj;
                subj.mesh             = mesh;
                subj.editMode         = editMode;
                subj.selectedVertices = mesh.selectedVertices.dup;
                subj.selectedEdges    = mesh.selectedEdges.dup;
                subj.selectedFaces    = mesh.selectedFaces.dup;
                auto vp = view.viewport();
                auto state = g_pipeCtx.pipeline.evaluate(subj, vp);
                if (state.symmetry.enabled
                 && state.symmetry.pairOf.length == mesh.vertices.length)
                {
                    symm       = state.symmetry;
                    symmActive = true;
                }
            }
        }

        // Snapshot the touched verts only. revert() restores them. With
        // symmetry active we also capture each selected vert's mirror
        // counterpart so revert undoes the mirror write too.
        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        foreach (i; 0 .. mesh.vertices.length) {
            if (vmask[i]) {
                touchedIdx  ~= cast(uint)i;
                touchedPrev ~= mesh.vertices[i];
            }
        }
        if (symmActive) {
            foreach (vi; 0 .. mesh.vertices.length) {
                if (!vmask[vi]) continue;
                if (symm.onPlane[vi]) continue;
                int mi = symm.pairOf[vi];
                if (mi < 0 || mi == cast(int)vi) continue;
                if (vmask[mi]) continue;
                touchedIdx  ~= cast(uint)mi;
                touchedPrev ~= mesh.vertices[mi];
            }
        }
        captured = true;

        switch (kind) {
            case "translate":
                foreach (i; 0 .. mesh.vertices.length)
                    if (vmask[i]) {
                        mesh.vertices[i].x += delta.x;
                        mesh.vertices[i].y += delta.y;
                        mesh.vertices[i].z += delta.z;
                    }
                break;
            case "rotate":
                auto m = pivotRotationMatrix(pivot, axis, angle);
                foreach (i; 0 .. mesh.vertices.length)
                    if (vmask[i]) {
                        auto v0 = Vec4(mesh.vertices[i].x,
                                       mesh.vertices[i].y,
                                       mesh.vertices[i].z, 1.0f);
                        auto v1 = mulMV(m, v0);
                        mesh.vertices[i] = Vec3(v1.x, v1.y, v1.z);
                    }
                break;
            case "scale":
                auto m = pivotScaleMatrix(pivot, factor.x, factor.y, factor.z);
                foreach (i; 0 .. mesh.vertices.length)
                    if (vmask[i]) {
                        auto v0 = Vec4(mesh.vertices[i].x,
                                       mesh.vertices[i].y,
                                       mesh.vertices[i].z, 1.0f);
                        auto v1 = mulMV(m, v0);
                        mesh.vertices[i] = Vec3(v1.x, v1.y, v1.z);
                    }
                break;
            default:
                throw new Exception("invalid kind '" ~ kind ~
                                    "', expected translate/rotate/scale");
        }

        // Phase 7.6b: symmetry mirror pass. Uses the pair table
        // captured BEFORE the switch above; mirrors each selected
        // vertex's new position into its plane-counterpart, and
        // projects on-plane selected verts back onto the plane.
        if (symmActive) {
            auto alsoTouched = new bool[](mesh.vertices.length);
            applySymmetryMirror(mesh, symm, vmask, alsoTouched);
        }

        ++mesh.mutationVersion;
        gpu.upload(*mesh);
        vc.invalidate();
        fc.invalidate();
        ec.invalidate();
        return true;
    }

    override bool revert() {
        if (!captured) return false;
        foreach (i, vid; touchedIdx) {
            if (vid < mesh.vertices.length)
                mesh.vertices[vid] = touchedPrev[i];
        }
        ++mesh.mutationVersion;
        gpu.upload(*mesh);
        vc.invalidate();
        fc.invalidate();
        ec.invalidate();
        return true;
    }
}
