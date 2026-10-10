module light_rig;

import math : Vec3;

// The viewport's light rig: two directional lights that are CONSTANTS IN EYE
// SPACE (they turn with the camera), read by the lit program's one upload
// site (`LitShader.useProgram`) and by the CPU mirror of its light function
// (`retopology_line_shade.lineShade`), so the fill and anything lit "by the
// same function" cannot drift (task 9130; world-fixed before it, 8600).
// Values: the shaded-style rig capture
// (doc/captures/viewport_shading_rig_capture_2026-10-02.md, cells C1, C1b, C2,
// C2b, C4; census: cells 0 and 5 of tests/unit/retopology_line_shade_test.d).
// Function: `col = Kd·(A + 0.7·max(N·key,0) + 0.3·max(N·fill,0)) + spec`,
// Kd = base colour × diffuse amount, spec = Blinn with the viewer at infinity
// (H = normalize(L + (0,0,1))) gated by N·L > 0, NOT scaled by the diffuse
// amount. We evaluate it per fragment; the reference per vertex (declared
// divergence, gap registry row 496). GL-free.

/// Key light, unit, eye space, TOWARD the light: (−sin a·cos b, −sin b,
/// cos a·cos b) at (a, b) = (0.9424778, −0.6283185) — upper left, toward the viewer.
enum Vec3  kKeyLightEye   = Vec3(-0.654509f, 0.587785f, 0.475528f);
/// Fill light, unit, eye space, toward the light: screen right.
enum Vec3  kFillLightEye  = Vec3(1.0f, 0.0f, 0.0f);
/// Key intensity: diffuse and specular alike.
enum float kKeyIntensity  = 0.7f;
/// Fill intensity: diffuse and specular alike.
enum float kFillIntensity = 0.3f;
/// Global ambient, multiplied by Kd (the diffuse colour × amount); not scaled
/// by the light gain.
enum float kLightAmbient  = 0.15f;

/// The Blinn exponent of a material of roughness `rough`: the captured table
/// (exponent vs the reference's own roughness), log-linear between its samples
/// (OUR choice), clamped to [0, 1]. The closed form was not identified (capture
/// C4), so the samples ARE the law. The 0.48 → 128 point is INFERRED, not a
/// read: 128 is read for 0.0–0.3, and 0.45–0.48 logged nothing new (the
/// probe's per-value quota, C4 table footnote). The caller's argument is
/// `1 − glossiness`: captured, rough = 1 − glossiness exactly (the reference's
/// material import reads it so and its export writes the inverse).
float specPowerForRoughness(float rough) @safe pure nothrow @nogc {
    import std.math : exp, log, isNaN;
    static immutable float[13] r = [0.0f, 0.48f, 0.5f, 0.55f, 0.6f, 0.65f,
        0.7f, 0.75f, 0.8f, 0.85f, 0.9f, 0.95f, 1.0f];
    static immutable float[13] p = [128.0f, 128.0f, 121.847458f, 95.922775f,
        76.322327f, 61.296902f, 49.638916f, 40.497078f, 33.260273f,
        27.482771f, 22.834875f, 19.069639f, 16.0f];
    if (isNaN(rough) || rough <= r[0]) return p[0];
    if (rough >= r[$ - 1]) return p[$ - 1];
    size_t i = 1;
    while (rough > r[i]) ++i;
    immutable float t = (rough - r[i - 1]) / (r[i] - r[i - 1]);
    return exp(log(p[i - 1]) + t * (log(p[i]) - log(p[i - 1])));
}

// The Gooch style's own light and tones (S4a; read through the same
// upload, `LitShader.useProgram`). Captured law
// (doc/captures/viewport_modes_advanced_reflection_2026-10-02.md §4):
// `out = min(mix(cool + coolKd·Kd, warm + warmKd·Kd, abs(N·L)), 1)`, Kd = base
// colour × diffuse amount, L eye space, two-sided abs, no specular. The
// reference evaluates N·L per vertex; we per fragment (declared, as row 496).

/// The Gooch light, unit, eye space, toward the light: (1,1,1)/√3, upper
/// right in front of the viewer (captured 0.57735026, 0.57735027, 0.57735027).
enum Vec3  kGoochLightEye = Vec3(0.57735027f, 0.57735027f, 0.57735027f);
/// The cool tone's constant part (N·L = 0).
enum Vec3  kGoochCool     = Vec3(0.0f, 0.0f, 0.35f);
/// The warm tone's constant part (|N·L| = 1).
enum Vec3  kGoochWarm     = Vec3(0.44f, 0.44f, 0.0f);
/// Kd's weight in the cool tone.
enum float kGoochCoolKd   = 0.2f;
/// Kd's weight in the warm tone.
enum float kGoochWarmKd   = 0.6f;
