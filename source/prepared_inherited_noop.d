module prepared_inherited_noop;

import core.atomic : atomicOp;
import tool : Tool;
import tools.edit.drag_weld : DragWeldTool;
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
import tools.create.pen : PenTool;
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
import prepared_tool_effect : PreparedInheritedNoopEffect,
                              PreparedInheritedNoopKind, OwnedId;

struct PreparedInheritedNoopToken {
    @disable this(this);
private:
    ulong owner, generation;
}

/// Dormant Prepared+Legacy producer for the two inherited base lifecycle
/// roots.  No production door calls this before the unified cutover.
PreparedInheritedNoopEffect prepareInheritedNoop(
        Tool target, PreparedInheritedNoopKind kind,
        PreparedRecordContext context) {
    auto targetOwner = target is null ? OwnedId.init
                                      : target.preparedLifecycleOwner;
    if (context is null)
        return PreparedInheritedNoopEffect(targetOwner, kind, false);
    scope(failure) context.discard();
    auto owner = PreparedInheritedNoopOwner.prepare(target, kind);
    const bool accepted = owner !is null &&
        context.prepareInheritedNoop(owner) && context.markNoHistoryInstall();
    if (!accepted) context.discard();
    return PreparedInheritedNoopEffect(targetOwner, kind, accepted);
}

struct ValidatedInheritedNoopToken {
    @disable this(this);
private:
    ulong owner, generation;
}

private shared ulong nextInheritedNoopOwner;

/// Closed owner for the two base Tool no-op hooks whose sole effective
/// factory product is exact DragWeldTool.  Install intentionally mutates no
/// live state; consuming the validated token is the complete effect.
final class PreparedInheritedNoopOwner {
private:
    Tool target_;
    PreparedInheritedNoopKind kind_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedInheritedNoopToken prepared_;
    ValidatedInheritedNoopToken validatedToken_;
public:
    @disable this();

    static PreparedInheritedNoopOwner prepare(
            Tool target, PreparedInheritedNoopKind kind) {
        if (!admit(target, kind))
            return null;
        return new PreparedInheritedNoopOwner(target, kind);
    }

    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null) return false;
        ++generation_;
        pending_ = true;
        prepared_.owner = owner_;
        prepared_.generation = generation_;
        return true;
    }

    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            !admit(target_, kind_) ||
            prepared_.owner != owner_ ||
            prepared_.generation != generation_) return false;
        validated_ = true;
        validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0;
        return true;
    }

    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        consume();
    }

    void abort() nothrow @nogc {
        if (!consumed_) consume();
    }

    PreparedInheritedNoopKind kind() const nothrow @nogc { return kind_; }
    version(unittest) bool consumedForTest() const nothrow @nogc {
        return consumed_ && target_ is null;
    }
    version(unittest) void corruptPreparedForTest(bool ownerIdentity)
            nothrow @nogc {
        if (ownerIdentity) ++prepared_.owner; else ++prepared_.generation;
    }
    version(unittest) void corruptValidatedForTest(bool ownerIdentity)
            nothrow @nogc {
        if (ownerIdentity) ++validatedToken_.owner;
        else ++validatedToken_.generation;
    }
