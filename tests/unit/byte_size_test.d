// byte_size_test — the two instruments of task 1903's O(Δ) measurement, and
// the cells that make them able to be WRONG (plan §8.2, mutations M-B1 / M-B2).
//
// WHY THIS FILE EXISTS AT ALL. `MeshEditDelta.byteSize()` and
// `MeshSnapshot.byteSize()` are measuring devices, and a measuring device that
// under-reports is invisible: the number it prints looks like a number. Before
// Stage B the delta's method counted 19 of its 26 heap arrays (six of the
// missing seven belong to `Kind.FaceReindex`, the entries this task is about to
// start emitting, so the bias grew with the work) and the snapshot had no
// method at all. Both are now written to one rule — `source/plane_bytes.d` —
// and both are checked here two ways:
//
//   1. **MECHANICALLY, by field enumeration.** Every dynamic array (and every
//      AA) declared on `MeshOpEntry` / `MeshSnapshot` is populated with ONE
//      element and then cleared; the number must move. A field added later
//      without an accounting line therefore reddens by construction, which is
//      exactly the failure that lost the seven. There is no allowlist and no
//      skip: an element type this file cannot mint is a `static assert`, not a
//      silently-skipped field.
//   2. **AGAINST A HAND-WRITTEN FLOOR**, typed out from the fixture's own
//      element counts rather than by calling the thing under test. The
//      enumeration proves a field is READ; the floor proves it is read at the
//      right SIZE — a `meshMaps` term that counts the registry but not each
//      map's `data` passes (1) and fails (2).
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT. M-B1 reddens the delta
// floor and M-B2 the snapshot map term; run them in isolation, or the second
// hides behind the first.
module tests.unit.byte_size_test;

import std.format : format;
import std.traits : FieldNameTuple, isDynamicArray, isAssociativeArray,
                    ForeachType, KeyType, ValueType;

import mesh;
import math            : Vec3;
import mesh_edit_delta : MeshEditDelta, MeshOpEntry, MeshEditScope;
import snapshot        : MeshSnapshot;
import plane_bytes     : planeBytes;

import tests.unit.fixtures : makeTaggedGridFull;

// ---------------------------------------------------------------------------
// One element of any field type the two aggregates declare.
//
// The `static assert(false)` arm is the point of the helper: a new field whose
// element type this file cannot mint stops the BUILD with a message naming the
// type, instead of being quietly dropped from the enumeration. A skipped field
// is a green cell that cannot come out differently.
// ---------------------------------------------------------------------------
private F oneElement(F)()
{
    static if (is(F == string))
    {
        return "x";
    }
    else static if (isAssociativeArray!F)
    {
        F aa;
        aa[KeyType!F.init] = ValueType!F.init;
        return aa;
    }
    else static if (isDynamicArray!F)
    {
        alias E = ForeachType!F;
        static if (__traits(compiles, new E[](1)))
            return new E[](1);
        else static if (is(E == FaceIdx))
        {
            // `FaceIdx` @disables its default constructor on purpose (a
            // FaceIdx nobody minted would be face 0, and face 0 is real), so
            // it has to be minted through its named escape.
            F a;
            a ~= FaceIdx.assumeFaceSpace(0);
            return a;
        }
        else
            static assert(false,
                "byte_size_test.oneElement: no way to mint one " ~ E.stringof
              ~ " — add a case here rather than letting the field enumeration "
              ~ "skip it silently");
    }
    else
        static assert(false, "oneElement called on a non-container: " ~ F.stringof);
}

/// Populate every container field of `agg` with exactly one element.
private void fillContainers(T)(ref T agg)
{
    static foreach (i, name; FieldNameTuple!T)
    {{
        alias F = typeof(T.tupleof[i]);
        static if (isDynamicArray!F || isAssociativeArray!F)
            agg.tupleof[i] = oneElement!F();
    }}
}

// ===========================================================================
// M-B1's mechanical half — EVERY `MeshOpEntry` array reaches
// `MeshEditDelta.byteSize()`.
//
// Mutation: delete any accounting line from `MeshEditDelta.byteSize` (the plan
// names `faceMat`) → that field's cell reddens by name.
// ===========================================================================

