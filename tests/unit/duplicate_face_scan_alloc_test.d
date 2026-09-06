// TASK 2020 — A PER-FACE READ OF `Mesh.selectedFaces` MUST NOT COME BACK,
// AT EITHER OF THE TWO SITES THAT HAD IT. Two cells live here, one per site:
// `duplicateSelectedFaces` (first) and the weld/dedup tail of
// `arrayFacesGrid` (second). They are separate cells because a mutation of
// one site is invisible to the other's driver — reverting the array site
// alone left the whole module gate green at 503 modules, exit 0, which is
// how the second cell came to be written at all.
//
// WHAT THIS PINS. `Mesh.selectedFaces` is an `@property` that materialises a
// fresh `bool[faces.length]` on every call. Reading it from inside a loop over
// `faces` therefore costs F bytes per face, i.e. F² bytes for the loop — and
// `duplicateSelectedFaces` did exactly that, twice. Measured before the fix:
// 5.1 s at 99 856 faces, 28.5 s at 202 500, 121.6 s at 399 424 (exponent 2.1
// against a face count that grew 4×), which is how the operation walked past
// the command bridge's own 120 s cap at the owner's 1M target size. After the
// fix, the same three sizes are 0.14 / 0.26 / 0.57 s and 1.78 s at 1M.
//
// WHY BYTES AND NOT SECONDS. A wall-clock ladder needs a quiet host and a
// tolerance nobody can defend; the allocation is the defect itself and is
// deterministic. `GC.allocatedInCurrentThread` charges an APPEND-grown array
// grown WITHOUT a reserve at about 8 KB however long it gets, because druntime
// extends the page-backed block in place (task 2160's finding), and an up-front
// `new T[](n)` at its PAGE-ROUNDED block — the payload rounded up to a 4 KiB
// multiple. That second half is measured, not inherited: the broken minus fixed
// residual of the array cell below is 16 350 / 24 576 / 40 932 B per arrayed
// face at F = 5 000 / 9 800 / 20 000, against 2·⌈F/4096⌉·4096 =
// 16 384 / 24 576 / 40 960 — within 0.2 %, and NOT the 2·F the payload model
// predicts. Both halves point the same way here: the legitimate part of these
// kernels is all appends and is therefore UNDER-counted, while the defect is an
// up-front `new bool[]` and is counted in full and a little over. The two
// populations of the FIRST cell are 965 B/face (fixed) against ~25 500 B/face
// (broken) at F = 10 000, so its ceiling has 4× headroom over the first and
// 6× clearance under the second.
//
// WHY THE COUNT IS QUADRATIC IN F AND NOT IN THE SELECTION. Both loops visit
// EVERY face and evaluate the property before testing the selection bit, so one
// selected face on a 1M grid paid the same ~2 TB of churn as half of them. That
// is what separated this from "duplicating a lot of geometry is expensive": on
// the live app at n=1000 with a SINGLE face selected, the command still ran past
// the bridge's 120 s leash. It is why the cell below keeps a half selection but
// the ceiling is expressed PER FACE OF THE MESH rather than per cloned face.
//
// MUTATION, FIRST CELL (2026-09-06): restoring either `selectedFaces[fi]`
// inside the two loops of `Mesh.duplicateSelectedFaces` reddens that cell's
// LAST assert, with the measured per-face figure in its message; the four
// counted floors above it — which the broken code also satisfies — stay green
// in the same run and so are bought by it.
module tests.unit.duplicate_face_scan_alloc_test;

import core.memory : GC;
import math : Vec3;
import mesh;
import mesh_edit_delta : MeshEditScope;

// The mesh is small on purpose: the defect is O(F²) and shows a 20× ceiling
// breach already at 10 000 faces, so a bigger cell would only cost the lane
// seconds to say the same thing.
enum int    kGridN         = 100;
enum size_t kFaces         = 10_000;          // kGridN * kGridN
enum size_t kSelected      = kFaces / 2;
enum double kMaxBytesPerFace = 4_000.0;

