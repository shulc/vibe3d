// One stroke builder for the pen: `source/tools/create/pen.d` produces NO
// geometry of its own. Every vertex, face and edge the tool appends — live
// preview, prepared parameter image, prepared deactivate candidate, live
// commit — goes through `appendPenGeometry` (`tools.create.pen_geometry`),
// so preview and commit cannot drift apart. Wave plan S1 (task 9356).
//
// The needle set is built from a RULE, not from a list of known call sites:
// every member of `Mesh` whose name is `add` + an upper-case letter. A new
// mesh adder tomorrow joins the set without an edit here. Counting is on
// WHOLE IDENTIFIERS (so `&mesh.addFace` and `addFace (` count as well as
// `addFace(`), over code with comments, strings and unittest bodies blanked.
// The three spellings that reach a member past that view — `.tupleof`,
// `__traits(getMember`, string `mixin(` — are counted in the RAW text.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — score mutations one
// at a time.
module tests.unit.pen_single_builder_census_test;

import std.file : exists, readText;
import std.format : format;
import std.path : buildPath, dirName;

import mesh : Mesh;
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
    countOccurrences, isIdentChar;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// Whole-identifier occurrences of `ident` in `code`: neither neighbour may be
/// an identifier character. Any following punctuation counts (a call, an
/// address-of, a delegate read).
private size_t countIdent(string code, string ident) {
    size_t n = 0, i = 0;
    while (i + ident.length <= code.length) {
        if (code[i .. i + ident.length] == ident &&
            (i == 0 || !isIdentChar(code[i - 1])) &&
            (i + ident.length == code.length ||
             !isIdentChar(code[i + ident.length]))) {
            ++n; i += ident.length;
        } else ++i;
    }
    return n;
}

/// The rule: every `Mesh` member named `add` + an upper-case letter.
private string[] meshAdders() {
    string[] names;
    static foreach (m; __traits(allMembers, Mesh)) {
        static if (m.length > 3 && m[0 .. 3] == "add" &&
                   m[3] >= 'A' && m[3] <= 'Z')
            names ~= m;
    }
    return names;
}

private string codeOf(string rel, out string raw) {
    immutable path = buildPath(repoRoot, rel);
    assert(exists(path), "census target " ~ path ~ " does not exist — the "
        ~ "census would scan nothing and stay green; move this entry with the file");
    raw = readText(path);
    return blankUnittestBodies(blankNonCode(raw));
}

unittest // pen.d appends no geometry except through the one builder
{
    // FLOOR: the needle set. Measured 2026-10-04 on the S1 lane: 8 adders
    // (addVertex, addEdge, addFace, addFaceFast, addWireEdgeFast, addMeshMap,
    // addWeightMap, addMeshMapOfKind). The three geometry producers the pen
    // used must be inside it.
    const adders = meshAdders();
    assert(adders.length == 8, format("Mesh adder rule now selects %s names "
        ~ "(%s); measured 8 — re-measure and pin, never widen blindly",
        adders.length, adders));
    foreach (must; ["addVertex", "addEdge", "addFace"]) {
        bool found;
        foreach (a; adders) if (a == must) found = true;
        assert(found, "adder rule lost " ~ must ~ " — the census is blind");
    }

    // Positive control of the counter (a negation below is only as good as
    // the counter that reports zero): every spelling counts, prefixes do not.
    assert(countIdent("m.addFace([0]); auto d = &m.addFace; addFaceFast(x);",
        "addFace") == 2, "identifier counter lost a spelling");

    string raw;
    const code = codeOf("source/tools/create/pen.d", raw);
    assert(code.length > 20_000, format("pen.d code view is %s bytes; the "
        ~ "census would read a stub", code.length));

    // NEEDLE: no mesh adder anywhere in pen.d production code.
    // State: RED on the pre-S1 tree (addFace 9, addEdge 2, addVertex 4).
    size_t[string] counts;
    foreach (a; adders) {
        const n = countIdent(code, a);
        if (n) counts[a] = n;
    }
    assert(counts.length == 0, format("pen.d appends geometry outside "
        ~ "appendPenGeometry: %s (expected none — route it through the builder)",
        counts));

    // STRUCTURAL: the bypasses that reach a member past the blanked view.
    assert(countOccurrences(raw, ".tupleof") == 0 &&
        countOccurrences(raw, "getMember") == 0 &&
        countOccurrences(raw, "mixin(") == 0 &&
        countOccurrences(raw, "mixin (") == 0,
        "pen.d gained a .tupleof / getMember / string-mixin spelling the "
        ~ "identifier census cannot see");

    // PIN: exactly the four producers call the builder — uploadPreview,
    // buildPreparedParamImage, buildPreparedDeactivateCandidate, commitPolygon.
    // State: RED on the pre-S1 tree (0).
    const calls = countIdent(code, "appendPenGeometry");
    assert(calls == 4, format("pen.d names appendPenGeometry %s times; "
        ~ "expected exactly the 4 producers", calls));
    // Rebuild search/order have one click producer; no release weld remains.
    assert(countIdent(code, "penMergeSources") == 1 &&
        countIdent(code, "penPolygonOrder") == 1,
        "pen rebuild search and order must each have one click producer");
    import std.algorithm : filter;
    import std.array : array;
    import std.ascii : isWhite;
    string compact(string text) { string result; foreach (char c; text) if (!isWhite(c)) result ~= c; return result; }
    assert(compact(" a\t b\n c\r ") == "abc", "rebuild token control");
    const formula = "penMergeSources(vertices_,frame.toWorld,3*viewWorldPerPixel(cachedVp))";
    assert(countOccurrences(compact(code), formula) == 1,
        "pen rebuild distance must be 3 world pixels at the current viewport");
    assert(countIdent(code, "weldVertex") == 0 &&
        countIdent(code, "findHoveredVertExcept") == 0,
        "pen release weld machinery remains");
}

