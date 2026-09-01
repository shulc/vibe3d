module prepared_poly_bevel_activation;

import core.atomic : atomicOp;
import mesh : Mesh;
import tools.edit.poly_bevel : PolyBevelTool, PreparedPolyBevelActivationImage;

struct PreparedPolyBevelActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedPolyBevelActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextPolyBevelActivationOwner;

final class PreparedPolyBevelActivationOwner {
private:
    version(unittest) static size_t abortCount_;
    PolyBevelTool target_; Mesh* source_;
    PreparedPolyBevelActivationImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedPolyBevelActivationToken prepared_;
    ValidatedPolyBevelActivationToken validatedToken_;
public:
    @disable this();
    static PreparedPolyBevelActivationOwner prepare(PolyBevelTool target) {
        if (target is null || target.classinfo !is PolyBevelTool.classinfo)
            return null;
        auto result = new PreparedPolyBevelActivationOwner(target);
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
            target_.classinfo !is PolyBevelTool.classinfo ||
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
    this(PolyBevelTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextPolyBevelActivationOwner, 1UL);
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
    import std.math : abs, sqrt;

    Mesh mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    EditMode mode = EditMode.Polygons; oldMesh.vertices[0] = Vec3(4,5,6);
    mesh.syncSelection(); mesh.selectFace(0);
    const expectedAnchor = mesh.faceCentroid(0);
    const expectedShift = mesh.faceNormal(0);
    const up = abs(expectedShift.y) < 0.9f ? Vec3(0,1,0) : Vec3(1,0,0);
    const side = cross(expectedShift, up);
    const sideLen = sqrt(side.x*side.x + side.y*side.y + side.z*side.z);
    const expectedInset = sideLen > 1e-6f ?
        side * (1.0f/sideLen) : Vec3(1,0,0);
    const expectedHash = mesh.selectionSignature(EditMode.Polygons);
    auto tool = new PolyBevelTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    const count = mesh.vertices.length, first = mesh.vertices[0];
    const livePtr = mesh.vertices.ptr;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.PolyBevel &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(count, first, livePtr, true,
        expectedAnchor, expectedAnchor, expectedShift, expectedInset,
        expectedHash) && context.installTraceForTest() == [26,8]);

    Mesh empty;
    auto emptyTool = new PolyBevelTool(() => &empty, &gpu, &mode,
        LitShader.init); emptyTool.seedPreparedActivationForTest(oldMesh);
    auto emptyContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(emptyTool.prepareActivate(emptyContext).accepted &&
        emptyContext.validate()); emptyContext.install();
    assert(emptyTool.preparedActivationForTest(0, Vec3.init, null, false,
        Vec3(1,2,3), Vec3(4,5,6), Vec3(7,8,9), Vec3(10,11,12), 13));

    Mesh allFaces = makeCube();
    auto allFrame = emptyTool.preparedFrameForTest(allFaces);
    assert(allFrame.gizmoValid && allFrame.anchor == Vec3(0,0,0) &&
        allFrame.shiftAxis == Vec3(0,1,0) &&
        allFrame.insetAxis == Vec3(0,0,-1));
    Mesh hiddenSelected = makeCube(); hiddenSelected.syncSelection();
    hiddenSelected.faceMarks[0] = Mesh.Marks.Select | Mesh.Marks.Hide;
    auto hiddenFrame = emptyTool.preparedFrameForTest(hiddenSelected);
    assert(hiddenFrame.gizmoValid &&
        hiddenFrame.anchor == hiddenSelected.faceCentroid(0) &&
        hiddenFrame.shiftAxis == hiddenSelected.faceNormal(0));
    Mesh stale = makeCube(); stale.syncSelection();
    stale.faceMarks ~= Mesh.Marks.Select;
    auto staleFrame = emptyTool.preparedFrameForTest(stale);
    assert(!staleFrame.gizmoValid && staleFrame.anchor == Vec3(0,0,0) &&
        staleFrame.baseAnchor == Vec3(4,5,6) &&
        staleFrame.shiftAxis == Vec3(7,8,9) &&
        staleFrame.insetAxis == Vec3(10,11,12) && staleFrame.gizmoSelHash == 13);

    tool.seedPreparedActivationForTest(oldMesh);
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(changed).accepted); mesh.vertices[0].x += 1;
    assert(!changed.validate()); changed.discard(); mesh.vertices[0].x -= 1;
    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new PolyBevelTool(() => selected, &gpu, &mode,
        LitShader.init); switching.seedPreparedActivationForTest(oldMesh);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedPolyBevelActivationOwner.abortCountForTest();
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedPolyBevelActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());

    auto wrong = PreparedPolyBevelActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedPolyBevelActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    auto aborted = PreparedPolyBevelActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin());

    class DerivedPolyBevel : PolyBevelTool {
        this(Mesh* delegate() nothrow @nogc source, GpuMesh* target,
                EditMode* em) { super(source, target, em, LitShader.init); }
    }
    auto derived = new DerivedPolyBevel(() => &mesh, &gpu, &mode);
    auto refused = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!derived.prepareActivate(refused).accepted && !refused.validate());
    assert(!tool.prepareActivate(null).accepted);
}
