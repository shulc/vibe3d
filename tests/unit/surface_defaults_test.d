// The default material (S1e): `Surface.init` IS the reference's default
// (doc/captures/viewport_shading_material_defaults_capture_2026-10-02.md Q2),
// and every "surface nobody authored" reads it — the IR defaults, the shader's
// padding slots, the CPU slot rule. Plus the slot-literal census over the GLSL
// templates and the assimp-family material law (C8f).
module tests.unit.surface_defaults_test;

import std.algorithm : canFind, count;
import std.conv      : to;
import std.file      : readText;
import std.format    : format;
import std.math      : abs, isNaN;
import std.path      : buildPath, dirName;
import std.string    : indexOf;

import math   : Vec3;
import mesh   : Mesh, Surface, kSurfaceSlots, effectiveSurfaceSlot, kDefaultSmoothingAngleDeg;
import shader : packSurfaceSlots, LIT_MAX_MATS, shaderSourceForValidation;
import io.scene_ir : ImportedSurface, roughnessFromShininess, applyAssimpMaterialKeys;
import light_rig : specPowerForRoughness;

private enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest { // Surface.init == the captured default material (Q2)
    // Polarity [E14]: FALSE before S1e (0.7 / 1.0 / 0 / 0.4, no smoothing
    // fields), TRUE after.
    enum doc = "doc/captures/viewport_shading_material_defaults_capture_2026-10-02.md Q2";
    immutable Surface s = Surface.init;
    assert(s.baseColor == Vec3(0.6f, 0.6f, 0.6f), "default base colour is not 0.6 (" ~ doc ~ ")");
    assert(s.diffuseAmount == 0.8f, "default diffuse amount is not 0.8 (" ~ doc ~ ")");
    assert(s.specularAmount == 0.04f, "default specular amount is not 0.04 (" ~ doc ~ ")");
    assert(s.glossiness == 0.6f, "default glossiness is not 0.6 = 1 - rough 0.4 (" ~ doc ~ ")");
    assert(s.opacity == 1.0f, "default opacity is not 1 (" ~ doc ~ ")");
    assert(s.smoothing, "default smoothing is not ON (" ~ doc ~ ")");
    assert(s.smoothingAngleDeg == 40.0f && kDefaultSmoothingAngleDeg == 40.0f,
        "default smoothing angle is not 40° (" ~ doc ~ ")");
}

unittest { // ImportedSurface: member pin, then every default mirrors Surface.init
    static assert([__traits(allMembers, ImportedSurface)] == ["name", "baseColor", "diffuse",
        "specular", "glossiness", "opacity", "smoothing", "smoothingAngleDeg"],
        "ImportedSurface gained or lost a member: map it onto Surface below");
    // IR member → Surface member of the same meaning.
    enum string[2][] map = [["name", "name"], ["baseColor", "baseColor"],
        ["diffuse", "diffuseAmount"], ["specular", "specularAmount"],
        ["glossiness", "glossiness"], ["opacity", "opacity"],
        ["smoothing", "smoothing"], ["smoothingAngleDeg", "smoothingAngleDeg"]];
    size_t checked;
    string[] drift;
    immutable ImportedSurface ir = ImportedSurface.init;
    immutable Surface su = Surface.init;
    static foreach (pair; map) {
        ++checked;
        if (__traits(getMember, ir, pair[0]) != __traits(getMember, su, pair[1]))
            drift ~= pair[0];
    }
    assert(checked == 8, format("mirror floor: %d members checked, expected 8", checked));
    assert(drift.length == 0, format("ImportedSurface defaults drifted from Surface.init: %s", drift));
}

