// Per-surface smoothing census (S1e, model M3): the global angle is gone, the
// policy has ONE builder read by the three producers, and both rule sites (the
// D corner and the GLSL fan-out) spell the same lower-slot pair rule. D regions
// are read through `blankNonCode`; GLSL regions are cut from the RAW text
// (`blankNonCode` deletes `q{…}` bodies — opponent addendum 1). Order per
// block: floor → needle → structure, each with a positive control.
module tests.unit.surface_smoothing_census_test;

import std.algorithm : sort, canFind;
import std.array     : array;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : baseName, buildPath, dirName, relativePath;
import std.string    : indexOf;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, countOccurrences, isIdentChar;

private enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private string codeText(string src) { return blankUnittestBodies(blankNonCode(src)); }

/// Every `source/**/*.d` file: relative path → code text.
private string[string] sourceCode() {
    string[string] out_;
    foreach (e; dirEntries(buildPath(root, "source"), "*.d", SpanMode.depth))
        out_[relativePath(e.name, buildPath(root, "source"))] = codeText(readText(e.name));
    return out_;
}

/// Whole-identifier occurrences of `id` in `s`.
private size_t identCount(string s, string id) {
    size_t n;
    for (size_t i = 0; i + id.length <= s.length; ++i) {
        if (s[i .. i + id.length] != id) continue;
        if (i > 0 && isIdentChar(s[i - 1])) continue;
        if (i + id.length < s.length && isIdentChar(s[i + id.length])) continue;
        ++n;
    }
    return n;
}

/// The identifiers of `s`, in order.
private string[] idents(string s) {
    string[] out_;
    size_t i;
    while (i < s.length) {
        if (isIdentChar(s[i]) && !(s[i] >= '0' && s[i] <= '9')) {
            immutable size_t b = i;
            while (i < s.length && isIdentChar(s[i])) ++i;
            out_ ~= s[b .. i];
        } else ++i;
    }
    return out_;
}

/// Whether `seq` occurs consecutively in the identifier stream of `s`.
private bool hasIdentSeq(string s, const string[] seq) {
    auto ids = idents(s);
    foreach (i; 0 .. ids.length + 1 >= seq.length ? ids.length + 1 - seq.length : 0)
        if (ids[i .. i + seq.length] == seq) return true;
    return false;
}

/// `{ … }` body of the first declaration starting with `head`.
private string bodyAt(string code, string head) {
    immutable ptrdiff_t at = code.indexOf(head);
    assert(at >= 0, "census: missing declaration `" ~ head ~ "`");
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    immutable size_t begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return code[begin .. i + 1];
    }
    assert(false, "census: unterminated body after `" ~ head ~ "`");
}

/// The `q{…}` body after `head` in the RAW `src` (brace-matched).
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

unittest { // (a) the global angle constant is gone; (b) so is the one-cosine plumbing
    // Control [E5].
    assert(identCount("enum float kSmoothingAngleDeg = 40.0f;", "kSmoothingAngleDeg") == 1,
        "control: the needle misses the old declaration");
    auto code = sourceCode();
    assert(code.length > 100, format("census floor: %d source files read", code.length));   // floor
    // Polarity [E14]: FALSE before S1e (vertex_normals.d declares it), TRUE after.
    string[] hitsA, hitsB;
    foreach (f, c; code) {
        if (identCount(c, "kSmoothingAngleDeg")) hitsA ~= f;
        foreach (id; ["locCosSmooth", "cosSmooth", "u_cosSmooth"])
            if (identCount(c, id)) hitsB ~= f ~ ":" ~ id;
    }
    assert(hitsA.length == 0, format("kSmoothingAngleDeg is back in %s — the angle is per surface", hitsA));
    assert(hitsB.length == 0, format("the one-cosine plumbing is back: %s", hitsB));
    // The GLSL side, from the raw template.
    immutable fan = glslRegion(readText(buildPath(root, "source", "subpatch_osd.d")),
                               "private enum string FAN_OUT_VERT_SRC");
    assert(fan.length > 500, "census: the fan-out template region is empty");   // floor
    assert(identCount(fan, "u_cosSmooth") == 0, "the fan-out template still reads u_cosSmooth");
}