unittest // MeshEditDelta.byteSize reads every array field MeshOpEntry declares
{
    MeshOpEntry full;
    fillContainers(full);

    MeshEditDelta whole;
    whole.log = [full];
    immutable size_t wholeBytes = whole.byteSize();

    // Non-vacuity: the populated entry must cost MORE than an empty one, or
    // every differential below is a subtraction of two equal numbers.
    MeshEditDelta bare;
    bare.log = [MeshOpEntry.init];
    assert(wholeBytes > bare.byteSize(),
        format("a MeshOpEntry with every array populated (%s bytes) does not "
             ~ "cost more than an empty one (%s bytes) — byteSize is reading "
             ~ "nothing at all", wholeBytes, bare.byteSize()));

    size_t counted = 0;
    static foreach (i, name; FieldNameTuple!MeshOpEntry)
    {{
        alias F = typeof(MeshOpEntry.tupleof[i]);
        static if (isDynamicArray!F || isAssociativeArray!F)
        {
            MeshOpEntry minus = full;
            minus.tupleof[i] = F.init;
            MeshEditDelta without;
            without.log = [minus];
            assert(without.byteSize() < wholeBytes,
                format("MeshOpEntry.%s is NOT counted by MeshEditDelta.byteSize()"
                     ~ " — clearing it left the total at %s. Every heap array on"
                     ~ " the entry must have an accounting line; this is how the"
                     ~ " seven FaceReindex arrays were lost (plan §8.2).",
                       name, without.byteSize()));
            ++counted;
        }
    }}

    // The enumeration's own floor: if `FieldNameTuple` ever stopped seeing the
    // fields, every cell above would vacuously not run.
    assert(counted >= 26,
        format("only %s array fields were enumerated on MeshOpEntry; it "
             ~ "declares at least 26 — the enumeration is not seeing them",
               counted));
}

// ===========================================================================
// M-B2's mechanical half — EVERY `MeshSnapshot` container reaches
// `MeshSnapshot.byteSize()`.
// ===========================================================================

unittest // MeshSnapshot.byteSize reads every container field it declares
{
    MeshSnapshot full;
    fillContainers(full);
    immutable size_t wholeBytes = full.byteSize();

    assert(wholeBytes > MeshSnapshot.init.byteSize(),
        "a MeshSnapshot with every container populated does not cost more "
      ~ "than an empty one — byteSize is reading nothing at all");

    size_t counted = 0;
    static foreach (i, name; FieldNameTuple!MeshSnapshot)
    {{
        alias F = typeof(MeshSnapshot.tupleof[i]);
        static if (isDynamicArray!F || isAssociativeArray!F)
        {
            MeshSnapshot minus = full;
            minus.tupleof[i] = F.init;
            assert(minus.byteSize() < wholeBytes,
                format("MeshSnapshot.%s is NOT counted by MeshSnapshot.byteSize()"
                     ~ " — clearing it left the total at %s. `capture` duplicates"
                     ~ " it, so the measurement must charge for it.",
                       name, minus.byteSize()));
            ++counted;
        }
    }}

    assert(counted >= 19,
        format("only %s container fields were enumerated on MeshSnapshot; it "
             ~ "declares 19 — the enumeration is not seeing them", counted));

    // `edgeSetMask` is the one that looks scalar and is not: a `ulong[ulong]`
    // whose naive reading is zero bytes. Named explicitly because the cell
    // above would also pass on a `length * 0` accounting.
    MeshSnapshot aaOnly;
    aaOnly.edgeSetMask[7] = 3;
    assert(aaOnly.byteSize() > MeshSnapshot.init.byteSize(),
        "MeshSnapshot.edgeSetMask (ulong[ulong]) contributes zero bytes — "
      ~ "rule 3 of plane_bytes exists precisely for this plane");
}

