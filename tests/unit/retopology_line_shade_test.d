// The retopology line shade (`retopology_line_shade.lineShade`) and the one
// light rig it shares with the lit program (`light_rig`).
//
// Numbers: `lineShade` against an independent double-precision copy of the
// light function at the item's local +Z; mirror-invariance; the item rotation
// that moves it. Source text: every upload of the lit program's light uniforms
// (`LitShader.useProgram`, `drawLitPreview`, the pen's lit preview) reads the
// rig's constants and none carries a light literal — the pixels cannot see a
// literal that equals the constant, so the text is the witness.
module tests.unit.retopology_line_shade_test;

import std.file   : readText;
import std.format : format;
import std.math   : abs, cos, sin, sqrt, pow, PI;
import std.path   : buildPath, dirName;
import std.regex  : regex, matchAll;

import light_rig : kLightDirection, kLightAmbient, kLightSpecStrength,
    kLightSpecPower;
import math : Vec3;
import retopology_line_shade : lineShade;
import tests.unit.census_symbols : blankNonCode, countOccurrences;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// The light function, written out in doubles from its definition (the lit
// fragment program's `litTerm`), at normal `n`, surface point `at`.
private double[3] reference(double[3] pal, double[3] n, double[3] at,
                            double[3] eye, double gain) {
    double[3] nrm(double[3] v) {
        immutable l = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        return [v[0] / l, v[1] / l, v[2] / l];
    }
    double d(double[3] a, double[3] b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
    immutable L = nrm([0.6, 1.0, 0.5]);
    immutable V = nrm([eye[0] - at[0], eye[1] - at[1], eye[2] - at[2]]);
    immutable H = nrm([L[0] + V[0], L[1] + V[1], L[2] + V[2]]);
    immutable N = nrm(n);
    immutable dif = d(N, L) > 0 ? d(N, L) : 0;
    immutable spc = pow(d(N, H) > 0 ? d(N, H) : 0, 32.0);
    immutable k = 0.20 + gain * dif * (1 - 0.20);
    immutable s = gain * spc * 0.25;
    return [pal[0] * k + s, pal[1] * k + s, pal[2] * k + s];
}

private void near(Vec3 got, double[3] want, string cell) {
    assert(abs(got.x - want[0]) < 1e-5 && abs(got.y - want[1]) < 1e-5
        && abs(got.z - want[2]) < 1e-5,
        format("%s: lineShade %s, expected %s", cell, got, want));
}

private float[16] rotY(double deg, double[3] t = [0, 0, 0]) {
    immutable float c = cast(float) cos(deg * PI / 180), s = cast(float) sin(deg * PI / 180);
    // Column-major; columns are the images of x, y, z.
    return [c, 0, -s, 0,  0, 1, 0, 0,  s, 0, c, 0,
            cast(float) t[0], cast(float) t[1], cast(float) t[2], 1];
}

private immutable Vec3 kPal = Vec3(0.11f, 0.25f, 0.41f);
private immutable double[3] kPalD = [0.11f, 0.25f, 0.41f];

unittest { // 0. the rig's values are the ones the lit program always had
    assert(kLightDirection == Vec3(0.6f, 1.0f, 0.5f) && kLightAmbient == 0.20f
        && kLightSpecStrength == 0.25f && kLightSpecPower == 32.0f,
        "light rig: a constant moved — every lit pixel in the suite moves with it");
}

unittest { // 1. identity item: the light at +Z, from the item's origin
    float[16] I = rotY(0);
    immutable Vec3 eye = Vec3(0, 0, 10);
    near(lineShade(kPal, I, eye, 1.0f),
         reference(kPalD, [0, 0, 1], [0, 0, 0], [0, 0, 10], 1.0), "1 gain 1");
    near(lineShade(kPal, I, eye, 5.0f / 3.0f),
         reference(kPalD, [0, 0, 1], [0, 0, 0], [0, 0, 10], 5.0 / 3.0), "1 gain 5/3");
}

unittest { // 2. the item's rotation moves it; the normal is mat3(model)·z
    float[16] R = rotY(40, [2, 0, 0]);
    immutable Vec3 eye = Vec3(0, 0, 10);
    immutable double s = sin(40 * PI / 180), c = cos(40 * PI / 180);
    immutable got = lineShade(kPal, R, eye, 1.0f);
    near(got, reference(kPalD, [s, 0, c], [2, 0, 0], [0, 0, 10], 1.0), "2 +40");
    float[16] I = rotY(0, [2, 0, 0]);
    immutable flat = lineShade(kPal, I, eye, 1.0f);
    assert(abs(got.z - flat.z) * 255 > 10,
        format("2: a +40 degree item rotation must move the shade (%s vs %s)",
               got, flat));
}

unittest { // 3. a mirrored item shades like the unmirrored one
    // scl.x = -1 leaves the third column: mat3·z = +z. A cofactor (normal
    // matrix) would give -z and clamp the diffuse term to 0.
    float[16] I = rotY(0);
    float[16] Mx = I; Mx[0] = -1;
    immutable Vec3 eye = Vec3(0, 0, 10);
    assert(lineShade(kPal, Mx, eye, 1.0f) == lineShade(kPal, I, eye, 1.0f),
        "3: the mirrored item's lines must shade like the unmirrored item's");
}

unittest { // 3b. a world non-uniform scale over a rotated item: the inverse-transpose
    // model = diag(3,1,1) · rotY(−30): the surface's world normal is
    // S⁻¹·R·z ∝ (sin θ/3, 0, cos θ), while the model's third column is
    // S·R·z ∝ (3·sin θ, 0, cos θ). Only the normal matrix gives the first.
    float[16] M = rotY(-30, [2, 0, 0]);
    foreach (col; 0 .. 3) M[col * 4 + 0] *= 3;   // row 0 (world x) scaled by 3
    immutable Vec3 eye = Vec3(0, 0, 10);
    immutable double s = sin(-30 * PI / 180), c = cos(-30 * PI / 180);
    immutable want = reference(kPalD, [s / 3, 0, c], [2, 0, 0], [0, 0, 10], 1.0);
    immutable wrong = reference(kPalD, [3 * s, 0, c], [2, 0, 0], [0, 0, 10], 1.0);
    // Discrimination floor first: the two candidates are ≥ 20 levels apart.
    assert(abs(want[2] - wrong[2]) * 255 >= 20,
        format("3b: rig cannot tell the normal matrix from the model column (%s vs %s)", want, wrong));
    near(lineShade(kPal, M, eye, 1.0f), want, "3b: diag(3,1,1)·rotY(-30) shades by the inverse-transpose normal");
}

// ---- the light-rig census --------------------------------------------------

/// Comment/string-free text with ALL whitespace removed, so a reflowed or
/// re-spaced literal reads the same.
private string dense(string code) {
    char[] o;
    foreach (ch; code)
        if (ch != ' ' && ch != '\n' && ch != '\t' && ch != '\r') o ~= ch;
    return cast(string) o;
}

// A light literal in either of its two shapes: the direction vector, or a
// numeric second argument of a light-uniform upload (0.2f / 0.20f / 0.2 ...).
private enum kDirLiteral = `Vec3\(0?\.6f?,1(\.0*)?f?,0?\.50*f?\)`;
private enum kUniformLiteral =
    `glUniform1f\([A-Za-z_.]*loc(Ambient|SpecStr|SpecPow),[0-9.]+f?\)`;

private size_t literals(string denseCode) {
    size_t n = 0;
    foreach (m; matchAll(denseCode, regex(kDirLiteral))) ++n;
    foreach (m; matchAll(denseCode, regex(kUniformLiteral))) ++n;
    return n;
}

unittest { // 4. positive control: the pre-slice upload text is seen
    // `LitShader.useProgram`'s light block as it stood before the rig existed.
    enum preSlice = q{
        Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));
        glUniform3f(locLightDir, lightDir.x, lightDir.y, lightDir.z);
        glUniform1f(locAmbient,  0.20f);
        glUniform1f(locSpecStr,  0.25f);
        glUniform1f(litShader.locSpecPow,
                    32.0f);
    };
    immutable n = literals(dense(preSlice));
    assert(n == 4, format("4 positive control: the census saw %s of the 4 "
        ~ "literals in the pre-slice text; its patterns are blind", n));
}

unittest { // 5. every upload site reads the rig, none carries a literal
    string all;
    foreach (rel; [["source", "shader.d"], ["source", "tools", "create", "pen.d"]])
        all ~= dense(blankNonCode(readText(buildPath(repoRoot ~ rel))));
    immutable lit = literals(all);
    assert(lit == 0, format("5: %s light literal(s) in the lit uploads; each "
        ~ "must read `light_rig`", lit));
    // Population floor: the three upload sites, each reading all four.
    immutable dirReads = countOccurrences(all, "normalize(kLightDirection)");
    assert(dirReads == 3, format("5 floor: expected the direction read at "
        ~ "the 3 upload sites, found %s", dirReads));
    foreach (name; ["kLightAmbient)", "kLightSpecStrength)", "kLightSpecPower)"]) {
        immutable n = countOccurrences(all, name);
        assert(n == 3, format("5 floor: expected %s at the 3 upload sites, "
            ~ "found %s", name, n));
    }
}
