module prepared_record_context;

// P1.0b.3d dormant producer context. Production activation doors do not import
// or construct this until the single P1.0c unified cutover.
import command : Command;
import command_history : CommandHistory, PreparedHistoryKind,
                         PreparedHistoryResult, PreparedHistoryToken,
                         ValidatedPreparedHistoryToken;
import record_observer_hub : RecordObserverHub;
import mesh : Mesh;
import mesh_gpu : GpuResourceOwner, GpuUploadOwner, GpuCreateOwner;
import handler : ClickPointResourceOwner;
import snap_render : SnapOverlayOwner;
import prepared_private_state : PreparedPrivateStateOwner, PreparedPrivateStateKind;
import prepared_selection_profile : PreparedSelectionProfileOwner;
import prepared_radial_sweep_transition : PreparedRadialSweepTransitionOwner;
import document : Layer;
import change_bus : PreparedDeliveryJournal, PreparedDeliverySpec, changeBus;
import change_bus : MeshEditScope;

private enum PreparedResourceKind : ubyte {
    HistoryInstall, NoHistoryInstall, MeshInstall, DeliveryInstall, GpuMeshDestroy, GpuUpload, ClickPointDestroy
    , GpuCreate, SnapOverlayClear, BoxState, PenState, PrimitiveState, VertexState,
    ArraySessionState, CloneSessionState, MagnetSessionState, ReductionSessionState,
    RadialSweepProfileState, RadialSweepTransitionState, GestureCarrierMismatch
}
private struct PreparedResourceEntry {
    PreparedResourceKind kind;
    GpuResourceOwner gpuDestroy;
    GpuUploadOwner gpuUpload;
    GpuCreateOwner gpuCreate;
    ClickPointResourceOwner clickDestroy;
    SnapOverlayOwner snapOverlay;
    PreparedPrivateStateOwner privateState;
    PreparedSelectionProfileOwner selectionProfile;
    PreparedRadialSweepTransitionOwner radialSweepTransition;
    Layer layerMesh;
    PreparedDeliveryJournal delivery;
}

/// One fallible prepare transaction jointly owns the detached history and
/// observer evolution. Tool producers receive this owner; they never discover
/// a global history, observer, or legacy delegate.
final class PreparedRecordContext {
private:
    CommandHistory history_;
    RecordObserverHub observers_;
    PreparedHistoryToken token_;
    ValidatedPreparedHistoryToken validated_;
    bool begun_, validated_Once;
    PreparedResourceEntry[] resources_;
    ulong resourceThread_, resourceContext_;
    bool historyMarker_;
    bool noHistoryMarker_;
    version (unittest) {
        static bool failAfterResourceBegin_;
        ubyte[16] installTrace_;
        size_t installTraceLength_;
    }
public:
    this(CommandHistory history, RecordObserverHub observers) {
        history_ = history;
        observers_ = observers;
        if (history_ !is null) {
            token_ = history_.beginPrepared();
            begun_ = true;
        }
    }

    void setResourceIdentity(ulong threadIdentity, ulong contextIdentity)
                             nothrow @nogc {
        resourceThread_ = threadIdentity;
        resourceContext_ = contextIdentity;
    }

    /// Append the exact history position among resource effects. Resource
    /// transactions require exactly one marker; history-only transactions keep
    /// their historical direct install path.
    bool markHistoryInstall() {
        if (!begun_ || validated_Once || historyMarker_ || noHistoryMarker_) return false;
        resources_.reserve(resources_.length + 1);
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.HistoryInstall;
        resources_ ~= e;
        historyMarker_ = true;
        return true;
    }

    bool markNoHistoryInstall() {
        if (!begun_ || validated_Once || historyMarker_ || noHistoryMarker_) return false;
        resources_.reserve(1 + resources_.length);
        PreparedResourceEntry e; e.kind = PreparedResourceKind.NoHistoryInstall;
        resources_ ~= e; noHistoryMarker_ = true; return true;
    }

