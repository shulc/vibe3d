module vibe3d.editing.tools.interactive.prepared_inherited_noop_source_cells;

import vibe3d.editing.tools.interactive.prepared_inherited_noop;
import core.atomic : atomicOp;
import vibe3d.editing.tools.interactive.tool : Tool;
import vibe3d.editing.tools.interactive.tools.create.arc : ArcTool;
import vibe3d.editing.tools.interactive.tools.alignment.array_tool : ArrayTool;
import vibe3d.editing.tools.interactive.tools.deform.bend : BendTool;
import vibe3d.editing.tools.interactive.tools.create.box : BoxTool;
import vibe3d.editing.tools.interactive.tools.edit.bridge_tool : BridgeTool;
import vibe3d.editing.tools.interactive.tools.create.capsule : CapsuleTool;
import vibe3d.editing.tools.interactive.tools.alignment.clone_tool : CloneTool;
import vibe3d.editing.tools.interactive.tools.create.cone : ConeTool;
import vibe3d.editing.tools.interactive.tools.create.cylinder : CylinderTool;
import vibe3d.editing.tools.interactive.tools.edit.edge_bevel : EdgeBevelTool;
import vibe3d.editing.tools.interactive.tools.edit.edge_extrude : EdgeExtrudeTool;
import vibe3d.editing.tools.interactive.tools.slice.edge_slice_tool : EdgeSliceTool;
import vibe3d.editing.tools.interactive.tools.slice.edge_slide : EdgeSlideTool;
import vibe3d.editing.tools.interactive.tools.alignment.linear_align_tool : LinearAlignTool;
import vibe3d.editing.tools.interactive.tools.slice.loop_slice_tool : LoopSliceTool;
import vibe3d.editing.tools.interactive.tools.deform.magnet : MagnetTool;
import vibe3d.editing.tools.interactive.tools.alignment.mirror : MirrorTool;
import vibe3d.editing.tools.interactive.tools.edit.poly_bevel : PolyBevelTool;
import vibe3d.editing.tools.interactive.tools.edit.poly_extrude : PolyExtrudeTool;
import vibe3d.editing.tools.interactive.tools.edit.poly_inset_tool : PolyInsetTool;
import vibe3d.editing.tools.interactive.tools.deform.push : PushTool;
import vibe3d.editing.tools.interactive.tools.alignment.radial_align_tool : RadialAlignTool;
import vibe3d.editing.tools.interactive.tools.alignment.radial_array_tool : RadialArrayTool;
import vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool : RadialSweepTool;
import vibe3d.editing.tools.interactive.tools.edit.reduce : ReductionTool;
import vibe3d.editing.tools.interactive.tools.slice.slice_tool : SliceTool;
import vibe3d.editing.tools.interactive.tools.deform.smooth_shift_tool : SmoothShiftTool;
import vibe3d.editing.tools.interactive.tools.create.sphere : SphereTool;
import vibe3d.editing.tools.interactive.tools.deform.stroke_extrude_tool : StrokeExtrudeTool;
import vibe3d.editing.tools.interactive.tools.edit.tack : TackTool;
import vibe3d.editing.tools.interactive.tools.create.torus : TorusTool;
import vibe3d.editing.tools.interactive.tools.create.tube : TubeTool;
import vibe3d.editing.tools.interactive.tools.edit.vertex_bevel_tool : VertexBevelTool;
import vibe3d.editing.tools.interactive.tools.edit.vertex_extrude_tool : VertexExtrudeTool;
import vibe3d.editing.tools.interactive.tools.edit.vert_merge_tool : VertexMergeTool;
import vibe3d.editing.tools.interactive.tools.create.vertex_place : VertexTool;
import vibe3d.editing.tools.interactive.tools.common.command_wrapper : XfrmJitterTool, XfrmQuantizeTool,
                                      XfrmSmoothTool;
import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedInheritedNoopEffect,
                              PreparedInheritedNoopKind, OwnedId;

