module vibe3d.editing.tools.interactive.prepared_topology_pen_activation;

import core.atomic : atomicOp;
import vibe3d.editing.tools.interactive.tool : ToolFlag;
import vibe3d.editing.pipeline.runtime.toolpipe.pipeline : ToolPipeContext, g_pipeCtx;
import vibe3d.editing.pipeline.runtime.toolpipe.stage : TaskCode;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.snap : SnapStage, PreparedSnapPushProjection;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.constrain : ConstrainStage,
    PreparedConstrainCompositionProjection;
import vibe3d.editing.tools.interactive.tools.edit.topology_pen.tool : TopologyPenTool,
    PreparedTopologyPenActivationImage;

struct PreparedTopologyPenActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedTopologyPenActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextTopologyPenActivationOwner;

final class PreparedTopologyPenActivationOwner {
private:
    TopologyPenTool target_;
    PreparedTopologyPenActivationImage image_;
    ToolPipeContext pipe_;
    SnapStage snap_;
    ConstrainStage constrain_;
    PreparedSnapPushProjection snapProjection_;
    PreparedConstrainCompositionProjection constrainProjection_;
    string snapOwner_;
    bool composesConstraint_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedTopologyPenActivationToken prepared_;
    ValidatedTopologyPenActivationToken validatedToken_;
public:
    @disable this();
    static PreparedTopologyPenActivationOwner prepare(TopologyPenTool target) {
        if (target is null || target.classinfo !is TopologyPenTool.classinfo)
            return null;
        auto result = new PreparedTopologyPenActivationOwner(target);
        result.image_ = target.buildPreparedActivation();
        result.snapOwner_ = target.preparedSnapArmOwner();
        result.composesConstraint_ = !target.hasFlag(ToolFlag.NoBackgroundConstraint);
        result.pipe_ = g_pipeCtx;
        if (result.pipe_ !is null) {
            result.snap_ = cast(SnapStage)
                result.pipe_.pipeline.findByTask(TaskCode.Snap);
            result.constrain_ = cast(ConstrainStage)
                result.pipe_.pipeline.findByTask(TaskCode.Cons);
            if (result.snap_ !is null)
                result.snapProjection_ = result.snap_.capturePreparedPushProjection();
            if (result.constrain_ !is null)
                result.constrainProjection_ =
                    result.constrain_.capturePreparedCompositionProjection();
        }
        return result.image_.valid ? result : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is TopologyPenTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedActivationLocalMatches(image_) ||
            target_.preparedSnapArmOwner() != snapOwner_ || g_pipeCtx !is pipe_ ||
            !stageShapeValid()) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedActivation(image_);
        if (snap_ !is null) snap_.installPreparedPushEnabled(snapOwner_, true);
        if (constrain_ !is null && composesConstraint_ &&
            !constrainProjection_.userLocked)
            constrain_.installPreparedPointComposition();
        consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    version(unittest) void corruptPreparedForTest() nothrow @nogc {
        ++prepared_.generation;
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && target_ is null && pipe_ is null &&
            snap_ is null && constrain_ is null;
    }
private:
    this(TopologyPenTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextTopologyPenActivationOwner, 1UL);
    }
    bool stageShapeValid() nothrow @nogc {
        if (pipe_ is null) return snap_ is null && constrain_ is null;
        if (!pipe_.pipeline.ownsTaskStage(TaskCode.Snap, snap_) ||
            !pipe_.pipeline.ownsTaskStage(TaskCode.Cons, constrain_)) return false;
        if (snap_ !is null &&
            !snap_.matchesPreparedPushProjection(snapProjection_)) return false;
        if (constrain_ !is null &&
            !constrain_.matchesPreparedCompositionProjection(
                constrainProjection_)) return false;
        return true;
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; pipe_ = null; snap_ = null;
        constrain_ = null; snapOwner_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
