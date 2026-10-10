// Module unittests for `tools.transform.item_xform_kernels`, moved verbatim out of source/tools/transform/item_xform_kernels.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.transform.item_xform_kernels_test;

import math : Vec3, matMul4, matrixFromEulerZYX, eulerZYXFromMatrix,
              applyAffine, scaleAlongBasis, identityMatrix;
import document : Layer, ItemXform;
public import document : MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG;
import std.math : fabs;
import tools.transform.item_xform_kernels;

// Identity gesture leaves composedMatrix() bit-unchanged — asserted on the
// MATRIX, not the euler triple (REVIEW-3): eulerZYXFromMatrix canonicalises
// in the gimbal band, so a base rot that is already non-canonical can
// legitimately show a different (but matrix-equivalent) triple. Here the
// gesture is a hard no-op (the identity fast path), so even the triple is
// untouched — this is the strongest case, not merely the matrix-only one.
unittest {
    auto l = new Layer();
    l.xform.pos = Vec3(1, 2, 3);
    l.xform.rot = Vec3(10, 20, 30);
    l.xform.scl = Vec3(2, 3, 4);
    l.xform.pivot = Vec3(0.5f, -1, 2);
    ItemXform[] baselines = [l.xform];
    Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);

    bool changed = applyGestureToItems([l], baselines, centre,
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
        Vec3(0,0,0), identityMatrix, Vec3(1,1,1));

    assert(!changed, "identity gesture must report changed=false");
    assert(l.xform.pos == baselines[0].pos);
    assert(l.xform.rot == baselines[0].rot);
    assert(l.xform.scl == baselines[0].scl);
    assert(l.xform.pivot == baselines[0].pivot);
}

// No gesture is refused: L4 deleted the decline path (the retired R5). Every
// combination below must leave `changed == true` (nothing silently no-ops).
unittest {
    auto mk = () {
        auto l = new Layer();
        l.xform.rot = Vec3(0, 47, 0);
        return l;
    };
    import math : pivotRotationMatrix;

    auto l1 = mk();
    auto b1 = [l1.xform];
    assert(applyGestureToItems([l1], b1, applyAffine(l1.xform.composedMatrix(), l1.xform.pivot),
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1), Vec3(1,0,0), identityMatrix, Vec3(1,1,1)));

    auto l2 = mk();
    auto b2 = [l2.xform];
    float[16] rg = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,0,1), 0.3f);
    assert(applyGestureToItems([l2], b2, applyAffine(l2.xform.composedMatrix(), l2.xform.pivot),
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1), Vec3(0,0,0), rg, Vec3(1,1,1)));

    auto l3 = mk();
    auto b3 = [l3.xform];
    assert(applyGestureToItems([l3], b3, applyAffine(l3.xform.composedMatrix(), l3.xform.pivot),
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1), Vec3(0,0,0), identityMatrix, Vec3(0.3f, 5, 1)));
}