private:
    static bool admit(Tool target, PreparedInheritedNoopKind kind)
            nothrow @nogc {
        if (target is null) return false;
        if (kind != PreparedInheritedNoopKind.Update)
            return target.classinfo is DragWeldTool.classinfo;
        return target.classinfo is ArcTool.classinfo ||
            target.classinfo is ArrayTool.classinfo ||
            target.classinfo is BendTool.classinfo ||
            target.classinfo is BoxTool.classinfo ||
            target.classinfo is BridgeTool.classinfo ||
            target.classinfo is CapsuleTool.classinfo ||
            target.classinfo is CloneTool.classinfo ||
            target.classinfo is ConeTool.classinfo ||
            target.classinfo is CylinderTool.classinfo ||
            target.classinfo is DragWeldTool.classinfo ||
            target.classinfo is EdgeBevelTool.classinfo ||
            target.classinfo is EdgeExtrudeTool.classinfo ||
            target.classinfo is EdgeSliceTool.classinfo ||
            target.classinfo is EdgeSlideTool.classinfo ||
            target.classinfo is LinearAlignTool.classinfo ||
            target.classinfo is LoopSliceTool.classinfo ||
            target.classinfo is MagnetTool.classinfo ||
            target.classinfo is MirrorTool.classinfo ||
            target.classinfo is PenTool.classinfo ||
            target.classinfo is PolyBevelTool.classinfo ||
            target.classinfo is PolyExtrudeTool.classinfo ||
            target.classinfo is PolyInsetTool.classinfo ||
            target.classinfo is PushTool.classinfo ||
            target.classinfo is RadialAlignTool.classinfo ||
            target.classinfo is RadialArrayTool.classinfo ||
            target.classinfo is RadialSweepTool.classinfo ||
            target.classinfo is ReductionTool.classinfo ||
            target.classinfo is SliceTool.classinfo ||
            target.classinfo is SmoothShiftTool.classinfo ||
            target.classinfo is SphereTool.classinfo ||
            target.classinfo is StrokeExtrudeTool.classinfo ||
            target.classinfo is TackTool.classinfo ||
            target.classinfo is TorusTool.classinfo ||
            target.classinfo is TubeTool.classinfo ||
            target.classinfo is VertexBevelTool.classinfo ||
            target.classinfo is VertexExtrudeTool.classinfo ||
            target.classinfo is VertexMergeTool.classinfo ||
            target.classinfo is VertexTool.classinfo ||
            target.classinfo is XfrmJitterTool.classinfo ||
            target.classinfo is XfrmQuantizeTool.classinfo ||
            target.classinfo is XfrmSmoothTool.classinfo;
    }

    this(Tool target, PreparedInheritedNoopKind kind) {
        target_ = target;
        kind_ = kind;
        owner_ = atomicOp!"+="(nextInheritedNoopOwner, 1UL);
    }

    void consume() nothrow @nogc {
        pending_ = validated_ = false;
        consumed_ = true;
        target_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import mesh : Mesh, GpuMesh;
    import prepared_record_context : PreparedRecordContext;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import tools.create.arc : ArcTool;

    Mesh mesh;
    GpuMesh gpu;
    auto target = new DragWeldTool(() => &mesh, &gpu, LitShader.init);

    foreach (kind; [PreparedInheritedNoopKind.Activate,
                    PreparedInheritedNoopKind.Deactivate]) {
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

    // A different factory product may also inherit Tool.update, but it is not
    // admitted for the two lifecycle kinds owned by this tranche.
    assert(PreparedInheritedNoopOwner.prepare(
        new ArcTool(() => &mesh, &gpu, LitShader.init),
        PreparedInheritedNoopKind.Activate) is null);

    foreach (ownerIdentity; [false, true]) {
        auto wrong = PreparedInheritedNoopOwner.prepare(
            target, PreparedInheritedNoopKind.Activate);
        assert(wrong.begin());
        wrong.corruptPreparedForTest(ownerIdentity);
        assert(!wrong.validate());
        wrong.abort();
        assert(wrong.consumedForTest);

        auto validated = PreparedInheritedNoopOwner.prepare(
            target, PreparedInheritedNoopKind.Deactivate);
        assert(validated.begin() && validated.validate());
        validated.corruptValidatedForTest(ownerIdentity);
        validated.install();
        assert(!validated.consumedForTest);
        validated.abort();
        assert(validated.consumedForTest);
    }

    auto aborted = PreparedInheritedNoopOwner.prepare(
        target, PreparedInheritedNoopKind.Activate);
    assert(aborted.begin());
    aborted.abort();
    assert(aborted.consumedForTest && !aborted.begin());

    // A throw after begin is terminal for this owner and leaves no journal
    // entry.  Discard makes the old context inert; a fresh pair can retry.
    auto faultOwner = PreparedInheritedNoopOwner.prepare(
        target, PreparedInheritedNoopKind.Deactivate);
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
        target, PreparedInheritedNoopKind.Deactivate);
    auto retry = new PreparedRecordContext(new CommandHistory(),
                                            new RecordObserverHub());
    assert(retry.prepareInheritedNoop(retryOwner) &&
           retry.markNoHistoryInstall() && retry.validate());
    retry.discard();
    assert(retryOwner.consumedForTest && !retry.validate());

    // Dormant producer preserves zero-live/no-history behavior for both exact
    // effective roots and never validates or installs early.
    foreach (kind; [PreparedInheritedNoopKind.Activate,
                    PreparedInheritedNoopKind.Deactivate]) {
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
    auto foreign = new ArcTool(() => &mesh, &gpu, LitShader.init);
    auto foreignEffect = prepareInheritedNoop(
        foreign,
        PreparedInheritedNoopKind.Activate, foreignContext);
    assert(!foreignEffect.accepted &&
           foreignEffect.owner == foreign.preparedLifecycleOwner &&
           foreignEffect.kind == PreparedInheritedNoopKind.Activate &&
           !foreignContext.validate());
    auto nullEffect = prepareInheritedNoop(target,
        PreparedInheritedNoopKind.Deactivate, null);
    assert(!nullEffect.accepted && nullEffect.owner == target.preparedLifecycleOwner &&
           nullEffect.kind == PreparedInheritedNoopKind.Deactivate);

    auto producerFault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    threw = false;
    try prepareInheritedNoop(target, PreparedInheritedNoopKind.Activate,
                             producerFault);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && producerFault.resourceCountForTest == 0);
    producerFault.discard();
    assert(!producerFault.validate());

    auto producerRetry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto retryEffect = prepareInheritedNoop(target,
        PreparedInheritedNoopKind.Activate, producerRetry);
    assert(retryEffect.accepted &&
           retryEffect.owner == target.preparedLifecycleOwner &&
           retryEffect.kind == PreparedInheritedNoopKind.Activate &&
           producerRetry.validate());
    producerRetry.install();
    producerRetry.install();
    assert(producerRetry.installTraceForTest == [17,8]);

    auto arc = new ArcTool(() => &mesh, &gpu, LitShader.init);
    auto updateContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto updateEffect = prepareInheritedNoop(arc,
        PreparedInheritedNoopKind.Update, updateContext);
    assert(updateEffect.accepted && updateEffect.kind ==
           PreparedInheritedNoopKind.Update &&
           updateEffect.owner == arc.preparedLifecycleOwner &&
           updateContext.validate());
    updateContext.install(); updateContext.install();
    assert(updateContext.installTraceForTest == [17,8]);
}
