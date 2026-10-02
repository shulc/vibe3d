// E4 (wave plan S2b, task 9190, model M4): the composite pass table is DATA
// and `run` only executes it. Order: per-mode pass-count floor -> the
// per-pass predicate (no feedback loop) with a local positive control -> the
// census that every framebuffer bind / attachment of the compositor goes
// through `applyPassTarget` / `restoreSceneTarget`.
module tests.unit.viewport_composite_test;

import std.format : format;
import std.traits : EnumMembers;
import display_state : CavityMode, CavityState, CompositePlan, resolveCavityParams;
import viewport_composite;

private EffectIds ids() {
    // Distinct non-zero names, so "the target is X" cannot hold by 0 == 0.
    return EffectIds(11, 12, 21, 22, 23, 24, [25, 26]);
}

private CompositePlan planOf(CavityMode m) {
    CavityState s;
    s.mode = m;
    return resolveCavityParams(s);
}

unittest { // the table per cavity mode: count floor first, then every pass legal
    immutable size_t[CavityMode] wantCount = [CavityMode.Off: 0, CavityMode.Screen: 2,
        // World / Both: copy + resolve until the world kernel (S3b) inserts
        // raw + blur H + blur V (then 5).
        CavityMode.World: 2, CavityMode.Both: 2];
    size_t modes;
    foreach (m; [EnumMembers!CavityMode]) {
        const t = compositePassTable(planOf(m), ids());
        assert(t.length == wantCount[m],
            format("E4 %s: %d passes, expected %d", m, t.length, wantCount[m]));
        ++modes;
        if (t.length == 0) continue;
        foreach (i, ref p; t[]) {
            assert(p.drawFbo == ids().effectsFbo,
                format("E4 %s pass %d draws into fbo %d, not the effects fbo", m, i, p.drawFbo));
            foreach (s; p.samples)
                assert(s == 0 || s != p.target,
                    format("E4 %s pass %d samples its own target %d", m, i, p.target));
            assert(p.target != ids().gbufTex && p.target != ids().depthTex,
                format("E4 %s pass %d targets the G-buffer or depth", m, i));
        }
        assert(t[][0].kind == CompositePassKind.copy && t[][0].readFbo == ids().sceneFbo
            && t[][0].target == ids().compositeSrcTex,
            format("E4 %s: the first pass must copy the scene colour into compositeSrcTex", m));
        assert(t[][$ - 1].kind == CompositePassKind.resolve && t[][$ - 1].target == ids().colorTex,
            format("E4 %s: the last pass must resolve into colorTex", m));
        assert(passTableViolation(t[], ids()) is null,
            format("E4 %s: %s", m, passTableViolation(t[], ids())));
    }
    assert(modes == 4, "E4 floor: every CavityMode");
}

unittest { // effectIdsOf maps every field of the cell's FBO (distinct ids, so a swap is seen)
    import viewport : ViewportFbo;
    ViewportFbo f;
    f.fbo = 1; f.effectsFbo = 2; f.colorTex = 3; f.depthTex = 4; f.gbufTex = 5;
    f.compositeSrcTex = 6; f.aoTex = [7, 8];
    assert(effectIdsOf(f) == EffectIds(1, 2, 3, 4, 5, 6, [7, 8]),
        format("effectIdsOf mapped %s", effectIdsOf(f)));
}

unittest { // positive control [E5]: the predicate rejects each illegal shape
    const good = compositePassTable(planOf(CavityMode.Screen), ids());
    assert(passTableViolation(good[], ids()) is null, "control: the shipped table must be legal");
    size_t rejected;
    void reject(string what, void delegate(ref CompositePass[] t) bad) {
        CompositePass[] t = good[].dup;
        bad(t);
        assert(passTableViolation(t, ids()) !is null, "control: " ~ what ~ " must be rejected");
        ++rejected;
    }
    reject("a resolve drawn on the scene fbo", (ref t) { t[$ - 1].drawFbo = ids().sceneFbo; });
    reject("a resolve sampling its own target (feedback loop)",
           (ref t) { t[$ - 1].samples[3] = t[$ - 1].target; });
    reject("a pass targeting the G-buffer", (ref t) { t[$ - 1].target = ids().gbufTex; });
    reject("a pass targeting the depth texture", (ref t) { t[0].target = ids().depthTex; });
    reject("a copy reading the effects fbo", (ref t) { t[0].readFbo = ids().effectsFbo; });
    reject("a table ending without the resolve into colorTex", (ref t) { t = t[0 .. 1]; });
    assert(rejected == 6, "control floor: six illegal shapes");
}

