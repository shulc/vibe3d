module prepared_vertex_extrude_activation;

import core.atomic : atomicOp;
import mesh : Mesh;
import tools.edit.vertex_extrude_tool : VertexExtrudeTool,
    PreparedVertexExtrudeActivationImage;

struct PreparedVertexExtrudeActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedVertexExtrudeActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextVertexExtrudeActivationOwner;

final class PreparedVertexExtrudeActivationOwner {
private:
    version(unittest) static size_t abortCount_;
    VertexExtrudeTool target_; Mesh* source_;
    PreparedVertexExtrudeActivationImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedVertexExtrudeActivationToken prepared_;
    ValidatedVertexExtrudeActivationToken validatedToken_;
public:
    @disable this();
    static PreparedVertexExtrudeActivationOwner prepare(VertexExtrudeTool target) {
        if (target is null || target.classinfo !is VertexExtrudeTool.classinfo)
            return null;
        auto result = new PreparedVertexExtrudeActivationOwner(target);
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
            target_.classinfo !is VertexExtrudeTool.classinfo ||
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
    this(VertexExtrudeTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextVertexExtrudeActivationOwner, 1UL);
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
    import math : Vec3, cross;
    import mesh : GpuMesh, makeCube;
    import prepared_record_context : PreparedRecordContext;
    import prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import std.math : sqrt;

    Mesh mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    EditMode mode = EditMode.Vertices; oldMesh.vertices[0] = Vec3(4,5,6);
    mesh.syncSelection(); mesh.selectVertex(0);
    const invRoot3 = 1.0f / sqrt(3.0f);
    const expectedShift = Vec3(-invRoot3, -invRoot3, -invRoot3);
    const up = Vec3(0,1,0), side = cross(expectedShift, up);
    const sideLen = sqrt(side.x*side.x + side.y*side.y + side.z*side.z);
    const expectedWidth = side * (1.0f/sideLen);
    auto tool = new VertexExtrudeTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    const count = mesh.vertices.length, first = mesh.vertices[0];
    const livePtr = mesh.vertices.ptr;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); auto effect = tool.prepareActivate(context);
    const expectedAnchor = mesh.selectionCentroidVertices();
    const expectedHash = mesh.selectionSignature(EditMode.Vertices);
    assert(effect.accepted && effect.kind == PreparedActivateKind.VertexExtrude &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(count, first, livePtr, true,
        expectedAnchor, expectedAnchor, expectedShift, expectedWidth,
        expectedHash) && context.installTraceForTest() == [28,8]);

    Mesh empty;
    auto emptyTool = new VertexExtrudeTool(() => &empty, &gpu, &mode,
        LitShader.init); emptyTool.seedPreparedActivationForTest(oldMesh);
    auto emptyContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(emptyTool.prepareActivate(emptyContext).accepted &&
        emptyContext.validate()); emptyContext.install();
    assert(emptyTool.preparedActivationForTest(0, Vec3.init, null, false,
        Vec3(1,2,3), Vec3(4,5,6), Vec3(7,8,9), Vec3(10,11,12), 13));
    Mesh allVertices = makeCube(); auto allFrame = emptyTool.preparedFrameForTest(allVertices);
    assert(allFrame.gizmoValid && allFrame.anchor == Vec3(0,0,0) &&
        allFrame.shiftAxis == Vec3(0,1,0) && allFrame.widthAxis == Vec3(0,0,-1));
    Mesh hidden = makeCube(); hidden.syncSelection();
    hidden.vertexMarks[0] = Mesh.Marks.Select | Mesh.Marks.Hide;
    auto hiddenFrame = emptyTool.preparedFrameForTest(hidden);
    assert(hiddenFrame.gizmoValid && hiddenFrame.anchor == hidden.vertices[0] &&
        hiddenFrame.shiftAxis == expectedShift && hiddenFrame.widthAxis == expectedWidth);

    tool.seedPreparedActivationForTest(oldMesh);
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;
    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new VertexExtrudeTool(() => selected, &gpu, &mode,
        LitShader.init); switching.seedPreparedActivationForTest(oldMesh);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedVertexExtrudeActivationOwner.abortCountForTest(); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedVertexExtrudeActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());
    auto wrong = PreparedVertexExtrudeActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedVertexExtrudeActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    auto aborted = PreparedVertexExtrudeActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort(); assert(aborted.payloadEmpty() && !aborted.begin());

    class Derived : VertexExtrudeTool {
        this(Mesh* delegate() nothrow @nogc s, GpuMesh* g, EditMode* m) {
            super(s, g, m, LitShader.init);
        }
    }
    auto derived = new Derived(() => &mesh, &gpu, &mode);
    assert(!derived.prepareActivate(new PreparedRecordContext(
        new CommandHistory(), new RecordObserverHub())).accepted);
    auto missing = new VertexExtrudeTool(() => null, &gpu, &mode, LitShader.init);
    auto missingContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!missing.prepareActivate(missingContext).accepted && !missingContext.validate());
    assert(!tool.prepareActivate(null).accepted);
}
