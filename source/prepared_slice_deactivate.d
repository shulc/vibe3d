module prepared_slice_deactivate;

import core.atomic : atomicOp;
import document : Layer;
import mesh : Mesh;
import tools.slice.slice_tool : SliceTool, PreparedSliceDeactivateImage;

struct PreparedSliceDeactivateToken { @disable this(this); private: ulong owner, generation; }
struct ValidatedSliceDeactivateToken { @disable this(this); private: ulong owner, generation; }
private shared ulong nextSliceDeactivateOwner;

final class PreparedSliceDeactivateOwner {
private:
    SliceTool target_; Layer layer_; Mesh* source_;
    PreparedSliceDeactivateImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedSliceDeactivateToken prepared_;
    ValidatedSliceDeactivateToken validatedToken_;
public:
    @disable this();
    static PreparedSliceDeactivateOwner prepare(SliceTool target, Layer layer) {
        if (target is null || target.classinfo !is SliceTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedSliceDeactivateOwner(target, layer);
        owner.image_ = target.buildPreparedDeactivateState(layer.meshRef());
        return owner.image_.valid ? owner : null;
    }
    @property bool commitEligible() const nothrow @nogc {
        return image_.commitEligible;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || source_ is null ||
            !image_.valid) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            layer_ is null || source_ is null || &layer_.meshRef() !is source_ ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedDeactivateStateMatches(image_, *source_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedDeactivateState(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
private:
    this(SliceTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextSliceDeactivateOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; layer_ = null; source_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import commands.mesh.session_edit : MeshSessionEdit;
    import editmode : EditMode;
    import mesh : GpuMesh, makeCube;
    import prepared_record_context : PreparedRecordContext;
    import prepared_tool_effect : PreparedDeactivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import view : View;

    auto layer = new Layer; layer.meshRef() = makeCube();
    GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto tool = new SliceTool(() => &layer.meshRef(), &gpu, &mode,
        LitShader.init);
    tool.seedPreparedDeactivateForTest(layer.meshRef());
    auto history = new CommandHistory(); auto view = new View(0,0,1,1);
    tool.setGestureBindings(history, () => new MeshSessionEdit(
        &layer.meshRef(), view, mode, "test.slice", "Slice"));
    auto context = new PreparedRecordContext(history, new RecordObserverHub());
    auto effect = tool.prepareDeactivate(context, layer);
    assert(effect.resourceAccepted && effect.historyAccepted &&
        effect.kind == PreparedDeactivateKind.Slice && context.validate());
    context.install(); size_t modelDepth, uiDepth;
    history.undoDepthCounts(modelDepth, uiDepth);
    assert(modelDepth == 1 && uiDepth == 0 &&
        tool.preparedDeactivateInstalledForTest() &&
        context.installTraceForTest() == [1,55]);

    auto idleLayer = new Layer; idleLayer.meshRef() = makeCube();
    GpuMesh idleGpu;
    auto idleTool = new SliceTool(() => &idleLayer.meshRef(), &idleGpu, &mode,
        LitShader.init);
    auto idleContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto idle = idleTool.prepareDeactivate(idleContext, idleLayer);
    assert(idle.resourceAccepted && !idle.historyAccepted &&
        idleContext.validate()); idleContext.install();
    assert(idleContext.installTraceForTest() == [8,55]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    GpuMesh staleGpu;
    auto staleTool = new SliceTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    staleTool.seedPreparedDeactivateForTest(staleLayer.meshRef());
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    assert(staleTool.prepareDeactivate(staleContext, staleLayer).resourceAccepted);
    staleTool.mutatePreparedDeactivateForTest();
    assert(!staleContext.validate());
}
