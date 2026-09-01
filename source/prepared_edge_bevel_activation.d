module prepared_edge_bevel_activation;

import core.atomic : atomicOp;
import mesh : Mesh;
import tools.edit.edge_bevel : EdgeBevelTool, PreparedEdgeBevelActivationImage;

struct PreparedEdgeBevelActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedEdgeBevelActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextEdgeBevelActivationOwner;

final class PreparedEdgeBevelActivationOwner {
private:
    version(unittest) static size_t abortCount_;
    EdgeBevelTool target_; Mesh* source_;
    PreparedEdgeBevelActivationImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedEdgeBevelActivationToken prepared_;
    ValidatedEdgeBevelActivationToken validatedToken_;
public:
    @disable this();
    static PreparedEdgeBevelActivationOwner prepare(EdgeBevelTool target) {
        if (target is null || target.classinfo !is EdgeBevelTool.classinfo)
            return null;
        auto result = new PreparedEdgeBevelActivationOwner(target);
        result.image_ = target.buildPreparedActivation(result.source_);
        return result.image_.valid ? result : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid)
            return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_;
        return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is EdgeBevelTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            target_.preparedActivationMesh() !is source_ || source_ is null ||
            !image_.before.matches(*source_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedActivation(image_); consume();
    }
    void abort() nothrow @nogc {
        if (consumed_) return;
        version(unittest) ++abortCount_;
        image_.clear(); consume();
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && !image_.before.filled &&
            image_.before.vertices.length == 0 && image_.before.faces.length == 0;
    }
    version(unittest) static size_t abortCountForTest() nothrow @nogc {
        return abortCount_;
    }
    version(unittest) void corruptPreparedForTest() nothrow @nogc {
        ++prepared_.generation;
    }
private:
    this(EdgeBevelTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextEdgeBevelActivationOwner, 1UL);
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
    import editmode : EditMode;
    import math : Vec3;
    import mesh : GpuMesh, makeCube;
    import prepared_record_context : PreparedRecordContext;
    import prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;

    Mesh mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    EditMode mode = EditMode.Edges; oldMesh.vertices[0] = Vec3(4,5,6);
    const expectedHash = mesh.selectionSignature(EditMode.Edges);
    auto tool = new EdgeBevelTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    const count = mesh.vertices.length, first = mesh.vertices[0];
    const livePtr = mesh.vertices.ptr;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.EdgeBevel &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(count, first, livePtr, true,
        Vec3(0,0,0), Vec3(0,0,0), Vec3(0,1,0), expectedHash) &&
        context.installTraceForTest() == [25,8]);

    Mesh empty;
    auto emptyTool = new EdgeBevelTool(() => &empty, &gpu, &mode,
        LitShader.init);
    emptyTool.seedPreparedActivationForTest(oldMesh);
    auto emptyContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(emptyTool.prepareActivate(emptyContext).accepted &&
        emptyContext.validate()); emptyContext.install();
    assert(emptyTool.preparedActivationForTest(0, Vec3.init, null, false,
        Vec3(1,2,3), Vec3(4,5,6), Vec3(7,8,9), 10));

    // One selected edge distinguishes the adjacent-face branch from the
    // empty-selection all-face fallback.
    Mesh selectedEdge = makeCube(); selectedEdge.syncSelection();
    selectedEdge.selectEdge(0);
    Vec3 normalSum = Vec3(0,0,0);
    const a = selectedEdge.edges[0][0], b = selectedEdge.edges[0][1];
    foreach (fi, face; selectedEdge.faces) {
        bool adjacent;
        foreach (k; 0 .. face.length) {
            const u = face[k], w = face[(k + 1) % face.length];
            if ((a == u && b == w) || (a == w && b == u)) {
                adjacent = true; break;
            }
        }
        if (adjacent) normalSum = normalSum +
            selectedEdge.faceNormal(cast(uint)fi);
    }
    import std.math : sqrt;
    const normalLen = sqrt(normalSum.x*normalSum.x +
        normalSum.y*normalSum.y + normalSum.z*normalSum.z);
    const selectedAxis = normalLen > 1e-6f ?
        normalSum * (1.0f/normalLen) : Vec3(0,1,0);
    auto selectedFrame = emptyTool.preparedFrameForTest(selectedEdge);
    assert(selectedFrame.gizmoValid);
    assert(selectedFrame.anchor == selectedEdge.selectionCentroidEdges());
    assert(selectedFrame.baseAnchor == selectedFrame.anchor);
    assert(selectedFrame.widthAxis == selectedAxis);
    assert(selectedFrame.gizmoSelHash ==
        selectedEdge.selectionSignature(EditMode.Edges));

    tool.seedPreparedActivationForTest(oldMesh);
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(changed).accepted); mesh.vertices[0].x += 1;
    assert(!changed.validate()); changed.discard(); mesh.vertices[0].x -= 1;

    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new EdgeBevelTool(() => selected, &gpu, &mode,
        LitShader.init); switching.seedPreparedActivationForTest(oldMesh);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedEdgeBevelActivationOwner.abortCountForTest();
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedEdgeBevelActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());

    auto wrong = PreparedEdgeBevelActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedEdgeBevelActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    auto aborted = PreparedEdgeBevelActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin());

    class DerivedEdgeBevel : EdgeBevelTool {
        this(Mesh* delegate() nothrow @nogc source, GpuMesh* target,
                EditMode* em) { super(source, target, em, LitShader.init); }
    }
    auto derived = new DerivedEdgeBevel(() => &mesh, &gpu, &mode);
    auto refused = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!derived.prepareActivate(refused).accepted && !refused.validate());
    assert(!tool.prepareActivate(null).accepted);
}
