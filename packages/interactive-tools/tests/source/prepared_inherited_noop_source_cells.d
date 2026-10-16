module prepared_inherited_noop_source_cells;

import prepared_inherited_noop;
import core.atomic : atomicOp;
import tool : Tool;
import tools.create.arc : ArcTool;
import tools.alignment.array_tool : ArrayTool;
import tools.deform.bend : BendTool;
import tools.create.box : BoxTool;
import tools.edit.bridge_tool : BridgeTool;
import tools.create.capsule : CapsuleTool;
import tools.alignment.clone_tool : CloneTool;
import tools.create.cone : ConeTool;
import tools.create.cylinder : CylinderTool;
import tools.edit.edge_bevel : EdgeBevelTool;
import tools.edit.edge_extrude : EdgeExtrudeTool;
import tools.slice.edge_slice_tool : EdgeSliceTool;
import tools.slice.edge_slide : EdgeSlideTool;
import tools.alignment.linear_align_tool : LinearAlignTool;
import tools.slice.loop_slice_tool : LoopSliceTool;
import tools.deform.magnet : MagnetTool;
import tools.alignment.mirror : MirrorTool;
import tools.edit.poly_bevel : PolyBevelTool;
import tools.edit.poly_extrude : PolyExtrudeTool;
import tools.edit.poly_inset_tool : PolyInsetTool;
import tools.deform.push : PushTool;
import tools.alignment.radial_align_tool : RadialAlignTool;
import tools.alignment.radial_array_tool : RadialArrayTool;
import tools.alignment.radial_sweep_tool : RadialSweepTool;
import tools.edit.reduce : ReductionTool;
import tools.slice.slice_tool : SliceTool;
import tools.deform.smooth_shift_tool : SmoothShiftTool;
import tools.create.sphere : SphereTool;
import tools.deform.stroke_extrude_tool : StrokeExtrudeTool;
import tools.edit.tack : TackTool;
import tools.create.torus : TorusTool;
import tools.create.tube : TubeTool;
import tools.edit.vertex_bevel_tool : VertexBevelTool;
import tools.edit.vertex_extrude_tool : VertexExtrudeTool;
import tools.edit.vert_merge_tool : VertexMergeTool;
import tools.create.vertex_place : VertexTool;
import tools.common.command_wrapper : XfrmJitterTool, XfrmQuantizeTool,
                                      XfrmSmoothTool;
import prepared_record_context : PreparedRecordContext;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedInheritedNoopEffect,
                              PreparedInheritedNoopKind, OwnedId;

unittest {
    import command_history : CommandHistory;
    import mesh : Mesh;
    import mesh_gpu : GpuMesh;
    import prepared_record_context : PreparedRecordContext;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import tools.create.arc : ArcTool;

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
