// Source census of the ONE background pixel ray and the ONE CONS-stage finder
// (task 9357, Pen parity wave S2). Every production pixel -> background-hit
// query goes through `BackgroundRayPicker.nearestAtPixel`; every reader of the
// live pipeline's constraint stage goes through `liveConstrainStage()`. Code
// views go through `blankNonCode` (comments and literals blanked, same
// offsets), so a mention in prose is not a site.
module tests.unit.background_pixel_ray_census_test;

import std.algorithm : sort;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.string : replace, strip;

import tests.unit.census_symbols : blankNonCode, isIdentChar;

private enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// Offsets of whole-identifier occurrences of `tok` in `s`.
private size_t[] tokenAt(string s, string tok) {
    size_t[] o;
    for (size_t i = 0; i + tok.length <= s.length; ++i) {
        if (s[i .. i + tok.length] != tok) continue;
        if (i > 0 && isIdentChar(s[i - 1])) continue;
        if (i + tok.length < s.length && isIdentChar(s[i + tok.length])) continue;
        o ~= i;
    }
    return o;
}

/// The text of the parenthesised argument list after the identifier at offset
/// `at` (whitespace skipped), or null when no `(` follows.
private string argsAfter(string s, size_t at) {
    size_t i = at;
    while (i < s.length && isIdentChar(s[i])) ++i;
    while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t' || s[i] == '\r')) ++i;
    if (i >= s.length || s[i] != '(') return null;
    size_t depth = 0;
    immutable begin = i + 1;
    for (; i < s.length; ++i) {
        if (s[i] == '(') ++depth;
        else if (s[i] == ')' && --depth == 0) return s[begin .. i];
    }
    return null;
}

/// Number of member accesses `.nearest` (any whitespace around the dot, any
/// use: call, template call, address taken) in the code view `s`.
private size_t memberNearest(string s) {
    size_t n;
    foreach (at; tokenAt(s, "nearest")) {
        size_t j = at;
        while (j > 0 && (s[j - 1] == ' ' || s[j - 1] == '\n' || s[j - 1] == '\t')) --j;
        if (j > 0 && s[j - 1] == '.') ++n;
    }
    return n;
}

/// CONS finders in the code view `code`: `findByTask` / `findAllByTask` whose argument names the token `Cons`.
private size_t consTaskFinders(string code) {
    size_t n;
    foreach (name; ["findByTask", "findAllByTask"])
        foreach (at; tokenAt(code, name)) {
            auto a = argsAfter(code, at);
            if (a !is null && tokenAt(a, "Cons").length) ++n;
        }
    return n;
}

private bool isWs(char c) { return c == ' ' || c == '\n' || c == '\t' || c == '\r'; }

/// True when `s` holds a `findByTask` / `findAllByTask` / `findById` token.
private bool hasFinder(string s) {
    return tokenAt(s, "findByTask").length || tokenAt(s, "findAllByTask").length
        || tokenAt(s, "findById").length;
}

/// `cast(ConstrainStage)` applied to a finder result in the code view `code`:
/// the operand (up to `;`) holds the finder call, or its leading identifier is
/// assigned (`x = …findBy…;`, `auto x = …`) from one anywhere in the file.
private size_t consCastFinders(string code) {
    size_t n;
    foreach (at; tokenAt(code, "ConstrainStage")) {
        size_t b = at, e = at + "ConstrainStage".length;
        while (b > 0 && isWs(code[b - 1])) --b;
        if (b == 0 || code[b - 1] != '(') continue;
        --b;
        while (b > 0 && isWs(code[b - 1])) --b;
        if (b < 4 || code[b - 4 .. b] != "cast" || (b > 4 && isIdentChar(code[b - 5]))) continue;
        while (e < code.length && isWs(code[e])) ++e;
        if (e >= code.length || code[e] != ')') continue;
        size_t semi = e + 1;
        while (semi < code.length && code[semi] != ';') ++semi;
        immutable operand = code[e + 1 .. semi];
        if (hasFinder(operand)) { ++n; continue; }
        size_t i = 0, j;
        while (i < operand.length && isWs(operand[i])) ++i;
        for (j = i; j < operand.length && isIdentChar(operand[j]); ++j) {}
        if (j == i) continue;
        foreach (v; tokenAt(code, operand[i .. j])) {
            size_t k = v + (j - i);
            while (k < code.length && isWs(code[k])) ++k;
            if (k + 1 >= code.length || code[k] != '=' || code[k + 1] == '=') continue;
            size_t end = k;
            while (end < code.length && code[end] != ';') ++end;
            if (hasFinder(code[k .. end])) { ++n; break; }
        }
    }
    return n;
}

/// `findById` calls whose RAW argument is the literal "constrain".
private size_t consIdFinders(string code, string raw) {
    size_t n;
    foreach (at; tokenAt(code, "findById")) {
        auto a = argsAfter(raw, at);
        if (a !is null && a.strip == `"constrain"`) ++n;
    }
    return n;
}

private string[] sourceFiles() {
    string[] o;
    foreach (e; dirEntries(buildPath(root, "source"), "*.d", SpanMode.depth))
        o ~= relativePath(e.name, buildPath(root, "source")).replace("\\", "/");
    o.sort();
    return o;
}

