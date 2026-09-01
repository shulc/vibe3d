module prepared_private_state;

import core.atomic : atomicOp;
import tools.create.box : BoxTool;
import tools.create.pen : PenTool;
import tools.create.primitive_create_tool : PrimitiveCreateTool, HandledCreateTool;
import tools.create.sphere : SphereTool;
import tools.create.vertex_place : VertexTool;
import tools.alignment.array_tool : ArrayTool;
import tools.alignment.clone_tool : CloneTool;
import tools.deform.magnet : MagnetTool;
import tools.edit.reduce : ReductionTool;
import snapshot : MeshSnapshot;

enum PreparedPrivateStateKind : ubyte {
    Box, Pen, Primitive, Vertex, ArraySession, CloneSession,
    MagnetSession, ReductionSession
}
private enum PrimitiveProjection : ubyte { Base, Handled, Sphere }
struct PreparedPrivateStateToken { @disable this(this); private ulong ownerId, generation; }
struct ValidatedPrivateStateToken { @disable this(this); private ulong ownerId, generation; }
private shared ulong nextPrivateStateOwnerId;

/// Closed owner: concrete typed targets and fixed final install arms only.
final class PreparedPrivateStateOwner {
private:
    version(unittest) static bool failSessionPrepareForTest_;
    immutable ulong ownerId;
    ulong generation;
    PreparedPrivateStateKind kind_;
    PrimitiveProjection primitiveProjection;
    BoxTool boxTarget;
    PenTool penTarget;
    PrimitiveCreateTool primitiveTarget;
    HandledCreateTool handledTarget;
    SphereTool sphereTarget;
    VertexTool vertexTarget;
    ArrayTool arrayTarget;
    CloneTool cloneTarget;
    MagnetTool magnetTarget;
    ReductionTool reductionTarget;
    MeshSnapshot activationBaseline;
    immutable bool sphereClearMethod;
    immutable int sphereAxis;
    bool pending, validated;
    PreparedPrivateStateToken prepared;
    ValidatedPrivateStateToken validatedToken;

