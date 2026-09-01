module prepared_edge_extrude_activation;

import core.atomic : atomicOp;
import mesh : Mesh;
import tools.edit.edge_extrude : EdgeExtrudeTool,
    PreparedEdgeExtrudeActivationImage;

struct PreparedEdgeExtrudeActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedEdgeExtrudeActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextEdgeExtrudeActivationOwner;

final class PreparedEdgeExtrudeActivationOwner {
private:
    version(unittest) static size_t abortCount_;
    EdgeExtrudeTool target_; Mesh* source_;
    PreparedEdgeExtrudeActivationImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedEdgeExtrudeActivationToken prepared_;
    ValidatedEdgeExtrudeActivationToken validatedToken_;
public:
    @disable this();
    static PreparedEdgeExtrudeActivationOwner prepare(EdgeExtrudeTool target) {
        if (target is null || target.classinfo !is EdgeExtrudeTool.classinfo)
            return null;
        auto result = new PreparedEdgeExtrudeActivationOwner(target);
        result.image_ = target.buildPreparedActivation(result.source_);
        return result.image_.valid ? result : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is EdgeExtrudeTool.classinfo ||
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
    this(EdgeExtrudeTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextEdgeExtrudeActivationOwner, 1UL);
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
    mesh.syncSelection(); mesh.selectEdge(0);
    auto tool = new EdgeExtrudeTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    auto expected = tool.preparedFrameForTest(mesh);
    const count = mesh.vertices.length, first = mesh.vertices[0];
    const livePtr = mesh.vertices.ptr;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.EdgeExtrude &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(count, first, livePtr,
        expected.gizmoValid, expected.anchor, expected.baseAnchor,
        expected.extrudeAxis, expected.widthAxis, expected.gizmoSelHash) &&
        context.installTraceForTest() == [29,8]);

    Mesh empty;
    auto emptyTool = new EdgeExtrudeTool(() => &empty, &gpu, &mode,
        LitShader.init); emptyTool.seedPreparedActivationForTest(oldMesh);
    auto emptyContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(emptyTool.prepareActivate(emptyContext).accepted &&
        emptyContext.validate()); emptyContext.install();
    const emptyHash = empty.selectionSignature(EditMode.Edges);
    assert(emptyTool.preparedActivationForTest(0, Vec3.init, null, false,
        Vec3(1,2,3), Vec3(4,5,6), Vec3(7,8,9), Vec3(10,11,12), emptyHash));
    Mesh allEdges = makeCube(); auto allFrame = emptyTool.preparedFrameForTest(allEdges);
    assert(allFrame.gizmoValid && allFrame.anchor == Vec3(0,0,0));
    Mesh hidden = makeCube(); hidden.syncSelection();
    hidden.edgeMarks[0] = Mesh.Marks.Select | Mesh.Marks.Hide;
    auto hiddenFrame = emptyTool.preparedFrameForTest(hidden);
    assert(hiddenFrame.gizmoValid && hiddenFrame.anchor ==
        (hidden.vertices[hidden.edges[0][0]] + hidden.vertices[hidden.edges[0][1]]) * 0.5f);

    tool.seedPreparedActivationForTest(oldMesh);
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;
    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new EdgeExtrudeTool(() => selected, &gpu, &mode,
        LitShader.init); switching.seedPreparedActivationForTest(oldMesh);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedEdgeExtrudeActivationOwner.abortCountForTest(); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedEdgeExtrudeActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());
    auto wrong = PreparedEdgeExtrudeActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedEdgeExtrudeActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    auto aborted = PreparedEdgeExtrudeActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort(); assert(aborted.payloadEmpty() && !aborted.begin());
    class Derived : EdgeExtrudeTool {
        this(Mesh* delegate() nothrow @nogc s, GpuMesh* g, EditMode* m) {
            super(s, g, m, LitShader.init);
        }
    }
    auto derived = new Derived(() => &mesh, &gpu, &mode);
    assert(!derived.prepareActivate(new PreparedRecordContext(
        new CommandHistory(), new RecordObserverHub())).accepted);
    auto missing = new EdgeExtrudeTool(() => null, &gpu, &mode, LitShader.init);
    auto missingContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!missing.prepareActivate(missingContext).accepted && !missingContext.validate());
    assert(!tool.prepareActivate(null).accepted);
}
