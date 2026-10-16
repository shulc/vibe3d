module vibe3d.editing.tools.interactive.prepared_pipe_activation_source_cells;

import vibe3d.editing.tools.interactive.prepared_pipe_activation;
import vibe3d.editing.tools.interactive.pipe_gizmo_host : PipeGizmoHost;
import vibe3d.editing.tools.interactive.registry : PreparedPipeAttrs;
import vibe3d.editing.pipeline.runtime.toolpipe.pipeline : Pipeline;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.actcenter : ActionCenterStage;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.axis : AxisStage;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.constrain : ConstrainStage,
    PreparedConstrainCompositionProjection;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.falloff : FalloffStage, PreparedFalloffAutoFit;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : FalloffType, FalloffShape, ElementMode;
import vibe3d.editing.commands.runtime.tool_activation_ownership : PipeArmScope;
import vibe3d.editing.pipeline.evaluation.toolpipe.attr_cache : NodeAttrs, recallNodeAttrs;
import vibe3d.editing.pipeline.runtime.toolpipe.stage : Stage, TaskCode;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.snap : SnapStage;
import vibe3d.editing.selection.query.toolpipe.guide : SnapGuide;

unittest {
    import vibe3d.editing.pipeline.contracts.toolpipe.packets : ConstrainGeom;
    import vibe3d.editing.tools.interactive.pipe_gizmo_host : PipeGizmoHost;

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