// ===========================================================================
// M-B1 — the delta's HAND-WRITTEN FLOOR.
//
// The entry below is typed out, so its cost is arithmetic anyone can redo
// without running the method under test. Mutation: delete the `faceMat` line
// from `MeshEditDelta.byteSize` → "delta byteSize N is below the hand-derived
// floor M".
// ===========================================================================

unittest // a hand-built RemoveFaces entry is at or above its hand-derived floor
{
    MeshOpEntry e;
    e.kind       = MeshOpEntry.Kind.RemoveFaces;
    e.fIdx       = [FaceIdx.assumeFaceSpace(1),
                    FaceIdx.assumeFaceSpace(4),
                    FaceIdx.assumeFaceSpace(7)];
    e.faceLists  = [[0u, 1u, 2u, 3u], [4u, 5u, 6u, 7u], [8u, 9u, 10u, 11u]];
    e.faceMat    = [1u, 0u, 1u];
    e.facePrt    = [0u, 2u, 5u];
    e.faceSub    = [0u, 1u, 0u];
    e.faceSetMsk = [0UL, 1UL, 0UL];
    e.faceOrd    = [0, 11, 23];

    MeshEditDelta d;
    d.log = [e];

    // Written out term by term, in the order the entry declares them. NOT a
    // call to planeBytes and NOT a call to byteSize — an independent sum.
    immutable size_t floor =
          MeshOpEntry.sizeof                    // the entry itself, once
        + 3 * FaceIdx.sizeof                    // fIdx
        + 3 * (uint[]).sizeof + 12 * uint.sizeof// faceLists: headers + corners
        + 3 * uint.sizeof                       // faceMat
        + 3 * uint.sizeof                       // facePrt
        + 3 * uint.sizeof                       // faceSub
        + 3 * ulong.sizeof                      // faceSetMsk
        + 3 * int.sizeof;                       // faceOrd

    assert(d.byteSize() >= floor,
        format("delta byteSize %s is below the hand-derived floor %s — an "
             ~ "accounting line is missing from MeshEditDelta.byteSize()",
               d.byteSize(), floor));
}

unittest // the RemoveVerts SELECTION-SET payload is charged for (Stage L5-b)
{
    // WHY THIS CELL EXISTS. §8's whole subject is the delta-vs-snapshot RATIO,
    // and it is only a measurement while `byteSize` reads every array. Stage
    // L5-b put three more on `Kind.RemoveVerts`; unread, a compaction entry
    // over a mesh with real selection sets reports roughly the size of an
    // empty one, and the ratio is biased in the DELTA's favour — the same
    // direction, and the same mechanism, as the seven arrays Stage B
    // recovered.
    //
    // MUTATION: delete any one of the three `vertSetMaskBefore` /
    // `edgeSetKeys` / `edgeSetWords` lines from
    // `MeshEditDelta.byteSize` -> "delta byteSize N is below the hand-derived
    // floor M". The FieldNameTuple census below this file's fold reddens too,
    // by field NAME; both are kept, because the census cannot say the sum is
    // right and this cannot say a NEW field was added.
    MeshOpEntry e;
    e.kind               = MeshOpEntry.Kind.RemoveVerts;
    e.vIdx               = [3u, 7u, 11u];
    e.pos                = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)];
    e.vertSetMaskBefore  = [1UL, 0UL, 5UL];
    e.edgeSetKeys  = [(3UL << 32) | 7UL, (7UL << 32) | 11UL];
    e.edgeSetWords = [1UL, 3UL];

    MeshEditDelta d;
    d.log = [e];

    // Written out term by term, an independent sum — NOT a call to planeBytes
    // and NOT a call to byteSize.
    immutable size_t floor =
          MeshOpEntry.sizeof                    // the entry itself, once
        + 3 * uint.sizeof                       // vIdx
        + 3 * Vec3.sizeof                       // pos
        + 3 * ulong.sizeof                      // vertSetMaskBefore
        + 2 * ulong.sizeof                      // edgeSetKeys
        + 2 * ulong.sizeof;                     // edgeSetWords

    assert(d.byteSize() >= floor,
        format("delta byteSize %s is below the hand-derived floor %s — an "
             ~ "accounting line is missing from MeshEditDelta.byteSize() for "
             ~ "Kind.RemoveVerts' selection-set payload (task 1903 Stage L5-b)",
               d.byteSize(), floor));

    // …and the payload is a real term, not noise inside the struct: the same
    // entry with the three arrays EMPTY must be strictly smaller. Without this
    // the floor above is satisfied by `MeshOpEntry.sizeof` alone on a tree
    // where all three accounting lines were deleted at once.
    MeshOpEntry bare;
    bare.kind = MeshOpEntry.Kind.RemoveVerts;
    bare.vIdx = e.vIdx.dup;
    bare.pos  = e.pos.dup;
    MeshEditDelta db;
    db.log = [bare];
    assert(d.byteSize() == db.byteSize() + 7 * ulong.sizeof,
        format("the selection-set payload accounts for %s bytes, expected "
             ~ "exactly 7 * 8 = 56 (3 vertex words + 2 keys + 2 words). A "
             ~ "difference of 0 means all three accounting lines are missing "
             ~ "together, which the floor assert above cannot see",
               d.byteSize() - db.byteSize()));
}

