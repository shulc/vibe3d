// The plan-uniform seam of the lit program (task 9040, model M1): every lit
// face DRAW in the viewport renderer is bracketed by ONE `applyPlan` after its
// program's `useProgram` and ONE `restorePlanDefaults` before the next lit
// `useProgram`. The setters behind the seam are module-private in `shader.d`,
// so a hand-set plan uniform outside it is a compile error; this census pins
// the bracket's POSITION at each draw, which the compiler cannot see.
//
// Order: population floor (lit draws) -> needle counts (seam calls) -> the
// per-draw structural check, with a local positive control for the checker.
// Position-based per draw, so it survives a site body moving into a helper.
// Below: the preview subset's park needle, and the fence on the four
// plan-uniform LOCATION fields (compile probe + raw-text census of the
// spellings that bypass `private`).
module tests.unit.lit_plan_seam_test;

import std.format : format;
import std.regex  : ctRegex, matchAll;

private string rendererCode() {
    import std.file : readText;
    import std.path : buildPath, dirName;
    import tests.unit.census_symbols : blankNonCode, blankUnittestBodies;
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    return blankUnittestBodies(blankNonCode(
        readText(buildPath(root, "source", "ui", "viewport_render.d"))));
}

/// A lit face draw: `.drawFaces(` / `.drawFacesHighlighted(` whose FIRST
/// argument is the lit program identifier.
private enum litDrawRe = ctRegex!(`\.(drawFaces|drawFacesHighlighted)\(\s*(lit|litShader)\b`);
private enum litUseRe  = ctRegex!(`\b(lit|litShader)\s*\.\s*useProgram\s*\(`);
private enum applyRe   = ctRegex!(`\bapplyPlan\b`);
private enum restoreRe = ctRegex!(`\brestorePlanDefaults\b`);
private enum fnHeadRe  = ctRegex!(`\bvoid\s+(\w+)\s*\(`);

private size_t[] positions(R)(string code, R re) {
    size_t[] o;
    foreach (m; matchAll(code, re)) o ~= cast(size_t)(m.pre.length);
    return o;
}

/// Nearest position in `ps` strictly before `at`, or -1.
private ptrdiff_t before(const size_t[] ps, size_t at) {
    ptrdiff_t best = -1;
    foreach (p; ps) if (p < at) best = cast(ptrdiff_t)p;
    return best;
}

/// Nearest position in `ps` strictly after `at`, or -1.
private ptrdiff_t after(const size_t[] ps, size_t at) {
    foreach (p; ps) if (p > at) return cast(ptrdiff_t)p;
    return -1;
}

/// "fn: spelling" for the draw at `at` (its enclosing function by the nearest
/// preceding `void name(` head).
private string drawName(string code, size_t at) {
    string fn = "?";
    foreach (m; matchAll(code[0 .. at], fnHeadRe)) fn = m[1];
    size_t e = at;
    while (e < code.length && code[e] != '(') ++e;
    return format("%s: `%s(` at byte %d", fn, code[at .. e], at);
}

/// Every lit draw whose bracket is broken, with the reason.
private string[] bracketViolations(string code) {
    auto draws = positions(code, litDrawRe);
    auto uses  = positions(code, litUseRe);
    auto apps  = positions(code, applyRe);
    auto rests = positions(code, restoreRe);
    string[] bad;
    foreach (d; draws) {
        immutable ptrdiff_t u  = before(uses, d);
        immutable ptrdiff_t a  = before(apps, d);
        immutable ptrdiff_t rb = before(rests, d);
        immutable ptrdiff_t r  = after(rests, d);
        immutable ptrdiff_t nu = after(uses, d);
        if (u < 0 || a < 0 || !(u < a))
            bad ~= drawName(code, d) ~ " — no applyPlan between its useProgram and the draw";
        else if (rb > a)
            bad ~= drawName(code, d) ~ " — restorePlanDefaults runs before the draw";
        else if (r < 0 || (nu >= 0 && nu < r))
            bad ~= drawName(code, d) ~ " — no restorePlanDefaults before the next lit useProgram";
    }
    return bad;
}