unittest { // (c) ONE policy builder, referenced only by the three producers' homes
    auto code = sourceCode();
    // Allowed set: the definition module, the CPU producer's rebuild, the GPU builder.
    size_t[string] refs;
    foreach (f, c; code) {
        immutable n = identCount(c, "buildSmoothPolicy");
        if (n) refs[f] = n;
    }
    foreach (f; ["vertex_normals.d", "mesh_gpu.d", "subpatch_osd.d"])
        assert(f in refs, "census floor: " ~ f ~ " no longer references buildSmoothPolicy");
    string[] outside;
    foreach (f, n; refs)
        if (!["vertex_normals.d", "mesh_gpu.d", "subpatch_osd.d"].canFind(f)) outside ~= f;
    assert(outside.length == 0,
        format("buildSmoothPolicy is referenced in %s — a producer that derives the policy itself", outside));
    // Inside the two producer modules the reference sits in the named function
    // (the one other reference is the module's import).
    immutable gpu = code["mesh_gpu.d"], osd = code["subpatch_osd.d"];
    immutable gIn = identCount(bodyAt(gpu, "private void rebuildFaceAdjacency("), "buildSmoothPolicy");
    immutable oIn = identCount(bodyAt(osd, "void installGl("), "buildSmoothPolicy");
    // The fan-out's second home: its material half, re-run on a Material commit
    // over an unchanged topology (`OsdAccel.refreshSmoothPolicy`).
    immutable oRe = identCount(bodyAt(osd, "bool refreshSmoothPolicy("), "buildSmoothPolicy");
    assert(gIn >= 1 && refs["mesh_gpu.d"] == gIn + 1,
        "census: mesh_gpu.d builds the policy outside rebuildFaceAdjacency");
    assert(oIn >= 1 && oRe >= 1 && refs["subpatch_osd.d"] == oIn + oRe + 1,
        "census: subpatch_osd.d builds the policy outside installGl / refreshSmoothPolicy");
}

unittest { // (d) the lower-slot pair rule in BOTH producers, keyed on identifiers
    // Controls [E5]: the needles find the rule lines and report a `max`.
    immutable dRule = "immutable float c = p.slotCos[min(sf, sg)]; p.faceSlot[g];";
    immutable gRule = "if (dot(ng, nf) < u_slotCos[min(sf, sg)]) continue; texelFetch(u_faceSlot, g)";
    assert(hasIdentSeq(dRule, ["slotCos", "min", "sf", "sg"]) && identCount(dRule, "faceSlot") == 1,
        "control: the D needle misses the rule line");
    assert(hasIdentSeq(gRule, ["u_slotCos", "min", "sf", "sg"]) && identCount(gRule, "u_faceSlot") == 1,
        "control: the GLSL needle misses the rule line");
    assert(identCount("p.slotCos[max(sf, sg)]", "max") == 1, "control: the `max` offender is not reported");
    immutable vn  = codeText(readText(buildPath(root, "source", "vertex_normals.d")));
    immutable cpu = bodyAt(vn, "private Vec3 smoothCorner(");
    immutable fan = glslRegion(readText(buildPath(root, "source", "subpatch_osd.d")),
                               "private enum string FAN_OUT_VERT_SRC");
    assert(cpu.length > 200 && fan.length > 500, "census floor: a rule region is empty");   // floor
    // One needle per producer: N = 2 surfaces, 2 reds under the "higher slot" mutation [E14].
    assert(hasIdentSeq(cpu, ["slotCos", "min", "sf", "sg"]) && identCount(cpu, "faceSlot") >= 1
        && identCount(cpu, "max") == 0,
        "the CPU corner (vertex_normals.smoothCorner) no longer spells slotCos[min(sf, sg)] over faceSlot, "
      ~ "or names max");
    assert(hasIdentSeq(fan, ["u_slotCos", "min", "sf", "sg"]) && identCount(fan, "u_faceSlot") >= 1
        && identCount(fan, "max") == 0,
        "the GPU fan-out (FAN_OUT_VERT_SRC) no longer spells u_slotCos[min(sf, sg)] over u_faceSlot, "
      ~ "or names max");
}

