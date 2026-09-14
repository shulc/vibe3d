module prepared_pipe_activation;

import pipe_gizmo_host : PipeGizmoHost;

import registry : PreparedPipeAttrs;
import toolpipe.pipeline : Pipeline;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.stages.axis : AxisStage;
import toolpipe.stages.constrain : ConstrainStage,
    PreparedConstrainCompositionProjection;
import toolpipe.stages.falloff : FalloffStage, PreparedFalloffAutoFit;
import toolpipe.packets : FalloffType, FalloffShape, ElementMode;
import tool_activation_ownership : PipeArmScope;

/// Owner-held prepared image for the universal tool-switch pipe prefix.
/// References stay inside this final owner; no reference enters the closed
/// PreparedToolEffect value algebra.
final class PreparedPipeActivationOwner {
private:
    PipeGizmoHost gizmoHost_;
    ActionCenterStage acen_;
    AxisStage axis_;
    ConstrainStage constrain_;
    FalloffStage falloff_;

    ActionCenterStage.Mode acenBefore_;
    bool acenLockedBefore_;
    // Task 5911: claim bits are part of the prepared image's stale witness.
    bool acenClaimedBefore_;
    uint acenEpochBefore_;
    AxisStage.Mode axisBefore_;
    bool axisLockedBefore_;
    bool axisClaimedBefore_;
    uint axisEpochBefore_;
    PreparedConstrainCompositionProjection constrainBefore_;
    FalloffType falloffTypeBefore_;
    FalloffShape falloffShapeBefore_;
    ElementMode falloffModeBefore_;
    bool falloffTransparentBefore_, falloffLockedBefore_;
    bool falloffClaimedBefore_;
    uint falloffEpochBefore_;

