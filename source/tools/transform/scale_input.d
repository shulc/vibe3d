module tools.transform.scale_input;

import math : Vec3, dot;
import std.math : isFinite, trunc;

enum ScaleNormalization : ubyte { gizmoProjection, viewportModelLength }
enum ScaleAccumulation : ubyte { continuous, eventTicks }
enum ScaleSampleComposition : ubyte { ratio, factorOffset }

// Task 8630: centre input is declared data; samples carry their composition.
// Captured construction and signed event ticks: doc/transform_8630_uniform_input_amendment_2026-09-30.md.
struct ScaleInputPolicy {
    ScaleNormalization normalization;
    float referencePixels = 120;
    float referenceScale = 1;
    float smallScale = 1;
    ScaleAccumulation accumulation;
    double ticksPerUnit = 100;
    double factorPerTick = .005;
    ScaleSampleComposition composition;
}

struct ScaleCentreInputState {
    Vec3 displacement, screenRight = Vec3(1,0,0), screenUp = Vec3(0,1,0);
    double previousDistance = 0, offset = 0;
}

double signedScaleDistance(Vec3 displacement, Vec3 direction, double modelLength) {
    if (displacement == Vec3(0,0,0)) return 0;
    return (dot(displacement, direction) < 0 ? -1 : 1) *
        cast(double)displacement.length() / modelLength;
}

float advanceScaleInput(ref ScaleCentreInputState state, double current,
                        in ScaleInputPolicy policy) {
    if (!isFinite(current)) return 1;
    const delta = current - state.previousDistance;
    state.previousDistance = current;
    if (policy.accumulation == ScaleAccumulation.continuous)
        return cast(float)(1 + current);
    if (delta != 0 && isFinite(delta)) {
        double ticks = trunc(delta * policy.ticksPerUnit);
        if (ticks == 0) ticks = delta < 0 ? -1 : 1;
        state.offset += ticks * policy.factorPerTick;
    }
    return cast(float)(1 + state.offset);
}

Vec3 evaluateScaleSample(Vec3 start, Vec3 sample,
                         ScaleSampleComposition composition, bool negativeEnabled) {
    if (composition == ScaleSampleComposition.ratio)
        return Vec3(start.x * sample.x, start.y * sample.y, start.z * sample.z);
    float apply(float held, float value) {
        if (!isFinite(value)) return held;
        const total = held + (value - 1);
        if (!isFinite(total)) return held;
        return negativeEnabled || total >= 0 ? total : 0;
    }
    return Vec3(apply(start.x, sample.x), apply(start.y, sample.y), apply(start.z, sample.z));
}