unittest // the FaceReindex payload is charged for — the six arrays that were lost
{
    // A FaceReindex entry is O(mesh) BY CONSTRUCTION (mesh_planes.rewriteFaces
    // dups every post-rewrite winding). If its six payload arrays are not
    // counted, Cell C of the §8 measurement — whose whole subject is that cost
    // — reads roughly the size of an empty entry.
    MeshOpEntry e;
    e.kind              = MeshOpEntry.Kind.FaceReindex;
    e.faceOldOfNew      = [0u, 1u, 2u, 3u];
    e.oldFaceCount      = 4;
    e.newFaceLists      = [[0u, 1u, 2u, 3u], [1u, 2u, 3u, 4u],
                           [2u, 3u, 4u, 5u], [3u, 4u, 5u, 6u]];
    e.faceSurvivorIdx   = [FaceIdx.assumeFaceSpace(2)];
    e.faceSurvivorLists = [[9u, 8u, 7u]];

    MeshEditDelta d;
    d.log = [e];

    immutable size_t floor =
          MeshOpEntry.sizeof
        + 4 * uint.sizeof                        // faceOldOfNew
        + 4 * (uint[]).sizeof + 16 * uint.sizeof // newFaceLists
        + 1 * FaceIdx.sizeof                     // faceSurvivorIdx
        + 1 * (uint[]).sizeof + 3 * uint.sizeof; // faceSurvivorLists

    assert(d.byteSize() >= floor,
        format("a FaceReindex entry reports %s bytes, below the hand-derived "
             ~ "floor %s — the payload this task's &rw ops emit is not being "
             ~ "charged for", d.byteSize(), floor));
}

// ===========================================================================
// M-B2 — the snapshot's HAND-WRITTEN FLOOR, on the §8 stand.
// ===========================================================================

unittest // MeshSnapshot.capture(makeTaggedGridFull(10)) clears its floor
{
    auto m  = makeTaggedGridFull(10);
    auto sn = MeshSnapshot.capture(m);

    // The stand must actually carry the planes, or the floor below is a sum of
    // zeroes and the whole cell is vacuous. This is the same non-vacuity the
    // fixture's own unittest asserts; repeated here because THIS cell is the
    // one that would go quietly green on a cube.
    assert(m.meshMaps.length >= 2, "the stand carries a corner map AND a point map");
    assert(m.edgeSetMask.length > 0, "the stand carries the AA plane");
    assert(m.surfaces.length >= 2, "the stand carries a real surface registry");

    size_t floor = 0;
    floor += m.vertices.length * Vec3.sizeof;
    floor += m.edges.length * (uint[2]).sizeof;
    foreach (fi; 0 .. m.faces.length) floor += m.faces[fi].length * uint.sizeof;
    floor += m.vertexMarks.length * uint.sizeof;
    floor += m.edgeMarks.length   * uint.sizeof;
    floor += m.faceMarks.length   * uint.sizeof;
    floor += m.vertexSelectionOrder.length * int.sizeof;
    floor += m.edgeSelectionOrder.length   * int.sizeof;
    floor += m.faceSelectionOrder.length   * int.sizeof;
    floor += m.surfaces.length * Surface.sizeof;
    floor += m.faceMaterial.length * uint.sizeof;
    floor += m.facePart.length     * uint.sizeof;
    foreach (ref mm; m.meshMaps) floor += mm.data.length * float.sizeof;
    floor += m.vertexSetMask.length * ulong.sizeof;
    floor += m.faceSetMask.length   * ulong.sizeof;
    floor += m.edgeSetMask.length   * (ulong.sizeof * 2);

    assert(sn.byteSize() >= floor,
        format("snapshot byteSize %s is below the hand-derived floor %s on "
             ~ "makeTaggedGridFull(10)", sn.byteSize(), floor));
}

