module retopology_line_shade;

import math : Vec3, normalize, dot;
import light_rig : kLightDirection, kLightAmbient, kLightSpecStrength,
    kLightSpecPower;

// An item's base edges and dots are lit by the SAME light function as its
// fill, evaluated at the item's LOCAL +Z axis carried through the item
// transform (captured: task 8600, plan §10.1). This is the CPU mirror of the
// lit program's `litTerm`: same expression, same constants (`light_rig`).
// The normal is `mat3(model)·ẑ`, exactly what the lit vertex shader does to
// a local +Z polygon's normal, so an edge and a +Z fill of the same item agree
// under every transform, mirrors included. One `V` per item, from its origin.

/// `palette` lit at the item's local +Z through `model` (column-major), seen
/// from `eyeWorld`, with the light gain `gain` on the part above ambient.
Vec3 lineShade(Vec3 palette, const ref float[16] model, Vec3 eyeWorld,
               float gain) @safe pure nothrow @nogc
{
    import std.math : pow;
    immutable Vec3 n = normalize(Vec3(model[8], model[9], model[10]));
    immutable Vec3 at = Vec3(model[12], model[13], model[14]);
    immutable Vec3 l = normalize(kLightDirection);
    immutable Vec3 v = normalize(eyeWorld - at);
    immutable Vec3 h = normalize(l + v);
    immutable float dif = dot(n, l) > 0.0f ? dot(n, l) : 0.0f;
    immutable float nh  = dot(n, h) > 0.0f ? dot(n, h) : 0.0f;
    immutable float spc = pow(nh, kLightSpecPower);
    immutable float k = kLightAmbient + gain * dif * (1.0f - kLightAmbient);
    immutable float s = gain * spc * kLightSpecStrength;
    return Vec3(palette.x * k + s, palette.y * k + s, palette.z * k + s);
}