unittest { // packSurfaceSlots: an empty table reads Surface.init in EVERY slot
    float[4 * LIT_MAX_MATS] base = -1, params = -1;
    packSurfaceSlots([], base, params);
    static assert(LIT_MAX_MATS == kSurfaceSlots, "the UBO slot count is not kSurfaceSlots");
    immutable Surface d = Surface.init;
    size_t slots;
    foreach (i; 0 .. LIT_MAX_MATS) {
        ++slots;
        assert(base[i * 4 .. i * 4 + 4] == [d.baseColor.x, d.baseColor.y, d.baseColor.z, d.opacity]
            && params[i * 4 .. i * 4 + 4] == [d.diffuseAmount, d.specularAmount, d.glossiness,
                                              specPowerForRoughness(1.0f - d.glossiness)],
            format("padding slot %d is %s / %s, not Surface.init", i,
                   base[i * 4 .. i * 4 + 4], params[i * 4 .. i * 4 + 4]));
    }
    assert(slots == kSurfaceSlots, format("padding floor: %d slots", slots));
    // An authored slot is read verbatim.
    Surface red = Surface("R", Vec3(1, 0, 0));
    packSurfaceSlots([red], base, params);
    assert(base[0 .. 3] == [1f, 0, 0] && base[4 .. 7] == [d.baseColor.x, d.baseColor.y, d.baseColor.z],
        "an authored slot 0 was not read, or slot 1 is not the default");
}

unittest { // the CPU slot rule, written against the constant
    Mesh m;
    m.faces = [[0u, 1, 2], [0u, 1, 2], [0u, 1, 2]];
    m.faceMaterial = [kSurfaceSlots - 1, kSurfaceSlots];   // face 2 past the array
    assert(effectiveSurfaceSlot(m, 0) == kSurfaceSlots - 1, "the last slot does not map to itself");
    assert(effectiveSurfaceSlot(m, 1) == 0, "a tag == kSurfaceSlots does not read slot 0");
    assert(effectiveSurfaceSlot(m, 2) == 0, "a face past faceMaterial does not read slot 0");
}

// ---- slot-literal census over the GLSL templates ---------------------------
// Opponent addendum 1: `blankNonCode` deletes `q{…}` bodies, so the GLSL
// regions are cut from the RAW source text (with a control on the cutter).

/// The `q{…}` body after the first `head` in `src` (brace-matched).
private string glslRegion(string src, string head) {
    immutable ptrdiff_t at = src.indexOf(head);
    assert(at >= 0, "census: no declaration `" ~ head ~ "`");
    immutable ptrdiff_t q = src[at .. $].indexOf("q{");
    assert(q >= 0, "census: `" ~ head ~ "` has no q{} template");
    size_t i = at + q + 2, depth = 1;
    immutable size_t begin = i;
    for (; i < src.length; ++i) {
        if (src[i] == '{') ++depth;
        else if (src[i] == '}' && --depth == 0) return src[begin .. i];
    }
    assert(false, "census: unterminated q{} after `" ~ head ~ "`");
}