unittest {
    Mesh m = makeGridPlane(kGridN);

    bool[] sel = new bool[](m.faces.length);
    foreach (i; 0 .. m.faces.length / 2) sel[i] = true;
    m.selectFacesFrom(sel);

    // POPULATION FLOOR FIRST, and it is not ceremony: "the allocation stayed
    // under the ceiling" is vacuously true of a kernel that duplicated nothing,
    // and `duplicateSelectedFaces` has three early `return 0` arms that would
    // deliver exactly that. Pin the counts before believing the bytes.
    assert(m.faces.length == kFaces,
           "grid population floor: expected 10 000 faces");
    assert(m.countSelectedFaces() == cast(int) kSelected,
           "selection floor: expected 5 000 selected faces");

    immutable ulong allocBefore = GC.allocatedInCurrentThread;
    size_t cloned;
    {
        // UNRECORDED: an op-log would add a second, legitimate O(F) payload to
        // the measurement and blunt the ratio the ceiling rests on. The defect
        // is in the kernel's own face scan and is present on both batch kinds.
        auto ed = MeshEditBatch.unrecorded(m, cast(uint) MeshEditScope.Geometry);
        cloned = ed.duplicateSelectedFaces();
        ed.close();
    }
    immutable ulong bytes = GC.allocatedInCurrentThread - allocBefore;

    // Still above the ceiling, still green on the broken kernel: the quadratic
    // scan produced the right geometry, only slowly.
    assert(cloned == kSelected,
           "the kernel must report 5 000 cloned faces");
    assert(m.faces.length == kFaces + kSelected,
           "post-op population floor: 15 000 faces");

    immutable double perFace = cast(double) bytes / cast(double) kFaces;
    assert(perFace < kMaxBytesPerFace,
           "mesh.duplicate allocated " ~ perFaceText(perFace) ~
           " bytes per mesh face; the ceiling is " ~ perFaceText(kMaxBytesPerFace)
           ~ ". A figure near 2*F means a"
           ~ " per-face read of the allocating `selectedFaces` property came"
           ~ " back into duplicateSelectedFaces — use isFaceSelected(fi).");
}

// ---------------------------------------------------------------------------
// SECOND SITE — the weld/dedup tail of `arrayFacesGrid`, source/mesh.d.
//
// WHY A SEPARATE CELL. The fix landed in two places and the cell above drives
// only one of them: with the array site reverted to its
// `fi < selectedFaces.length ? selectedFaces[fi] : false` ternary, `dub test
// --config=tests` was green at 503 modules, exit 0. "Fixed the same way" is an
// assertion with nothing behind it until something can go red for it.
//
// THE VACUITY HAZARD, and it is the whole reason this cell is shaped the way it
// is. The per-face read sits under TWO guards — `mergeVertices && mergeDistance
// > 0`, and then `weldCoincidentVertices(epsSq) > 0`. Miss either and the
// kernel never enters the dedup block: the byte count comes in low, the ceiling
// holds honestly, and the cell reports that a line it never executed is cheap.
// So the weld is not assumed, it is PINNED BY COUNT. `makeGridPlane` spans
// [-1, 1] on X, so an offset of exactly 2.0 butts slot (1,0,0) against the
// original and their shared vertex column — `kSide` verts — coincides EXACTLY
// in float, well inside the 0.001 epsilon; the surviving vertex count must
// therefore be `2*V - kSide` and not `2*V`.
//
// THE DENOMINATOR IS THE ARRAYED FACE COUNT, not the grid's. The loop is
// `foreach (fi, ref f; faces)` AFTER the clones have been appended, so its F is
// the doubled count. Broken, every iteration materialises the property TWICE —
// once for `.length`, once for the index — i.e. 2 page-rounded `bool[F]` blocks
// per face, F² of them for the loop. Measured on this driver at F = 5 000 /
// 9 800 / 20 000 arrayed faces: 17 735 / 25 739 / 42 271 B per arrayed face
// broken, against 1 385 / 1 163 / 1 339 fixed. F = 9 800 is the cell below,
// where the ceiling sits 3.4x above the fixed figure and 6.4x below the broken
// one.
//
// NO `MeshEditBatch` HERE, deliberately: `ArrayTool.applyHeadless` calls
// `arrayFacesGrid` bare on the mesh (source/tools/alignment/array_tool.d), so
// the bare call IS the production shape and the cell does not have to argue for
// a batch kind the way the cell above does.
//
// MUTATION, SECOND CELL (2026-09-06): restoring that ternary reddens the LAST
// assert here with the measured per-face figure in its message; the six floors
// above it — grid population, vertex population, selection, clone count, arrayed
// face count and the weld count — stay green in the same run and are bought by
// it.
enum int    kArrayGridN  = 70;
enum size_t kArrayFaces  = 4_900;   // kArrayGridN^2
enum size_t kArrayVerts  = 5_041;   // (kArrayGridN + 1)^2
enum size_t kSide        = 71;      // kArrayGridN + 1 — the column that welds
enum double kMaxBytesPerArrayedFace = 4_000.0;