unittest { // the bracket checker itself: rejects the three broken shapes, accepts the good one
    enum good = "void f() { lit.useProgram(m, vp); lit.applyPlan(p); g.drawFaces(lit, x);"
              ~ " lit.restorePlanDefaults(); lit.useProgram(m, vp); }";
    enum early = "void f() { lit.useProgram(m, vp); lit.applyPlan(p); lit.restorePlanDefaults();"
               ~ " g.drawFaces(lit, x); lit.useProgram(m, vp); }";
    enum none = "void f() { lit.useProgram(m, vp); g.drawFaces(lit, x);"
              ~ " lit.restorePlanDefaults(); }";
    enum late = "void f() { lit.useProgram(m, vp); lit.applyPlan(p); g.drawFaces(lit, x);"
              ~ " lit.useProgram(m, vp); lit.restorePlanDefaults(); }";
    assert(positions(good, litDrawRe).length == 1, "control: the draw needle must find the snippet's draw");
    assert(bracketViolations(good).length == 0,
        format("control: a well-bracketed draw was rejected: %s", bracketViolations(good)));
    assert(bracketViolations(early).length == 1,
        "control: a restore BEFORE the draw must be rejected");
    assert(bracketViolations(none).length == 1,
        "control: a draw with no applyPlan must be rejected");
    assert(bracketViolations(late).length == 1,
        "control: a restore only after the next lit useProgram must be rejected");
}

unittest { // every lit face draw in the renderer sits inside one applyPlan / restorePlanDefaults bracket
    immutable code = rendererCode();
    // Floor first: the renderer's lit face draws (drawPlainItem, the backdrop,
    // the primary's highlighted and plain draws). Measured 2026-10-02:
    //   grep -nE "\.(drawFaces|drawFacesHighlighted)\((lit|litShader)\b" source/ui/viewport_render.d
    //   -> 4 lines.
    immutable size_t draws = positions(code, litDrawRe).length;
    assert(draws == 4,
        format("census: expected 4 lit face draws in viewport_render.d, found %d — "
               ~ "a draw was added or removed; re-measure before trusting the bracket check", draws));
    // Needles: three face SITES (the primary's two draws share one bracket).
    immutable size_t apps  = positions(code, applyRe).length;
    immutable size_t rests = positions(code, restoreRe).length;
    assert(apps == 3 && rests == 3,
        format("census: expected 3 applyPlan and 3 restorePlanDefaults (one per face site), "
               ~ "found %d / %d", apps, rests));
    // Structural: per draw. True after task 9040; before it there was no
    // applyPlan at all, so every draw was reported.
    const string[] bad = bracketViolations(code);
    assert(bad.length == 0,
        format("census: lit face draws outside the plan-uniform bracket: %s", bad));
}

unittest { // the create-tool preview re-seeds the park through the seam's preview subset before its draw
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.string : indexOf;
    import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, countOccurrences;
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable code = blankUnittestBodies(blankNonCode(
        readText(buildPath(root, "source", "shader.d"))));
    enum head = "void drawLitPreview(";
    assert(countOccurrences(code, head) == 1, "census: expected drawLitPreview defined once in shader.d");
    immutable ptrdiff_t at = code.indexOf(head);
    immutable ptrdiff_t end = code.indexOf("\n}", at);
    immutable body_ = code[at .. end];
    // Floor: the preview's one lit face draw.
    assert(countOccurrences(body_, ".drawFaces(litShader") == 1,
        "census: expected one lit face draw in drawLitPreview");
    // The re-seed (redundant with every scene site's restore while those hold;
    // it is what keeps a preview lit when one does not).
    assert(countOccurrences(body_, ".applyPreviewPlan(") == 1
        && body_.indexOf(".applyPreviewPlan(") < body_.indexOf(".drawFaces(litShader"),
        "census: drawLitPreview must call applyPreviewPlan once, before its face draw");
}