private bool identCh(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

/// Whole-token occurrences of `tok` (an identifier or a number) in `s`.
private size_t tokenCount(string s, string tok) {
    size_t n;
    for (size_t i = 0; i + tok.length <= s.length; ++i) {
        if (s[i .. i + tok.length] != tok) continue;
        if (i > 0 && (identCh(s[i - 1]) || s[i - 1] == '.')) continue;
        immutable size_t e = i + tok.length;
        if (e < s.length && (identCh(s[e]) || s[e] == '.')) continue;
        ++n;
    }
    return n;
}

/// Occurrences of `vMatId` followed (whitespace aside) by `<`.
private size_t matIdCompares(string s) {
    size_t n;
    for (size_t i = 0; i + 6 <= s.length; ++i) {
        if (s[i .. i + 6] != "vMatId" || (i > 0 && identCh(s[i - 1]))) continue;
        size_t j = i + 6;
        if (j < s.length && identCh(s[j])) continue;
        while (j < s.length && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n')) ++j;
        if (j < s.length && s[j] == '<') ++n;
    }
    return n;
}

unittest { // GLSL slot sites all come from kSurfaceSlots: floor → needle → produced text
    // Control on the cutter and the needles [E5]: today's literal line is found.
    immutable string control = "q{ uint  mi  = (vMatId < uint(64)) ? vMatId : uint(0); }";
    immutable cut = glslRegion("private immutable string X = " ~ control, "string X");
    assert(tokenCount(cut, "64") == 1 && matIdCompares(cut) == 1,
        "control: the needles miss the pre-S1e literal slot line");
    immutable shaderSrc = readText(buildPath(root, "source", "shader.d"));
    immutable osdSrc    = readText(buildPath(root, "source", "subpatch_osd.d"));
    immutable lit = glslRegion(shaderSrc, "private immutable string litFragSrc");
    immutable fan = glslRegion(osdSrc, "private enum string FAN_OUT_VERT_SRC");
    // Floor [E4]: the placeholder is where the census looks.
    assert(count(lit, "%SLOTS%") >= 3,
        "the slot placeholder vanished from litFragSrc — the census region is empty");
    assert(count(fan, "%SLOTS%") >= 1, "the slot placeholder vanished from FAN_OUT_VERT_SRC — the census region is empty");
    // Needle. Polarity [E14]: true AFTER S1e (allowed set ∅), false before
    // (3 sites on f14631fe, 4 with the Gooch arm). A literal `64` reintroduced
    // at any one site makes this the offender list of that site.
    string[] offenders;
    if (tokenCount(lit, "64")) offenders ~= format("litFragSrc ×%d", tokenCount(lit, "64"));
    if (tokenCount(fan, "64")) offenders ~= format("FAN_OUT_VERT_SRC ×%d", tokenCount(fan, "64"));
    assert(offenders.length == 0,
        format("a literal slot count 64 is back in %s — splice %%SLOTS%% from kSurfaceSlots", offenders));
    assert(matIdCompares(lit) == 0,
        format("litFragSrc compares vMatId directly %d time(s) — call surfaceSlotOf(vMatId)", matIdCompares(lit)));
    assert(tokenCount(lit, "surfaceSlotOf") >= 2,
        format("litFragSrc names surfaceSlotOf %d time(s): the helper or its call is gone",
               tokenCount(lit, "surfaceSlotOf")));
    // The PRODUCED text.
    immutable produced = shaderSourceForValidation("litFragSrc");
    assert(produced.canFind("mat_base[" ~ kSurfaceSlots.to!string ~ "]")
        && produced.indexOf("%SLOTS%") < 0,
        "the produced litFragSrc does not carry the spliced slot count");
}

// ---- assimp-family material law (C8f; pure, no assimp) ----------------------

unittest { // roughnessFromShininess at the captured points and its edges
    void row(float ns, float want, string why) {
        immutable float r = roughnessFromShininess(ns);
        assert(abs(r - want) <= 1e-6, format("rough(Ns %s) = %.7f, expected %.7f (%s)", ns, r, want, why));
    }
    row(50, 0.6356144f, "C8f");
    row(200, 0.4356144f, "C8f");
    row(1000, 0.2034216f, "C8f");
    row(4, 1.0f, "C8f");
    row(2, 1.0f, "clamped; the reference stores 1.1 unclamped — gap G5");
    row(8192, 0.0f, "clamp at 0");
    row(-5, 1.0f, "Ns <= 0 → 1.0");
    row(float.nan, 1.0f, "NaN → 1.0");
    // Ns 0 stays green when the `!(ns > 0)` branch is deleted, by
    // construction (log2(0) = −∞ clamps to 1): the −5 / NaN rows witness it.
    row(0, 1.0f, "C8f: Ns 0 reads 1.0");
}

unittest { // applyAssimpMaterialKeys: the K row, and absent keys keep Surface.init
    ImportedSurface s;
    applyAssimpMaterialKeys(s, true, Vec3(0.2f, 0.5f, 0.8f), true, 50);
    assert(s.diffuse == 1.0f, "K: diffuse amount is not 1.0");
    assert(abs(s.specular - 0.5f) <= 1e-6, format("K: specular %s, expected mean(Ks) 0.5", s.specular));
    assert(abs(s.glossiness - 0.3643856f) <= 1e-6, format("K: glossiness %s, expected 0.3643856", s.glossiness));
    ImportedSurface a;
    applyAssimpMaterialKeys(a, false, Vec3(0.9f, 0.9f, 0.9f), false, 50);
    assert(a.diffuse == 1.0f && a.specular == Surface.init.specularAmount
        && a.glossiness == Surface.init.glossiness,
        format("absent keys: diffuse %s specular %s glossiness %s, expected 1.0 / Surface.init",
               a.diffuse, a.specular, a.glossiness));
}
