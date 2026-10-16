module vibe3d.editing.tools.interactive.prepared_xfrm_activation_session_source_cells;

import vibe3d.editing.tools.interactive.prepared_xfrm_activation_session;
import core.atomic : atomicOp;
import vibe3d.editing.tools.interactive.tools.transform.xfrm_transform : XfrmTransformTool,
    PreparedXfrmActivationResetImage;
import vibe3d.editing.tools.interactive.tools.transform.move : MoveTool;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.actcenter : ActionCenterStage;
import vibe3d.editing.tools.interactive.tools.transform.rotate : RotateTool;
import vibe3d.editing.tools.interactive.tools.transform.scale : ScaleTool;
import vibe3d.editing.tools.interactive.prepared_transform_product_activation :
    PreparedTransformProductActivationOwner;

unittest {
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import vibe3d.util.math.math : Vec3;
    import vibe3d.mesh.core.mesh : Mesh, makeCube;
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;

    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    foreach (mask; 0 .. 8) {
        auto history = new CommandHistory();
        auto tool = new XfrmTransformTool(() => &mesh, &gpu, &mode);
        tool.flagT = (mask & 1) != 0;
        tool.flagR = (mask & 2) != 0;
        tool.flagS = (mask & 4) != 0;
        // Seed the wrapper/bank pair out of sync so the install postcondition
        // cannot pass merely because both defaults happen to be false.
        tool.negScale = true;
        tool.setUndoBindings(history, null);
        tool.seedPreparedActivationResetForTest(false, true, true, true, true);
        tool.moveBank().seedPreparedProductActivationForTest();
        tool.rotateBank().seedPreparedProductActivationForTest();
        tool.scaleBank().seedPreparedProductActivationForTest();
        auto context = new PreparedRecordContext(history,
            new RecordObserverHub());
        auto effect = tool.prepareActivate(context);
        assert(effect.accepted && effect.flags == mask && effect.runId == 1 &&
            effect.owner == tool.preparedOwnerForTest() &&
            tool.preparedActivationResetSeedForTest());
        assert(history.currentRunId == 0,
            "prepared nextRun mutated live history");
        assert(context.validate()); context.install(); context.install();
        assert(history.currentRunId == 1 &&
            context.installTraceForTest() == [18, 1, 19] &&
            tool.preparedActivationResetPostForTest(true, true, true));
        assert(tool.preparedBankInputsForTest(),
            "prepared Xfrm activation must install wrapper negScale into "
            ~ "the embedded Scale input bank");
        if (tool.flagT) assert(tool.moveBank().preparedProductActivationForTest());
        else assert(tool.moveBank().preparedProductActivationSeedForTest());
        if (tool.flagR)
            assert(tool.rotateBank().preparedProductActivationForTest());
        else assert(tool.rotateBank().preparedProductActivationSeedForTest());
        if (tool.flagS) assert(tool.scaleBank().preparedProductActivationForTest());
        else assert(tool.scaleBank().preparedProductActivationSeedForTest());
    }

    // The legacy null-history arm skips nextRun but preserves the same phase
    // position with a NoHistory marker.
    auto noHistoryTool = new XfrmTransformTool(() => &mesh, &gpu, &mode);
    noHistoryTool.flagT = noHistoryTool.flagR = noHistoryTool.flagS = false;
    noHistoryTool.seedPreparedActivationResetForTest(false, false,
        false, true, false);
    auto noHistoryContext = new PreparedRecordContext(null,
        new RecordObserverHub());
    auto noHistoryEffect = noHistoryTool.prepareActivate(noHistoryContext);
    assert(noHistoryEffect.accepted && noHistoryEffect.runId == 0 &&
        noHistoryContext.validate());
    noHistoryContext.install(); noHistoryContext.install();
    assert(noHistoryContext.installTraceForTest() == [18, 8, 19] &&
        noHistoryTool.preparedActivationResetPostForTest(false, true, false));

    // Exact admission and captured flags/sub identities are validated before
    // the first install.
    class DerivedXfrm : XfrmTransformTool {
        this(Mesh* delegate() source, GpuMesh* gpu_, EditMode* mode_) {
            super(source, gpu_, mode_);
        }
        override void activate() { super.activate(); }
    }
    auto derived = new DerivedXfrm(() => &mesh, &gpu, &mode);
    assert(PreparedXfrmActivationSessionOwner.prepare(derived) is null);

    // The context owns the closed Pre -> marker -> Post grammar.
    auto orderTool = new XfrmTransformTool(() => &mesh, &gpu, &mode);
    orderTool.flagT = orderTool.flagR = orderTool.flagS = false;
    auto markerFirst = new PreparedRecordContext(null, new RecordObserverHub());
    assert(markerFirst.markNoHistoryInstall());
    auto markerFirstOwner = PreparedXfrmActivationSessionOwner.prepare(orderTool);
    assert(!markerFirst.prepareXfrmActivationPre(markerFirstOwner));
    markerFirst.discard(); markerFirstOwner.abort();
    auto missingMarker = new PreparedRecordContext(null, new RecordObserverHub());
    auto missingOwner = PreparedXfrmActivationSessionOwner.prepare(orderTool);
    assert(missingMarker.prepareXfrmActivationPre(missingOwner));
    assert(!missingMarker.prepareXfrmActivationPost(missingOwner));
    assert(!missingMarker.validate() && missingOwner.payloadEmpty());
    auto missingPost = new PreparedRecordContext(null, new RecordObserverHub());
    auto missingPostOwner = PreparedXfrmActivationSessionOwner.prepare(orderTool);
    assert(missingPost.prepareXfrmActivationPre(missingPostOwner) &&
        missingPost.markNoHistoryInstall());
    assert(!missingPost.validate() && missingPostOwner.payloadEmpty());
    auto duplicate = new PreparedRecordContext(null, new RecordObserverHub());
    auto duplicateOwner = PreparedXfrmActivationSessionOwner.prepare(orderTool);
    assert(duplicate.prepareXfrmActivationPre(duplicateOwner));
    assert(!duplicate.prepareXfrmActivationPre(duplicateOwner));
    duplicate.discard();

    // A tool bound to one history refuses a context owned by another.
    auto expectedHistory = new CommandHistory();
    auto wrongHistoryTool = new XfrmTransformTool(() => &mesh, &gpu, &mode);
    wrongHistoryTool.setUndoBindings(expectedHistory, null);
    auto mismatchedHistory = new CommandHistory();
    auto wrongHistory = new PreparedRecordContext(mismatchedHistory,
        new RecordObserverHub());
    assert(!wrongHistoryTool.prepareActivate(wrongHistory).accepted &&
        wrongHistory.resourceCountForTest() == 0 && !wrongHistory.validate());
    auto recoveredHistory = new PreparedRecordContext(mismatchedHistory,
        new RecordObserverHub());
    assert(recoveredHistory.markNoHistoryInstall() && recoveredHistory.validate());
    recoveredHistory.discard();

    // Both phase tokens bind owner and generation before and after validation.
    foreach (post; [false, true]) foreach (ownerIdentity; [false, true]) {
        auto corrupt = PreparedXfrmActivationSessionOwner.prepare(orderTool);
        assert(corrupt.beginPre() && corrupt.beginPost());
        corrupt.corruptPreparedForTest(post, ownerIdentity);
        bool valid = corrupt.validatePre();
        if (valid) valid = corrupt.validatePost();
        assert(!valid); corrupt.abort(); assert(corrupt.payloadEmpty());

        auto corruptValidated =
            PreparedXfrmActivationSessionOwner.prepare(orderTool);
        assert(corruptValidated.beginPre() && corruptValidated.beginPost() &&
            corruptValidated.validatePre() && corruptValidated.validatePost());
        corruptValidated.corruptValidatedForTest(post, ownerIdentity);
        corruptValidated.installPre(); corruptValidated.installPost();
        corruptValidated.abort(); assert(corruptValidated.payloadEmpty());
    }

    auto changed = new XfrmTransformTool(() => &mesh, &gpu, &mode);
    changed.flagT = true; changed.flagR = changed.flagS = false;
    auto changedOwner = PreparedXfrmActivationSessionOwner.prepare(changed);
    auto changedContext = new PreparedRecordContext(null,
        new RecordObserverHub());
    assert(changedContext.prepareXfrmActivationPre(changedOwner));
    assert(changedContext.markNoHistoryInstall());
    assert(changedContext.prepareXfrmActivationPost(changedOwner));
    changed.flagT = false;
    assert(!changedContext.validate() && changedOwner.payloadEmpty());

    // Validation is the final live-shape read. Commit consumes only validated
    // scalar tokens and the captured image, so a later flag write cannot split
    // wrapper/history/post installation.
    auto postValidate = new XfrmTransformTool(() => &mesh, &gpu, &mode);
    postValidate.flagT = true; postValidate.flagR = postValidate.flagS = false;
    postValidate.seedPreparedActivationResetForTest(false, false,
        false, true, false);
    auto postValidateContext = new PreparedRecordContext(null,
        new RecordObserverHub());
    auto postValidateEffect = postValidate.prepareActivate(postValidateContext);
    assert(postValidateEffect.accepted && postValidateContext.validate());
    postValidate.flagT = false;
    postValidateContext.install();
    assert(postValidateContext.installTraceForTest() == [18, 8, 19] &&
        postValidate.preparedActivationResetPostForTest(false, true, false));

    // Failure after either phase begin is terminal and a fresh owner retries.
    auto faultTool = new XfrmTransformTool(() => &mesh, &gpu, &mode);
    faultTool.flagT = faultTool.flagR = faultTool.flagS = false;
    auto preFaultOwner = PreparedXfrmActivationSessionOwner.prepare(faultTool);
    auto preFault = new PreparedRecordContext(null, new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try preFault.prepareXfrmActivationPre(preFaultOwner);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && preFaultOwner.payloadEmpty()); preFault.discard();

    auto postFaultOwner = PreparedXfrmActivationSessionOwner.prepare(faultTool);
    auto postFault = new PreparedRecordContext(null, new RecordObserverHub());
    assert(postFault.prepareXfrmActivationPre(postFaultOwner) &&
        postFault.markNoHistoryInstall());
    PreparedRecordContext.failAfterResourceBeginForTest(true); threw = false;
    try postFault.prepareXfrmActivationPost(postFaultOwner);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && postFaultOwner.payloadEmpty()); postFault.discard();
    auto retry = new PreparedRecordContext(null, new RecordObserverHub());
    auto retryOwner = PreparedXfrmActivationSessionOwner.prepare(faultTool);
    assert(retry.prepareXfrmActivationPre(retryOwner) &&
        retry.markNoHistoryInstall() &&
        retry.prepareXfrmActivationPost(retryOwner) && retry.validate());
    retry.discard(); assert(retryOwner.payloadEmpty());
}
