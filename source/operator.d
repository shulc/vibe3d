module operator;

import toolpipe.packets : SubjectPacket, WorkplanePacket, SymmetryPacket,
                          SnapPacket, ActionCenterPacket, AxisPacket,
                          FalloffPacket, ConstrainPacket, PathPacket;

// ---------------------------------------------------------------------------
// Operator architecture — Phase 0 of doc/operator_refactor_plan.md.
//
// Unifies the kernel-side responsibilities of Stages (upstream packet
// publishers) and mesh-mutating Commands (terminal mesh operations) under
// one interface.
//
// The toolpipe is a sequence of Operators, each declaring which slot it
// occupies via its Task tag (WGHT, ACEN, AXIS, ACTR, ...). The engine walks
// the slot chain and evaluates each one in order — upstream operators
// publish their packets into the VectorStack; terminal operators (ACTR slot)
// read packets and mutate the mesh. The VectorStack is a packet bag;
// operators null-check a slot to discover what upstream published.
//
// Design choices:
//   * VectorStack is a fixed-size array indexed by PacketKind (compile-time
//     mapping from packet type to slot) — O(1) put/get with no hashing,
//     with null-handling semantics for absent packets.
//   * Operator is an interface; concrete types are either Stages (upstream)
//     or Commands (terminal). Multiple Operators may occupy one slot (the
//     WGHT-slot stacking case for falloff Mix Mode).
// ---------------------------------------------------------------------------

/// Toolpipe slot tag. Pipeline walks slots in declaration order on each
/// evaluation.
enum Task : ubyte {
    Work = 0,    // workplane basis
    Symm = 1,    // symmetry mirror
    Snap = 2,    // snap candidates
    Cons = 3,    // background-mesh constraint (post-snap, pre-acen)
    Acen = 4,    // action center
    Axis = 5,    // action axis
    Wght = 6,    // per-vert weight (falloff)
    Actr = 7,    // the actor: mutates the mesh
    Path = 8,    // path generator: publishes a parametric-curve packet
}

/// Packet type index. Compile-time mapping via `packetKindOf!T`; the
/// VectorStack stores slots indexed by this enum so put/get is O(1) with
/// no hashing.
///
/// Adding a new packet type: register it in PacketKind, extend the
/// `packetKindOf` template, expose put/get for it in VectorStack.
enum PacketKind : ubyte {
    Subject       = 0,
    Workplane     = 1,
    Symmetry      = 2,
    Snap          = 3,
    ActionCenter  = 4,
    ActionAxis    = 5,
    Falloff       = 6,
    Constrain     = 7,
    Path          = 8,
    Count         = 9
}

/// Compile-time map T → PacketKind. Used by VectorStack.put!T/get!T to
/// index the right slot without runtime type lookup. Adding a packet
/// type means adding a static-if branch here.
template packetKindOf(T) {
    static if (is(T == SubjectPacket))            enum packetKindOf = PacketKind.Subject;
    else static if (is(T == WorkplanePacket))     enum packetKindOf = PacketKind.Workplane;
    else static if (is(T == SymmetryPacket))      enum packetKindOf = PacketKind.Symmetry;
    else static if (is(T == SnapPacket))          enum packetKindOf = PacketKind.Snap;
    else static if (is(T == ActionCenterPacket))  enum packetKindOf = PacketKind.ActionCenter;
    else static if (is(T == AxisPacket))          enum packetKindOf = PacketKind.ActionAxis;
    else static if (is(T == FalloffPacket))       enum packetKindOf = PacketKind.Falloff;
    else static if (is(T == ConstrainPacket))     enum packetKindOf = PacketKind.Constrain;
    else static if (is(T == PathPacket))          enum packetKindOf = PacketKind.Path;
    else                                          static assert(false,
        "packetKindOf: unregistered packet type " ~ T.stringof
        ~ " — add a branch in source/operator.d");
}

/// Type-keyed packet bag — the only data channel between Operators in the
/// toolpipe. Upstream operators `put()` their packets; downstream
/// operators `get()` them. Missing packets return null — consumers MUST
/// null-check, since a slot is null when no upstream operator published it.
///
/// Lifetime: packets are pointers into stack-allocated storage owned by
/// the operator that put() them in. The VectorStack lives only for the
/// duration of one `pipeline.evaluate(vts)` call — operators that need
/// to retain a packet across frames must copy by value into their own
/// fields. Asserts on out-of-scope reads aren't possible without runtime
/// help; the convention is enforced by review.
struct VectorStack {
    private void*[PacketKind.Count] _slots;

    /// Publish a packet. Replaces any prior value in the slot — last
    /// writer wins. For WGHT-slot Mix Mode (Phase 8) the FalloffStage
    /// reads the existing FalloffPacket via get!FalloffPacket and
    /// publishes a composite *replacing* the previous one.
    void put(T)(T* packet) {
        _slots[packetKindOf!T] = cast(void*)packet;
    }