    this(PreparedPrivateStateKind kind) {
        ownerId = atomicOp!"+="(nextPrivateStateOwnerId, 1UL); kind_ = kind;
        sphereClearMethod = false; sphereAxis = 0;
    }
    this(PreparedPrivateStateKind kind, bool clearMethod, int axis) {
        ownerId = atomicOp!"+="(nextPrivateStateOwnerId, 1UL); kind_ = kind;
        sphereClearMethod = clearMethod; sphereAxis = axis;
    }
public:
    static PreparedPrivateStateOwner box(BoxTool target) {
        if (target is null || target.classinfo !is BoxTool.classinfo) return null;
        auto o = new PreparedPrivateStateOwner(PreparedPrivateStateKind.Box);
        o.boxTarget = target; return o;
    }
    static PreparedPrivateStateOwner pen(PenTool target) {
        auto o = new PreparedPrivateStateOwner(PreparedPrivateStateKind.Pen);
        o.penTarget = target; return o;
    }
    static PreparedPrivateStateOwner primitive(PrimitiveCreateTool target) {
        auto o = new PreparedPrivateStateOwner(PreparedPrivateStateKind.Primitive);
        o.primitiveTarget = target; o.primitiveProjection = PrimitiveProjection.Base; return o;
    }
    static PreparedPrivateStateOwner primitive(HandledCreateTool target) {
        auto o = new PreparedPrivateStateOwner(PreparedPrivateStateKind.Primitive);
        o.handledTarget = target; o.primitiveProjection = PrimitiveProjection.Handled; return o;
    }
    static PreparedPrivateStateOwner primitive(SphereTool target) {
        auto o = new PreparedPrivateStateOwner(PreparedPrivateStateKind.Primitive,
            target.preparedSphereClearMethod, target.preparedSphereAxis);
        o.sphereTarget = target; o.primitiveProjection = PrimitiveProjection.Sphere; return o;
    }
    static PreparedPrivateStateOwner vertex(VertexTool target) {
        auto o = new PreparedPrivateStateOwner(PreparedPrivateStateKind.Vertex);
        o.vertexTarget = target; return o;
    }
    static PreparedPrivateStateOwner arraySession(ArrayTool target) {
        if (target is null) return null;
        auto o = new PreparedPrivateStateOwner(PreparedPrivateStateKind.ArraySession);
        o.arrayTarget = target; o.activationBaseline = target.prepareActivationBaseline(); return o;
    }
    static PreparedPrivateStateOwner cloneSession(CloneTool target) {
        if (target is null || target.classinfo !is CloneTool.classinfo) return null;
        auto o = new PreparedPrivateStateOwner(PreparedPrivateStateKind.CloneSession);
        o.cloneTarget = target; o.activationBaseline = target.prepareActivationBaseline(); return o;
    }
    static PreparedPrivateStateOwner magnetSession(MagnetTool target) {
        if (target is null || target.classinfo !is MagnetTool.classinfo) return null;
        auto o = new PreparedPrivateStateOwner(PreparedPrivateStateKind.MagnetSession);
        o.magnetTarget = target; o.activationBaseline = target.prepareActivationBaseline(); return o;
    }
    static PreparedPrivateStateOwner reductionSession(ReductionTool target) {
        if (target is null || target.classinfo !is ReductionTool.classinfo) return null;
        auto image = target.prepareActivationBaseline();
        version(unittest) if (failSessionPrepareForTest_) {
            failSessionPrepareForTest_ = false;
            throw new Exception("injected session image prepare failure");
        }
        auto o = new PreparedPrivateStateOwner(PreparedPrivateStateKind.ReductionSession);
        o.reductionTarget = target; o.activationBaseline = image; return o;
    }
    @property PreparedPrivateStateKind kind() const nothrow @nogc { return kind_; }
    bool owns(VertexTool target) const nothrow @nogc {
        return kind_ == PreparedPrivateStateKind.Vertex && vertexTarget is target;
    }
    bool owns(ArrayTool target) const nothrow @nogc {
        return kind_ == PreparedPrivateStateKind.ArraySession && arrayTarget is target;
    }
    bool owns(CloneTool target) const nothrow @nogc {
        return kind_ == PreparedPrivateStateKind.CloneSession && cloneTarget is target;
    }
    bool owns(MagnetTool target) const nothrow @nogc {
        return kind_ == PreparedPrivateStateKind.MagnetSession && magnetTarget is target;
    }
    bool owns(ReductionTool target) const nothrow @nogc {
        return kind_ == PreparedPrivateStateKind.ReductionSession && reductionTarget is target;
    }
private:
    bool hasTarget() const nothrow @nogc {
        final switch (kind_) {
        case PreparedPrivateStateKind.Box: return boxTarget !is null;
        case PreparedPrivateStateKind.Pen: return penTarget !is null;
        case PreparedPrivateStateKind.Primitive:
            final switch (primitiveProjection) {
            case PrimitiveProjection.Base: return primitiveTarget !is null;
            case PrimitiveProjection.Handled: return handledTarget !is null;
            case PrimitiveProjection.Sphere: return sphereTarget !is null;
            }
        case PreparedPrivateStateKind.Vertex: return vertexTarget !is null;
        case PreparedPrivateStateKind.ArraySession:
            return arrayTarget !is null && activationBaseline.filled;
        case PreparedPrivateStateKind.CloneSession:
            return cloneTarget !is null && activationBaseline.filled;
        case PreparedPrivateStateKind.MagnetSession:
            return magnetTarget !is null && activationBaseline.filled;
        case PreparedPrivateStateKind.ReductionSession:
            return reductionTarget !is null && activationBaseline.filled;
        }
    }
public:
    bool begin() nothrow @nogc {
        if (pending || !hasTarget()) return false;
        ++generation; pending = true; validated = false;
        prepared.ownerId = ownerId; prepared.generation = generation; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending || validated || prepared.ownerId != ownerId ||
            prepared.generation != generation || !hasTarget()) return false;
        validated = true; validatedToken.ownerId = ownerId;
        validatedToken.generation = generation; return true;
    }
    void install() nothrow @nogc {
        if (!pending || !validated || validatedToken.ownerId != ownerId ||
            validatedToken.generation != generation) return;
        final switch (kind_) {
        case PreparedPrivateStateKind.Box: boxTarget.installPreparedPrivateActivation(); break;
        case PreparedPrivateStateKind.Pen: penTarget.installPreparedPrivateActivation(); break;
        case PreparedPrivateStateKind.Primitive:
            final switch (primitiveProjection) {
            case PrimitiveProjection.Base: primitiveTarget.installPreparedPrimitiveReset(); break;
            case PrimitiveProjection.Handled: handledTarget.installHandledResetProjection(); break;
            case PrimitiveProjection.Sphere:
                sphereTarget.installPreparedSphereReset(sphereClearMethod, sphereAxis); break;
            } break;
        case PreparedPrivateStateKind.Vertex: vertexTarget.installPreparedPrivateDeactivate(); break;
        case PreparedPrivateStateKind.ArraySession:
            arrayTarget.installPreparedActivation(activationBaseline); break;
        case PreparedPrivateStateKind.CloneSession:
            cloneTarget.installPreparedActivation(activationBaseline); break;
        case PreparedPrivateStateKind.MagnetSession:
            magnetTarget.installPreparedActivation(activationBaseline); break;
        case PreparedPrivateStateKind.ReductionSession:
            reductionTarget.installPreparedActivation(activationBaseline); break;
        }
        pending = validated = false;
        validatedToken.ownerId = validatedToken.generation = 0;
    }
    void abort() nothrow @nogc {
        activationBaseline = MeshSnapshot.init;
        pending = validated = false;
    }
    version(unittest) bool activationPayloadFilledForTest() const nothrow @nogc {
        return activationBaseline.filled;
    }
}