unittest { // the preview subset parks every plan uniform: applyPreviewPlan's body calls restorePlanDefaults
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.string : indexOf;
    import tests.unit.census_symbols : balancedSpan, blankNonCode, blankUnittestBodies, countOccurrences;
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable code = blankUnittestBodies(blankNonCode(
        readText(buildPath(root, "source", "shader.d"))));
    enum head = "void applyPreviewPlan(";
    // Floor: the area exists once and its body is found.
    assert(countOccurrences(code, head) == 1, "census: expected applyPreviewPlan defined once in shader.d");
    immutable ptrdiff_t at = code.indexOf(head);
    immutable ptrdiff_t open = code.indexOf('{', at);
    immutable body_ = open < 0 ? "" : balancedSpan(code, cast(size_t)open, '{', '}');
    assert(body_.length > 2, "census: applyPreviewPlan has no braced body in shader.d");
    // Needle: the park. A later slice may ADD preview-honoured setters after it
    // (S1a's smoothNormals); the park itself stays exactly once.
    assert(countOccurrences(body_, "restorePlanDefaults(") == 1,
        "census: applyPreviewPlan must park the plan uniforms (call restorePlanDefaults once) — "
        ~ "without it a preview drawn after an unlit face pass inherits that pass's shading");
}

// The fence on the plan-uniform LOCATIONS. Outside shader.d a location field
// would let a face pass write a plan uniform by hand
// (`glUniform1f(lit.locDim, …)`), bypassing `applyPlan`. Two layers
// (docs evidence-form item 1): the compiler fence for member access, and a RAW
// text census for the three spellings that bypass `private` across modules —
// `__traits(getMember)`, string `mixin` and `.tupleof`.
unittest { // compile fence: the four plan-uniform locations are unreachable from another module
    import shader : LitShader;
    // Positive control first: the same probe DOES reach a public location of
    // the same class, so a false below means "private", not "probe broken".
    static assert(__traits(compiles, (LitShader s) { int v = s.locFaceAlpha; }),
        "control: the probe no longer reaches a public LitShader field — fix the probe, not the expectation");
    static assert(!__traits(compiles, (LitShader s) { int v = s.locDim; }),
        "fence: LitShader.locDim is reachable outside shader.d — a face pass can hand-write u_dim");
    static assert(!__traits(compiles, (LitShader s) { int v = s.locLightGain; }),
        "fence: LitShader.locLightGain is reachable outside shader.d — a face pass can hand-write u_lightGain");
    static assert(!__traits(compiles, (LitShader s) { int v = s.locShading; }),
        "fence: LitShader.locShading is reachable outside shader.d — a face pass can hand-write u_shading");
    static assert(!__traits(compiles, (LitShader s) { int v = s.locFillColor; }),
        "fence: LitShader.locFillColor is reachable outside shader.d — a face pass can hand-write u_fillColor");
}