    /// Read a previously-published packet. Returns null if the slot is
    /// empty. Callers handle the missing-packet case (the operator
    /// gracefully degrades — e.g. MeshSmooth applies without falloff
    /// when get!FalloffPacket returns null).
    T* get(T)() {
        return cast(T*)_slots[packetKindOf!T];
    }

    /// Cheap presence check, equivalent to `get!T() !is null`. Useful
    /// when the operator only needs to gate behavior on a packet's
    /// existence without dereferencing it.
    bool has(T)() const {
        return _slots[packetKindOf!T] !is null;
    }

    /// Runtime presence check by PacketKind. The templated `has!T()`
    /// needs the packet type at compile time; this overload answers the
    /// same question for a kind discovered at runtime — used by the
    /// pipeline to validate each operator's `requiredPackets()` against
    /// what has actually been published (or supplied by the caller).
    bool has(PacketKind kind) const {
        return _slots[kind] !is null;
    }
}

/// Boilerplate stubs for terminal (Actr-slot) Operators. Provides
/// task() / requiredPackets() / reset() — the small fixed values
/// every convolve/transform command needs. evaluate(vts) is NOT
/// included so the implementing Command provides its own kernel.
/// Used by Phase 5 / Phase 6 migrants alike — Phase 6 ones write a
/// real evaluate(vts) body, Phase 5 ones used the OperatorActrShim
/// variant (deleted in Phase 6).
mixin template OperatorActrCommon() {
    Task task() const { return Task.Actr; }
    PacketKind[] requiredPackets() const { return [PacketKind.Subject]; }
    void reset() {}
}

/// One slot in the toolpipe. Implementations come in two flavors:
///
///   * Upstream (Work / Symm / Snap / Acen / Axis / Wght): read
///     SubjectPacket and optionally upstream packets from vts, publish
///     own packet via vts.put. MUST be idempotent — the pipeline is
///     re-walked every frame.
///
///   * Terminal (Actr): read packets from vts, mutate the subject
///     mesh in-place. Called once per drag-event / Apply click.
///
/// `task()` tags which slot the operator belongs to. `requiredPackets()`
/// declares dependencies on upstream packets — Pipeline validation
/// (Phase 7) warns when an Actr operator depends on Falloff but no
/// Wght-slot operator is plugged. Most operators leave this empty.
///
/// `reset()` is called when the operator is plugged into a fresh pipeline
/// (preset activation, scene reset).
interface Operator {
    Task task() const;
    /// Process upstream packets and (for Actr) mutate the mesh.
    /// Returns true on a meaningful effect, false on a no-op rejection
    /// (e.g. empty mesh, invalid count, no-op selection). Mirrors the
    /// bool return of the legacy `Command.apply()` so the HTTP /
    /// history dispatchers can distinguish "did nothing" from
    /// "succeeded" without throwing.
    bool evaluate(ref VectorStack vts);
    void reset();
    PacketKind[] requiredPackets() const;
}

// ---------------------------------------------------------------------------
// VectorStack unit tests
// ---------------------------------------------------------------------------

unittest {
    // Default-constructed vts has no packets.
    VectorStack vts;
    assert(!vts.has!SubjectPacket);
    assert(!vts.has!FalloffPacket);
    assert(vts.get!SubjectPacket is null);
}

unittest {
    // put/get round-trip — pointer identity preserved.
    VectorStack vts;
    SubjectPacket subj;
    vts.put(&subj);
    assert(vts.has!SubjectPacket);
    assert(vts.get!SubjectPacket is &subj);
}

unittest {
    // Multiple packet kinds coexist independently.
    VectorStack vts;
    SubjectPacket subj;
    FalloffPacket fp;
    fp.enabled = true;
    vts.put(&subj);
    vts.put(&fp);
    assert(vts.get!SubjectPacket is &subj);
    assert(vts.get!FalloffPacket.enabled);
    // Replacing one doesn't disturb the other.
    SubjectPacket subj2;
    vts.put(&subj2);
    assert(vts.get!SubjectPacket is &subj2);
    assert(vts.get!FalloffPacket.enabled);
}

unittest {
    // Last writer wins within a slot.
    VectorStack vts;
    FalloffPacket a; a.enabled = true;
    FalloffPacket b; b.enabled = false;
    vts.put(&a);
    vts.put(&b);
    assert(vts.get!FalloffPacket is &b);
    assert(!vts.get!FalloffPacket.enabled);
}

unittest {
    import math : Vec3;
    // PathPacket put/get round-trip — pointer identity preserved.
    VectorStack vts;
    PathPacket pp;
    pp.enabled = true;
    pp.knots   = [Vec3(0, 0, 0), Vec3(1, 0, 0)];
    vts.put(&pp);
    assert(vts.has!PathPacket);
    auto got = vts.get!PathPacket();
    assert(got is &pp);
    assert(got.enabled);
    assert(got.knots.length == 2);
    // PathPacket coexists independently with SubjectPacket.
    SubjectPacket subj;
    vts.put(&subj);
    assert(vts.get!PathPacket() is &pp);
    assert(vts.get!SubjectPacket() is &subj);
}
