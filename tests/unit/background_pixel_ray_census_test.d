// Source census of the ONE background ray and the ONE CONS-stage finder
// (task 9357; task 9403). Every production ray -> background-hit query goes
// through `ConstrainStage.rayHit` (the one `.nearest` call) and its pixel /
// gated forms; every reader of the live pipeline's constraint stage goes
// through `liveConstrainStage()`. Code views go through `blankNonCode`
// (comments and literals blanked, same offsets), so a mention in prose is not
// a site.
module tests.unit.background_pixel_ray_census_test;

import std.algorithm : canFind, sort;
import std.array : array;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.string : replace, strip;

import tests.unit.census_symbols : blankNonCode, isIdentChar, symbolTokenHits;

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
        ~ "nearest(o, d);\n"
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

unittest { // (a) the ONE background query: `.nearest` in the CONS stage only; its callers
    // Polarity: TRUE after task 9403. Before it the topology pen called the
    // picker itself (`nearestAtPixel`) and no form existed: the floor and the
    // client roster below were EMPTY. Restoring an inline query in a client
    // reddens the `.nearest` home list or the roster, naming the file.
    auto files = sourceFiles();
    assert(files.length > 300, format("census floor: %d source files", files.length));
    static immutable forms = ["backgroundHit", "rayHit", "rayHitAt", "surfaceOnRay", "surfaceAt"];
    string[] nearestHomes, clients;
    size_t[string] inStage;
    foreach (f; files) {
        immutable code = blankNonCode(readText(buildPath(root, "source", f)));
        if (f == "bvh_pick.d") continue;
        foreach (_; 0 .. memberNearest(code)) nearestHomes ~= f;
        foreach (form; forms) {
            immutable n = tokenAt(code, form).length;
            if (f == "toolpipe/stages/constrain.d") { inStage[form] = n; continue; }
            foreach (_; 0 .. n) clients ~= f ~ ":" ~ form;
        }
    }
    // Floor: each form is declared in constrain.d and each reaches the next
    // there (backgroundHit: decl + rayHit; rayHit: decl + rayHitAt +
    // surfaceOnRay; surfaceOnRay: decl + surfaceAt; rayHitAt: decl + the hover
    // publish; surfaceAt: decl).
    assert(inStage == ["backgroundHit": size_t(2), "rayHit": 3, "rayHitAt": 2, "surfaceOnRay": 2,
                       "surfaceAt": 1],
        format("census floor: the stage's own form tokens (measured); got %s", inStage));
    assert(nearestHomes == ["toolpipe/stages/constrain.d"],
        format("`.nearest` outside bvh_pick.d must be exactly constrain.d's `backgroundHit`; a client "
               ~ "calling the picker builds its own query: %s", nearestHomes));
    enum pen = "tools/edit/topology_pen/tool.d:";
    assert(clients == ["tools/create/create_common.d:surfaceOnRay", "tools/create/pen.d:rayHitAt",
                       pen ~ "backgroundHit", pen ~ "backgroundHit", pen ~ "rayHit"],
        format("background ray clients outside constrain.d must be exactly the free-point resolver's "
               ~ "`surfaceOnRay` (task 9404), the pen's raycast press check `rayHitAt` (task 9416), "
               ~ "the topology pen's `rayHit` (its drag rays through an exact projected point) and its "
               ~ "pipeline-less `backgroundHit` (import + call); got %s", clients));
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

unittest { // (c) a FREE point reads the surface, a primitive's PRESS point does not (task 9404)
    // Polarity: TRUE after task 9404 (K-C role law). The resolver lives in
    // create_common.d; its only client is the vertex tool (the pen joins in
    // P1, the base drag in C2d via `baseDragPoint`). A primitive press calling it — box,
    // sphere-family, torus or tube — appears in the roster and reddens it.
    auto files = sourceFiles();
    assert(files.length > 300, format("census floor: %d source files", files.length));
    static immutable forms = ["placeFreePoint", "baseDragPoint", "backgroundPoint", "backgroundSurfacePoint"];
    string[] clients;
    size_t[string] home;
    foreach (f; files) {
        immutable code = blankNonCode(readText(buildPath(root, "source", f)));
        foreach (form; forms) {
            immutable n = tokenAt(code, form).length;
            if (f == "tools/create/create_common.d") { home[form] = n; continue; }
            foreach (_; 0 .. n) clients ~= f ~ ":" ~ form;
        }
    }
    // Floor: placeFreePoint, baseDragPoint = their declarations; backgroundPoint
    // = its declaration + the two callers' calls; backgroundSurfacePoint = its
    // declaration + backgroundPoint's call.
    assert(home == ["placeFreePoint": size_t(1), "baseDragPoint": 1, "backgroundPoint": 3,
                    "backgroundSurfacePoint": 2],
        format("census floor: the resolver's own tokens in create_common.d (measured); got %s", home));
    // Task 9415 (P1): the pen joins with the surface step (import + call); its
    // plane point is its own (a drag keeps the raw normal channel).
    // Task 9473 (C2d): the box, radial and torus base drags (import + call).
    enum vp = "tools/create/vertex_place.d:", pen = "tools/create/pen.d:", dp = ":baseDragPoint";
    assert(clients == ["tools/create/box.d" ~ dp, "tools/create/box.d" ~ dp,
                       pen ~ "backgroundSurfacePoint", pen ~ "backgroundSurfacePoint",
                       "tools/create/primitive_create_tool.d" ~ dp, "tools/create/primitive_create_tool.d" ~ dp,
                       "tools/create/torus.d" ~ dp, "tools/create/torus.d" ~ dp,
                       vp ~ "placeFreePoint", vp ~ "placeFreePoint"],
        format("free-point clients must be exactly the base drags, the pen's surface step and the vertex "
               ~ "tool (import + call each); a primitive press must stay the plane point; got %s", clients));
    foreach (press; ["tools/create/box.d", "tools/create/primitive_create_tool.d",
                     "tools/create/torus.d", "tools/create/tube.d"])
        assert(files.canFind(press), "census floor: the primitive press file " ~ press ~ " moved");
    // Task 9473 (C2d): the base drag reads the background through
    // `baseDragPoint`, from each family's MOTION block, never its press; the
    // tube has no reference base drag (gap row) and stays the plane point.
    string[] dragSites;
    foreach (f; ["tools/create/box.d", "tools/create/primitive_create_tool.d", "tools/create/torus.d",
                 "tools/create/tube.d"])
        foreach (h; symbolTokenHits(blankNonCode(readText(buildPath(root, "source", f))), f, "baseDragPoint("))
            dragSites ~= h.key;
    sort(dragSites);
    assert(dragSites == ["BoxTool.onMouseMotion", "SizedRadialCreateTool.onMouseMotion",
                         "TorusTool.onMouseMotion"],
        format("baseDragPoint calls must be exactly the box, radial and torus motion blocks: %s", dragSites));
    // ...and every mouse handler of those tools resolves under the event's own
    // cell: `syncEventViewport` is the FIRST statement of each (task 0209's rule).
    import std.regex : matchAll, regex;
    string[] syncSites;
    size_t handlers;
    foreach (f; ["tools/create/box.d", "tools/create/primitive_create_tool.d", "tools/create/torus.d"]) {
        immutable code = blankNonCode(readText(buildPath(root, "source", f)));
        foreach (h; symbolTokenHits(code, f, "syncEventViewport(")) syncSites ~= h.key;
        handlers += tokenAt(code, "onMouseButtonDown").length + tokenAt(code, "onMouseButtonUp").length
                  + tokenAt(code, "onMouseMotion").length;
        immutable first = matchAll(code, regex(`override bool onMouse(ButtonDown|ButtonUp|Motion)`
            ~ `\([^)]*\)\s*\{\s*syncEventViewport\(cachedVp, vts\);`)).array.length;
        assert(first == 3, format("%s: syncEventViewport must open all three mouse handlers (%d do)", f, first));
    }
    sort(syncSites);
    assert(handlers == 9, format("census floor: 9 mouse-handler tokens in the three tools, got %d", handlers));
    assert(syncSites == ["BoxTool.onMouseButtonDown", "BoxTool.onMouseButtonUp", "BoxTool.onMouseMotion",
                         "SizedRadialCreateTool.onMouseButtonDown", "SizedRadialCreateTool.onMouseButtonUp",
                         "SizedRadialCreateTool.onMouseMotion", "TorusTool.onMouseButtonDown",
                         "TorusTool.onMouseButtonUp", "TorusTool.onMouseMotion"],
        format("syncEventViewport calls must be exactly the three tools' mouse handlers: %s", syncSites));
    immutable vertexTool = blankNonCode(readText(buildPath(root, "source", "tools/create/vertex_place.d")));
    assert(tokenAt(vertexTool, "kGuideTypes").length == 0,
        "the vertex tool passes no guide mask: after the guide-block deletion it has no candidate to strip");
    assert(tokenAt(vertexTool, "snapLocalHit").length == 2,
        "census floor: the vertex tool's motion preview still snaps through snapLocalHit (import + call)");
}

unittest { // (d) the topology pen's ONE after-placement pass (task 9510, capture K-SC rule 4)
    // Polarity: TRUE after task 9510. Before it the pen re-snapped through its
    // own nearest-foot helpers (`footOnBackground` / `footOn`: Move, Move
    // Loop, slide endpoints, Add Loop) and two inline `closestPointOnMeshes`
    // calls (both Smooth passes), whatever the constraint's geometry; only the
    // vertex slide ran the stage's `pass`. Restoring any of them reddens the
    // zero list or the counts below.
    auto files = sourceFiles();
    string[] retired;
    foreach (f; files) {
        immutable code = blankNonCode(readText(buildPath(root, "source", f)));
        foreach (tok; ["footOnBackground", "footOn", "gDeltaOffset"])
            foreach (_; tokenAt(code, tok)) retired ~= f ~ ":" ~ tok;
    }
    assert(retired.length == 0, format("the pen's retired re-snap helpers must not come back: %s", retired));
    immutable pen = blankNonCode(readText(buildPath(root, "source", "tools/edit/topology_pen/tool.d")));
    // Floor: the home's declaration plus its five callers (the carried targets,
    // the vertex slide, Add Loop, both Smooth passes), every spelling counted.
    assert(tokenAt(pen, "passLocal").length == 6,
        format("census floor: passLocal decl + 5 callers; got %d", tokenAt(pen, "passLocal").length));
    size_t passMembers;
    foreach (at; tokenAt(pen, "pass")) {
        size_t j = at;
        while (j > 0 && isWs(pen[j - 1])) --j;
        if (j > 0 && pen[j - 1] == '.') ++passMembers;
    }
    assert(passMembers == 1 && tokenAt(pen, "constrainPoint").length == 2,
        format("the stage's `.pass` is called once (inside passLocal) and `constrainPoint` only by its "
               ~ "pipeline-less arm (import + call); got %d / %d", passMembers,
               tokenAt(pen, "constrainPoint").length));
    // What stays a nearest-foot query of its own: the Dup Edge direction's
    // normal and Dup Loop's per-vertex `resnapToBackground` (import + 2 calls).
    assert(tokenAt(pen, "closestPointOnMeshes").length == 3,
        format("closestPointOnMeshes in the pen: import + the Dup Edge normal + resnapToBackground; got %d",
               tokenAt(pen, "closestPointOnMeshes").length));
}
