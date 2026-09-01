module prepared_private_state;

import core.atomic : atomicOp;
import tools.create.box : BoxTool;
import tools.create.pen : PenTool;
import tools.create.primitive_create_tool : PrimitiveCreateTool, HandledCreateTool;
import tools.create.sphere : SphereTool;
import tools.create.capsule : CapsuleTool;
import tools.create.cone : ConeTool;
import tools.create.cylinder : CylinderTool;
import tools.create.torus : TorusTool;
import tools.create.tube : TubeTool;
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
private enum PrimitiveProjection : ubyte {
    Base, Handled, Sphere, Capsule, Cone, Cylinder, Torus, Tube
}
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
        if (target is null || target.classinfo !is PenTool.classinfo) return null;
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
    static PreparedPrivateStateOwner primitiveProduct(PrimitiveCreateTool target) {
        if (target is null) return null;
        PreparedPrivateStateOwner o;
        if (target.classinfo is SphereTool.classinfo) {
            auto sphere = cast(SphereTool) target;
            o = new PreparedPrivateStateOwner(PreparedPrivateStateKind.Primitive,
                sphere.preparedSphereClearMethod, sphere.preparedSphereAxis);
            o.sphereTarget = sphere;
            o.primitiveProjection = PrimitiveProjection.Sphere;
            return o;
        }
        o = new PreparedPrivateStateOwner(PreparedPrivateStateKind.Primitive);
        o.primitiveTarget = target;
        if (target.classinfo is CapsuleTool.classinfo)
            o.primitiveProjection = PrimitiveProjection.Capsule;
        else if (target.classinfo is ConeTool.classinfo)
            o.primitiveProjection = PrimitiveProjection.Cone;
        else if (target.classinfo is CylinderTool.classinfo)
            o.primitiveProjection = PrimitiveProjection.Cylinder;
        else if (target.classinfo is TorusTool.classinfo)
            o.primitiveProjection = PrimitiveProjection.Torus;
        else if (target.classinfo is TubeTool.classinfo)
            o.primitiveProjection = PrimitiveProjection.Tube;
        else return null;
        return o;
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
            case PrimitiveProjection.Capsule:
            case PrimitiveProjection.Cone:
            case PrimitiveProjection.Cylinder:
            case PrimitiveProjection.Torus:
            case PrimitiveProjection.Tube: return primitiveTarget !is null;
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
            case PrimitiveProjection.Capsule:
                (cast(CapsuleTool) primitiveTarget).installPreparedRadialActivation(); break;
            case PrimitiveProjection.Cone:
                (cast(ConeTool) primitiveTarget).installPreparedRadialActivation(); break;
            case PrimitiveProjection.Cylinder:
                (cast(CylinderTool) primitiveTarget).installPreparedRadialActivation(); break;
            case PrimitiveProjection.Torus:
                (cast(TorusTool) primitiveTarget).installPreparedActivation(); break;
            case PrimitiveProjection.Tube:
                (cast(TubeTool) primitiveTarget).installPreparedActivation(); break;
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
    import mesh_gpu : GpuCreateOwner;
    import prepared_record_context : PreparedRecordContext;
    import prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
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

    // The inherited activation declaration has six exact concrete products.
    // Every product keeps its live state and old GL header until the joint
    // transaction validates, then installs private -> GPU -> no-history once.
    auto capsule = new CapsuleTool(() => &mesh, &gpu, null);
    auto cone = new ConeTool(() => &mesh, &gpu, null);
    auto cylinder = new CylinderTool(() => &mesh, &gpu, null);
    auto productSphere = new SphereTool(() => &mesh, &gpu, null, true);
    auto torus = new TorusTool(() => &mesh, &gpu, null);
    auto tube = new TubeTool(() => &mesh, &gpu, null);
    capsule.seedPreparedRadialActivationForTest();
    cone.seedPreparedRadialActivationForTest();
    cylinder.seedPreparedRadialActivationForTest();
    productSphere.seedPreparedRadialActivationForTest();
    productSphere.seedPreparedSphereForTest(2, 7);
    torus.seedPreparedActivationForTest();
    tube.seedPreparedActivationForTest();

    void installProduct(PrimitiveCreateTool product, uint oldName, ubyte projection) {
        product.preparedPreviewGpu().faceVao = oldName;
        auto gpuOwner = GpuCreateOwner.fakeForLegacyInitTest(
            product.preparedPreviewGpu());
        auto context = new PreparedRecordContext(null, new RecordObserverHub());
        context.setResourceIdentity(7, 11);
        auto effect = product.prepareActivate(context, gpuOwner);
        bool projectionStillDirty;
        switch (projection) {
        case 0: projectionStillDirty =
            (cast(CapsuleTool) product).preparedRadialActivationDirtyForTest(); break;
        case 1: projectionStillDirty =
            (cast(ConeTool) product).preparedRadialActivationDirtyForTest(); break;
        case 2: projectionStillDirty =
            (cast(CylinderTool) product).preparedRadialActivationDirtyForTest(); break;
        case 3: projectionStillDirty =
            (cast(SphereTool) product).preparedRadialActivationDirtyForTest() &&
            (cast(SphereTool) product).preparedSphereMethodForTest() == 7; break;
        case 4: projectionStillDirty =
            (cast(TorusTool) product).preparedActivationDirtyForTest(); break;
        case 5: projectionStillDirty =
            (cast(TubeTool) product).preparedActivationDirtyForTest(); break;
        case 6: projectionStillDirty =
            (cast(SphereTool) product).preparedRadialActivationDirtyForTest() &&
            (cast(SphereTool) product).preparedSphereMethodForTest() == 6; break;
        default: assert(false, "unknown primitive test projection");
        }
        assert(effect.accepted && effect.kind == PreparedActivateKind.Primitive &&
            effect.owner == product.preparedOwnerForTest() &&
            product.preparedPreviewGpu().faceVao == oldName &&
            projectionStillDirty);
        assert(context.validate());
        context.install(); context.install();
        assert(product.preparedPreviewGpu().faceVao != 0 &&
            product.preparedPreviewGpu().faceVao != oldName &&
            context.installTraceForTest() == [7, 5, 8]);
    }
    installProduct(capsule, 31, 0); installProduct(cone, 32, 1);
    installProduct(cylinder, 33, 2); installProduct(productSphere, 34, 3);
    installProduct(torus, 35, 4); installProduct(tube, 36, 5);
    assert(capsule.preparedRadialActivationForTest());
    assert(cone.preparedRadialActivationForTest());
    assert(cylinder.preparedRadialActivationForTest());
    assert(productSphere.preparedRadialActivationForTest() &&
        productSphere.preparedSphereMethodForTest() == 0 &&
        productSphere.preparedSphereSyncedAxisForTest() == 2);
    assert(torus.preparedActivationForTest());
    assert(tube.preparedActivationForTest());

    // prim.sphere shares the exact product class with prim.ellipsoid but its
    // resetSession preserves method while still synchronizing the axis.
    auto globe = new SphereTool(() => &mesh, &gpu, null, false);
    globe.seedPreparedRadialActivationForTest();
    globe.seedPreparedSphereForTest(1, 6);
    installProduct(globe, 37, 6);
    assert(globe.preparedRadialActivationForTest() &&
        globe.preparedSphereMethodForTest() == 6 &&
        globe.preparedSphereSyncedAxisForTest() == 1);

    // A joint identity failure aborts both owners without touching live state;
    // a fresh context and owner can retry the same concrete product.
    cylinder.seedPreparedRadialActivationForTest();
    cylinder.preparedPreviewGpu().faceVao = 71;
    auto faultGpu = GpuCreateOwner.fakeForLegacyInitTest(
        cylinder.preparedPreviewGpu());
    auto faultContext = new PreparedRecordContext(null, new RecordObserverHub());
    faultContext.setResourceIdentity(99, 100);
    assert(cylinder.prepareActivate(faultContext, faultGpu).accepted);
    assert(!faultContext.validate() && faultGpu.fakeCleanupCountForTest() == 1 &&
        cylinder.preparedPreviewGpu().faceVao == 71 &&
        !cylinder.preparedRadialActivationForTest());
    auto retryGpu = GpuCreateOwner.fakeForLegacyInitTest(
        cylinder.preparedPreviewGpu());
    auto retryContext = new PreparedRecordContext(null, new RecordObserverHub());
    retryContext.setResourceIdentity(7, 11);
    assert(cylinder.prepareActivate(retryContext, retryGpu).accepted &&
        retryContext.validate());
    retryContext.install();
    assert(cylinder.preparedRadialActivationForTest() &&
        retryContext.installTraceForTest() == [7, 5, 8]);

    GpuMesh foreignGpu;
    auto refuseContext = new PreparedRecordContext(null, new RecordObserverHub());
    refuseContext.setResourceIdentity(7, 11);
    auto refused = tube.prepareActivate(refuseContext,
        GpuCreateOwner.fakeForLegacyInitTest(&foreignGpu));
    assert(!refused.accepted && refused.kind == PreparedActivateKind.Primitive &&
        refused.owner == tube.preparedOwnerForTest() && !refuseContext.validate());
    auto nullGpuContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto nullGpu = tube.prepareActivate(nullGpuContext, null);
    assert(!nullGpu.accepted && !nullGpuContext.validate());

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

    import command_history : CommandHistory;
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