unittest { // positive control of the four scanners on a probe (must stay green)
    immutable probe = "a.nearest(o, d); b . nearest!(S)(o); auto f = &c.\n nearest;\n"
        ~ "nearest(o, d); p.nearestAtPixel(1, 2);\n"
        ~ "x.findByTask(TaskCode.Cons); y.findByTask( TaskCode . Cons ); z.findAllByTask(Cons);\n"
        ~ "w.findByTask(TaskCode.Snap); v.findByTask(TaskCode.Consume);\n"
        ~ `u.findById("constrain"); t.findById( "constrain" ); s.findById("axis");` ~ "\n"
        ~ "immutable k = TaskCode.Cons; auto c1 = cast(ConstrainStage) q.findByTask(k);\n"
        ~ "auto r = q.findByTask(k); auto c2 = cast( ConstrainStage )\n r;\n"
        ~ "auto c3 = cast(ConstrainStage) other; auto c4 = cast(SnapStage) q.findByTask(k);\n"
        ~ "bool b = o == q.findByTask(k); auto c5 = cast(ConstrainStage) o; foo!(ConstrainStage)(q.findByTask(k));\n";
    immutable code = blankNonCode(probe);
    assert(memberNearest(code) == 3,
        format("probe: three member `.nearest` spellings (call, template, address); got %d",
               memberNearest(code)));
    assert(consTaskFinders(code) == 3,
        format("probe: three Cons task finders (spacing-independent, findAllByTask too; "
               ~ "Snap and Consume excluded); got %d", consTaskFinders(code)));
    assert(consIdFinders(code, probe) == 2,
        format("probe: two findById(\"constrain\") spellings; got %d", consIdFinders(code, probe)));
    assert(consCastFinders(code) == 2,
        format("probe: two cast(ConstrainStage) finder spellings (direct, via a local variable; "
               ~ "a non-finder operand, a comparison, a template argument and a SnapStage cast excluded); got %d", consCastFinders(code)));
}

unittest { // (a) the ONE pixel ray: production callers of nearestAtPixel, and no raw `.nearest`
    // Polarity: TRUE after task 9357. Before it the caller roster is EMPTY
    // (the CONS stage and the topology pen each built their own ray and
    // called `.nearest`); restoring an inline ray reddens the roster or the
    // `.nearest` offender list, naming the file.
    auto files = sourceFiles();
    assert(files.length > 300, format("census floor: %d source files", files.length));
    string[] callers, rawNearest;
    size_t defs;
    foreach (f; files) {
        immutable code = blankNonCode(readText(buildPath(root, "source", f)));
        immutable n = tokenAt(code, "nearestAtPixel").length;
        if (f == "bvh_pick.d") { defs = n; continue; }
        if (n) callers ~= f;
        if (memberNearest(code)) rawNearest ~= f;
    }
    // Floor: the definition is where the census looks for it.
    assert(defs == 1, format("census floor: bvh_pick.d must declare nearestAtPixel once; found %d", defs));
    assert(callers == ["toolpipe/stages/constrain.d", "tools/edit/topology_pen/tool.d"],
        format("nearestAtPixel production callers must be exactly the CONS stage and the topology "
               ~ "pen (the Pen tool (`tools/create/pen.d`) joins in S3b); got %s", callers));
    assert(rawNearest.length == 0,
        format("a raw `.nearest` member call outside bvh_pick.d builds its own pixel ray; "
               ~ "route it through nearestAtPixel: %s", rawNearest));
}

unittest { // (b) the ONE CONS finder over g_pipeCtx: inline finders outside constrain.d
    // Polarity: TRUE after task 9357. Before it four `findByTask(TaskCode.Cons)`
    // sites stood outside constrain.d (constrain.toggle, the topology pen's
    // activation and its background ray query, the prepared activation).
    // The prepared images keep their own finders (the pen image over its captured `pipe_`).
    auto files = sourceFiles();
    assert(files.length > 300, format("census floor: %d source files", files.length));
    string[] taskFinders, idFinders, castFinders;
    size_t inStage, idInStage, castInStage;
    foreach (f; files) {
        immutable raw  = readText(buildPath(root, "source", f));
        immutable code = blankNonCode(raw);
        immutable t = consTaskFinders(code), i = consIdFinders(code, raw), c = consCastFinders(code);
        if (f == "toolpipe/stages/constrain.d") { inStage = t; idInStage = i; castInStage = c; continue; }
        foreach (_; 0 .. t) taskFinders ~= f;
        foreach (_; 0 .. i) idFinders ~= f;
        foreach (_; 0 .. c) castFinders ~= f;
    }
    // Floor: the finder itself is the one site in its home.
    assert(inStage == 1 && idInStage == 0 && castInStage == 1,
        format("census floor: constrain.d must hold exactly the liveConstrainStage finder "
               ~ "(task %d, id %d, cast %d)", inStage, idInStage, castInStage));
    assert(idFinders == ["prepared_pipe_activation.d"],
        format("findById(\"constrain\") sites outside constrain.d (measured: the prepared pipe "
               ~ "activation, its own pipeline): %s", idFinders));
    assert(taskFinders == ["prepared_topology_pen_activation.d"],
        format("CONS task finders outside constrain.d must be exactly the prepared topology-pen "
               ~ "activation (captured `pipe_`); every g_pipeCtx reader calls liveConstrainStage(): %s",
               taskFinders));
    assert(castFinders == ["prepared_pipe_activation.d", "prepared_topology_pen_activation.d"],
        format("cast(ConstrainStage) over a findBy* result outside constrain.d must be exactly the "
               ~ "prepared pipe activation (its own pipeline) and the prepared topology-pen activation "
               ~ "(captured `pipe_`); every g_pipeCtx reader calls liveConstrainStage(): %s", castFinders));
}