unittest {
    Mesh m = makeGridPlane(kArrayGridN);

    // Population floors BEFORE the op: every number below is derived from these
    // two, so a changed `makeGridPlane` must redden here and not silently move
    // the weld arithmetic.
    assert(m.faces.length == kArrayFaces,
           "grid population floor: expected 4 900 faces");
    assert(m.vertices.length == kArrayVerts,
           "grid population floor: expected 5 041 vertices");

    bool[] mask = new bool[](m.faces.length);
    mask[] = true;                       // the grid kernel's operand

    // A half selection, so `keptSelected` has both bits to carry. It does not
    // gate the defect — the property is materialised BEFORE the bit is read —
    // but a cell that measured the read of an all-false selection would be one
    // rewrite away from looking like it did.
    bool[] sel = new bool[](m.faces.length);
    foreach (i; 0 .. m.faces.length / 2) sel[i] = true;
    m.selectFacesFrom(sel);
    assert(m.countSelectedFaces() == cast(int)(kArrayFaces / 2),
           "selection floor: expected 2 450 selected faces");

    immutable ulong allocBefore = GC.allocatedInCurrentThread;
    immutable size_t added = m.arrayFacesGrid(
        mask, /*numX*/2, /*numY*/1, /*numZ*/1,
        /*offset*/Vec3(2, 0, 0), /*jitter*/Vec3(0, 0, 0),
        /*scale*/Vec3(1, 1, 1), /*rotateDeg*/Vec3(0, 0, 0),
        /*between*/false, /*replaceSource*/false, /*invertPolygons*/false,
        /*mergeVertices*/true, /*mergeDistance*/0.001f);
    immutable ulong bytes = GC.allocatedInCurrentThread - allocBefore;

    // Floors AFTER the op, all green on the broken kernel too: the quadratic
    // scan built the right geometry, it just paid F bytes a face to do it.
    assert(added == kArrayFaces,
           "the grid kernel must report 4 900 cloned faces");
    assert(m.faces.length == 2 * kArrayFaces,
           "arrayed population floor: 9 800 faces, i.e. the dedup pass kept "
           ~ "every one and its loop ran over the doubled population");
    // THE WELD FLOOR — the one that makes the ceiling below mean anything. If
    // this holds, `weldCoincidentVertices` returned non-zero and the dedup block
    // carrying the fixed line executed.
    assert(m.vertices.length == 2 * kArrayVerts - kSide,
           "weld floor: the shared 71-vertex column must have welded (expected "
           ~ "10 011 vertices). Un-welded 10 082 means the dedup block never "
           ~ "ran and the ceiling below is vacuous.");

    immutable double perFace = cast(double) bytes / cast(double)(2 * kArrayFaces);
    assert(perFace < kMaxBytesPerArrayedFace,
           "arrayFacesGrid allocated " ~ perFaceText(perFace) ~
           " bytes per arrayed face; the ceiling is "
           ~ perFaceText(kMaxBytesPerArrayedFace) ~
           ". A figure near 2*F means a per-face read of the allocating"
           ~ " `selectedFaces` property came back into the weld/dedup tail —"
           ~ " use isFaceSelected(fi).");
}

private string perFaceText(double v) {
    import std.conv : to;
    return (cast(long) v).to!string;
}
