module commands.mesh.magnet;

import display_sync : refreshDisplay;
import command;
import mesh;
import view;
import editmode;
import viewcache;
import math : Vec3, Viewport;
import params : Param;
import change_bus : MeshEditScope;
import toolpipe.packets : FalloffPacket, FalloffType, FalloffShape, ElementConnect, SubjectPacket;
import falloff : evaluateFalloff, IFalloffAware;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import deform_magnet : applyMagnet;

/// Convergent attraction deformer — pulls each vertex in the moving set
/// toward `target`, weighted by an Element-sphere falloff centred at
/// `center` (radius `dist`).
///
/// Moving set: selected geometry (empty selection ⇒ whole mesh),
/// same rule as mesh.jitter / mesh.transform.
///
/// Returns false (→ HTTP status:error) when:
///   - strength == 0, OR
///   - no vertex falls inside the falloff sphere (all weights == 0).
///
/// Interactive surface: `xfrm.magnet` tool.
class MeshMagnet : Command, Operator, IFalloffAware {
private:
    GpuMesh*         gpu;
    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    Vec3         target_   = Vec3(0, 0, 0);
    float        strength_ = 1.0f;
    float        dist_     = 1.0f;
    Vec3         center_   = Vec3(0, 0, 0);
    int          anchor_   = -1;

    // Optional injected falloff (IFalloffAware path — from the tool pipe).
    FalloffPacket falloff_;
    bool          hasFalloff_;

    // Undo delta.
    uint[] touchedIdx_;
    Vec3[] touchedPrev_;

public:
    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.magnet"; }
    override string label() const { return "Magnet"; }

    override Param[] params() {
        return [
            Param.vec3_ ("target",   "Target",   &target_,   Vec3(0,0,0)),
            Param.float_("strength", "Strength", &strength_, 1.0f),
            Param.float_("dist",     "Dist",     &dist_,     1.0f),
            Param.vec3_ ("center",   "Center",   &center_,   Vec3(0,0,0)),
            Param.int_  ("anchor",   "Anchor",   &anchor_,  -1),
        ];
    }

    // IFalloffAware — lets the tool pipe inject a pre-computed falloff.
    void setFalloff(FalloffPacket fp) {
        falloff_    = fp;
        hasFalloff_ = true;
    }

    // Operator
    mixin OperatorActrCommon;
    bool evaluate(ref VectorStack vts) {
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (auto fp = vts.get!FalloffPacket())
            setFalloff(*fp);
        return applyKernel();
    }

    override bool revert() {
        if (touchedIdx_.length == 0) return false;
        foreach (k; 0 .. touchedIdx_.length)
            if (touchedIdx_[k] < mesh.vertices.length)
                mesh.vertices[touchedIdx_[k]] = touchedPrev_[k];
        mesh.commitChange(MeshEditScope.Position);
        refreshDisplay(mesh, gpu, vc, ec, fc);
        return true;
    }

private:
    bool applyKernel() {
        if (strength_ <= 0.0f) return false;

        // Build moving set (same mask as mesh.jitter).
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

        int[] indices;
        foreach (i; 0 .. cast(int)mesh.vertices.length)
            if (vmask[i]) indices ~= i;

        // Build Element FalloffPacket (or use injected one from tool pipe).
        FalloffPacket fp;
        if (hasFalloff_) {
            fp = falloff_;
        } else {
            fp.type         = FalloffType.Element;
            fp.enabled      = true;
            fp.pickedCenter = center_;
            fp.pickedRadius = dist_;
            fp.connect      = ElementConnect.Ignore;
            fp.shape        = FalloffShape.Smooth;
            fp.anchorPos    = [center_];
            if (anchor_ >= 0)
                fp.anchorRing = [cast(uint)anchor_];
        }

        Viewport vp;   // Element falloff ignores viewport
        applyMagnet(mesh, indices, target_, strength_, fp, vp,
                    touchedIdx_, touchedPrev_);

        if (touchedIdx_.length == 0) return false;

        mesh.commitChange(MeshEditScope.Position);
        refreshDisplay(mesh, gpu, vc, ec, fc);
        return true;
    }
}