unittest { // census: every bind / attachment in viewport_composite.d goes through the two target functions
    import std.algorithm : canFind, count;
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.regex : ctRegex, matchAll;
    import std.string : indexOf;
    import tests.unit.census_symbols : balancedSpan, blankNonCode, blankUnittestBodies;
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable code = blankUnittestBodies(blankNonCode(
        readText(buildPath(root, "source", "viewport_composite.d"))));
    // The enclosing function of a position: the nearest preceding
    // `void name(` head whose braced body contains it.
    string enclosing(size_t at) {
        string fn;
        foreach (m; matchAll(code[0 .. at], ctRegex!(`\bvoid\s+(\w+)\s*\(`))) {
            immutable size_t head = m.pre.length;
            immutable ptrdiff_t open = code.indexOf('{', head);
            immutable span = open < 0 ? "" : balancedSpan(code, cast(size_t)open, '{', '}');
            if (span.length && cast(size_t)open + span.length > at) fn = m[1];
        }
        return fn;
    }
    immutable string[2] allowed = ["applyPassTarget", "restoreSceneTarget"];
    size_t[string] inside;
    string[] outside;
    // Keyed on the IDENTIFIER, not `name(`: a spaced call `glBindFramebuffer (`,
    // an address `&glBindFramebuffer` and every attach entry point all count.
    foreach (m; matchAll(code, ctRegex!(`\b(glBindFramebuffer|glFramebufferTexture\w*|glFramebufferRenderbuffer)\b`))) {
        immutable fn = enclosing(m.pre.length);
        if (allowed[].canFind(fn)) inside[m[1]] += 1;
        else outside ~= format("%s in %s", m[1], fn.length ? fn : "<module>");
    }
    // Floor: each spelling is found at least once inside the allowed set.
    assert(inside.get("glBindFramebuffer", 0) >= 1 && inside.get("glFramebufferTexture2D", 0) >= 1,
        format("E4 census: the allowed functions %s hold no bind/attach (found %s) — the area moved",
               allowed, inside));
    assert(outside.length == 0,
        format("E4 census: framebuffer binds/attachments outside %s: %s", allowed, outside));
    // Opponent r3 addendum 1: `restoreSceneTarget(` called exactly ONCE in
    // `run`, after the pass loop.
    immutable ptrdiff_t at = code.indexOf("void run(");
    assert(at >= 0, "E4 census: ViewportCompositor.run not found");
    immutable run = balancedSpan(code, cast(size_t)code.indexOf('{', at), '{', '}');
    assert(run.count("restoreSceneTarget(") == 1,
        format("E4 census: restoreSceneTarget( called %d times in run, expected once",
               run.count("restoreSceneTarget(")));
    immutable ptrdiff_t loop = run.indexOf("foreach (ref pass;");
    assert(loop >= 0, "E4 census: the pass loop of run not found");
    immutable loopEnd = loop + balancedSpan(run, cast(size_t)run.indexOf('{', loop), '{', '}').length
                      + (run.indexOf('{', loop) - loop);
    assert(run.indexOf("restoreSceneTarget(") > loopEnd,
        "E4 census: restoreSceneTarget( must run after the pass loop");
    // The binding readback sits immediately before each pass's draw call.
    immutable loopBody = run[loop .. loopEnd];
    foreach (draw; ["glBlitFramebuffer(", "glDrawArrays("]) {
        immutable ptrdiff_t d = loopBody.indexOf(draw);
        assert(d >= 0, "E4 census: " ~ draw ~ " missing from the pass loop");
        immutable ptrdiff_t rec = loopBody[0 .. d].lastIndexOfStr("recordBinding(");
        assert(rec >= 0 && loopBody[rec .. d].count(";") == 1,
            "E4 census: recordBinding( must be the statement right before " ~ draw);
    }
}

private ptrdiff_t lastIndexOfStr(string s, string needle) {
    import std.string : lastIndexOf;
    return s.lastIndexOf(needle);
}

unittest { // S3a (task 9230): the screen-curvature inputs the resolve receives
    // Tap distance: one logical pixel in framebuffer pixels, floored at 1.
    static immutable int[3][] taps = [
        [650, 650, 1], [1300, 650, 2], [975, 650, 2], [1625, 650, 3],
        [600, 650, 1], [100, 650, 1], [0, 650, 1], [650, 0, 1], [-5, 650, 1]];
    foreach (t; taps)
        assert(curvatureTapPx(t[0], t[1]) == t[2],
            format("S3a curvatureTapPx(%d, %d) = %d, expected %d",
                   t[0], t[1], curvatureTapPx(t[0], t[1]), t[2]));
    // Controls: 0.5/max(ridge², 1e-4) and 0.7/max(valley², 1e-4).
    static float[2] ctl(float r, float v) {
        CavityState s;
        s.mode = CavityMode.Screen;
        s.screenRidge = r;
        s.screenValley = v;
        return curvatureControls(resolveCavityParams(s));
    }
    static bool near(float a, float b) { return a > b * 0.9999f && a < b * 1.0001f; }
    static immutable float[4][] rows = [
        [1, 1, 0.5f, 0.7f], [2, 0.5f, 0.125f, 2.8f], [0, 0, 5000, 7000], [0.5f, 2, 2, 0.175f]];
    foreach (r; rows) {
        immutable float[2] c = ctl(r[0], r[1]);
        assert(near(c[0], r[2]) && near(c[1], r[3]),
            format("S3a curvatureControls(ridge %s, valley %s) = %s, expected [%s, %s]",
                   r[0], r[1], c, r[2], r[3]));
    }
    // The term runs for Screen and Both only.
    size_t modes;
    foreach (m; [EnumMembers!CavityMode]) {
        immutable bool want = m == CavityMode.Screen || m == CavityMode.Both;
        assert(screenCurvatureOn(planOf(m)) == want,
            format("S3a screenCurvatureOn(%s) must be %s", m, want));
        ++modes;
    }
    assert(modes == 4, format("S3a population: 4 cavity modes, checked %d", modes));
}
