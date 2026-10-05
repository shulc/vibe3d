// array_hidden_operand_test -- a hidden face never enters the clone operand.
//
// Capture K-AR (toolcards/shared_layer2/findings_K-AR.md, rule 2): the array
// and the radial array share one operand, and a hidden polygon is not in it.
// Through the command surface a hidden face cannot be selected at all (hide
// deselects, select skips hidden), so the kernels' own subtraction is reached
// only by a caller that hands them a mask directly -- which is what these
// cells do. Each forces the hidden bottom face into the mask beside the
// visible top face and expects exactly ONE clone, of the top face.
module tests.unit.array_hidden_operand_test;

import mesh;
import math : Vec3;
import std.math : PI;

private struct Rig { Mesh m; bool[] mask; size_t top, bottom; }

private Rig hiddenBottomRig() {
    Rig r;
    r.m = makeCube();
    r.m.syncSelection();
    assert(r.m.faces.length == 6, "rig floor: the cube has 6 faces");
    size_t nTop, nBottom;
    foreach (fi, f; r.m.faces) {
        float y = 0;
        foreach (vi; f) y += r.m.vertices[vi].y;
        y /= f.length;
        if (y > 0.4f)  { r.top = fi; ++nTop; }
        if (y < -0.4f) { r.bottom = fi; ++nBottom; }
    }
    assert(nTop == 1 && nBottom == 1, "rig floor: one top and one bottom face");
    r.m.setFaceHidden(r.bottom, true);
    assert(r.m.isFaceHidden(r.bottom) && !r.m.isFaceHidden(r.top),
           "rig floor: only the bottom face is hidden");
    r.mask = new bool[](r.m.faces.length);
    r.mask[r.top] = true;
    r.mask[r.bottom] = true;   // forced in: the subject
    return r;
}

private void assertOnlyTopCloned(ref Rig r, size_t added, string kernel) {
    assert(added == 1, kernel ~ ": the hidden face entered the operand -- "
           ~ "expected 1 clone (the top face), not 2");
    assert(r.m.faces.length == 7, kernel ~ ": expected 7 faces after one clone");
    float y = 0;
    foreach (vi; r.m.faces[6]) y += r.m.vertices[vi].y;
    y /= r.m.faces[6].length;
    assert(y > 0.4f, kernel ~ ": the one clone must be the visible TOP face");
}

unittest { // linear / grid array
    auto r = hiddenBottomRig();
    const added = r.m.arrayFacesGrid(r.mask, 2, 1, 1, Vec3(2, 0, 0),
        Vec3(0, 0, 0), Vec3(1, 1, 1), Vec3(0, 0, 0),
        false, false, false, false, 0.001f);
    assertOnlyTopCloned(r, added, "arrayFacesGrid");
}

unittest { // radial array, count 2 about Y
    auto r = hiddenBottomRig();
    const added = r.m.radialArrayFaces(r.mask, 2, 'Y', Vec3(0, 0, 0),
        2 * PI, Vec3(0, 0, 0), 0);
    assertOnlyTopCloned(r, added, "radialArrayFaces");
}