unittest // the map plane specifically — the enumeration cannot see its SIZE
{
    // An accounting that counts `meshMaps.length * MeshMap.sizeof` and forgets
    // each map's `data` passes the field enumeration above (the term is
    // non-zero) and under-reports a real mesh by the largest single plane it
    // has. This is the cell M-B2 reddens.
    auto m  = makeTaggedGridFull(10);
    auto sn = MeshSnapshot.capture(m);

    size_t mapDataBytes = 0;
    foreach (ref mm; m.meshMaps) mapDataBytes += mm.data.length * float.sizeof;
    assert(mapDataBytes > 0,
        "the stand carries no map DATA — this cell would be vacuous");

    auto stripped = sn;
    stripped.meshMaps = null;

    assert(sn.byteSize() >= stripped.byteSize() + mapDataBytes,
        format("snapshot byteSize omits the map plane: with maps %s, without "
             ~ "maps %s, and the maps hold %s bytes of data",
               sn.byteSize(), stripped.byteSize(), mapDataBytes));
}

// ===========================================================================
// The production witness — a REAL recorded delta, and the O(Δ) property the
// whole measurement rests on.
//
// Neither floor above proves the delta a live kernel records is proportional
// to the EDIT rather than to the mesh. This cell does, without depending on
// the exact entry shape a kernel chooses: twice the edit must cost more than
// the edit, on a mesh whose size never changes.
// ===========================================================================

private size_t deltaBytesForFaceDelete(int gridN, in size_t[] victims)
{
    Mesh m = makeTaggedGridFull(gridN);
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Polygons | MeshEditScope.Marks);
        bool[] mask = new bool[](m.faces.length);
        foreach (v; victims) mask[v] = true;
        cast(void) ed.deleteFacesByMask(mask);
        d = ed.close();
    }
    assert(!d.isEmpty(), "deleteFacesByMask under a recording batch logged nothing");
    return d.byteSize();
}

unittest // a recorded delta scales with the EDIT, not with the mesh
{
    // Faces chosen non-adjacent on a 10x10 grid (row-major fi = i*10 + j) so
    // the delete strands no vertex and the entry stays a clean RemoveFaces.
    immutable size_t three = deltaBytesForFaceDelete(10, [11, 44, 77]);
    immutable size_t six   = deltaBytesForFaceDelete(10, [11, 13, 44, 46, 77, 79]);

    assert(six > three,
        format("deleting six faces recorded %s bytes and deleting three "
             ~ "recorded %s — the op-log is not proportional to the edit, "
             ~ "which is the premise the whole O(Delta) measurement rests on",
               six, three));

    // …and the same three-face edit on a mesh with 3.24x the faces must not
    // cost 3.24x as much. This is Cell A's claim in miniature: it is what
    // separates an O(Delta) log from a snapshot in disguise.
    immutable size_t threeBig = deltaBytesForFaceDelete(18, [11, 44, 77]);
    assert(threeBig < three * 2,
        format("the same 3-face delete cost %s bytes on a 10x10 grid and %s on "
             ~ "an 18x18 one — the log is scaling with the MESH", three, threeBig));
}