unittest // the builder module is where the adders went (control of the above)
{
    string raw;
    const code = codeOf("source/tools/create/pen_geometry.d", raw);
    assert(code.length > 1_000, "pen_geometry.d code view is a stub");
    foreach (a; ["addVertex", "addEdge", "addFace"])
        assert(countIdent(code, a) >= 1, "builder no longer calls " ~ a
            ~ " — the zero in pen.d would then prove nothing about routing");
}

unittest // every pen point comes from the one resolver (wave plan S3a, task 9358)
{
    // The click (Idle and Drawing), the hover and the drag each turned a pixel
    // into a point with their own plane hit and snap call, through a plane
    // anchored at the frame origin. They now share `resolvePenPoint`, whose
    // anchor is the current point. Counts are whole identifiers in the code
    // view and INCLUDE the import line where the name is imported.
    string raw;
    const code = codeOf("source/tools/create/pen.d", raw);
    assert(code.length > 20_000, "pen.d code view is a stub");

    // NEEDLE: the plane and snap primitives appear once (plus the import),
    // inside the resolver; the focus-origin frame picker and the per-site
    // plane helper are gone. State: RED on the pre-S3a tree (snapLocalHit 5,
    // workplaneCursorPlaneHit 3, localCursorPlane 4, pickWorkplaneFrame 3).
    const size_t[string] want = ["snapLocalHit": 2,
        "workplaneCursorPlaneHit": 2, "localCursorPlane": 0,
        "pickWorkplaneFrame": 0];
    assert(want.length == 4, "resolver needle table lost a row");
    // Positive control: each needle, spelled as in the table, is countable.
    foreach (name, n; want)
        assert(countIdent("a." ~ name ~ "(x); auto d = &" ~ name ~ ";", name)
            == 2, "identifier counter cannot see " ~ name);
    foreach (name, n; want) {
        const got = countIdent(code, name);
        assert(got == n, format("pen.d names %s %s times; expected %s — a "
            ~ "point is produced outside resolvePenPoint", name, got, n));
    }

    // PIN: the resolver's definition plus its four producers (Idle click,
    // Drawing click, hover, drag). State: RED on the pre-S3a tree (0).
    const calls = countIdent(code, "resolvePenPoint");
    assert(calls == 5, format("pen.d names resolvePenPoint %s times; "
        ~ "expected 5 (definition + 4 producers)", calls));
}

unittest // the facing is decided at one site; the builder orders every ring alike (S4, task 9361)
{
    string raw;
    const code = codeOf("source/tools/create/pen.d", raw);
    assert(code.length > 20_000, "pen.d code view is a stub");
    // PIN: one call of the decision (it sits above the append / insert /
    // Make-Quads split, so one call serves all three). State: RED before S4 (0).
    const calls = countIdent(code, "penFacingFlip");
    assert(calls == 1, format("pen.d names penFacingFlip %s times; expected "
        ~ "the one 3rd-point decision", calls));

    // The builder has no Preview-only winding: `purpose` is read once (the
    // sub-minimum Commit face) besides its declaration. State: RED before S4
    // (3: the transitional `purpose == Commit && flip` term).
    string graw;
    const gcode = codeOf("source/tools/create/pen_geometry.d", graw);
    assert(countOccurrences("a PenBuildPurpose.Commit && b",
        "PenBuildPurpose.Commit &&") == 1, "literal counter is blind");
    assert(countOccurrences(gcode, "PenBuildPurpose.Commit &&") == 0,
        "pen_geometry.d gates the flip on the Commit purpose again");
    const purposeReads = countIdent(gcode, "purpose");
    assert(purposeReads == 5, format("pen_geometry.d names `purpose` %s times; "
        ~ "expected 5 (parameter + the selectNew marks, S8; its hand-off to the "
        ~ "non-wall shapes, S9: argument + parameter; the sub-minimum Commit "
        ~ "face)", purposeReads));
    // The ring routine is the builder's: one definition, one call.
    assert(countIdent(gcode, "penRingOrder") == 3, format("pen_geometry.d names "
        ~ "penRingOrder %s times; expected 3 (definition, click order, uncaptured-mode fallback)", countIdent(gcode, "penRingOrder")));
}
