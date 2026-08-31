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

@PreparedAggregate struct PreparedJournalEntry {
    OwnedId subject;
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