    bool prepareDestroy(GpuResourceOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(resources_.length + 1);
        if (!owner.beginEnlistedDestroy()) return false;
        scope(failure) owner.abortEnlisted();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected resource enlist failure");
        resources_ ~= PreparedResourceEntry(
            PreparedResourceKind.GpuMeshDestroy, owner);
        return true;
    }

    bool prepareUpload(GpuUploadOwner owner, ref const Mesh mesh,
                       const uint[] edgeOrigin = null,
                       const uint[] vertOrigin = null,
                       const uint[] faceOrigin = null) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(resources_.length + 1);
        if (!owner.beginEnlistedUpload(mesh, edgeOrigin, vertOrigin,
                                       faceOrigin)) return false;
        scope(failure) owner.abortEnlisted();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected resource enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.GpuUpload; e.gpuUpload = owner;
        resources_ ~= e;
        return true;
    }

    bool prepareDestroy(ClickPointResourceOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(resources_.length + 1);
        if (!owner.beginEnlistedDestroy()) return false;
        scope(failure) owner.abortEnlisted();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected resource enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.ClickPointDestroy;
        e.clickDestroy = owner;
        resources_ ~= e;
        return true;
    }

    bool prepareCreate(GpuCreateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.beginEnlistedCreate()) return false;
        scope(failure) { owner.abortEnlisted(); }
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected GPU create enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.GpuCreate;
        e.gpuCreate = owner; resources_ ~= e; return true;
    }

    bool prepareSnapClear(SnapOverlayOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.beginClear()) return false;
        scope(failure) owner.abortClear();
        PreparedResourceEntry e; e.kind = PreparedResourceKind.SnapOverlayClear;
        e.snapOverlay = owner; resources_ ~= e; return true;
    }

    bool preparePrivateState(PreparedPrivateStateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        PreparedResourceEntry e; e.privateState = owner;
        final switch (owner.kind) {
        case PreparedPrivateStateKind.Box: e.kind = PreparedResourceKind.BoxState; break;
        case PreparedPrivateStateKind.Pen: e.kind = PreparedResourceKind.PenState; break;
        case PreparedPrivateStateKind.Primitive: e.kind = PreparedResourceKind.PrimitiveState; break;
        case PreparedPrivateStateKind.Vertex: e.kind = PreparedResourceKind.VertexState; break;
        case PreparedPrivateStateKind.ArraySession: e.kind = PreparedResourceKind.ArraySessionState; break;
        case PreparedPrivateStateKind.CloneSession: e.kind = PreparedResourceKind.CloneSessionState; break;
        case PreparedPrivateStateKind.MagnetSession: e.kind = PreparedResourceKind.MagnetSessionState; break;
        case PreparedPrivateStateKind.ReductionSession: e.kind = PreparedResourceKind.ReductionSessionState; break;
        }
        resources_ ~= e; return true;
    }

    bool prepareSelectionProfile(PreparedSelectionProfileOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected selection-profile enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.RadialSweepProfileState;
        e.selectionProfile = owner; resources_ ~= e; return true;
    }

    bool prepareRadialSweepTransition(PreparedRadialSweepTransitionOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected radial-sweep transition enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.RadialSweepTransitionState;
        e.radialSweepTransition = owner; resources_ ~= e; return true;
    }

    bool prepareGestureCarrierMismatch() {
        if (!begun_ || validated_Once) return false;
        resources_.reserve(1 + resources_.length);
        PreparedResourceEntry e; e.kind = PreparedResourceKind.GestureCarrierMismatch;
        resources_ ~= e; return true;
    }

    bool prepareMeshImageCommit(Layer layer, ref const Mesh image, uint flags) {
        if (!begun_ || validated_Once || layer is null || flags == 0) return false;
        resources_.reserve(resources_.length + 2);
        if (!layer.beginEnlistedMesh()) return false;
        scope(failure) { layer.abortEnlistedMesh(); invalidateTransaction(); }
        if (!layer.replaceEnlistedShadow(image)) {
            layer.abortEnlistedMesh(); invalidateTransaction(); return false;
        }
        {
            auto shadowScope = layer.beginEnlistedShadowMutation();
            layer.enlistedShadow().commitChange(flags);
            shadowScope.close();
        }
        auto spec = layer.drainEnlistedDelivery();
        auto delivery = PreparedDeliveryJournal.prepare([spec]);
        PreparedResourceEntry meshEntry; meshEntry.kind = PreparedResourceKind.MeshInstall;
        meshEntry.layerMesh = layer; resources_ ~= meshEntry;
        PreparedResourceEntry deliveryEntry; deliveryEntry.kind = PreparedResourceKind.DeliveryInstall;
        deliveryEntry.delivery = delivery; resources_ ~= deliveryEntry;
        return true;
    }

    /// Adopt an image whose detached kernel already performed the exact
    /// legacy commitChange. Its pending delivery was drained by that kernel;
    /// do not stamp or derive the image a second time here.
    bool prepareStampedMeshImage(Layer layer, ref const Mesh image,
                                 uint flags, uint domains) {
        if (!begun_ || validated_Once || layer is null || flags == 0) return false;
        resources_.reserve(resources_.length + 2);
        if (!layer.beginEnlistedMesh()) return false;
        scope(failure) { layer.abortEnlistedMesh(); invalidateTransaction(); }
        if (!layer.replaceEnlistedShadow(image)) {
            layer.abortEnlistedMesh(); invalidateTransaction(); return false;
        }
        auto delivery = PreparedDeliveryJournal.prepare(
            [layer.enlistedDeliveryForStampedImage(flags, domains)]);
        PreparedResourceEntry meshEntry; meshEntry.kind = PreparedResourceKind.MeshInstall;
        meshEntry.layerMesh = layer; resources_ ~= meshEntry;
        PreparedResourceEntry deliveryEntry; deliveryEntry.kind = PreparedResourceKind.DeliveryInstall;
        deliveryEntry.delivery = delivery; resources_ ~= deliveryEntry;
        return true;
    }

    bool preparePositionCommit(Layer layer) {
        if (!begun_ || validated_Once || layer is null) return false;
        resources_.reserve(resources_.length + 2);
        if (!layer.beginEnlistedMesh()) return false;
        scope(failure) {
            layer.abortEnlistedMesh();
            invalidateTransaction();
        }
        {
            auto shadowScope = layer.beginEnlistedShadowMutation();
            layer.enlistedShadow().commitChange(MeshEditScope.Position);
            shadowScope.close();
        }
        auto spec = layer.drainEnlistedDelivery();
        auto delivery = PreparedDeliveryJournal.prepare([spec]);
        PreparedResourceEntry meshEntry;
        meshEntry.kind = PreparedResourceKind.MeshInstall;
        meshEntry.layerMesh = layer;
        resources_ ~= meshEntry;
        PreparedResourceEntry deliveryEntry;
        deliveryEntry.kind = PreparedResourceKind.DeliveryInstall;
        deliveryEntry.delivery = delivery;
        resources_ ~= deliveryEntry;
        return true;
    }

    PreparedHistoryResult prepare(Command cmd, PreparedHistoryKind kind,
                                  ulong runId = 0,
                                  string preparedTraceJson = null) {
        if (!begun_ || validated_Once) return PreparedHistoryResult.init;
        return history_.prepareRecord(token_, cmd, kind, runId,
                                      observers_, preparedTraceJson);
    }

    PreparedHistoryResult consolidate(ulong runId) {
        if (!begun_ || validated_Once) return PreparedHistoryResult.init;
        return history_.prepareConsolidate(token_, runId);
    }

    ulong nextRun() {
        if (!begun_ || validated_Once) return 0;
        return history_.prepareNextRun(token_);
    }

    bool validate() nothrow @nogc {
        if (!begun_ || validated_Once) return false;
        if (resources_.length > 0 && !historyMarker_) {
            if (!noHistoryMarker_) {
                invalidateTransaction();
                return false;
            }
        }
        foreach (ref e; resources_) {
            bool ok;
            final switch (e.kind) {
            case PreparedResourceKind.HistoryInstall: ok = true; break;
            case PreparedResourceKind.NoHistoryInstall: ok = true; break;
            case PreparedResourceKind.MeshInstall:
                ok = e.layerMesh.validateEnlistedMesh(); break;
            case PreparedResourceKind.DeliveryInstall:
                ok = e.delivery !is null && e.delivery.validate(); break;
            case PreparedResourceKind.GpuMeshDestroy:
                ok = e.gpuDestroy.validateEnlisted(resourceThread_, resourceContext_); break;
            case PreparedResourceKind.GpuUpload:
                ok = e.gpuUpload.validateEnlisted(resourceThread_, resourceContext_); break;
            case PreparedResourceKind.ClickPointDestroy:
                ok = e.clickDestroy.validateEnlisted(resourceThread_, resourceContext_); break;
            case PreparedResourceKind.GpuCreate:
                ok = e.gpuCreate.validateEnlisted(resourceThread_, resourceContext_); break;
            case PreparedResourceKind.SnapOverlayClear:
                ok = e.snapOverlay.validateClear(); break;
            case PreparedResourceKind.BoxState:
            case PreparedResourceKind.PenState:
            case PreparedResourceKind.PrimitiveState:
            case PreparedResourceKind.VertexState:
            case PreparedResourceKind.ArraySessionState:
            case PreparedResourceKind.CloneSessionState:
            case PreparedResourceKind.MagnetSessionState:
            case PreparedResourceKind.ReductionSessionState:
                ok = e.privateState.validate(); break;
            case PreparedResourceKind.RadialSweepProfileState:
                ok = e.selectionProfile !is null && e.selectionProfile.validate(); break;
            case PreparedResourceKind.RadialSweepTransitionState:
                ok = e.radialSweepTransition !is null && e.radialSweepTransition.validate(); break;
            case PreparedResourceKind.GestureCarrierMismatch: ok = true; break;
            }
            if (!ok) { invalidateTransaction(); return false; }
        }
        if (noHistoryMarker_) validated_Once = true;
        else {
            validated_ = history_.validatesPreparedToken(token_, observers_);
            validated_Once = validated_.valid;
        }
        if (!validated_Once) invalidateTransaction();
        return validated_Once;
    }

    void install() nothrow {
        if (!validated_Once) return;
        bool installedHistory;
        foreach (ref e; resources_) final switch (e.kind) {
        case PreparedResourceKind.HistoryInstall:
            history_.installPreparedToken(validated_); installedHistory = true;
            version (unittest) installTrace_[installTraceLength_++] = 1;
            break;
        case PreparedResourceKind.NoHistoryInstall:
            history_.discardPreparedToken(token_); installedHistory = true;
            version (unittest) installTrace_[installTraceLength_++] = 8;
            break;
        case PreparedResourceKind.MeshInstall:
            e.layerMesh.installEnlistedMesh();
            version (unittest) installTrace_[installTraceLength_++] = 3;
            break;
        case PreparedResourceKind.DeliveryInstall:
            e.delivery.replay(changeBus);
            version (unittest) installTrace_[installTraceLength_++] = 4;
            break;
        case PreparedResourceKind.GpuMeshDestroy:
            e.gpuDestroy.installEnlisted();
            version (unittest) installTrace_[installTraceLength_++] = 2;
            break;
        case PreparedResourceKind.GpuUpload:
            e.gpuUpload.installEnlisted();
            version (unittest) installTrace_[installTraceLength_++] = 2;
            break;
        case PreparedResourceKind.ClickPointDestroy:
            e.clickDestroy.installEnlisted();
            version (unittest) installTrace_[installTraceLength_++] = 2;
            break;
        case PreparedResourceKind.GpuCreate:
            e.gpuCreate.installEnlisted();
            version (unittest) installTrace_[installTraceLength_++] = 5;
            break;
        case PreparedResourceKind.SnapOverlayClear:
            e.snapOverlay.installClear();
            version (unittest) installTrace_[installTraceLength_++] = 6;
            break;
        case PreparedResourceKind.BoxState:
        case PreparedResourceKind.PenState:
        case PreparedResourceKind.PrimitiveState:
        case PreparedResourceKind.VertexState:
        case PreparedResourceKind.ArraySessionState:
        case PreparedResourceKind.CloneSessionState:
        case PreparedResourceKind.MagnetSessionState:
        case PreparedResourceKind.ReductionSessionState:
            e.privateState.install();
            version (unittest) installTrace_[installTraceLength_++] = 7;
            break;
        case PreparedResourceKind.RadialSweepProfileState:
            e.selectionProfile.install();
            version (unittest) installTrace_[installTraceLength_++] = 9;
            break;
        case PreparedResourceKind.RadialSweepTransitionState:
            e.radialSweepTransition.install();
            version (unittest) installTrace_[installTraceLength_++] = 10;
            break;
        case PreparedResourceKind.GestureCarrierMismatch:
            ++changeBus.gestureCarrierMismatch;
            version (unittest) installTrace_[installTraceLength_++] = 11;
            break;
        }
        if (!installedHistory) history_.installPreparedToken(validated_);
        resources_.length = 0;
        historyMarker_ = false;
        noHistoryMarker_ = false;
        validated_Once = false;
        begun_ = false;
    }

    void discard() nothrow @nogc {
        if (!begun_ || validated_Once) return;
        history_.discardPreparedToken(token_);
        abortResources();
        begun_ = false;
    }

