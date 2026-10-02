// The retopology line shade (`retopology_line_shade.lineShade`) and the one
// light rig it shares with the lit program (`light_rig`), task 9130.
//
// Numbers: the rig's constants against the captured values (cell 0);
// `lineShade` against an independent double-precision copy of the EYE-SPACE
// light function at the item's local +Z (cells 1-3b), including the
// view-relative law — a camera turn with the item fixed moves the shade (2c)
// — and the product order normalMatrix(view·model) (2d).
// Source text: the rig is uploaded at ONE site, `LitShader.useProgram`; no
// other function of a lit-program file reads a rig constant or spells a rig
// location other than its declaration and lookup (cells 4-5; the rig
// locations are also `private`, cell 5a).
module tests.unit.retopology_line_shade_test;

import std.file   : dirEntries, readText, SpanMode;
import std.format : format;
import std.math   : abs, cos, sin, sqrt, PI;
import std.path   : buildPath, dirName;
import std.regex  : ctRegex, matchAll, matchFirst, replaceAll;
import std.string : indexOf;

import light_rig : kKeyLightEye, kFillLightEye, kKeyIntensity, kFillIntensity,
    kLightAmbient, specPowerForRoughness;
import math : Vec3;
import retopology_line_shade : lineShade;
import tests.unit.census_symbols : balancedSpan, blankNonCode,
    blankUnittestBodies, countOccurrences, lineOf;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---- an independent double copy of the light function ----------------------

private alias D3 = double[3];
private D3 nrm(D3 v) {
    immutable l = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return [v[0] / l, v[1] / l, v[2] / l];
}
private double dot3(D3 a, D3 b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }

// The captured rig, from its DEFINITION (the preset angles), not from the
// module: key = (−sin a·cos b, −sin b, cos a·cos b), fill = the same at
// (−π/2, 0); 0.7 / 0.3; ambient 0.15.
private D3 angleDir(double a, double b) {
    return [-sin(a) * cos(b), -sin(b), cos(a) * cos(b)];
}
private immutable D3 kKey  = [-0.654509, 0.587785, 0.475528];
private immutable D3 kFill = [1.0, 0.0, 0.0];

/// Column-major 4x4 product a·b, in doubles.
private double[16] mul(const float[16] a, const float[16] b) {
    double[16] o = 0;
    foreach (c; 0 .. 4) foreach (r; 0 .. 4) foreach (k; 0 .. 4)
        o[c * 4 + r] += cast(double) a[k * 4 + r] * b[c * 4 + k];
    return o;
}

/// The eye-space normal of the item's local +Z: the inverse-transpose of the
/// upper 3x3 of view·model applied to ẑ = row 2 of the INVERSE, by Cramer.
private D3 eyeNormalZ(const float[16] model, const float[16] view) {
    immutable m = mul(view, model);
    double a(int r, int c) { return m[c * 4 + r]; }
    immutable double det =
          a(0,0) * (a(1,1) * a(2,2) - a(1,2) * a(2,1))
        - a(0,1) * (a(1,0) * a(2,2) - a(1,2) * a(2,0))
        + a(0,2) * (a(1,0) * a(2,1) - a(1,1) * a(2,0));
    // (M⁻ᵀ)·ẑ = third row of M⁻¹ as a column = cofactors C(r,2)/det... i.e.
    // the cross product of M's first two columns, over det.
    D3 n = [a(1,0) * a(2,1) - a(2,0) * a(1,1),
            a(2,0) * a(0,1) - a(0,0) * a(2,1),
            a(0,0) * a(1,1) - a(1,0) * a(0,1)];
    immutable double s = det < 0 ? -1.0 : 1.0;   // orientation-preserving
    return nrm([s * n[0], s * n[1], s * n[2]]);
}