unittest { // raw-text census of the spellings that bypass private: names, getMember, mixin, tupleof
    import std.array : replace;
    import std.file : dirEntries, readText, SpanMode;
    import std.path : buildPath, dirName;
    import tests.unit.census_symbols : countOccurrences;
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable src = buildPath(root, "source");
    auto nameRe   = ctRegex!(`\b(locDim|locLightGain|locShading|locFillColor)\b`);
    auto mixinRe  = ctRegex!(`\bmixin\s*\(`);
    // Local positive control for the name needle (raw text: a string literal counts).
    assert(positions(`__traits(getMember, lit, "locDim"); x.locFillColor`, nameRe).length == 2,
        "control: the location-name needle must find a bare and a quoted spelling");
    size_t scanned, litFiles;
    string[] named;          // files outside shader.d naming a plan-uniform location
    string[string] reflect;  // LitShader-mentioning files with a bypass spelling -> counts
    foreach (de; dirEntries(src, "*.d", SpanMode.depth)) {
        immutable rel = de.name[src.length + 1 .. $].replace("\\", "/");
        if (rel == "shader.d") continue;
        ++scanned;
        immutable raw = readText(de.name);   // RAW: strings and comments included
        if (positions(raw, nameRe).length) named ~= rel;
        if (countOccurrences(raw, "LitShader") == 0) continue;
        ++litFiles;
        immutable t = countOccurrences(raw, ".tupleof");
        immutable g = countOccurrences(raw, "__traits(getMember");
        immutable m = positions(raw, mixinRe).length;
        if (t + g + m) reflect[rel] = format("tupleof=%d getMember=%d mixin=%d", t, g, m);
    }
    // Floors on the two domains. Measured 2026-10-02:
    //   find source -name '*.d' | wc -l -> 582 (581 without shader.d);
    //   grep -rl LitShader source --include=*.d | grep -v '^source/shader.d$' | wc -l -> 80.
    assert(scanned >= 581, format("census: the source scan covers %d files outside shader.d, floor 581 — "
        ~ "the walk lost its domain", scanned));
    assert(litFiles >= 80, format("census: %d files outside shader.d mention LitShader, floor 80 — "
        ~ "the reflection domain shrank; re-measure", litFiles));
    // Needle 1 (stationary, true before and after any slice): nobody outside
    // shader.d names a plan-uniform location, in code, string or mixin.
    assert(named.length == 0,
        format("census: plan-uniform location names outside shader.d: %s", named));
    // Needle 2 (stationary ALLOWED set): the bypass spellings in LitShader files
    // are the measured ones, none on a LitShader (registration field walks and
    // the mesh version reads). A new row is a new reflection site next to a lit
    // program: show it does not reach a LitShader, then add the row.
    //   for f in $(grep -rl LitShader source --include=*.d); do grep -c ... ; done -> the 3 rows below.
    enum string[string] allowed = [
        "create_tool_registration.d": "tupleof=0 getMember=1 mixin=0",
        "edit_tool_registration.d": "tupleof=0 getMember=1 mixin=0",
        "tools/alignment/radial_sweep_tool.d": "tupleof=0 getMember=4 mixin=0",
    ];
    assert(reflect == allowed,
        format("census: reflection spellings beside a LitShader changed: found %s, allowed %s", reflect, allowed));
}

// D4 (task 9060, model M4): the backdrop's cache upkeep is never behind a draw
// gate. `drawItemSequence` asserts the upkeep ran for every sequence layer, so
// its behavioural failure is a crash; this census is the witness instead.
// Polarity: false before task 9060 (no `backdropKeepsUpload`), true after.
unittest { // the backdrop upkeep: one gpuFor in draw, guarded by backdropKeepsUpload alone
    import std.string : indexOf, lastIndexOf;
    import tests.unit.census_symbols : balancedSpan, countOccurrences;
    immutable code = rendererCode();
    string bodyOf(string head) {
        assert(countOccurrences(code, head) == 1,
            format("census: expected `%s` defined once in viewport_render.d", head));
        immutable ptrdiff_t at = code.indexOf(head);
        immutable ptrdiff_t open = code.indexOf('{', at);
        immutable b = open < 0 ? "" : balancedSpan(code, cast(size_t)open, '{', '}');
        assert(b.length > 2, format("census: `%s` has no braced body", head));
        return b;
    }
    immutable draw = bodyOf("void draw(SceneInputs");
    enum gpuFor = "bgGpuCache.gpuFor(";
    // Floor and ceiling: ONE upkeep call in the frame.
    assert(countOccurrences(draw, gpuFor) == 1,
        format("census: expected exactly one `%s` in ViewportSceneRenderer.draw, found %d",
               gpuFor, countOccurrences(draw, gpuFor)));
    // The guarding span: from the upkeep loop's `foreach (` to the call.
    immutable ptrdiff_t call = draw.indexOf(gpuFor);
    immutable ptrdiff_t loop = draw[0 .. call].lastIndexOf("foreach (");
    assert(loop >= 0, "census: the upkeep gpuFor is not inside a foreach");
    immutable guard = draw[loop .. call];
    assert(countOccurrences(guard, "backdropKeepsUpload(") == 1,
        "census: the upkeep's guard must be backdropKeepsUpload — found: " ~ guard);
    foreach (flag; ["drawFaces", "drawWire", "entersItemSequence", "backdropDrawsLayer"])
        assert(countOccurrences(guard, flag) == 0,
            format("census: `%s` crept into the backdrop upkeep guard — the upload of a layer "
                   ~ "that is not drawn (or drawn by the item sequence) stops being kept: %s", flag, guard));
    // `entersItemSequence(` (call spelling) only inside backdropDrawsLayer.
    immutable drawsLayer = bodyOf("bool backdropDrawsLayer(");
    assert(countOccurrences(drawsLayer, "entersItemSequence(") == 1,
        "census: backdropDrawsLayer must call entersItemSequence once");
    assert(countOccurrences(code, "entersItemSequence(") == 1,
        format("census: entersItemSequence( is called %d times in viewport_render.d; "
               ~ "only backdropDrawsLayer may call it", countOccurrences(code, "entersItemSequence(")));
}

