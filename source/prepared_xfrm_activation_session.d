module prepared_xfrm_activation_session;

import core.atomic : atomicOp;
import tools.transform.xfrm_transform : XfrmTransformTool,
    PreparedXfrmActivationResetImage;
import tools.transform.move : MoveTool;
import tools.transform.rotate : RotateTool;
import tools.transform.scale : ScaleTool;
import prepared_transform_product_activation :
    PreparedTransformProductActivationOwner;

struct PreparedXfrmActivationPreToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct PreparedXfrmActivationPostToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct ValidatedXfrmActivationPreToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct ValidatedXfrmActivationPostToken {
    @disable this(this);
private:
    ulong owner, generation;
}
private shared ulong nextXfrmActivationOwner;

/// Exact two-phase Xfrm activation owner. Pre installs the wrapper reset,
/// enabled product activations in T/R/S order and unconditional wrapper links.
/// Post installs routing/session tail after the prepared history marker.
final class PreparedXfrmActivationSessionOwner {
private:
    XfrmTransformTool target_;
    MoveTool move_;
    RotateTool rotate_;
    ScaleTool scale_;
    PreparedXfrmActivationResetImage reset_;
    PreparedTransformProductActivationOwner moveOwner_;
    PreparedTransformProductActivationOwner rotateOwner_;
    PreparedTransformProductActivationOwner scaleOwner_;
    immutable ulong owner_;
    ulong generation_;
    immutable ubyte flags_;
    bool preBegun_, postBegun_, validated_, preInstalled_, consumed_;
    PreparedXfrmActivationPreToken pre_;
    PreparedXfrmActivationPostToken post_;
    ValidatedXfrmActivationPreToken validatedPre_;
    ValidatedXfrmActivationPostToken validatedPost_;
public:
    @disable this();

    static PreparedXfrmActivationSessionOwner prepare(XfrmTransformTool target) {
        if (target is null || target.classinfo !is XfrmTransformTool.classinfo)
            return null;
        auto owner = new PreparedXfrmActivationSessionOwner(target);
        owner.reset_ = target.buildPreparedActivationReset();
        if (!owner.reset_.valid) return null;
        if ((owner.flags_ & 1) != 0) {
            owner.moveOwner_ = PreparedTransformProductActivationOwner.prepare(owner.move_);
            if (owner.moveOwner_ is null) { owner.reset_.clear(); return null; }
        }
        if ((owner.flags_ & 2) != 0) {
            owner.rotateOwner_ = PreparedTransformProductActivationOwner.prepare(owner.rotate_);
            if (owner.rotateOwner_ is null) { owner.scrub(); return null; }
        }
        if ((owner.flags_ & 4) != 0) {
            owner.scaleOwner_ = PreparedTransformProductActivationOwner.prepare(owner.scale_);
            if (owner.scaleOwner_ is null) { owner.scrub(); return null; }
        }
        return owner;
    }

    ubyte flags() const nothrow @nogc { return flags_; }
    bool owns(XfrmTransformTool target) const nothrow @nogc {
        return target_ is target;
    }

    bool beginPre() nothrow @nogc {
        if (preBegun_ || postBegun_ || consumed_ || !shapeValid()) return false;
        if (moveOwner_ !is null && !moveOwner_.begin()) return false;
        if (rotateOwner_ !is null && !rotateOwner_.begin()) {
            if (moveOwner_ !is null) moveOwner_.abort();
            return false;
        }
        if (scaleOwner_ !is null && !scaleOwner_.begin()) {
            if (rotateOwner_ !is null) rotateOwner_.abort();
            if (moveOwner_ !is null) moveOwner_.abort();
            return false;
        }
        ++generation_; preBegun_ = true;
        pre_.owner = owner_; pre_.generation = generation_;
        return true;
    }

    bool beginPost() nothrow @nogc {
        if (!preBegun_ || postBegun_ || validated_ || consumed_ ||
            !shapeValid()) return false;
        postBegun_ = true; post_.owner = owner_;
        post_.generation = generation_; return true;
    }

    bool validatePre() nothrow @nogc {
        if (!preBegun_ || !postBegun_ || validated_ || consumed_ ||
            !shapeValid() || pre_.owner != owner_ ||
            pre_.generation != generation_) return false;
        if (moveOwner_ !is null && !moveOwner_.validate()) return false;
        if (rotateOwner_ !is null && !rotateOwner_.validate()) return false;
        if (scaleOwner_ !is null && !scaleOwner_.validate()) return false;
        validated_ = true; validatedPre_.owner = owner_;
        validatedPre_.generation = generation_;
        pre_.owner = pre_.generation = 0; return true;
    }

    bool validatePost() nothrow @nogc {
        if (!validated_ || consumed_ || !shapeValid() ||
            post_.owner != owner_ || post_.generation != generation_)
            return false;
        validatedPost_.owner = owner_;
        validatedPost_.generation = generation_;
        post_.owner = post_.generation = 0; return true;
    }

