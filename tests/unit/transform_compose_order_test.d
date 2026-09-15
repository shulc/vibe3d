module tests.unit.transform_compose_order_test;

import math : Vec3, applyAffine, cross, matMul4, pivotRotationMatrix,
              pivotScaleMatrix, pivotScaleMatrixBasis, translationMatrix;
import std.math : PI, fabs;
import tools.transform.xform_kernels : composeRunMatrix, runScaleAxes;

private bool near(float a, float b, float tolerance = 1e-5f)
{
    return fabs(a - b) <= tolerance;
}

unittest // Scale axes make the held rotation act after action-frame scale.
{
    immutable Vec3 centre = Vec3(-1.2f, 0, 1.2f);
    immutable Vec3 mR = Vec3(0, 0, 1);
    immutable Vec3 mU = Vec3(1, 0, 0);
    immutable Vec3 mF = Vec3(0, 1, 0);
    const rot = pivotRotationMatrix(Vec3(0, 0, 0), Vec3(0, 1, 0),
                                    -20.0f * cast(float)(PI / 180.0));
    Vec3 sX, sY, sZ;
    runScaleAxes(true, Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1),
                 true, rot, mR, mU, mF, sX, sY, sZ);

    assert((sX - applyAffine(rot, mR)).length <= 1e-6f
        && (sY - applyAffine(rot, mU)).length <= 1e-6f
        && (sZ - applyAffine(rot, mF)).length <= 1e-6f,
        "6207 held rotation must win even when a settled frame exists");

    const scaleLin = pivotScaleMatrixBasis(Vec3(0, 0, 0), sX, sY, sZ,
                                            2.0f, 1.0f, 1.0f);
    const fold = composeRunMatrix(false, translationMatrix(Vec3(0, 0, 0)),
                                  true, rot, true, scaleLin);
    immutable Vec3[4] points = [Vec3(0, 0, 0), Vec3(1.2f, 0, 0),
                                Vec3(0, 0, 1.2f), Vec3(1.2f, 0, 1.2f)];
    immutable Vec3[4] expected = [Vec3(0.748479f, 0, -0.644838f),
                                  Vec3(1.876111f, 0, -0.234414f),
                                  Vec3(-0.072369f, 0, 1.610424f),
                                  Vec3(1.055262f, 0, 2.020848f)];
    foreach (i, point; points) {
        const mapped = centre + applyAffine(fold, point - centre);
        assert((mapped - expected[i]).length <= 1e-5f,
            "6207 scale-axis fold must equal c+R*(M*S*M^T)*(p-c)");
    }

    runScaleAxes(true, Vec3(0, 1, 0), Vec3(0, 0, 1), Vec3(1, 0, 0),
                 false, rot, mR, mU, mF, sX, sY, sZ);
    assert(sX == Vec3(0, 1, 0) && sY == Vec3(0, 0, 1)
        && sZ == Vec3(1, 0, 0),
        "6207 no-rotation chain must keep its settled gizmo frame");
    runScaleAxes(false, Vec3(), Vec3(), Vec3(), false, rot,
                 mR, mU, mF, sX, sY, sZ);
    assert(sX == mR && sY == mU && sZ == mF,
        "6207 fresh no-rotation run must keep its frozen frame");
}

unittest // The run fold applies linear factors before translation.
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
    const mapped = centre + applyAffine(actual, point - centre);
    const expectedMapped = Vec3(2.658846f, 0, -1.017691f);
    assert(near(mapped.x, expectedMapped.x)
        && near(mapped.y, expectedMapped.y)
        && near(mapped.z, expectedMapped.z),
        "6207 composition law requires c + T + S*R*(p-c)");

    const translatedFirst = matMul4(scaleLin, matMul4(rot, tr));
    const rival = centre + applyAffine(translatedFirst, point - centre);
    assert((mapped - rival).length > 0.25f,
        "6207 compose witness must separate translation-left from translation-right");
}
