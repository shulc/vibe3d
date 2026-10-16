module vibe3d.editing.tools.transform.tests.unit.tools.transform.scale_input_test;
import vibe3d.editing.tools.transform.tools.transform.scale_input;
import vibe3d.util.math.math : Vec3;
import std.math : abs;

unittest {
    const start = Vec3(1.4f, 2, .4f), sample = Vec3(1.3f, 1.5f, .4f);
    auto ratio = evaluateScaleSample(start, sample, ScaleSampleComposition.ratio, false);
    assert(abs(ratio.x - 1.82f) < 1e-6 && ratio.y == 3 && abs(ratio.z - .16f) < 1e-6,
        "default ratio sample law");
    auto offset = evaluateScaleSample(start, sample, ScaleSampleComposition.factorOffset, false);
    assert(abs(offset.x - 1.7f) < 1e-6 && offset.y == 2.5f && offset.z == 0,
        "absolute factor offset and composed clamp on every axis");
    const negativeHeld = Vec3(-.2f,-.4f,-.6f);
    assert(evaluateScaleSample(negativeHeld, Vec3(1,1,1), ScaleSampleComposition.ratio, false) == negativeHeld,
        "ratio identity preserves finite negative held control");
    assert(evaluateScaleSample(negativeHeld, Vec3(1,1,1), ScaleSampleComposition.factorOffset, false) == negativeHeld,
        "offset identity preserves finite negative held even when permission is disabled");
    assert(evaluateScaleSample(start, Vec3(1,1,1), ScaleSampleComposition.factorOffset, false) == start,
        "offset identity preserves held start");
    assert(evaluateScaleSample(start, sample, ScaleSampleComposition.factorOffset, false) == offset,
        "absolute sample replay is idempotent");
    const signedResult = evaluateScaleSample(start, sample, ScaleSampleComposition.factorOffset, true);
    assert(abs(signedResult.z + .2f) < 1e-6, "negative permission follows composition");
    assert(abs(evaluateScaleSample(Vec3(1.7f,1.7f,1.7f), Vec3(-.2f,-.2f,-.2f),
        ScaleSampleComposition.factorOffset, false).x - .5f) < 1e-6, "signed sample stays unclamped before composition");
    const invalid = evaluateScaleSample(start, Vec3(float.nan,float.infinity,-float.infinity),
        ScaleSampleComposition.factorOffset, false);
    assert(invalid == start, "invalid offset samples preserve start");
    const overflow = evaluateScaleSample(Vec3(float.max,float.max,float.max),
        Vec3(float.max,float.max,float.max), ScaleSampleComposition.factorOffset, false);
    assert(overflow == Vec3(float.max,float.max,float.max), "invalid composed offset preserves finite start");
}

unittest {
    ScaleInputPolicy defaults;
    assert(defaults.normalization == ScaleNormalization.gizmoProjection &&
        defaults.accumulation == ScaleAccumulation.continuous &&
        defaults.composition == ScaleSampleComposition.ratio &&
        defaults.referencePixels == 120 && defaults.referenceScale == 1 && defaults.smallScale == 1 &&
        defaults.ticksPerUnit == 100 && defaults.factorPerTick == .005,
        "neutral scale input defaults");
    defaults.ticksPerUnit = 7; defaults.factorPerTick = 90;
    ScaleCentreInputState continuous;
    assert(advanceScaleInput(continuous, .4, defaults) == 1.4f, "continuous default ignores ticks");
    ScaleInputPolicy policy;
    policy.accumulation = ScaleAccumulation.eventTicks;
    ScaleCentreInputState step2, step4;
    foreach (i; 1 .. 41) advanceScaleInput(step2, i * 2.0 / 72, policy);
    foreach (i; 1 .. 21) advanceScaleInput(step4, i * 4.0 / 72, policy);
    assert(abs(step2.offset - .4) < 1e-10, "two pixel event population40 offset .4");
    assert(abs(step4.offset - .5) < 1e-10, "four pixel event population20 offset .5 separates smooth gain");
    ScaleCentreInputState state;
    assert(advanceScaleInput(state, 0, policy) == 1, "exact zero gives no tick");
    assert(advanceScaleInput(state, .00001, policy) == 1.005f, "tiny positive minimum tick");
    assert(advanceScaleInput(state, 0, policy) == 1, "tiny negative minimum tick reversal");
    advanceScaleInput(state, .028, policy);
    advanceScaleInput(state, .039, policy);
    assert(abs(state.offset - .015) < 1e-10, "successive distance updates without fractional remainder");
    assert(advanceScaleInput(state, double.nan, policy) == 1, "nonfinite input is identity");
    assert(abs(state.offset - .015) < 1e-10, "invalid input preserves finite accumulator");
    ScaleCentreInputState enormous;
    enormous.previousDistance = -double.max;
    assert(advanceScaleInput(enormous, double.max, policy) == 1,
        "overflowed successive delta preserves finite sample");
    assert(signedScaleDistance(Vec3(0,0,0), Vec3(1,0,0), 72) == 0, "zero vector distance");
    assert(signedScaleDistance(Vec3(-3,4,0), Vec3(1,0,0), 10) == -.5, "signed vector length");
    assert(signedScaleDistance(Vec3(0,-5,0), Vec3(1,0,0), 10) == .5, "zero sign dot is positive");
}
