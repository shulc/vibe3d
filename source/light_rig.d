module light_rig;

import math : Vec3;

// The viewport's light rig: the constants every upload of the lit program's
// light uniforms reads, and the CPU mirror of its light function reads, so
// the fill and anything lit "by the same function" cannot drift (task 8600;
// census: cells 4-5 of `tests/unit/retopology_line_shade_test.d`). GL-free.

/// World light direction, UNNORMALISED; every reader normalises it.
enum Vec3  kLightDirection    = Vec3(0.6f, 1.0f, 0.5f);
/// Ambient term, left unscaled by the light gain.
enum float kLightAmbient      = 0.20f;
/// Specular strength.
enum float kLightSpecStrength = 0.25f;
/// Specular (Blinn) power.
enum float kLightSpecPower    = 32.0f;
