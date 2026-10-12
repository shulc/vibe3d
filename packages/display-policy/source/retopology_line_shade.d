module retopology_line_shade;

import math : Vec3, normalize, dot, normalMatrix, matMul4;
import light_rig : kKeyLightEye, kFillLightEye, kKeyIntensity, kFillIntensity,
    kLightAmbient;

// An item's base edges and dots are lit by the SAME light function as its
// fill, evaluated at the item's LOCAL +Z axis carried through the item
// transform (captured: task 8600, plan §10.1). This is the CPU mirror of the
// lit program's Retopology arm of `litTerm` (diffuse amount 1, no specular):
// same expression, same constants (`light_rig`), same EYE space. The normal is
// `normalMatrix(view·model)·ẑ` (its third column), exactly what the lit vertex
// shader does to a local +Z polygon's normal, so an edge and a +Z fill of the
// same item agree under every item transform AND every camera — the rig is
// view-relative, so turning the camera moves the shade.

/// `palette` lit at the item's local +Z through `model` and the camera `view`
/// (both column-major), with the light gain `gain` on the part above ambient.
Vec3 lineShade(Vec3 palette, const ref float[16] model,
               const ref float[16] view, float gain) @safe pure nothrow @nogc
{
    immutable float[9] nm = normalMatrix(matMul4(view, model));
    immutable Vec3 n = normalize(Vec3(nm[6], nm[7], nm[8]));
    immutable float nk = dot(n, kKeyLightEye), nf = dot(n, kFillLightEye);
    immutable float dif = kKeyIntensity * (nk > 0.0f ? nk : 0.0f)
                        + kFillIntensity * (nf > 0.0f ? nf : 0.0f);
    immutable float k = kLightAmbient + gain * dif;
    return Vec3(palette.x * k, palette.y * k, palette.z * k);
}
