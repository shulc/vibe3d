module prepared_stroke_extrude_activation;

import core.atomic : atomicOp;
import mesh : Mesh;
import tools.deform.stroke_extrude_tool : StrokeExtrudeTool,
    PreparedStrokeExtrudeActivationImage;

struct PreparedStrokeExtrudeActivationToken {
    @disable this(this);
private: ulong owner, generation;
}
struct ValidatedStrokeExtrudeActivationToken {
    @disable this(this);
private: ulong owner, generation;
}
private shared ulong nextStrokeExtrudeActivationOwner;

/// Detached exact activation image for StrokeExtrudeTool. Only scalar tokens
/// cross the record context; the deep MeshSnapshot remains owner-private.
final class PreparedStrokeExtrudeActivationOwner {
private:
    version(unittest) static size_t abortCount_;
    StrokeExtrudeTool target_;
    Mesh* source_;
    PreparedStrokeExtrudeActivationImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedStrokeExtrudeActivationToken prepared_;
    ValidatedStrokeExtrudeActivationToken validatedToken_;
public:
    @disable this();
    static PreparedStrokeExtrudeActivationOwner prepare(StrokeExtrudeTool target) {
        if (target is null || target.classinfo !is StrokeExtrudeTool.classinfo)
            return null;
        auto result = new PreparedStrokeExtrudeActivationOwner(target);
        result.image_ = target.buildPreparedActivation(result.source_);
        return result.image_.valid ? result : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_;
        return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is StrokeExtrudeTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            target_.preparedActivationMesh() !is source_ || source_ is null ||
            !image_.before.matches(*source_))
            return false;
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
        target_.installPreparedActivation(image_);
        consume();
    }
    void abort() nothrow @nogc {
        if (consumed_) return;
        version(unittest) ++abortCount_;
        image_.clear(); consume();
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && !image_.before.filled &&
            image_.before.vertices.length == 0 && image_.before.edges.length == 0 &&
            image_.before.faces.length == 0 && image_.before.meshMaps.length == 0;
    }
    version(unittest) static size_t abortCountForTest() nothrow @nogc {
        return abortCount_;
    }
    version(unittest) void corruptPreparedForTest(bool owner) nothrow @nogc {
        if (owner) ++prepared_.owner; else ++prepared_.generation;
    }
private:
    this(StrokeExtrudeTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextStrokeExtrudeActivationOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; source_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import mesh : Mesh, GpuMesh, makeCube;
    import prepared_record_context : PreparedRecordContext;
    import prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import math : Vec3;

    Mesh mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    oldMesh.vertices[0] = Vec3(4,5,6);
    auto tool = new StrokeExtrudeTool(() => &mesh, &gpu, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    const count = mesh.vertices.length;
    const first = mesh.vertices[0];
    const livePtr = mesh.vertices.ptr;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.StrokeExtrude &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(count, first, livePtr) &&
        context.installTraceForTest() == [20,8]);

    tool.seedPreparedActivationForTest(oldMesh);
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0] = Vec3(70,80,90);
    assert(!changed.validate()); changed.discard();

    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new StrokeExtrudeTool(() => selected, &gpu, LitShader.init);
    switching.seedPreparedActivationForTest(oldMesh);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(switching.prepareActivate(switched).accepted);
    selected = &replacement;
    assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedStrokeExtrudeActivationOwner.abortCountForTest();
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedStrokeExtrudeActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());

    auto wrong = PreparedStrokeExtrudeActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest(true);
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());

    mesh.vertices[0] = first;
    auto once = PreparedStrokeExtrudeActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    auto aborted = PreparedStrokeExtrudeActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin());

    class DerivedStroke : StrokeExtrudeTool {
        this(Mesh* delegate() nothrow @nogc source, GpuMesh* target) {
            super(source, target, LitShader.init);
        }
    }
    auto derived = new DerivedStroke(() => &mesh, &gpu);
    auto refusedContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto refused = derived.prepareActivate(refusedContext);
    assert(!refused.accepted && refused.kind == PreparedActivateKind.StrokeExtrude &&
        refused.owner == derived.preparedOwnerForTest() &&
        !refusedContext.validate());
    auto nullEffect = tool.prepareActivate(null);
    assert(!nullEffect.accepted && nullEffect.kind == PreparedActivateKind.StrokeExtrude &&
        nullEffect.owner == tool.preparedOwnerForTest());
}
