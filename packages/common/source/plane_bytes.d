// ---------------------------------------------------------------------------
// plane_bytes — ONE accounting rule for "how many bytes does this hold?", and
// the only place it is written down (task 1903 Stage B, plan §8.2).
//
// WHY A MODULE OF ITS OWN. Two instruments answer that question about the same
// edit: `MeshEditDelta.byteSize()` (`source/mesh_edit_delta.d`) and
// `MeshSnapshot.byteSize()` (`source/snapshot.d`). The whole point of the §8
// measurement is the RATIO between them, and a ratio between two different
// definitions of the word "size" is not a measurement. Before this module the
// delta's method counted 19 of its 26 heap arrays and the snapshot had no
// method at all — the delta's undercount grew exactly with the `FaceReindex`
// entries this task is about to start emitting, i.e. it was biased in the
// DELTA's favour, the opposite direction from the bias the card warns about.
//
// Neither `mesh_edit_delta` nor `snapshot` imports the other, and this helper
// belongs to neither of them, so it lives here: a leaf module that imports
// nothing but `std.traits` and can therefore be imported from anywhere without
// a cycle.
//
// ---------------------------------------------------------------------------
// THE RULE, in full, because every term of it is load-bearing somewhere:
//
//   1. A flat heap array contributes `length * element.sizeof`.
//   2. An array OF arrays contributes the outer SLICE HEADERS
//      (`length * T.sizeof`, 16 bytes each on 64-bit) PLUS every inner array's
//      element bytes. The headers are not a rounding term — they are what
//      makes an empty-but-present inner array cost something, which is what
//      lets `tests/unit/byte_size_test.d` enumerate the fields mechanically:
//      a field populated with one default element must move the number, or the
//      enumeration cell cannot tell "counted" from "not counted".
//   3. An associative array contributes `length * (key.sizeof + value.sizeof)`
//      — NOT zero. `MeshSnapshot.edgeSetMask` is a `ulong[ulong]`, the one
//      plane that looks like a scalar field and is not.
//   4. A string contributes its byte length (it is rule 1 with `char`), and a
//      registry of names is rule 2 over strings.
//   5. The CONTAINING struct's own `.sizeof` is added ONCE — once per op-log
//      entry, once per snapshot — by the caller, not by this helper.
//
// What the rule deliberately does NOT model: GC block rounding, the capacity
// slack `~=` leaves behind, and the collector's own bookkeeping. Those are real
// (memory `measuring_allocation_in_d`: the GC counter reports the BLOCK size,
// and `~=` extends page-backed blocks in place) and they are measured
// SEPARATELY, by the `GC.stats` readout beside the byte ratio — see plan §8.3
// item 4 and the 0680 regression, which was collector work rather than bytes
// and which no byte ratio could have seen.
// ---------------------------------------------------------------------------
module plane_bytes;

import std.traits : isAssociativeArray, KeyType, ValueType;

/// Rules 1, 2 and 4 — a heap array, flat or nested, `string` included.
///
/// The nested case is selected with `is(T == U[], U)` and NOT `is(T : U[], U)`,
/// and the difference is a real defect this spelling avoids: a STATIC array
/// element (`Mesh.edges` is `uint[2][]`) implicitly CONVERTS to a slice, so the
/// `:` form would take the nested branch on it and count each pair twice —
/// once as the 8 bytes it occupies and once again as "two `uint`s behind a
/// pointer it does not have".
size_t planeBytes(T)(const(T)[] a) pure nothrow @safe @nogc
{
    static if (is(T == U[], U))
    {
        size_t n = a.length * T.sizeof;          // the outer slice headers
        foreach (ref e; a) n += e.length * U.sizeof;
        return n;
    }
    else
        return a.length * T.sizeof;
}

/// Rule 3 — an associative array. Counts one key plus one value per entry;
/// the hash table's own buckets and the per-entry allocation overhead are
/// outside the rule (see the module comment on what is measured separately).
size_t planeBytes(AA)(const(AA) aa) pure nothrow @safe @nogc
if (isAssociativeArray!AA)
{
    return aa.length * (KeyType!AA.sizeof + ValueType!AA.sizeof);
}

// ---------------------------------------------------------------------------
// The rule's own cells. These are about the RULE, not about either instrument;
// the instruments are enumerated field-by-field in
// `tests/unit/byte_size_test.d`.
// ---------------------------------------------------------------------------

unittest // rule 1: a flat array is elements times element size
{
    uint[] a = [1, 2, 3];
    assert(planeBytes(a) == 3 * uint.sizeof);

    float[] f;
    assert(planeBytes(f) == 0, "a null array holds nothing");
}

unittest // rule 2: a nested array carries its headers AND its elements
{
    uint[][] nested = [[1u, 2u, 3u, 4u], [5u, 6u]];
    immutable size_t headers = 2 * (uint[]).sizeof;
    assert(planeBytes(nested) == headers + 6 * uint.sizeof);

    // The property the enumeration test rests on: PRESENT but EMPTY inner
    // arrays still cost their headers, so populating a nested field with one
    // default element is observable.
    uint[][] oneEmpty = new uint[][](1);
    assert(planeBytes(oneEmpty) == (uint[]).sizeof,
           "a present-but-empty inner array must still cost its header — "
         ~ "without this the field enumeration in byte_size_test cannot "
         ~ "distinguish a counted nested field from an uncounted one");
}

unittest // rule 2 must NOT fire on a STATIC array element (Mesh.edges)
{
    uint[2][] edges = [[0u, 1u], [1u, 2u], [2u, 3u]];
    assert(planeBytes(edges) == 3 * (uint[2]).sizeof,
           "uint[2][] holds its pairs INLINE — counting them again as if they "
         ~ "sat behind a slice header would double the edge plane");
    assert((uint[2]).sizeof == 2 * uint.sizeof, "sanity: a static pair is 8 bytes");
}

unittest // rule 3: an AA is not free
{
    ulong[ulong] aa;
    aa[1] = 7;
    aa[2] = 9;
    assert(planeBytes(aa) == 2 * (ulong.sizeof + ulong.sizeof));

    ulong[ulong] empty;
    assert(planeBytes(empty) == 0);
}

unittest // rule 4: strings, and registries of strings
{
    string s = "abcd";
    assert(planeBytes(s) == 4);

    string[] names = ["a", "bcd"];
    assert(planeBytes(names) == 2 * string.sizeof + 4);
}