    bool hasAcen_, hasAxis_, hasFalloff_;
    ActionCenterStage.Mode acenMode_;
    AxisStage.Mode axisMode_;
    FalloffType falloffType_;
    FalloffShape falloffShape_;
    ElementMode falloffMode_;
    bool falloffTransparent_;
    string acenWire_, axisWire_, falloffTypeWire_, falloffShapeWire_;
    PreparedFalloffAutoFit falloffAutoFit_;
    PipeArmScope armScope_;

public:
    static PreparedPipeActivationOwner prepare(ref Pipeline pipeline,
                                                in PreparedPipeAttrs attrs,
                                                PipeGizmoHost gizmoHost = null,
                                                PipeArmScope armScope = PipeArmScope.presetArm) {
        auto result = new PreparedPipeActivationOwner();
        result.armScope_ = armScope;
        result.gizmoHost_ = gizmoHost;
        result.acen_ = cast(ActionCenterStage)pipeline.findById("actionCenter");
        result.axis_ = cast(AxisStage)pipeline.findById("axis");
        result.constrain_ = cast(ConstrainStage)pipeline.findById("constrain");
        result.falloff_ = cast(FalloffStage)pipeline.findById("falloff");
        if (result.acen_ is null || result.axis_ is null ||
            result.constrain_ is null || result.falloff_ is null)
            throw new Exception("prepared pipe activation requires all transient stages");

        result.acenBefore_ = result.acen_.mode;
        result.acenLockedBefore_ = result.acen_.userLocked;
        result.acenClaimedBefore_ = result.acen_.presetClaimed();
        result.acenEpochBefore_ = result.acen_.slotEpoch;
        result.axisBefore_ = result.axis_.mode;
        result.axisLockedBefore_ = result.axis_.userLocked;
        result.axisClaimedBefore_ = result.axis_.presetClaimed();
        result.axisEpochBefore_ = result.axis_.slotEpoch;
        result.constrainBefore_ = result.constrain_.capturePreparedCompositionProjection();
        result.falloffTypeBefore_ = result.falloff_.type;
        result.falloffShapeBefore_ = result.falloff_.shape;
        result.falloffModeBefore_ = result.falloff_.elementMode;
        result.falloffTransparentBefore_ = result.falloff_.transparent;
        result.falloffLockedBefore_ = result.falloff_.userLocked;
        result.falloffClaimedBefore_ = result.falloff_.presetClaimed();
        result.falloffEpochBefore_ = result.falloff_.slotEpoch;

        result.acenMode_ = result.acen_.userLocked
            ? result.acen_.mode : ActionCenterStage.Mode.None;
        result.axisMode_ = result.axis_.userLocked
            ? result.axis_.mode : AxisStage.Mode.None;
        result.falloffType_ = result.falloff_.userLocked
            ? result.falloff_.type : FalloffType.None;
        result.falloffShape_ = result.falloff_.userLocked
            ? result.falloff_.shape : FalloffShape.Linear;
        result.falloffMode_ = result.falloff_.userLocked
            ? result.falloff_.elementMode : ElementMode.Auto;
        result.falloffTransparent_ = result.falloff_.userLocked
            ? result.falloff_.transparent : false;

        foreach (stageId, stageAttrs; attrs) {
            switch (stageId) {
            case "actionCenter":
                result.hasAcen_ = true;
                result.acenMode_ = ActionCenterStage.Mode.None;
                foreach (name, value; stageAttrs) {
                    if (name != "mode" || !ActionCenterStage.parsePreparedMode(value, result.acenMode_))
                        throw new Exception("invalid prepared action-center preset attr");
                    result.acenWire_ = value.idup;
                }
                if (result.acenWire_.length == 0)
                    throw new Exception("prepared action-center preset requires mode");
                break;
            case "axis":
                result.hasAxis_ = true;
                result.axisMode_ = AxisStage.Mode.None;
                foreach (name, value; stageAttrs) {
                    if (name != "mode" || !AxisStage.parsePreparedMode(value, result.axisMode_))
                        throw new Exception("invalid prepared axis preset attr");
                    result.axisWire_ = value.idup;
                }
                if (result.axisWire_.length == 0)
                    throw new Exception("prepared axis preset requires mode");
                break;
            case "falloff":
                result.hasFalloff_ = true;
                result.falloffType_ = FalloffType.None;
                result.falloffShape_ = FalloffShape.Linear;
                result.falloffMode_ = ElementMode.Auto;
                result.falloffTransparent_ = false;
                foreach (name, value; stageAttrs) {
                    switch (name) {
                    case "type":
                        if (!FalloffStage.parsePreparedType(value, result.falloffType_))
                            throw new Exception("invalid prepared falloff type");
                        result.falloffTypeWire_ = value.idup;
                        break;
                    case "shape":
                        if (!FalloffStage.parsePreparedShape(value, result.falloffShape_))
                            throw new Exception("invalid prepared falloff shape");
                        break;
                    case "mode":
                        if (!FalloffStage.parsePreparedElementMode(value, result.falloffMode_))
                            throw new Exception("invalid prepared falloff mode");
                        break;
                    case "transparent":
                        if (!FalloffStage.parsePreparedTransparent(value, result.falloffTransparent_))
                            throw new Exception("invalid prepared falloff transparent");
                        break;
                    default: throw new Exception("unsupported prepared falloff preset attr");
                    }
                }
                if (result.falloffTypeWire_.length == 0)
                    throw new Exception("prepared falloff preset requires type");
                result.falloffShapeWire_ =
                    FalloffStage.preparedShapeWire(result.falloffShape_).idup;
                break;
            default: throw new Exception("unsupported prepared pipe preset stage");
            }
        }
        final switch (armScope) {
            case PipeArmScope.presetArm:
                break;
            case PipeArmScope.replayRestore:
                if (result.acen_.userLocked) result.hasAcen_ = false;
                if (result.axis_.userLocked) result.hasAxis_ = false;
                if (result.falloff_.userLocked) result.hasFalloff_ = false;
                break;
            case PipeArmScope.keepPipe:
                result.hasAcen_ = result.hasAxis_ = result.hasFalloff_ = false;
                break;
        }
        if (result.hasFalloff_)
            result.falloffAutoFit_ = result.falloff_
                .prepareAutoFitForActivation(result.falloffType_);
        return result;
    }

    bool validate() const nothrow @nogc {
        return acen_.mode == acenBefore_ && acen_.userLocked == acenLockedBefore_ &&
            acen_.presetClaimed() == acenClaimedBefore_ &&
            acen_.slotEpoch == acenEpochBefore_ && axis_.mode == axisBefore_ &&
            axis_.userLocked == axisLockedBefore_ && axis_.slotEpoch == axisEpochBefore_ &&
            axis_.presetClaimed() == axisClaimedBefore_ &&
            constrain_.matchesPreparedCompositionProjection(constrainBefore_) &&
            falloff_.type == falloffTypeBefore_ && falloff_.shape == falloffShapeBefore_ &&
            falloff_.elementMode == falloffModeBefore_ &&
            falloff_.transparent == falloffTransparentBefore_ &&
            falloff_.userLocked == falloffLockedBefore_ &&
            falloff_.presetClaimed() == falloffClaimedBefore_ &&
            falloff_.slotEpoch == falloffEpochBefore_;
    }