unittest { // (e) the fan-out's unit-6 binding is restored and its TBO deleted
    // No pixel can witness a leaked binding or a leaked handle: this census IS the witness.
    immutable osd = codeText(readText(buildPath(root, "source", "subpatch_osd.d")));
    immutable refresh = bodyAt(osd, "bool refreshIntoFaceVbo(");
    immutable clear   = bodyAt(osd, "void clear()");
    assert(refresh.length > 1000 && clear.length > 300, "census floor: a GL body vanished");
    assert(identCount(refresh, "GL_TEXTURE6") == 2,
        format("refreshIntoFaceVbo names GL_TEXTURE6 %d time(s): bind + restore is 2",
               identCount(refresh, "GL_TEXTURE6")));
    assert(identCount(refresh, "prevTex6") == 3,
        format("refreshIntoFaceVbo names prevTex6 %d time(s): declare + save + restore is 3",
               identCount(refresh, "prevTex6")));
    import std.array : replace;
    immutable flat = clear.replace(" ", "").replace("\n", "");
    assert(countOccurrences(flat, "glDeleteTextures(1,&faceSlotTex)") == 1,
        "clear() no longer deletes faceSlotTex");
    assert(countOccurrences(flat, "glDeleteBuffers(1,&faceSlotVbo)") == 1,
        "clear() no longer deletes faceSlotVbo");
}

/// The `;`-terminated declaration starting with `head` (code text).
private string declAt(string code, string head) {
    immutable ptrdiff_t at = code.indexOf(head);
    assert(at >= 0, "census: missing `" ~ head ~ "`");
    immutable ptrdiff_t semi = code[at .. $].indexOf(';');
    assert(semi >= 0, "census: unterminated `" ~ head ~ "`");
    return code[at .. at + semi + 1];
}

unittest { // (f) app.d routes a Material commit to the live preview and its full upload
    // No pixel reaches either term today (a Material commit under a live preview
    // also publishes Position in the same frame — card F1/F8), so this census IS
    // the witness. Controls [E5].
    immutable ctl = "enum uint kSubpatchTriggers = MeshEditScope.Position | MeshEditScope.Material;";
    assert(hasIdentSeq(ctl, ["MeshEditScope", "Material"]), "control: the trigger needle misses its term");
    immutable app = codeText(readText(buildPath(root, "source", "app.d")));
    // Floor: one declaration, and its region carries the pre-S1e Position term.
    assert(identCount(app, "kSubpatchTriggers") == 2,
        format("census floor: app.d names kSubpatchTriggers %d time(s): declaration + the flags test is 2",
               identCount(app, "kSubpatchTriggers")));
    immutable trig = declAt(app, "enum uint kSubpatchTriggers");
    assert(hasIdentSeq(trig, ["MeshEditScope", "Position"]), "census floor: the trigger region lost Position");
    // Needle 1. True after S1e; red if `Material` leaves the mask.
    assert(hasIdentSeq(trig, ["MeshEditScope", "Material"]),
        "kSubpatchTriggers lost MeshEditScope.Material — a Material-only commit never reaches rebuildIfStale");
    // The upload condition: floor on its pre-S1e terms, then needle 2.
    immutable ptrdiff_t c = app.indexOf("else if ((wantPreview && (versionChanged");
    assert(c >= 0, "census floor: the preview upload condition `else if ((wantPreview && (versionChanged` moved");
    immutable ptrdiff_t brace = app[c .. $].indexOf('{');
    immutable cond = app[c .. c + brace];
    assert(identCount(cond, "previewInstalledThisFrame") == 1, "census floor: the upload condition lost its install term");
    assert(identCount(cond, "previewMaterialRefreshed") == 1,
        "the preview upload condition lost previewMaterialRefreshed — the material refresh never uploads");
}