version(unittest) unittest {
    import mesh : Mesh, GpuMesh, makeCube;
    Mesh mesh = makeCube(); GpuMesh gpu;
    auto sphere = new SphereTool(() => &mesh, &gpu, null, true);
    sphere.seedPreparedSphereForTest(2, 7);
    auto owner = PreparedPrivateStateOwner.primitive(sphere);
    assert(owner.begin());
    sphere.seedPreparedSphereForTest(0, 8);
    assert(owner.validate()); owner.install();
    assert(sphere.preparedSphereMethodForTest() == 0);
    assert(sphere.preparedSphereSyncedAxisForTest() == 2,
           "source mutation changed detached prepared projection");
    sphere.seedPreparedSphereForTest(1, 9); owner.install();
    assert(sphere.preparedSphereMethodForTest() == 9);

    import editmode : EditMode;
    EditMode reductionMode = EditMode.Polygons;
    auto reduction = new ReductionTool(() => &mesh, &gpu, &reductionMode, null);
    reduction.seedPreparedActivationForTest(false, true);
    immutable originalX = mesh.vertices.length ? mesh.vertices[0].x : 0.0f;
    PreparedPrivateStateOwner.failSessionPrepareForTest_ = true;
    bool threw;
    try PreparedPrivateStateOwner.reductionSession(reduction);
    catch (Exception) threw = true;
    assert(threw && !reduction.preparedActiveForTest() && reduction.preparedBuiltForTest());
    auto session = PreparedPrivateStateOwner.reductionSession(reduction);
    assert(session.begin());
    if (mesh.vertices.length) mesh.vertices[0].x = originalX + 7;
    assert(session.validate()); session.install();
    assert(reduction.preparedActiveForTest() && !reduction.preparedBuiltForTest());
    assert(reduction.preparedBaselineXForTest() == originalX,
           "live source mutation aliased owner-retained snapshot");
    assert(reduction.preparedBaselineFilledForTest());
    assert(!session.activationPayloadFilledForTest(),
           "successful install retained a shallow owner descriptor");
    assert(!session.begin(), "consumed session owner re-armed without an image");
    reduction.seedPreparedActivationForTest(false, true);
    session.install();
    assert(!reduction.preparedActiveForTest() && reduction.preparedBuiltForTest());
    auto discarded = PreparedPrivateStateOwner.reductionSession(reduction);
    assert(discarded.activationPayloadFilledForTest() && discarded.begin());
    discarded.abort();
    assert(!discarded.activationPayloadFilledForTest());
    assert(!discarded.begin(), "aborted session owner re-armed without an image");
    assert(reduction.preparedBaselineFilledForTest(),
           "owner abort cleared or aliased installed tool baseline");

    import prepared_record_context : PreparedRecordContext;
    import command_history : CommandHistory;
    import record_observer_hub : RecordObserverHub;
    PreparedRecordContext freshContext() {
        return new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    }
    auto arrayTool = new ArrayTool(() => &mesh, &gpu, &reductionMode);
    arrayTool.seedPreparedActivationForTest();
    auto arrayContext = freshContext();
    assert(arrayTool.prepareActivate(arrayContext,
                                     PreparedPrivateStateOwner.arraySession(arrayTool)).accepted);
    assert(!arrayTool.preparedActivationInstalledForTest());
    assert(arrayContext.validate()); arrayContext.install();
    assert(arrayTool.preparedActivationInstalledForTest());
    assert(arrayContext.installTraceForTest() == [7,8]);

    auto cloneTool = new CloneTool(() => &mesh, &gpu, &reductionMode);
    cloneTool.seedPreparedActivationForTest();
    auto cloneContext = freshContext();
    assert(cloneTool.prepareActivate(cloneContext,
                                     PreparedPrivateStateOwner.cloneSession(cloneTool)).accepted);
    assert(cloneContext.validate()); cloneContext.install();
    assert(cloneTool.preparedActivationInstalledForTest());
    assert(cloneContext.installTraceForTest() == [7,8]);

    auto magnetTool = new MagnetTool(() => &mesh, &gpu, &reductionMode);
    magnetTool.seedPreparedActivationForTest();
    auto magnetContext = freshContext();
    assert(magnetTool.prepareActivate(magnetContext,
                                      PreparedPrivateStateOwner.magnetSession(magnetTool)).accepted);
    assert(magnetContext.validate()); magnetContext.install();
    assert(magnetTool.preparedActivationInstalledForTest());
    assert(magnetContext.installTraceForTest() == [7,8]);

    auto reduction2 = new ReductionTool(() => &mesh, &gpu, &reductionMode, null);
    reduction2.seedPreparedActivationForTest(false, true);
    auto reductionContext = freshContext();
    assert(reduction2.prepareActivate(reductionContext,
                                     PreparedPrivateStateOwner.reductionSession(reduction2)).accepted);
    assert(reductionContext.validate()); reductionContext.install();
    assert(reduction2.preparedActiveForTest() && !reduction2.preparedBuiltForTest());
    assert(reductionContext.installTraceForTest() == [7,8]);

    reduction2.seedPreparedActivationForTest(false, true);
    reductionContext.install();
    assert(!reduction2.preparedActiveForTest() && reduction2.preparedBuiltForTest(),
           "a consumed prepared activation installed twice");

    auto nullContext = arrayTool.prepareActivate(null,
        PreparedPrivateStateOwner.arraySession(arrayTool));
    assert(!nullContext.accepted);
    auto nullOwnerContext = freshContext();
    auto nullOwner = arrayTool.prepareActivate(nullOwnerContext, null);
    assert(!nullOwner.accepted && !nullOwnerContext.validate());

    auto wrongContext = freshContext();
    auto wrong = arrayTool.prepareActivate(wrongContext,
                                           PreparedPrivateStateOwner.cloneSession(cloneTool));
    assert(!wrong.accepted && !wrongContext.validate());
}
