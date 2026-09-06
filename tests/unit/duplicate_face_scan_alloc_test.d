// TASK 2020 — `mesh.duplicate` must not be QUADRATIC IN THE FACE COUNT.
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
// deterministic. `GC.allocatedInCurrentThread` charges an APPEND-grown array by
// page and a `new T[](n)` by whole payload (task 2160's finding), which points
// the right way here: the legitimate half of this kernel is all appends and is
// therefore UNDER-counted, while the defect is a whole-payload `new bool[]` and
// is counted in full. The two populations are 965 B/face (fixed) against
// ~21 000 B/face (broken) at F = 10 000, so the ceiling below has 4× headroom
// over the first and 5× clearance under the second.
//
// WHY THE COUNT IS QUADRATIC IN F AND NOT IN THE SELECTION. Both loops visit
// EVERY face and evaluate the property before testing the selection bit, so one
// selected face on a 1M grid paid the same ~2 TB of churn as half of them. That
// is what separated this from "duplicating a lot of geometry is expensive": on
// the live app at n=1000 with a SINGLE face selected, the command still ran past
// the bridge's 120 s leash. It is why the cell below keeps a half selection but
// the ceiling is expressed PER FACE OF THE MESH rather than per cloned face.
//
// MUTATION (2026-09-06): restoring either `selectedFaces[fi]` inside the two
// loops of `Mesh.duplicateSelectedFaces` reddens the LAST assert here, with the
// measured per-face figure in its message; the three asserts above it — which
// the broken code also satisfies — stay green in the same run and so are bought
// by it.
module tests.unit.duplicate_face_scan_alloc_test;

import core.memory : GC;
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
           " bytes per mesh face; the ceiling is 4000. A figure near 2*F means a"
           ~ " per-face read of the allocating `selectedFaces` property came"
           ~ " back into duplicateSelectedFaces — use isFaceSelected(fi).");
}

private string perFaceText(double v) {
    import std.conv : to;
    return (cast(long) v).to!string;
}
