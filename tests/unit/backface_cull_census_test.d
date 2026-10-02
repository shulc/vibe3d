// Source census of the back-face cull (S1d, model M6). Culling is DISPLAY
// only: picking never reads the cull policy or the surface flag, the vertex
// drop's uniform has one writer pair, the per-side cull state is set only by
// the side bracket, the picker keeps its own `glDisable(GL_CULL_FACE)`, and
// both create-tool previews choose their pass through `previewFacePass`.
// Code views go through `blankNonCode`; GLSL regions (inside `q{…}`, which it
// blanks) are cut from the raw text.
module tests.unit.backface_cull_census_test;

import std.algorithm : canFind, sort;
import std.array : array;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.string : indexOf, replace;

import tests.unit.census_symbols : blankNonCode, isIdentChar;

private enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// Whole-identifier occurrences of `tok` in `s`.
private size_t tokens(string s, string tok) {
    size_t n;
    for (size_t i = 0; i + tok.length <= s.length; ++i) {
        if (s[i .. i + tok.length] != tok) continue;
        if (i > 0 && isIdentChar(s[i - 1])) continue;
        if (i + tok.length < s.length && isIdentChar(s[i + tok.length])) continue;
        ++n;
    }
    return n;
}

/// The body of the function whose declaration starts with `head` (through the
/// first line that is a lone `}` at the declaration's indent or less).
private string fnBody(string src, string head) {
    immutable a = src.indexOf(head);
    assert(a >= 0, "census: `" ~ head ~ "` not found");
    immutable close = src[a .. $].indexOf("\n}\n");
    assert(close > 0, "census: `" ~ head ~ "` has no closing brace");
    return src[a .. a + close];
}