unittest {
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.mesh.core.mesh : Mesh;
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;
    import vibe3d.viewport.gpu.shader : LitShader;
    import vibe3d.editing.tools.interactive.tools.create.arc : ArcTool;

    Mesh mesh;
    GpuMesh gpu;
    auto target = new ArcTool(() => &mesh, &gpu, LitShader.init);

    foreach (kind; [PreparedInheritedNoopKind.Update]) {
        auto owner = PreparedInheritedNoopOwner.prepare(target, kind);
        auto context = new PreparedRecordContext(new CommandHistory(),
                                                  new RecordObserverHub());
        assert(owner !is null && owner.kind == kind &&
            context.prepareInheritedNoop(owner) &&
            context.markNoHistoryInstall() && context.validate());
        context.install();
        context.install();
        assert(owner.consumedForTest &&
               context.installTraceForTest == [17, 8]);
    }

    foreach (ownerIdentity; [false, true]) {
        auto wrong = PreparedInheritedNoopOwner.prepare(
            target, PreparedInheritedNoopKind.Update);
        assert(wrong.begin());
        wrong.corruptPreparedForTest(ownerIdentity);
        assert(!wrong.validate());
        wrong.abort();
        assert(wrong.consumedForTest);

        auto validated = PreparedInheritedNoopOwner.prepare(
            target, PreparedInheritedNoopKind.Update);
        assert(validated.begin() && validated.validate());
        validated.corruptValidatedForTest(ownerIdentity);
        validated.install();
        assert(!validated.consumedForTest);
        validated.abort();
        assert(validated.consumedForTest);
    }

    auto aborted = PreparedInheritedNoopOwner.prepare(
        target, PreparedInheritedNoopKind.Update);
    assert(aborted.begin());
    aborted.abort();
    assert(aborted.consumedForTest && !aborted.begin());

    // A throw after begin is terminal for this owner and leaves no journal
    // entry.  Discard makes the old context inert; a fresh pair can retry.
    auto faultOwner = PreparedInheritedNoopOwner.prepare(
        target, PreparedInheritedNoopKind.Update);
    auto fault = new PreparedRecordContext(new CommandHistory(),
                                            new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    bool threw;
    try fault.prepareInheritedNoop(faultOwner);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && faultOwner.consumedForTest &&
           fault.resourceCountForTest == 0);
    fault.discard();
    assert(!fault.validate());

    auto retryOwner = PreparedInheritedNoopOwner.prepare(
        target, PreparedInheritedNoopKind.Update);
    auto retry = new PreparedRecordContext(new CommandHistory(),
                                            new RecordObserverHub());
    assert(retry.prepareInheritedNoop(retryOwner) &&
           retry.markNoHistoryInstall() && retry.validate());
    retry.discard();
    assert(retryOwner.consumedForTest && !retry.validate());

    // Dormant producer preserves zero-live/no-history behavior for both exact
    // effective roots and never validates or installs early.
    foreach (kind; [PreparedInheritedNoopKind.Update]) {
        auto producerContext = new PreparedRecordContext(new CommandHistory(),
            new RecordObserverHub());
        auto effect = prepareInheritedNoop(target, kind, producerContext);
        assert(effect.accepted && effect.kind == kind &&
               effect.owner == target.preparedLifecycleOwner);
        assert(producerContext.validate());
        producerContext.install();
        producerContext.install();
        assert(producerContext.installTraceForTest == [17,8]);
    }
    auto foreignContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto foreign = new Tool();          // not a closed factory product
    auto foreignEffect = prepareInheritedNoop(
        foreign,
        PreparedInheritedNoopKind.Update, foreignContext);
    assert(!foreignEffect.accepted &&
           foreignEffect.owner == foreign.preparedLifecycleOwner &&
           foreignEffect.kind == PreparedInheritedNoopKind.Update &&
           !foreignContext.validate());
    auto nullEffect = prepareInheritedNoop(target,
        PreparedInheritedNoopKind.Update, null);
    assert(!nullEffect.accepted && nullEffect.owner == target.preparedLifecycleOwner &&
           nullEffect.kind == PreparedInheritedNoopKind.Update);

    auto producerFault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    threw = false;
    try prepareInheritedNoop(target, PreparedInheritedNoopKind.Update,
                             producerFault);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && producerFault.resourceCountForTest == 0);
    producerFault.discard();
    assert(!producerFault.validate());

    auto producerRetry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto retryEffect = prepareInheritedNoop(target,
        PreparedInheritedNoopKind.Update, producerRetry);
    assert(retryEffect.accepted &&
           retryEffect.owner == target.preparedLifecycleOwner &&
           retryEffect.kind == PreparedInheritedNoopKind.Update &&
           producerRetry.validate());
    producerRetry.install();
    producerRetry.install();
    assert(producerRetry.installTraceForTest == [17,8]);
}
