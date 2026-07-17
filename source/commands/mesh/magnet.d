module commands.mesh.magnet;

import command;
import mesh;
import view;
import editmode;
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
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
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
        return true;
    }

private:
    bool applyKernel() {
        if (strength_ <= 0.0f) return false;
        // `dist` is an EXPLICIT command param (a real spatial radius),
        // not the interactive tool-pipe's "not yet picked" sentinel.
        // falloff.d's elementWeight() has a degenerate-radius fallback
        // (`pickedRadius <= 1e-9f` → return weight=1.0 EVERYWHERE) meant
        // to keep an in-flight interactive drag from dividing by zero
        // before ACEN/FalloffStage have placed a real radius — that
        // fallback must stay in place for the tool-pipe (`hasFalloff_`)
        // path. But feeding it dist<=0 straight from this command's own
        // param inverted the meaning: instead of "no local effect", it
        // became "affect the whole mesh" (task 0318 fuzz report). Reject
        // it as invalid input instead, mirroring the strength_ guard
        // above; a genuinely tiny-but-positive dist (e.g. 0.001) still
        // falls through to the normal sphere math and correctly no-ops
        // when nothing is within radius.
        if (!hasFalloff_ && dist_ <= 1e-9f) return false;

        // Build moving set (same mask as mesh.jitter).
        //
        // Perf (task 0388): `mesh.selectedX` is a @property that rebuilds a
        // whole `bool[]` per read — indexing it inside these loops was
        // O(mesh²). Iterate the lock-step `*Marks.length` and test via the
        // non-allocating `isXSelected(i)` scalar accessor instead.
        bool[] vmask = new bool[](mesh.vertices.length);
        bool any = false;
        if (editMode == EditMode.Vertices) {
            foreach (i; 0 .. mesh.vertexMarks.length)
                if (mesh.isVertexSelected(i)) { vmask[i] = true; any = true; }
        } else if (editMode == EditMode.Edges) {
            foreach (i; 0 .. mesh.edgeMarks.length)
                if (mesh.isEdgeSelected(i))
                    foreach (vi; mesh.edges[i]) { vmask[vi] = true; any = true; }
        } else {
            foreach (i; 0 .. mesh.faceMarks.length)
                if (mesh.isFaceSelected(i))
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
        return true;
    }
}