// The seam's two halves name the SAME setters: a plan uniform `applyPlan`
// writes and `restorePlanDefaults` does not park would leak one face pass's
// value into every later draw of the shared program (task 9070 added the
// normal source; this pins the contract for every later uniform).
unittest {
    import std.algorithm : sort, uniq;
    import std.array : array;
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.string : indexOf;
    import tests.unit.census_symbols : balancedSpan, blankNonCode, blankUnittestBodies;
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable code = blankUnittestBodies(blankNonCode(readText(buildPath(root, "source", "shader.d"))));
    string body_(string head) {
        immutable ptrdiff_t at = code.indexOf(head);
        assert(at >= 0, "census: " ~ head ~ " missing from shader.d");
        return balancedSpan(code, cast(size_t)code.indexOf('{', at), '{', '}');
    }
    string[] setters(string b) {
        string[] o;
        foreach (m; matchAll(b, ctRegex!(`\b(set[A-Z]\w*)\s*\(`))) o ~= m[1];
        o.sort();
        return o.uniq.array;
    }
    auto a = setters(body_("void applyPlan(")), r = setters(body_("void restorePlanDefaults("));
    assert(a.length >= 5, format("census: applyPlan calls %d setters, floor 5", a.length));
    assert(a == r, format("census: applyPlan writes %s but restorePlanDefaults parks %s", a, r));
    // The preview subset: the park, then the normal source the preview honours.
    immutable p = body_("void applyPreviewPlan(");
    immutable ptrdiff_t park = p.indexOf("restorePlanDefaults("), sm = p.indexOf("setSmoothNormals(plan.smoothNormals)");
    assert(park >= 0 && sm > park,
        "census: applyPreviewPlan must park, then honour the plan's normal source");
    // The preview draws with an identity model, so it binds through
    // `useProgram(identity, …)` — the one upload site of the normal matrix
    // (normalMatrix(view·identity)) and the light rig (task 9130) — before
    // its face draw.
    immutable d = body_("void drawLitPreview(");
    immutable ptrdiff_t nm = d.indexOf(".useProgram(identity,"), draw = d.indexOf(".drawFaces(litShader");
    assert(nm >= 0 && draw > nm,
        "census: drawLitPreview must bind through useProgram(identity, …) before its face draw");
}

unittest { // compile fence: the normal-source locations are unreachable from another module too
    import shader : LitShader;
    static assert(__traits(compiles, (LitShader s) { int v = s.locFaceAlpha; }),
        "control: the probe no longer reaches a public LitShader field — fix the probe, not the expectation");
    static assert(!__traits(compiles, (LitShader s) { int v = s.locSmoothNormals; }),
        "fence: LitShader.locSmoothNormals is reachable outside shader.d — a face pass can hand-write u_smoothNormals");
    static assert(!__traits(compiles, (LitShader s) { int v = s.locNormalMatrix; }),
        "fence: LitShader.locNormalMatrix is reachable outside shader.d");
}

