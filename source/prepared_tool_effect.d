module prepared_tool_effect;

// P1.0a: the closed, value-owned language shared by future prepared tool
// transitions.  It is intentionally not wired to either activation door yet.

import std.traits : FieldNameTuple, FieldTypeTuple, isAssociativeArray,
                    isDelegate, isDynamicArray, isFunctionPointer,
                    isPointer, isScalarType, hasUDA;

enum PreparedOwnedContainer;
enum PreparedAggregate;

enum PreparedEffectKind : ubyte {
    None,
    Scalar,
    FixedRecord,
    OwnedBuffer,
    MeshDelta,
    DocumentDelta,
    PipeInstall,
    SessionInstall,
    StickyInstall,
    HistoryInstall,
    JournalEntry,
    CandidateHandle,
}

/// Closed value vocabulary for P1.0b.1 tool-instance state. Interpretation is
/// deliberately owned by each concrete tool installer; this is not a field
/// offset or byte-decoding protocol.
enum PreparedToolStateKind : ubyte { None, Bool, Int32, Vec3 }
enum PreparedParamKind : ubyte { None, DirtyFlag, SphereAxis }
enum PreparedDeactivateKind : ubyte {
    None, Array, Clone, RadialArray, Magnet, SmoothShift, StrokeExtrude,
    EdgeBevel, EdgeExtrude, PolyBevel, PolyExtrude, PolyInset, Reduction,
    VertexMerge, VertexBevel, VertexExtrude, Xfrm, Move, Rotate, Scale,
    CommandWrapper, Tack, TransformNormalUpload, Vertex,
}
enum PreparedActivateKind : ubyte { None, Vertex, Array, Clone, Magnet, Reduction }
enum PreparedRadialSweepKind : ubyte { Activate, Param, Deactivate }
enum PreparedRadialArrayKind : ubyte { Activate, Deactivate }
enum PreparedTransformActivationKind : ubyte { LinearAlign, RadialAlign }
enum PreparedTransformProductKind : ubyte { Move, Rotate, Scale }
enum PreparedMoveUpdateKind : ubyte {
    None, InactiveNoop, DraggingNoop, WrapperEditOpenNoop, Refresh
}

@PreparedAggregate struct PreparedActivateEffect {
    OwnedId owner;
    PreparedActivateKind kind;
}

@PreparedAggregate struct PreparedSessionActivateEffect {
    OwnedId owner;
    PreparedActivateKind kind;
    bool accepted;
}
@PreparedAggregate struct PreparedRadialSweepEffect {
    OwnedId owner;
    PreparedRadialSweepKind kind;
    bool accepted;
    size_t inserted;
}
@PreparedAggregate struct PreparedRadialArrayEffect {
    OwnedId owner;
    PreparedRadialArrayKind kind;
    bool accepted;
}
@PreparedAggregate struct PreparedTransformActivationEffect {
    OwnedId owner;
    PreparedTransformActivationKind kind;
    bool accepted;
}
@PreparedAggregate struct PreparedTransformProductEffect {
    OwnedId owner;
    PreparedTransformProductKind kind;
    bool accepted;
}
@PreparedAggregate struct PreparedMoveUpdateEffect {
    OwnedId owner;
    PreparedMoveUpdateKind kind;
    bool accepted;
}

/// Scalar-only dormant P1.0b.3d producer result. The concrete tool owns the
/// interpretation of its reset constants; no reference-bearing history or
/// observer state escapes PreparedRecordContext through this carrier.
@PreparedAggregate struct PreparedDeactivateEffect {
    OwnedId owner;
    PreparedDeactivateKind kind;
    bool historyAccepted;
    bool resourceAccepted;

    this(OwnedId owner, PreparedDeactivateKind kind, bool historyAccepted)
         pure nothrow @safe @nogc {
        this.owner = owner;
        this.kind = kind;
        this.historyAccepted = historyAccepted;
        this.resourceAccepted = true; // no resource obligation
    }
    this(OwnedId owner, PreparedDeactivateKind kind, bool historyAccepted,
         bool resourceAccepted) pure nothrow @safe @nogc {
        this.owner = owner;
        this.kind = kind;
        this.historyAccepted = historyAccepted;
        this.resourceAccepted = resourceAccepted;
    }
}

static assert(PreparedDeactivateEffect(OwnedId(1),
    PreparedDeactivateKind.Move, false).resourceAccepted);

@PreparedAggregate struct PreparedBoxParamEffect {
    OwnedId owner;
    bool historyAccepted;
    bool liveRunActive;
    int liveUndoDepth;
    bool paramBeforeValid;
}

@PreparedAggregate struct PreparedToolStateDelta {
    OwnedId owner;
    PreparedToolStateKind kind;
    bool boolValue;
    int intValue;
    float x, y, z;

    static PreparedToolStateDelta none(OwnedId owner) pure nothrow @safe @nogc {
        return PreparedToolStateDelta(owner, PreparedToolStateKind.None);
    }
    static PreparedToolStateDelta boolean(OwnedId owner, bool value) pure nothrow @safe @nogc {
        auto result = PreparedToolStateDelta(owner, PreparedToolStateKind.Bool);
        result.boolValue = value;
        return result;
    }
    static PreparedToolStateDelta integer(OwnedId owner, int value) pure nothrow @safe @nogc {
        auto result = PreparedToolStateDelta(owner, PreparedToolStateKind.Int32);
        result.intValue = value;
        return result;
    }
    static PreparedToolStateDelta vec3(OwnedId owner, float x, float y, float z) pure nothrow @safe @nogc {
        auto result = PreparedToolStateDelta(owner, PreparedToolStateKind.Vec3);
        result.x = x; result.y = y; result.z = z;
        return result;
    }
}