    void install() nothrow {
        if (gizmoHost_ !is null) gizmoHost_.cancelDrag();
        if (armScope_ == PipeArmScope.keepPipe) return;
        if (hasAcen_) acen_.claimForPreset();
        if (hasAxis_) axis_.claimForPreset();
        if (hasFalloff_) falloff_.claimForPreset();
        acen_.installPreparedTransientReset();
        axis_.installPreparedTransientReset();
        constrain_.installPreparedTransientReset();
        falloff_.installPreparedTransientReset();
        if (hasAcen_) acen_.installPreparedMode(acenMode_, acenWire_);
        if (hasAxis_) axis_.installPreparedMode(axisMode_, axisWire_);
        if (hasFalloff_) {
            falloff_.installPreparedPreset(falloffType_, falloffShape_,
                falloffMode_, falloffTransparent_, falloffTypeWire_, falloffShapeWire_);
            falloff_.installPreparedAutoFit(falloffAutoFit_);
        }
        if (hasAcen_) acen_.claimForPreset();
        if (hasAxis_) axis_.claimForPreset();
        if (hasFalloff_) falloff_.claimForPreset();
    }
}

unittest {
    import toolpipe.packets : ConstrainGeom;
    import pipe_gizmo_host : PipeGizmoHost;

    Pipeline pipeline;
    auto acen = new ActionCenterStage(null, null);
    auto axis = new AxisStage();
    auto constrain = new ConstrainStage();
    auto falloff = new FalloffStage();
    pipeline.add(acen);
    pipeline.add(axis);
    pipeline.add(constrain);
    pipeline.add(falloff);

    acen.mode = ActionCenterStage.Mode.Origin;
    axis.mode = AxisStage.Mode.World;
    constrain.enabled = true;
    constrain.geom = ConstrainGeom.Screen;
    constrain.offset = 7.0f;
    falloff.type = FalloffType.Linear;
    falloff.shape = FalloffShape.EaseOut;

    char[] stageBuf = "falloff".dup;
    char[] keyBuf = "shape".dup;
    char[] valueBuf = "smooth".dup;
    PreparedPipeAttrs attrs;
    attrs[cast(string)stageBuf] = [cast(string)keyBuf: cast(string)valueBuf,
        "type": "radial", "mode": "edgeCent", "transparent": "true"];
    attrs["actionCenter"] = ["mode": "border"];
    attrs["axis"] = ["mode": "element"];

    auto gizmoHost = new PipeGizmoHost();
    auto prepared = PreparedPipeActivationOwner.prepare(pipeline, attrs, gizmoHost);
    assert(acen.mode == ActionCenterStage.Mode.Origin &&
           axis.mode == AxisStage.Mode.World && constrain.enabled &&
           falloff.type == FalloffType.Linear,
           "prepared pipe activation wrote live state during prepare");
    stageBuf[] = 'x';
    keyBuf[] = 'x';
    valueBuf[] = 'x';
    assert(prepared.validate(),
           "prepared pipe activation borrowed descriptor storage");

    prepared.install();
    assert(gizmoHost.preparedCancelCountForTest == 1,
        "prepared pipe activation omitted the one-shot gizmo cancel");
    assert(acen.mode == ActionCenterStage.Mode.Border &&
           axis.mode == AxisStage.Mode.Element,
           "prepared pipe activation omitted ACEN/Axis preset install");
    assert(!constrain.enabled && constrain.geom == ConstrainGeom.Point &&
           constrain.offset == 0.0f,
           "prepared pipe activation omitted Constrain reset");
    assert(falloff.type == FalloffType.Radial &&
           falloff.shape == FalloffShape.Smooth &&
           falloff.elementMode == ElementMode.Edge && falloff.transparent,
           "prepared pipe activation omitted Falloff preset image");

    PreparedPipeAttrs invalid = ["axis": ["mode": "world"],
                                 "falloff": ["type": "not-a-type"]];
    const acenBefore = acen.mode;
    const axisBefore = axis.mode;
    const falloffBefore = falloff.type;
    bool rejected;
    try PreparedPipeActivationOwner.prepare(pipeline, invalid);
    catch (Exception) rejected = true;
    assert(rejected && acen.mode == acenBefore && axis.mode == axisBefore &&
           falloff.type == falloffBefore,
           "invalid prepared pipe descriptor partially mutated live stages");

    auto stale = PreparedPipeActivationOwner.prepare(pipeline, PreparedPipeAttrs.init);
    constrain.offset = 3.0f;
    assert(!stale.validate(),
           "prepared pipe stale witness omitted Constrain offset");

    falloff.userLocked = true;
    falloff.type = FalloffType.Linear;
    falloff.shape = FalloffShape.Custom;
    falloff.elementMode = ElementMode.Polygon;
    falloff.transparent = true;
    auto locked = PreparedPipeActivationOwner.prepare(pipeline,
        ["actionCenter": ["mode": "origin"]]);
    locked.install();
    assert(falloff.userLocked && falloff.type == FalloffType.Linear &&
           falloff.shape == FalloffShape.Custom &&
           falloff.elementMode == ElementMode.Polygon && falloff.transparent,
           "prepared pipe reset discarded a user-locked Falloff image");
}
