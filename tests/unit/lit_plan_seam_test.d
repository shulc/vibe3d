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

unittest { // the bracket checker itself: rejects the two broken shapes, accepts the good one
    enum good = "void f() { lit.useProgram(m, vp); lit.applyPlan(p); g.drawFaces(lit, x);"
              ~ " lit.restorePlanDefaults(); lit.useProgram(m, vp); }";
    enum early = "void f() { lit.useProgram(m, vp); lit.applyPlan(p); lit.restorePlanDefaults();"
               ~ " g.drawFaces(lit, x); lit.useProgram(m, vp); }";
    enum none = "void f() { lit.useProgram(m, vp); g.drawFaces(lit, x);"
              ~ " lit.restorePlanDefaults(); }";
    assert(positions(good, litDrawRe).length == 1, "control: the draw needle must find the snippet's draw");
    assert(bracketViolations(good).length == 0,
        format("control: a well-bracketed draw was rejected: %s", bracketViolations(good)));
    assert(bracketViolations(early).length == 1,
        "control: a restore BEFORE the draw must be rejected");
    assert(bracketViolations(none).length == 1,
        "control: a draw with no applyPlan must be rejected");
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
