module prepared_private_state;

import core.atomic : atomicOp;
import tools.create.box : BoxTool;
import tools.create.pen : PenTool;
import tools.create.primitive_create_tool : PrimitiveCreateTool, HandledCreateTool;
import tools.create.sphere : SphereTool;
import tools.create.vertex_place : VertexTool;

enum PreparedPrivateStateKind : ubyte { Box, Pen, Primitive, Vertex }
private enum PrimitiveProjection : ubyte { Base, Handled, Sphere }
struct PreparedPrivateStateToken { @disable this(this); private ulong ownerId, generation; }
struct ValidatedPrivateStateToken { @disable this(this); private ulong ownerId, generation; }
private shared ulong nextPrivateStateOwnerId;

/// Closed owner: concrete typed targets and fixed final install arms only.
final class PreparedPrivateStateOwner {
private:
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
    @property PreparedPrivateStateKind kind() const nothrow @nogc { return kind_; }
    bool owns(VertexTool target) const nothrow @nogc {
        return kind_ == PreparedPrivateStateKind.Vertex && vertexTarget is target;
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
        }
        pending = validated = false;
        validatedToken.ownerId = validatedToken.generation = 0;
    }
    void abort() nothrow @nogc { pending = validated = false; }
}

version(unittest) unittest {
    import mesh : Mesh, GpuMesh;
    Mesh mesh; GpuMesh gpu;
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
}
