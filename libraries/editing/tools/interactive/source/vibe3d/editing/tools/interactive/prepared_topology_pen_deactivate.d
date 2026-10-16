module vibe3d.editing.tools.interactive.prepared_topology_pen_deactivate;

import core.atomic : atomicOp;
import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
import vibe3d.editing.pipeline.runtime.toolpipe.pipeline : ToolPipeContext, g_pipeCtx;
import vibe3d.editing.pipeline.runtime.toolpipe.stage : TaskCode;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.snap : SnapStage, PreparedSnapPushProjection;
import vibe3d.editing.tools.interactive.tools.edit.topology_pen.tool : TopologyPenTool,
    PreparedTopologyPenDeactivateImage;

struct PreparedTopologyPenDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedTopologyPenDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextTopologyPenDeactivateOwner;

final class PreparedTopologyPenDeactivateOwner {
private:
    TopologyPenTool target_;
    PreparedTopologyPenDeactivateImage image_;
    ToolPipeContext pipe_;
    SnapStage snap_;
    PreparedSnapPushProjection snapProjection_;
    string snapOwner_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedTopologyPenDeactivateToken prepared_;
    ValidatedTopologyPenDeactivateToken validatedToken_;
public:
    @disable this();
    static PreparedTopologyPenDeactivateOwner prepare(TopologyPenTool target,
            PreparedRecordContext context) {
        if (target is null || target.classinfo !is TopologyPenTool.classinfo)
            return null;
        auto owner = new PreparedTopologyPenDeactivateOwner(target);
        owner.image_ = target.buildPreparedDeactivate(context);
        if (!owner.image_.valid) return null;
        owner.pipe_ = g_pipeCtx;
        owner.snap_ = target.preparedSnapStageForDeactivate();
        owner.snapOwner_ = target.preparedSnapArmOwner();
        if (owner.snap_ !is null)
            owner.snapProjection_ = owner.snap_.capturePreparedPushProjection();
        return owner;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is TopologyPenTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedDeactivateLocalMatches(image_) ||
            target_.preparedSnapArmOwner() != snapOwner_ || g_pipeCtx !is pipe_ ||
            !snapShapeValid()) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedDeactivate(image_);
        if (snap_ !is null) snap_.installPreparedPopEnabled(snapOwner_);
        consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
private:
    this(TopologyPenTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextTopologyPenDeactivateOwner, 1UL);
    }
    bool snapShapeValid() nothrow @nogc {
        if (pipe_ is null) return snap_ is null;
        if (!pipe_.pipeline.ownsTaskStage(TaskCode.Snap, snap_)) return false;
        return snap_ is null || snap_.matchesPreparedPushProjection(snapProjection_);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; pipe_ = null; snap_ = null; snapOwner_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
