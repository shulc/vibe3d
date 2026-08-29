// mesh_face_marks_setter_test -- `setFaceMarksFrom`'s mask contract, including the self-aliasing call.
//
// The mask says which bits the source may write; every other bit of the
// destination survives. The second cell passes `faceMarks` as its own source
// -- a real call shape in the tree, and the one an in-place rewrite would
// corrupt.
//
// These blocks stood in the body of `struct Mesh` until task 3160 -- step 1
// of `doc/tasks/work/2910-mesh-struct-seams.md`, which took fifty `unittest`
// blocks out of a 16 782-line struct body. They are HERE rather than at
// module scope in `mesh.d` because they compile against `Mesh`'s PUBLIC API
// alone: the criterion `tests/unit/README.md` states and task 0706 set. The
// eighteen blocks that read a `private` name stayed behind under the same
// rule, at module scope in `mesh.d`. Bodies are byte-identical to what stood
// in the struct, dedented by four columns; the only edit is the member enum
// `Marks`, which is spelled `Mesh.Marks` outside the body.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT, so a mutation that
// should redden two blocks here only ever proves the first. Run them in
// isolation.
module tests.unit.mesh_face_marks_setter_test;

import mesh;
import math : Vec3;
import tests.unit.mesh_by_value_gate;

// The seam's compile-time gate: nothing in this module may take a `Mesh` by
// VALUE. `tests/unit/mesh_by_value_gate.d` says why nothing behavioural
// catches that, and carries the gate's own positive control.
private void byValueGateAnchor() {}
mixin MeshByValueGate!(__traits(parent, byValueGateAnchor));

unittest { // setFaceMarksFrom mask contract (code review NIT, task
    // 0613): pin BOTH halves directly on the primitive, unmediated by
    // any caller's OWN Select backstop. Every production call site
    // (deleteFacesByMask's clearFaceSelectionResize, loop-slice's
    // resetSelection, etc.) clears or restores Select unconditionally
    // right afterward, so a keepMask regression AT THE CALL SITE is
    // invisible from the outside — only a direct test of the primitive
    // itself can discriminate it.
    Mesh m;
    m.setFaceMarksFrom([Mesh.Marks.Select | Mesh.Marks.Hide, Mesh.Marks.Subpatch], ~Mesh.Marks.Select);
    assert(m.faceMarks[0] == Mesh.Marks.Hide,
        "setFaceMarksFrom: keepMask must drop the Select bit — a slip "
        ~ "to uint.max would let it survive");
    assert(m.faceMarks[1] == Mesh.Marks.Subpatch,
        "setFaceMarksFrom: keepMask must NOT drop bits outside itself — "
        ~ "a slip to 0 (or to ~uint.max) would silently wipe "
        ~ "Subpatch/Hide too");
}

unittest { // self-aliasing (src is faceMarks itself) survives, per the
    // doc comment above this method's body — every mesh_planes.
    // rewriteFaces-migrated call site passes faceMarks as its own src.
    Mesh m;
    m.faceMarks = [Mesh.Marks.Select | Mesh.Marks.Hide, Mesh.Marks.Select | Mesh.Marks.Subpatch];
    m.setFaceMarksFrom(m.faceMarks, ~Mesh.Marks.Select);
    assert(m.faceMarks == [cast(uint) Mesh.Marks.Hide, cast(uint) Mesh.Marks.Subpatch],
        "setFaceMarksFrom: passing faceMarks as its own src must still "
        ~ "read each word before overwriting it — a resize+zero "
        ~ "reading of this method's body would wipe every word to 0 "
        ~ "instead of masking it");
}