@PreparedAggregate struct PreparedParamDelta {
    OwnedId owner;
    PreparedParamKind kind;
    bool boolValue;
    int intValue;
    float x, y, z;

    static PreparedParamDelta none(OwnedId owner) pure nothrow @safe @nogc {
        return PreparedParamDelta(owner, PreparedParamKind.None);
    }
    static PreparedParamDelta dirty(OwnedId owner) pure nothrow @safe @nogc {
        auto result = PreparedParamDelta(owner, PreparedParamKind.DirtyFlag);
        result.boolValue = true;
        return result;
    }
    static PreparedParamDelta sphereAxis(OwnedId owner, int axis,
                                          float x, float y, float z)
                                          pure nothrow @safe @nogc {
        auto result = PreparedParamDelta(owner, PreparedParamKind.SphereAxis);
        result.intValue = axis; result.x = x; result.y = y; result.z = z;
        return result;
    }
}

/// An owner-issued identity.  It is not an address and cannot borrow owner
/// storage.  Zero is the empty token in every owner namespace.
@PreparedAggregate struct OwnedId { ulong value; }

/// Explicitly owned immutable variable-sized storage. The slice is private so
/// clients cannot manufacture a borrowed carrier with a struct literal;
/// construction always copies. Struct copies share immutable backing safely.
@PreparedOwnedContainer struct OwnedBytes {
    alias Element = immutable(ubyte);
private:
    immutable(ubyte)[] storage_;
public:
    static OwnedBytes copyOf(const(ubyte)[] source) {
        OwnedBytes result;
        result.storage_ = cast(immutable(ubyte)[]) source.dup;
        return result;
    }
    size_t length() const pure nothrow @safe @nogc { return storage_.length; }
    ubyte at(size_t i) const pure nothrow @safe @nogc { return storage_[i]; }
    bool equals(const(ubyte)[] rhs) const pure nothrow @safe @nogc {
        return storage_ == rhs;
    }
}

@PreparedAggregate struct PreparedScalar { OwnedId owner; ulong value; }
@PreparedAggregate struct PreparedFixedRecord { OwnedId owner; ulong a; ulong b; }
@PreparedAggregate struct PreparedMeshDelta { OwnedId owner; OwnedBytes bytes; }
@PreparedAggregate struct PreparedDocumentDelta { OwnedId owner; OwnedBytes bytes; }
@PreparedAggregate struct PreparedInstall { OwnedId owner; OwnedBytes bytes; }
@PreparedAggregate struct PreparedHistoryInstall { OwnedId owner; OwnedBytes bytes; }

/// Scalar identity issued by the subject owner. It contains no dereferenceable
/// address; only that owner can resolve the current generation to its retained
/// subject.
@PreparedAggregate struct PreparedSubjectToken {
    ulong ownerId;
    ulong generation;
    ulong birthId;
}

@PreparedAggregate struct PreparedJournalEntry {
    PreparedSubjectToken subject;
    uint flags;
    uint selectionDomains;
}

@PreparedAggregate struct PreparedCandidateHandle { OwnedId owner; OwnedId candidate; }

/// Final tagged carrier.  All payload slots are members of the closed algebra;
/// `kind` selects exactly one.  Adding a kind therefore changes this module's
/// exhaustive commit switch and the source census together.
@PreparedAggregate struct PreparedToolEffect {
    PreparedEffectKind kind;
    PreparedScalar scalar;
    PreparedFixedRecord fixedRecord;
    OwnedBytes ownedBuffer;
    PreparedMeshDelta meshDelta;
    PreparedDocumentDelta documentDelta;
    PreparedInstall install;
    PreparedHistoryInstall history;
    PreparedJournalEntry journal;
    PreparedCandidateHandle candidate;
    PreparedToolStateDelta toolState;
    PreparedParamDelta param;
}

/// Recursive allow-by-construction check. OwnedBytes is the sole admitted
/// container with backing storage; its constructor owns a copy. Ordinary
/// slices/AAs, references, pointers and executable values are rejected even
/// when nested in another aggregate.
template isPreparedField(T) {
    static if (hasUDA!(T, PreparedOwnedContainer))
        enum isPreparedField = isPreparedField!(T.Element);
    else static if (is(T == string) || isDynamicArray!T || isAssociativeArray!T
                 || isPointer!T || isDelegate!T || isFunctionPointer!T
                 || is(T == class) || is(T == interface))
        enum isPreparedField = false;
    else static if (is(T == enum) || isScalarType!T)
        enum isPreparedField = true;
    else static if (hasUDA!(T, PreparedAggregate)) {
        enum isPreparedField = allPreparedFields!(FieldTypeTuple!T);
    } else
        enum isPreparedField = false;
}

private template allPreparedFields(T...) {
    static if (T.length == 0) enum allPreparedFields = true;
    else enum allPreparedFields = isPreparedField!(T[0])
                               && allPreparedFields!(T[1 .. $]);
}

template requirePreparedField(T) {
    static assert(isPreparedField!T,
        "prepared effect field is not owned: " ~ T.stringof);
    enum requirePreparedField = true;
}

static assert(requirePreparedField!PreparedToolEffect);