// E3 (task 9190): every plan-seam call in the renderer hands the G-buffer a
// surface id — the layer index the site draws, through `surfaceIdForLayer`.
// Polarity: false before 9190 (one-argument calls), true after.
unittest {
    import std.string : indexOf;
    import tests.unit.census_symbols : balancedSpan, countOccurrences;
    import std.algorithm : count;
    immutable code = rendererCode();
    string[] calls;
    for (ptrdiff_t p = code.indexOf(".applyPlan("); p >= 0; p = code.indexOf(".applyPlan(", p + 1))
        calls ~= balancedSpan(code, cast(size_t)(p + ".applyPlan".length), '(', ')');
    // Floor and ceiling: the three face sites (S1p census above).
    assert(calls.length == 3, format("E3: expected 3 applyPlan calls in viewport_render.d, found %d", calls.length));
    // Each site's own layer index, by name (backdrop list entry, sequence
    // entry, the primary).
    immutable string[3] want = ["surfaceIdForLayer(layerIndex)", "surfaceIdForLayer(e.layer)",
                                "surfaceIdForLayer(document.activeIndex())"];
    foreach (w; want)
        assert(calls.count!(c => c.indexOf(w) >= 0) == 1,
            format("E3: no applyPlan call passes `%s` — calls: %s", w, calls));
}

// E5 (task 9190): no colour clear while the integer G-buffer may be in the
// draw set (WebGL2: INVALID_OPERATION; desktop GL permits it, so no pixel
// reddens — the witness is text). Markers found once each FIRST.
unittest {
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.string : indexOf;
    import tests.unit.census_symbols : balancedSpan, blankNonCode, blankUnittestBodies, countOccurrences;
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable code = rendererCode();
    string bodyIn(string src, string head) {
        assert(countOccurrences(src, head) == 1, format("E5: expected `%s` defined once", head));
        immutable ptrdiff_t at = src.indexOf(head);
        return balancedSpan(src, cast(size_t)src.indexOf('{', at), '{', '}');
    }
    immutable draw = bodyIn(code, "void draw(SceneInputs");
    assert(countOccurrences(draw, "beginSurfacePasses(") == 1
        && countOccurrences(draw, "endSurfacePasses(") == 1,
        "E5: the surface-pass bracket markers must occur once each in draw");
    immutable ptrdiff_t b = draw.indexOf("beginSurfacePasses("), e = draw.indexOf("endSurfacePasses(");
    assert(b < e, "E5: beginSurfacePasses must precede endSurfacePasses");
    assert(countOccurrences(draw[b .. e], "glClear(") == 0,
        "E5: a glClear( runs between beginSurfacePasses and endSurfacePasses");
    // The module's clears: the frame clear (before the bracket) and
    // beginItem's depth-only clear (the helpers called inside the bracket
    // reach no other). Ceiling == floor == 2.
    assert(countOccurrences(code, "glClear(") == 2,
        format("E5: viewport_render.d has %d glClear( calls; expected the frame clear and beginItem's",
               countOccurrences(code, "glClear(")));
    assert(draw[0 .. b].indexOf("glClear(") >= 0, "E5: the frame clear must precede the bracket");
    immutable item = bodyIn(code, "private void beginItem(");
    assert(countOccurrences(item, "glClear(") == 1 && countOccurrences(item, "GL_COLOR_BUFFER_BIT") == 0,
        "E5: beginItem must clear depth only (GL_COLOR_BUFFER_BIT in its body)");
    immutable vp = blankUnittestBodies(blankNonCode(readText(buildPath(root, "source", "viewport.d"))));
    immutable bsp = bodyIn(vp, "void beginSurfacePasses(");
    assert(countOccurrences(bsp, "glClearBufferuiv(") == 1,
        "E5: beginSurfacePasses must clear the G-buffer with glClearBufferuiv");
    assert(countOccurrences(bsp, "GL_COLOR_BUFFER_BIT") == 0 && countOccurrences(bsp, "glClear(") == 0,
        "E5: beginSurfacePasses must not colour-clear (GL_COLOR_BUFFER_BIT / glClear( in its body)");
}