private:
    void abortResources() nothrow @nogc {
        foreach (ref e; resources_) final switch (e.kind) {
        case PreparedResourceKind.HistoryInstall: break;
        case PreparedResourceKind.NoHistoryInstall: break;
        case PreparedResourceKind.MeshInstall: e.layerMesh.abortEnlistedMesh(); break;
        case PreparedResourceKind.DeliveryInstall: break;
        case PreparedResourceKind.GpuMeshDestroy: e.gpuDestroy.abortEnlisted(); break;
        case PreparedResourceKind.GpuUpload: e.gpuUpload.abortEnlisted(); break;
        case PreparedResourceKind.ClickPointDestroy: e.clickDestroy.abortEnlisted(); break;
        case PreparedResourceKind.GpuCreate: e.gpuCreate.abortEnlisted(); break;
        case PreparedResourceKind.SnapOverlayClear: e.snapOverlay.abortClear(); break;
        case PreparedResourceKind.BoxState:
        case PreparedResourceKind.PenState:
        case PreparedResourceKind.PrimitiveState:
        case PreparedResourceKind.VertexState: e.privateState.abort(); break;
        case PreparedResourceKind.ArraySessionState:
        case PreparedResourceKind.CloneSessionState:
        case PreparedResourceKind.MagnetSessionState:
        case PreparedResourceKind.ReductionSessionState: e.privateState.abort(); break;
        case PreparedResourceKind.RadialSweepProfileState: e.selectionProfile.abort(); break;
        case PreparedResourceKind.RadialSweepTransitionState: e.radialSweepTransition.abort(); break;
        case PreparedResourceKind.GestureCarrierMismatch: break;
        }
        resources_.length = 0;
        historyMarker_ = false;
        noHistoryMarker_ = false;
    }

    void invalidateTransaction() nothrow @nogc {
        abortResources();
        if (begun_ && !validated_Once) history_.discardPreparedToken(token_);
        begun_ = false;
        validated_Once = false;
    }
