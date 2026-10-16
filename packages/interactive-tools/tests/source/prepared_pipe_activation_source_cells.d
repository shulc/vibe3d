module prepared_pipe_activation_source_cells;

import prepared_pipe_activation;
import pipe_gizmo_host : PipeGizmoHost;
import registry : PreparedPipeAttrs;
import toolpipe.pipeline : Pipeline;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.stages.axis : AxisStage;
import toolpipe.stages.constrain : ConstrainStage,
    PreparedConstrainCompositionProjection;
import toolpipe.stages.falloff : FalloffStage, PreparedFalloffAutoFit;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : FalloffType, FalloffShape, ElementMode;
import tool_activation_ownership : PipeArmScope;
import toolpipe.attr_cache : NodeAttrs, recallNodeAttrs;
import toolpipe.stage : Stage, TaskCode;
import toolpipe.stages.snap : SnapStage;
import toolpipe.guide : SnapGuide;

unittest {
    import vibe3d.editing.pipeline.contracts.toolpipe.packets : ConstrainGeom;
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
    assert(!constrain.enabled && constrain.geom == ConstrainGeom.Off &&
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