    void installPre() nothrow @nogc {
        if (!validated_ || preInstalled_ || consumed_ ||
            validatedPre_.owner != owner_ ||
            validatedPre_.generation != generation_) return;
        target_.installPreparedActivationResetPre(reset_);
        if (moveOwner_ !is null) moveOwner_.install();
        if (rotateOwner_ !is null) rotateOwner_.install();
        if (scaleOwner_ !is null) scaleOwner_.install();
        target_.installPreparedWrapperLinks();
        preInstalled_ = true;
    }

    void installPost() nothrow @nogc {
        if (!validated_ || !preInstalled_ || consumed_ ||
            validatedPost_.owner != owner_ ||
            validatedPost_.generation != generation_) return;
        target_.installPreparedActivationResetPost(reset_);
        consume();
    }

    void abort() nothrow @nogc {
        if (consumed_) return;
        if (moveOwner_ !is null) moveOwner_.abort();
        if (rotateOwner_ !is null) rotateOwner_.abort();
        if (scaleOwner_ !is null) scaleOwner_.abort();
        scrub(); consume();
    }

    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !reset_.valid && (moveOwner_ is null || moveOwner_.payloadEmpty()) &&
            (rotateOwner_ is null || rotateOwner_.payloadEmpty()) &&
            (scaleOwner_ is null || scaleOwner_.payloadEmpty());
    }
    version(unittest) void corruptPreparedForTest(bool post, bool ownerIdentity)
            nothrow @nogc {
        if (post) {
            if (ownerIdentity) ++post_.owner; else ++post_.generation;
        } else {
            if (ownerIdentity) ++pre_.owner; else ++pre_.generation;
        }
    }
    version(unittest) void corruptValidatedForTest(bool post, bool ownerIdentity)
            nothrow @nogc {
        if (post) {
            if (ownerIdentity) ++validatedPost_.owner;
            else ++validatedPost_.generation;
        } else {
            if (ownerIdentity) ++validatedPre_.owner;
            else ++validatedPre_.generation;
        }
    }
private:
    this(XfrmTransformTool target) {
        target_ = target;
        move_ = target.moveBank(); rotate_ = target.rotateBank();
        scale_ = target.scaleBank(); flags_ = target.preparedActivationFlags();
        owner_ = atomicOp!"+="(nextXfrmActivationOwner, 1UL);
    }
    bool shapeValid() nothrow @nogc {
        return target_ !is null && reset_.valid &&
            target_.preparedActivationShape(flags_, move_, rotate_, scale_);
    }
    void scrub() nothrow @nogc { reset_.clear(); }
    void consume() nothrow @nogc {
        scrub(); preBegun_ = postBegun_ = validated_ = preInstalled_ = false;
        consumed_ = true; target_ = null; move_ = null; rotate_ = null; scale_ = null;
        moveOwner_ = rotateOwner_ = scaleOwner_ = null;
        pre_.owner = pre_.generation = post_.owner = post_.generation = 0;
        validatedPre_.owner = validatedPre_.generation = 0;
        validatedPost_.owner = validatedPost_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import editmode : EditMode;
    import math : Vec3;
    import mesh : Mesh, GpuMesh, makeCube;
    import prepared_record_context : PreparedRecordContext;
    import record_observer_hub : RecordObserverHub;

    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    foreach (mask; 0 .. 8) {
        auto history = new CommandHistory();
        auto tool = new XfrmTransformTool(() => &mesh, &gpu, &mode);
        tool.flagT = (mask & 1) != 0;
        tool.flagR = (mask & 2) != 0;
        tool.flagS = (mask & 4) != 0;
        tool.setUndoBindings(history, null);
        tool.seedPreparedActivationResetForTest(false, true, true, true, true);
        tool.moveBank().seedPreparedProductActivationForTest();
        tool.rotateBank().seedPreparedProductActivationForTest();
        tool.scaleBank().seedPreparedProductActivationForTest();
        auto first = mesh.vertices[0]; auto livePtr = mesh.vertices.ptr;
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
            tool.preparedWrapperLinksForTest() &&
            tool.preparedActivationResetPostForTest(true, true, true));
        if (tool.flagT) assert(tool.moveBank().preparedProductActivationForTest());
        else assert(tool.moveBank().preparedProductActivationSeedForTest());
        if (tool.flagR) assert(tool.rotateBank().preparedProductActivationForTest(
            mesh.vertices.length, first, livePtr));
        else assert(tool.rotateBank().preparedProductActivationSeedForTest());
        if (tool.flagS) assert(tool.scaleBank().preparedProductActivationForTest(
            mesh.vertices.length, first, livePtr, Vec3(2,3,4)));
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