/// The `q{…}` body after the first `head` in `src` (brace-matched).
private string glslRegion(string src, string head) {
    immutable ptrdiff_t at = src.indexOf(head);
    assert(at >= 0, "census: `" ~ head ~ "` not found");
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

private string[] sourceFiles() {
    string[] o;
    foreach (e; dirEntries(buildPath(root, "source"), "*.d", SpanMode.depth))
        o ~= relativePath(e.name, buildPath(root, "source")).replace("\\", "/");
    o.sort();
    return o;
}

unittest { // (a) the cull POLICY reaches only the display: a picker reading it reddens here
    // Polarity [E14]: stationary — TRUE before a mutation that makes a picker
    // (select_visibility, gpu_select, bvh_pick) read the display cull; the
    // offender list then names that file.
    immutable string[] allowed = ["display_state.d", "http_providers.d", "shader.d", "ui/viewport_render.d"];
    auto files = sourceFiles();
    assert(files.length > 300, format("census floor: %d source files", files.length));
    string[] holders;
    foreach (f; files)
        if (tokens(blankNonCode(readText(buildPath(root, "source", f))), "cullBySurface")) holders ~= f;
    // Floor: the policy's home and its one face-pass reader.
    assert(holders.canFind("display_state.d") && holders.canFind("ui/viewport_render.d"),
        format("census floor: cullBySurface must live in display_state.d and be read by "
               ~ "ui/viewport_render.d; found in %s", holders));
    string[] offenders;
    foreach (h; holders) if (!allowed.canFind(h)) offenders ~= h;
    assert(offenders.length == 0,
        format("cullBySurface is read outside the display (%s) — a picker reading the display cull "
               ~ "changes picking, which S1d pins unchanged", offenders));
    // The picking modules name none of the sidedness vocabulary.
    size_t pickers;
    foreach (f; ["gpu_select.d", "select_visibility.d", "bvh_pick.d"]) {
        immutable code = blankNonCode(readText(buildPath(root, "source", f)));
        ++pickers;
        foreach (tok; ["cullBySurface", "bySurface", "twoSided", "anyTwoSided", "FaceSide", "faceSidesFor"])
            assert(tokens(code, tok) == 0, format("%s reads `%s`: picking must not see the display cull", f, tok));
    }
    assert(pickers == 3);
}

unittest { // (b) `locBackSide`: declared and located in shader.d, written only by the side bracket
    // Raw text: `.tupleof`, `__traits(getMember` and a string mixin would
    // reach it without spelling a call [E1, E3].
    size_t total;
    foreach (f; sourceFiles()) {
        immutable raw = readText(buildPath(root, "source", f));
        immutable n = tokens(raw, "locBackSide");
        total += n;
        if (f == "shader.d")
            assert(n == 2, format("shader.d names locBackSide %d time(s): the declaration and its "
                                  ~ "glGetUniformLocation are 2", n));
        else if (f == "mesh_gpu.d") {
            immutable begin = tokens(fnBody(raw, "private void beginFaceSide("), "locBackSide");
            immutable end   = tokens(fnBody(raw, "private void endFaceSide("), "locBackSide");
            assert(begin == 1 && end == 1 && n == 2,
                format("mesh_gpu.d: locBackSide %d time(s) (beginFaceSide %d, endFaceSide %d) — only the "
                       ~ "side bracket may raise and park the vertex drop", n, begin, end));
        } else
            assert(n == 0, format("%s names locBackSide: only the side bracket may write it", f));
    }
    assert(total == 4, format("locBackSide population: %d, expected 4", total));
}

unittest { // (c) the double-sided bit is read by the vertex stage only
    immutable raw = readText(buildPath(root, "source", "shader.d"));
    immutable block = glslRegion(raw, "private enum string materialsBlockGlsl");
    immutable vert  = glslRegion(raw, "private immutable string litVertSrc");
    immutable frag  = glslRegion(raw, "private immutable string litFragSrc");
    assert(tokens(block, "mat_flags") == 1, "the Materials block must declare mat_flags once");
    assert(tokens(vert, "mat_flags") == 1 && tokens(vert, "u_backSide") == 2,
        "litVertSrc must read mat_flags once, in the u_backSide drop");
    assert(tokens(frag, "mat_flags") == 0 && tokens(frag, "u_backSide") == 0,
        "litFragSrc reads the sidedness bit: the drop is a vertex-stage clip, never a discard");
    assert(tokens(frag, "discard") == 0, "litFragSrc discards: early depth is lost for every lit draw");
    // Every lit arm and the G-buffer read the flipped normal.
    assert(tokens(frag, "shadingNormal") == 5,
        format("litFragSrc names shadingNormal %d time(s): the helper, Material, Retopology, Gooch "
               ~ "and the G-buffer are 5", tokens(frag, "shadingNormal")));
}

unittest { // (d) GL cull state in mesh_gpu.d is the side bracket's
    immutable code = blankNonCode(readText(buildPath(root, "source", "mesh_gpu.d")));
    immutable begin = fnBody(code, "private void beginFaceSide(");
    immutable end   = fnBody(code, "private void endFaceSide(");
    foreach (call; ["glCullFace(", "glEnable(GL_CULL_FACE)", "glDisable(GL_CULL_FACE)"]) {
        size_t all;
        for (ptrdiff_t at = code.indexOf(call); at >= 0; at = code.indexOf(call, at + 1)) ++all;
        size_t inside;
        foreach (b; [begin, end])
            for (ptrdiff_t at = b.indexOf(call); at >= 0; at = b.indexOf(call, at + 1)) ++inside;
        assert(inside >= 1, format("census floor: no `%s` in the side bracket", call));
        assert(all == inside, format("mesh_gpu.d: `%s` %d time(s), %d inside begin/endFaceSide — a "
                                     ~ "second cull site", call, all, inside));
    }
}

/// Is `glDisable(GL_CULL_FACE);` in `body` before its first `glDrawArrays(`?
private bool pickerDisablesCullFirst(string body) {
    immutable d = body.indexOf("glDisable(GL_CULL_FACE);");
    immutable a = body.indexOf("glDrawArrays(");
    return d >= 0 && a >= 0 && d < a;
}

unittest { // (e) the picker keeps its own cull-off before its first draw
    immutable code = blankNonCode(readText(buildPath(root, "source", "gpu_select.d")));
    immutable at = code.indexOf("void renderMode(");
    assert(at >= 0, "gpu_select.d: renderMode not found");
    immutable body = code[at .. $];
    // Positive control [E5]: the same scan over the text with the line removed reports it.
    assert(!pickerDisablesCullFirst(body.replace("glDisable(GL_CULL_FACE);", "")),
        "control: the scan cannot see a missing glDisable(GL_CULL_FACE)");
    assert(pickerDisablesCullFirst(body),
        "gpu_select.renderMode no longer disables GL_CULL_FACE before its first draw: the pre-pass "
        ~ "would inherit a display cull (picking is pinned unchanged)");
}

unittest { // (f) both create-tool previews choose their pass through previewFacePass
    immutable shaderCode = blankNonCode(readText(buildPath(root, "source", "shader.d")));
    immutable penCode    = blankNonCode(readText(buildPath(root, "source", "tools", "create", "pen.d")));
    immutable lp = fnBody(shaderCode, "void drawLitPreview(");
    size_t n;
    n += tokens(lp, "previewFacePass");
    n += tokens(penCode, "previewFacePass") - (penCode.canFind("import shader") ? 1 : 0);
    assert(n == 2, format("previewFacePass is passed %d time(s): drawLitPreview and PenTool.draw are 2", n));
    assert(lp.canFind(".drawFaces(litShader, previewFacePass(plan))")
        && penCode.canFind(".drawFaces(litShader, previewFacePass(plan))"),
        "a create-tool preview no longer draws through previewFacePass(plan)");
}