public:

    void installedDepths(out size_t modelDepth, out size_t uiDepth) const {
        modelDepth = 0; uiDepth = 0;
        if (history_ !is null) history_.undoDepthCounts(modelDepth, uiDepth);
    }
    version (unittest) const(ubyte)[] installTraceForTest() const nothrow @nogc {
        return installTrace_[0 .. installTraceLength_];
    }
    version (unittest) size_t resourceCountForTest() const nothrow @nogc {
        return resources_.length;
    }
    version (unittest) static void failAfterResourceBeginForTest(bool value)
            nothrow @nogc { failAfterResourceBegin_ = value; }
}

unittest {
    import command : Command, CmdFlags;
    import mesh : Mesh;
    import view : View;
    import editmode : EditMode;
    final class C : Command {
        private Mesh mesh_;
        private View view_ = new View(0, 0, 1, 1);
        this() { super(&mesh_, view_, EditMode.Vertices); }
        override string name() const { return "prepared.context.test"; }
        override string label() const { return "prepared context"; }
        override CmdFlags cmdFlags() const { return CmdFlags.Model; }
        protected override bool applyImpl() { return true; }
    }
    auto history = new CommandHistory();
    auto hub = new RecordObserverHub();
    hub.setMacroActive(true);
    auto context = new PreparedRecordContext(history, hub);
    auto result = context.prepare(new C(), PreparedHistoryKind.Plain);
    size_t models, ui;
    history.undoDepthCounts(models, ui);
    assert(result.accepted && models == 0 && hub.macroLength == 0);
    assert(context.validate());
    context.install();
    history.undoDepthCounts(models, ui);
    assert(models == 1 && hub.macroLength == 1);
    context.install();
    history.undoDepthCounts(models, ui);
    assert(models == 1 && hub.macroLength == 1);
}

