module commands.mesh.radial_align;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math : Vec3;
import params : Param;
import change_bus : MeshEditScope;
import tools.align_kernels : extractAlignChain, radialAlignTargets, lerp3,
                              MAX_ALIGN_SIDES;

/// Distribute a selected vertex CHAIN at equal angular slots around a
/// circle (task 0361 — replaces the previous sphere-projection algorithm,
/// which did not match the reference "Radial Align" tool: the reference
/// has NO cylinder/sphere mode, only planar `circle`/`nside`). See
/// `tools/align_kernels.d`'s module doc comment for the full captured
/// law: center = mean chain position, radius = mean distance from
/// center, N points at equal `360/N`-degree slots in chain order.
///
/// This one-shot Command has no falloff plumbing (that lives in the
/// interactive `xfrm.radialAlignTool`, tools/radial_align_tool.d, which
/// shares this same kernel) — `weight` here is a plain uniform blend.
class MeshRadialAlign : Command, Operator {
    mixin OperatorActrCommon;
    private uint[] touchedIdx;
    private Vec3[] touchedPrev;

    private string mode_   = "circle";
    private int    side_   = 4;
    private float  rotate_ = 0.0f;
    private float  angle_  = 0.0f;
    private float  weight_ = 1.0f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.radial_align"; }
    override string label() const { return "Radial Align"; }

    // `radius`/`centerX/Y/Z` interactive override and `smooth`/`flatten`
    // (Polygons-mode-only smoothing) are intentionally not exposed — see
    // tools/radial_align_tool.d's params() doc comment (same reasoning
    // applies to this one-shot Command).
    override Param[] params() {
        return [
            Param.enum_("mode", "Mode", &mode_,
                [["circle", "Circle"], ["nside", "N-Sided"]], "circle"),
            Param.int_("side", "Side", &side_, 4)
                .min(1).max(MAX_ALIGN_SIDES).enforceBounds(),
            Param.float_("rotate", "Rotate", &rotate_, 0.0f).angle(),
            Param.float_("angle", "Angle", &angle_, 0.0f).angle(),
            Param.float_("weight", "Weight", &weight_, 1.0f)
                .min(0.0f).max(1.0f).enforceBounds(),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        auto chain = extractAlignChain(mesh, editMode);
        if (chain.verts.length < 1) return false;

        Vec3[] source = new Vec3[](chain.verts.length);
        foreach (i, vi; chain.verts) source[i] = mesh.vertices[vi];

        bool nsideMode = (mode_ == "nside");
        auto aligned = radialAlignTargets(source, nsideMode, side_, angle_, rotate_);

        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        foreach (i, vi; chain.verts) {
            touchedIdx  ~= vi;
            touchedPrev ~= mesh.vertices[vi];
            mesh.vertices[vi] = lerp3(source[i], aligned[i], weight_);
        }

        mesh.commitChange(MeshEditScope.Position);
        refreshDisplayActive(mesh);
        return true;
    }

    override bool revert() {
        if (touchedIdx.length == 0) return false;
        foreach (i, vi; touchedIdx)
            if (vi < mesh.vertices.length) mesh.vertices[vi] = touchedPrev[i];
        mesh.commitChange(MeshEditScope.Position);
        refreshDisplayActive(mesh);
        return true;
    }
}