private double[3] reference(D3 pal, D3 n, double gain) {
    immutable N = nrm(n);
    immutable dif = 0.7 * (dot3(N, kKey) > 0 ? dot3(N, kKey) : 0)
                  + 0.3 * (dot3(N, kFill) > 0 ? dot3(N, kFill) : 0);
    immutable k = 0.15 + gain * dif;
    return [pal[0] * k, pal[1] * k, pal[2] * k];
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

private float[16] rotX(double deg, double[3] t = [0, 0, 0]) {
    immutable float c = cast(float) cos(deg * PI / 180), s = cast(float) sin(deg * PI / 180);
    return [1, 0, 0, 0,  0, c, s, 0,  0, -s, c, 0,
            cast(float) t[0], cast(float) t[1], cast(float) t[2], 1];
}

private immutable Vec3 kPal = Vec3(0.11f, 0.25f, 0.41f);
private immutable double[3] kPalD = [0.11f, 0.25f, 0.41f];

unittest { // 0. the rig's values are the captured ones
    immutable D3 key = angleDir(0.9424778, -0.6283185);
    immutable D3 fill = angleDir(-1.570796, 0.0);
    foreach (i; 0 .. 3) {
        assert(abs(key[i] - kKey[i]) < 2e-6 && abs(fill[i] - kFill[i]) < 2e-6,
            "0: the test's own rig copy disagrees with the preset angles");
        assert(abs([kKeyLightEye.x, kKeyLightEye.y, kKeyLightEye.z][i] - kKey[i]) < 1e-6
            && abs([kFillLightEye.x, kFillLightEye.y, kFillLightEye.z][i] - kFill[i]) < 1e-6,
            format("0: light_rig directions moved: key %s fill %s", kKeyLightEye, kFillLightEye));
    }
    assert(kKeyIntensity == 0.7f && kFillIntensity == 0.3f && kLightAmbient == 0.15f,
        "0: a light_rig level moved — every lit pixel in the suite moves with it");
    // The exponent table: the captured samples, the clamp and both ends.
    immutable double[2][] samples = [[0.0, 128.0], [0.3, 128.0], [0.5, 121.847458],
        [0.6, 76.322327], [0.7, 49.638916], [0.9, 22.834875], [1.0, 16.0]];
    foreach (sp; samples)
        assert(abs(specPowerForRoughness(cast(float) sp[0]) - sp[1]) < 1e-3,
            format("0: exponent at rough %s is %s, captured %s", sp[0],
                   specPowerForRoughness(cast(float) sp[0]), sp[1]));
    // Between samples (the closed form is open, capture C4): OUR choice is
    // log-linear — at 0.625 the geometric mean of the 0.6 and 0.65 samples,
    // 68.40, where linear interpolation would give 68.81.
    {
        immutable double geo = sqrt(76.322327 * 61.296902), lin = (76.322327 + 61.296902) / 2;
        assert(abs(geo - lin) >= 0.3, "0: the interpolation cell cannot tell log from linear");
        assert(abs(specPowerForRoughness(0.625f) - geo) < 0.05,
            format("0: exponent between samples is %s, log-linear %s (linear %s)",
                   specPowerForRoughness(0.625f), geo, lin));
    }
    // Outside [0, 1] and NaN: clamped to the ends (a glossiness outside [0, 1]
    // or a NaN from a file must not index past the table). Above 1 the walk
    // would run off the table's end, so the call is caught here and the red
    // is THIS message, not a bounds Error that kills the module.
    {
        import std.exception : collectException;
        float hi = 0;
        Throwable e = collectException!Throwable(hi = specPowerForRoughness(1.5f));
        assert(e is null && hi == 16.0f, format("0: roughness 1.5 must clamp to the "
            ~ "table's end, 16 — read %s, threw %s: the upper clamp is gone", hi,
            e is null ? "nothing" : typeid(e).name));
    }
    assert(specPowerForRoughness(-0.5f) == 128.0f,
        "0: roughness below 0 must clamp to the table's start, 128");
    assert(specPowerForRoughness(float.nan) == 128.0f, "0: a NaN roughness must read the clamp, 128");
}

unittest { // 1. identity item, identity camera: the light at eye +Z
    float[16] I = rotY(0);
    near(lineShade(kPal, I, I, 1.0f), reference(kPalD, [0, 0, 1], 1.0), "1 gain 1");
    near(lineShade(kPal, I, I, 5.0f / 3.0f),
         reference(kPalD, [0, 0, 1], 5.0 / 3.0), "1 gain 5/3");
}

unittest { // 2. the item's rotation moves it; the normal is mat3(model)·z
    float[16] R = rotY(40, [2, 0, 0]);
    float[16] I = rotY(0);
    immutable double s = sin(40 * PI / 180), c = cos(40 * PI / 180);
    immutable got = lineShade(kPal, R, I, 1.0f);
    near(got, reference(kPalD, [s, 0, c], 1.0), "2 +40");
    float[16] T = rotY(0, [2, 0, 0]);
    immutable flat = lineShade(kPal, T, I, 1.0f);
    assert(abs(got.z - flat.z) * 255 > 10,
        format("2: a +40 degree item rotation must move the shade (%s vs %s)",
               got, flat));
}

unittest { // 2c. the view-relative law: a camera turn with the item fixed MOVES the shade,
    // and a camera turn that the item follows (fixed in eye space) does not.
    float[16] M = rotY(0, [0, 0, -3]);
    float[16] I = rotY(0);
    float[16] V = rotX(35);                  // the camera pitches
    immutable base = lineShade(kPal, M, I, 1.0f);
    immutable turned = lineShade(kPal, M, V, 1.0f);
    near(turned, reference(kPalD, eyeNormalZ(M, V), 1.0), "2c camera +35");
    assert(abs(turned.z - base.z) * 255 > 10,
        format("2c: a camera turn must move a fixed item's shade (%s vs %s) — "
               ~ "the rig is eye space, not world", turned, base));
    float[16] W = rotX(-35, [0, 0, -3]);     // the item turns back by the same angle
    immutable followed = lineShade(kPal, W, V, 1.0f);
    near(followed, reference(kPalD, [0, 0, 1], 1.0), "2c item follows the camera");
}

unittest { // 2d. the PRODUCT ORDER: normalMatrix(view·model), not (model·view).
    // A translation-only item (2c) or an identity camera (2, 3b) makes the two
    // orders agree, so the swap needs a rotated item AND a pitched camera:
    // rotY(−40) under rotX(35). Expected from the independent double copy.
    float[16] M = rotY(-40, [1, 0, -3]);
    float[16] V = rotX(35, [0, 0, -2]);
    immutable want  = reference(kPalD, eyeNormalZ(M, V), 1.0);   // view·model
    immutable wrong = reference(kPalD, eyeNormalZ(V, M), 1.0);   // model·view
    // Premise first: the two orders are ≥ 6 levels apart on some channel
    // (measured 11.3 on blue).
    double sep = 0;
    foreach (c; 0 .. 3) if (abs(want[c] - wrong[c]) * 255 > sep) sep = abs(want[c] - wrong[c]) * 255;
    assert(sep >= 6, format("2d: rig cannot tell view·model from model·view "
        ~ "(%.2f levels: %s vs %s)", sep, want, wrong));
    near(lineShade(kPal, M, V, 1.0f), want,
         "2d: rotY(-40) item under a rotX(35) camera shades by normalMatrix(view·model)");
}

unittest { // 3. a mirrored item shades like the unmirrored one
    float[16] I = rotY(0);
    float[16] Mx = I; Mx[0] = -1;
    immutable a = lineShade(kPal, Mx, I, 1.0f), b = lineShade(kPal, I, I, 1.0f);
    assert(abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 && abs(a.z - b.z) < 1e-6,
        "3: the mirrored item's lines must shade like the unmirrored item's");
}

unittest { // 3b. a world non-uniform scale over a rotated item: the inverse-transpose
    // model = diag(3,1,1) · rotY(−30): the surface's world normal is
    // S⁻¹·R·z ∝ (sin θ/3, 0, cos θ), while the model's third column is
    // S·R·z ∝ (3·sin θ, 0, cos θ). Only the normal matrix gives the first.
    // The key light lies at −x, so θ = −30 tilts the +Z normal toward it.
    float[16] M = rotY(-30, [2, 0, 0]);
    foreach (col; 0 .. 3) M[col * 4 + 0] *= 3;   // row 0 (world x) scaled by 3
    float[16] I = rotY(0);
    immutable double s = sin(-30 * PI / 180), c = cos(-30 * PI / 180);
    immutable want = reference(kPalD, [s / 3, 0, c], 1.0);
    immutable wrong = reference(kPalD, [3 * s, 0, c], 1.0);
    // Discrimination floor first: the two candidates are ≥ 6 levels apart.
    assert(abs(want[2] - wrong[2]) * 255 >= 6,
        format("3b: rig cannot tell the normal matrix from the model column (%s vs %s)", want, wrong));
    near(lineShade(kPal, M, I, 1.0f), want, "3b: diag(3,1,1)·rotY(-30) shades by the inverse-transpose normal");
}

// ---- the one-upload-site census ---------------------------------------------

private immutable string[] kRigIds =
    ["kKeyLightEye", "kFillLightEye", "kKeyIntensity", "kFillIntensity", "kLightAmbient"];
private immutable string[] kRigLocs =
    ["locKeyDir", "locFillDir", "locKeyI", "locFillI", "locAmbient"];

private enum identRe  = ctRegex!(`\b(kKeyLightEye|kFillLightEye|kKeyIntensity|kFillIntensity|kLightAmbient|locKeyDir|locFillDir|locKeyI|locFillI|locAmbient)\b`);
private enum importRe = ctRegex!(`\bimport\b[^;]*;`);
/// A location's declaration (`GLint locX`) and its one `glGetUniformLocation`
/// assignment: the only spellings of a location allowed outside the span.
private enum locDeclRe   = ctRegex!(`\bGLint\s+$`);
private enum locAssignRe = ctRegex!(`^\s*=\s*glGetUniformLocation\s*\(`);
private enum addrOfRe    = ctRegex!(`&\s*$`);
/// Every rig location and uniform NAME, for the raw-text fence (5a).
private enum rigNameRe = ctRegex!(`\b(locKeyDir|locFillDir|locKeyI|locFillI|locAmbient|u_keyDir|u_fillDir|u_keyI|u_fillI|u_ambient)\b`);

/// Blank import declarations (an import NAMES a constant, it does not read it),
/// keeping offsets.
private string blankImports(string code) {
    char[] o = code.dup;
    foreach (m; matchAll(code, importRe))
        foreach (i; m.pre.length .. m.pre.length + m.hit.length)
            if (o[i] != '\n') o[i] = ' ';
    return cast(string) o;
}

/// Offenders in `code`: every spelling of a rig identifier outside
/// [allowLo, allowHi) — a constant read, a location in an upload, `&locX`, an
/// alias — EXCEPT a location's declaration and its `glGetUniformLocation`
/// assignment, which are counted into `allowed` (the complement's floor).
private string[] offenders(string file, string code, size_t allowLo, size_t allowHi,
                           ref size_t allowed) {
    string[] o;
    bool inside(size_t p) { return p >= allowLo && p < allowHi; }
    foreach (m; matchAll(code, identRe)) {
        immutable p = m.pre.length;
        if (inside(p)) continue;
        immutable string id = m.hit;
        if (id.length > 3 && id[0 .. 3] == "loc") {
            immutable before = code[(p >= 64 ? p - 64 : 0) .. p];
            immutable after  = code[p + id.length .. $];
            immutable head   = after[0 .. (after.length < 64 ? after.length : 64)];
            if (!matchFirst(before, locDeclRe).empty || !matchFirst(head, locAssignRe).empty) {
                ++allowed;
                continue;
            }
            o ~= format("%s:%d %s %s", file, lineOf(code, p),
                matchFirst(before, addrOfRe).empty ? "names" : "takes the address of", id);
            continue;
        }
        o ~= format("%s:%d reads %s", file, lineOf(code, p), id);
    }
    return o;
}

/// [lo, hi) of `LitShader.useProgram`'s body in shader.d's blanked code.
private size_t[2] useProgramSpan(string code) {
    immutable ptrdiff_t cls = code.indexOf("class LitShader");
    assert(cls >= 0, "5: class LitShader not found in shader.d");
    immutable ptrdiff_t at = code[cls .. $].indexOf("void useProgram(");
    assert(at >= 0, "5: LitShader.useProgram not found");
    immutable ptrdiff_t open = code.indexOf('{', cls + at);
    immutable b = balancedSpan(code, cast(size_t) open, '{', '}');
    assert(b.length > 2, "5: LitShader.useProgram has no braced body");
    return [cast(size_t) open, cast(size_t) open + b.length];
}

unittest { // 4. positive control: the census sees each pre-slice upload shape
    // A hand upload in a function that is NOT useProgram, in the three
    // spellings a pre-slice site used or a bypass would use.
    enum preSlice = q{
        void drawLitPreview() {
            glUniform3f(litShader.locKeyDir, kKeyLightEye.x, kKeyLightEye.y, kKeyLightEye.z);
            glUniform1f(litShader.locAmbient,
                        kLightAmbient);
            float a = kFillIntensity;
            GLint* bypass = &locFillI;
            private GLint locKeyI;
            locKeyI = glGetUniformLocation(program, "u_keyI");
        }
        void useProgram() { glUniform1f(locKeyI, kKeyIntensity); }
    };
    // Allowed span = the second function's body.
    immutable lo = preSlice.indexOf("void useProgram()");
    size_t allowed;
    const got = offenders("ctl", preSlice, lo, preSlice.length, allowed);
    // 3 kKeyLightEye + kLightAmbient + kFillIntensity reads, 2 locations in
    // uploads, 1 `&locFillI` = 8; the declaration + assignment are allowed (2).
    assert(got.length == 8, format("4 positive control: the census saw %s "
        ~ "of the 8 offences in the pre-slice text; its needles are blind: %s",
        got.length, got));
    assert(got[$ - 1].indexOf("takes the address of locFillI") >= 0,
        format("4 positive control: `&locFillI` is not reported as an address-of: %s", got));
    assert(allowed == 2, format("4 positive control: %s of the 2 allowed location "
        ~ "spellings (declaration, glGetUniformLocation) were allowed", allowed));
    assert(blankImports("import light_rig : kKeyLightEye;").indexOf("kKeyLightEye") < 0,
        "4 positive control: an import declaration must not count as a read");
}

unittest { // 5. the rig is read and uploaded ONLY inside LitShader.useProgram
    import std.array : replace;
    immutable src = buildPath(repoRoot, "source");
    // Domain from the RULE: every source file naming LitShader, plus shader.d
    // and the pen preview; light_rig.d declares the constants and is excluded.
    string[] files;
    foreach (de; dirEntries(src, "*.d", SpanMode.depth)) {
        immutable rel = de.name[src.length + 1 .. $].replace("\\", "/");
        if (rel == "light_rig.d") continue;
        immutable raw = readText(de.name);
        if (rel == "shader.d" || rel == "tools/create/pen.d"
            || countOccurrences(raw, "LitShader") > 0)
            files ~= rel;
    }
    // Floor: measured 2026-10-02 —
    //   grep -rl LitShader source --include=*.d | wc -l -> 81 (shader.d and pen.d among them).
    assert(files.length >= 81, format("5 floor: the lit-program domain is %d files, "
        ~ "floor 81 — the walk lost its domain", files.length));

    string[] bad;
    size_t[string] insideReads;
    size_t shaderAllowed, otherAllowed;
    foreach (rel; files) {
        immutable code = blankImports(blankUnittestBodies(blankNonCode(
            readText(buildPath(src, rel)))));
        size_t lo = size_t.max, hi = size_t.max;
        if (rel == "shader.d") {
            immutable sp = useProgramSpan(code);
            lo = sp[0]; hi = sp[1];
            foreach (m; matchAll(code[lo .. hi], identRe)) insideReads[m.hit] += 1;
        }
        bad ~= offenders(rel, code, lo, hi, rel == "shader.d" ? shaderAllowed : otherAllowed);
    }
    // Complement floor: outside useProgram, shader.d spells each location only
    // in its declaration and its glGetUniformLocation assignment — measured
    // 2026-10-02: grep -nE "GLint (locKeyDir|locFillDir|locKeyI|locFillI|locAmbient)|(locKeyDir|locFillDir|locKeyI|locFillI|locAmbient) *= *glGetUniformLocation"
    // source/shader.d | wc -l -> 10. Fewer = the allowance stopped matching.
    assert(shaderAllowed == 10 && otherAllowed == 0, format("5 floor: %s allowed "
        ~ "location spellings in shader.d (measured 10: 5 declarations + 5 "
        ~ "assignments), %s elsewhere (want 0)", shaderAllowed, otherAllowed));
    // Population floor: useProgram reads every rig constant and uploads every
    // rig location (each name ≥ 1 inside the allowed span).
    foreach (id; kRigIds ~ kRigLocs)
        assert((id in insideReads) !is null && insideReads[id] >= 1,
            format("5 floor: LitShader.useProgram no longer reads/uploads %s — "
                   ~ "the one upload site lost its rig (%s)", id, insideReads));
    // Stationary assert over the ALLOWED set {LitShader.useProgram}: true
    // after task 9130. A red names the re-added hand upload (drawLitPreview,
    // PenTool.draw, or any create tool's lit preview).
    assert(bad.length == 0, format("5: the light rig is read or uploaded outside "
        ~ "LitShader.useProgram — a hand upload came back: %s", bad));
}

unittest { // 5a. the fence: rig locations are private, and nobody spells around it
    import shader : LitShader;
    // Positive control: the same probe DOES compile on a public field, so a
    // `false` below means "private", not "the probe is malformed".
    static assert(__traits(compiles, (LitShader s) { auto v = s.locModel; }),
        "5a control: the probe cannot read the public LitShader.locModel — "
        ~ "the fence below is vacuous");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locKeyDir; }),
        "5a: LitShader.locKeyDir is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locFillDir; }),
        "5a: LitShader.locFillDir is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locKeyI; }),
        "5a: LitShader.locKeyI is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locFillI; }),
        "5a: LitShader.locFillI is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locAmbient; }),
        "5a: LitShader.locAmbient is reachable outside shader.d");
    import std.array : replace;
    immutable src = buildPath(repoRoot, "source");
    size_t scanned;
    string[] named;
    foreach (de; dirEntries(src, "*.d", SpanMode.depth)) {
        immutable rel = de.name[src.length + 1 .. $].replace("\\", "/");
        if (rel == "shader.d") continue;
        ++scanned;
        immutable raw = readText(de.name);   // RAW: strings and comments too
        if (!matchAll(raw, rigNameRe).empty) named ~= rel;
    }
    // Floor: find source -name '*.d' | wc -l -> 582 on 2026-10-02 (581 without shader.d).
    assert(scanned >= 581, format("5a floor: scanned %d files outside shader.d, floor 581", scanned));
    // Stationary: no file outside shader.d names a rig location or uniform —
    // a `__traits(getMember, lit, "locKeyDir")` or a
    // `glGetUniformLocation(p, "u_keyDir")` would.
    assert(named.length == 0, format("5a: rig location / uniform names outside shader.d: %s", named));
}