version (unittest) unittest {
    import mesh : GpuMesh, makeCube;
    import handler : ClickPointHandler, ClickPointResourceOwner;
    import change_bus : changeBus;
    auto history = new CommandHistory();
    auto hub = new RecordObserverHub();

    // Resource then history (Box/Primitive ordering).
    auto firstHandle = new ClickPointHandler();
    auto firstOwner = new ClickPointResourceOwner(firstHandle, 7, 11);
    auto first = new PreparedRecordContext(history, hub);
    first.setResourceIdentity(7, 11);
    assert(first.prepareDestroy(firstOwner));
    assert(first.markHistoryInstall());
    assert(first.validate());
    first.install();
    assert(first.installTrace_[0 .. first.installTraceLength_] == [2, 1]);

    // History then resource (CommandWrapper ordering).
    auto secondHandle = new ClickPointHandler();
    auto secondOwner = new ClickPointResourceOwner(secondHandle, 7, 11);
    auto second = new PreparedRecordContext(history, hub);
    second.setResourceIdentity(7, 11);
    assert(second.markHistoryInstall());
    assert(second.prepareDestroy(secondOwner));
    assert(second.validate());
    second.install();
    assert(second.installTrace_[0 .. second.installTraceLength_] == [1, 2]);

    // Allocation/post-begin failure cannot strand an owner; discard and a
    // fresh transaction can immediately enlist the same owner.
    GpuMesh faultGpu;
    auto faultOwner = new GpuResourceOwner(&faultGpu, 7, 11);
    auto fault = new PreparedRecordContext(history, hub);
    PreparedRecordContext.failAfterResourceBegin_ = true;
    bool threw;
    try fault.prepareDestroy(faultOwner);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBegin_ = false;
    assert(threw);
    fault.discard();
    auto retry = new PreparedRecordContext(history, hub);
    retry.setResourceIdentity(7, 11);
    assert(retry.prepareDestroy(faultOwner));
    assert(retry.markHistoryInstall());
    retry.discard();

    // A joint-validation refusal is terminal: even correcting the identity
    // cannot revive or partially install the discarded transaction.
    GpuMesh refusedGpu;
    auto refusedOwner = new GpuResourceOwner(&refusedGpu, 7, 11);
    auto refused = new PreparedRecordContext(history, hub);
    refused.setResourceIdentity(8, 11);
    assert(refused.prepareDestroy(refusedOwner));
    assert(refused.markHistoryInstall());
    assert(!refused.validate());
    refused.setResourceIdentity(7, 11);
    assert(!refused.validate());
    refused.install();
    auto afterRefusal = new PreparedRecordContext(history, hub);
    afterRefusal.setResourceIdentity(7, 11);
    assert(afterRefusal.prepareDestroy(refusedOwner));
    afterRefusal.discard();

    // A delivery allocation failure happens before either Mesh/Delivery row
    // is appended and terminally clears the earlier history marker. Live
    // state stays unchanged; the Layer is immediately reusable by a fresh
    // context.
    auto faultLayer = new Layer();
    faultLayer.meshRef() = makeCube();
    const faultVersion = faultLayer.meshRef().mutationVersion;
    const faultDeliveries = changeBus.deliveryCount;
    auto meshFault = new PreparedRecordContext(new CommandHistory(),
                                               new RecordObserverHub());
    assert(meshFault.markHistoryInstall());
    PreparedDeliveryJournal.setFailPrepareForTest(true);
    threw = false;
    try meshFault.preparePositionCommit(faultLayer);
    catch (Exception) threw = true;
    PreparedDeliveryJournal.setFailPrepareForTest(false);
    assert(threw && meshFault.resourceCountForTest() == 0);
    assert(faultLayer.meshRef().mutationVersion == faultVersion);
    assert(changeBus.deliveryCount == faultDeliveries);
    assert(!meshFault.validate());
    auto meshRetry = new PreparedRecordContext(new CommandHistory(),
                                               new RecordObserverHub());
    assert(meshRetry.markHistoryInstall());
    assert(meshRetry.preparePositionCommit(faultLayer));
    assert(meshRetry.validate());
    meshRetry.install();
    assert(faultLayer.meshRef().mutationVersion == faultVersion + 1);
    assert(changeBus.deliveryCount == faultDeliveries + 1);

    GpuMesh createdGpu;
    auto createOwner = GpuCreateOwner.fakeForTest(&createdGpu);
    auto snapOwner = new SnapOverlayOwner();
    auto failedCreate = new PreparedRecordContext(new CommandHistory(),
                                                  new RecordObserverHub());
    failedCreate.setResourceIdentity(7, 11);
    PreparedRecordContext.failAfterResourceBegin_ = true;
    threw = false;
    try failedCreate.prepareCreate(createOwner);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBegin_ = false;
    assert(threw && failedCreate.resourceCountForTest() == 0);
    assert(createdGpu.faceVao == 0 && createOwner.fakeCleanupCountForTest() == 1);
    auto mixed = new PreparedRecordContext(new CommandHistory(),
                                           new RecordObserverHub());
    mixed.setResourceIdentity(7, 11);
    assert(mixed.markHistoryInstall());
    assert(mixed.prepareCreate(createOwner));
    assert(mixed.prepareSnapClear(snapOwner));
    assert(createdGpu.faceVao == 0);
    assert(mixed.validate());
    mixed.install();
    assert(createdGpu.faceVao != 0);
    assert(mixed.installTraceForTest() == [1,5,6]);

    auto topologyLayer = new Layer();
    topologyLayer.meshRef() = makeCube();
    Mesh emptyImage;
    auto topology = new PreparedRecordContext(new CommandHistory(),
                                              new RecordObserverHub());
    assert(topology.markHistoryInstall());
    assert(topology.prepareMeshImageCommit(topologyLayer, emptyImage,
                                           MeshEditScope.Geometry));
    assert(topologyLayer.meshRef().vertices.length == 8);
    assert(topology.validate()); topology.install();
    assert(topologyLayer.meshRef().vertices.length == 0);
    assert(topology.installTraceForTest() == [1,3,4]);

    auto topologyFaultLayer = new Layer();
    topologyFaultLayer.meshRef() = makeCube();
    auto topologyFault = new PreparedRecordContext(new CommandHistory(),
                                                   new RecordObserverHub());
    assert(topologyFault.markHistoryInstall());
    PreparedDeliveryJournal.setFailPrepareForTest(true);
    threw = false;
    try topologyFault.prepareMeshImageCommit(topologyFaultLayer, emptyImage,
                                             MeshEditScope.Geometry);
    catch (Exception) threw = true;
    PreparedDeliveryJournal.setFailPrepareForTest(false);
    assert(threw && topologyFault.resourceCountForTest() == 0);
    assert(topologyFaultLayer.meshRef().vertices.length == 8);
    assert(!topologyFault.validate());
    auto topologyRetry = new PreparedRecordContext(new CommandHistory(),
                                                   new RecordObserverHub());
    assert(topologyRetry.markHistoryInstall());
    assert(topologyRetry.prepareMeshImageCommit(topologyFaultLayer, emptyImage,
                                                MeshEditScope.Geometry));
    topologyRetry.discard();
    assert(topologyFaultLayer.meshRef().vertices.length == 8);
}
