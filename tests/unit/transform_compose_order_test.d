module tests.unit.transform_compose_order_test;

import math : Vec3, applyAffine, cross, matMul4, pivotRotationMatrix,
              pivotScaleMatrix, translationMatrix;
import std.math : PI, fabs;
import tools.transform.xform_kernels : composeRunMatrix;

private bool near(float a, float b, float tolerance = 1e-5f)
{
    return fabs(a - b) <= tolerance;
}

unittest // The run fold retains the pre-6207 order during phase 1a.
{
    immutable Vec3 centre = Vec3(-1.2f, 0, 1.2f);
    immutable Vec3 point = Vec3(0, 0, -1.2f);
    immutable Vec3 delta = Vec3(0.5f, 0, 0);
    const tr = translationMatrix(delta);
    const rot = pivotRotationMatrix(Vec3(0, 0, 0), Vec3(0, 1, 0),
                                    -30.0f * cast(float)(PI / 180.0));
    const scaleLin = pivotScaleMatrix(Vec3(0, 0, 0), 1.5f, 1.5f, 1.5f);

    assert((point - centre).length > 1.0f,
        "6207 compose witness needs an off-centre point");
    assert(cross(point - centre, delta).length > 1.0f,
        "6207 compose witness needs a non-collinear translation");

    const noTranslate = composeRunMatrix(false, tr, true, rot, true, scaleLin);
    const expectedNoTranslate = matMul4(scaleLin, rot);
    foreach (i; 0 .. 16)
        assert(noTranslate[i] == expectedNoTranslate[i],
            "6207 no-translate fold must remain S*R");

    const translateOnly = composeRunMatrix(true, tr, false, rot, false, scaleLin);
    foreach (i; 0 .. 16)
        assert(translateOnly[i] == tr[i],
            "6207 translate-only fold must equal T");

    const actual = composeRunMatrix(true, tr, true, rot, true, scaleLin);
    const expected = matMul4(scaleLin, matMul4(rot, tr));
    foreach (i; 0 .. 16)
        assert(near(actual[i], expected[i]),
            "6207 phase 1a fold must compose S*(R*T)");

    const mapped = centre + applyAffine(actual, point - centre);
    assert((mapped - centre).length > 0.5f,
        "6207 compose witness must exercise the affine map");
}
