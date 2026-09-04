// tool_commit_seam_census_g8_test — the text half of the gesture-recording
// seam, for group G8, the APP-LEVEL FACTORY TABLE (task 1905, phase D, tail).
//
// ONE FILE PER FAMILY, and that is not filing tidiness. A single tree-wide
// census would serialise the lanes behind each other, and the failure it
// invites is the silent one: two lanes each append a roster line to the same
// file, the merge keeps one, and the lost line's family is then unwatched with
// nothing red to say so. Per-family files make that collision a textual
// conflict instead of a disappearance.
//
// HERE G8 DIFFERS FROM EVERY SIBLING — THE FAMILY IS NOT A DIRECTORY OF TOOLS.
// G1 owned `source/tools/create/`, G4 eleven files of `source/tools/edit/`, G7
// the `topology_pen/` package. G8 owns no tool at all. Its subject is the
// TABLE the application hands the tools: the twenty-four `MeshSessionEdit`
// factories `source/app.d` builds, the twenty-seven `EditorApp` fields they
// are wired into, and the sixty-eight places `source/registration.d` spends
// them. So the members below do not ask "does this tool still call the seam" —
// phases B and C answered that, family by family. They ask the three questions
// that only exist once the factories are ONE parameterised builder instead of
// twenty-four hand-written closures:
//
//   * is every factory still WIRED (a declared-and-unassigned `EditorApp`
//     field is a null delegate, and a null delegate is the silent failure this
//     whole task exists to remove — `recordGestureEdit` returns false, the
//     mesh stays edited, and no undo entry is written);
//   * is every WIRE NAME still byte-identical (undo history, event-log replay
//     and macros all dispatch on the string, and after the collapse all
//     twenty-four strings live in one table where a single careless edit
//     reaches any of them);
//   * and is the alias hazard the plan named as danger Б7 still dead.
//
// THAT LAST ONE IS THE POINT OF MEMBER 4, so it is worth saying plainly. The
// plan (card 1905, §1) recorded `VertexEditFactory` as ONE NAME FOR TWO
// DIFFERENT DELEGATE TYPES — `MeshSessionEdit delegate()` in `vertex_place.d`
// and `drag_weld.d`, `MeshVertexEdit delegate()` in `transform.d` and
// `xfrm_transform.d` — and warned that "unify the alias" RE-TYPES two tools
// and both keep compiling. Phases B and C deleted the two `MeshSessionEdit`
// spellings as a side effect of migrating their tools, so on this tree the
// hazard is gone: measured, two declarations remain and both name the same
// type. Nothing in the compiler defends that. A third `alias VertexEditFactory
// = MeshSessionEdit delegate();` dropped into any tool module tomorrow
// compiles, is unused where it is written, and restores the exact ambiguity
// the plan feared — which is the mutation member 4 was driven with.
//
// WHAT THIS FILE CANNOT SEE, said here so nobody trusts it for that:
//   * WHICH gesture a factory ends up labelling. The thirteen `topoPen*` rows
//     are passed BY POSITION to `setPenFactories`, and a swap there re-pairs
//     two gestures with two wire names while every count below is unchanged.
//     That chain is member 7 of `tool_commit_seam_census_g7_test.d`, which
//     reads the wire name out of the same table this file rosters.
//   * WHAT a factory records. That is the frozen plane fixtures'
//     (`tests/fixtures/tool_gesture/g*.json`) job, family by family.
//   * WHETHER the collapse changed behaviour. It cannot: the builder's lambda
//     is the same expression the twenty-four lambdas held. The witness for
//     that is the suite, not a text scan.
//
// EVERY NON-VACUITY FLOOR IS INSIDE THE ACCUMULATOR, NEVER AHEAD OF IT. A
// floor written as a separate assert ABOVE the roster raise aborts the module
// first — druntime stops at the first failed assert — so it SWALLOWS the row
// it exists to accompany: you read "the scanner found 0" and never learn which
// name moved. Folded in, the floor is one more finding in the same list, the
// module fails once, and a blinded run can be checked on the observable that
// separates the two: does it report ITS OWN rows, or only the floor's line?
//
// EVERY MEMBER READS THE TREE THROUGH ONE FUNCTION, `readSource`, and that is
// deliberate: it gives the blinding drill a single place to break. Making it
// return "" turns every member's scan vacuous at once, and each member then
// has to print its own floor row rather than throwing or passing.
//
// MUTATIONS, one per member — every one of them was run, all six compile
// (`dub build` RC=0), and the verbatim message is in the task card (3270).
// Five redden ONLY this file; number 5 is the exception, and its exception is
// worth reading rather than smoothing over:
//   1. declare a 25th `MeshSessionEdit delegate() fooEditFactory;` on
//      `EditorApp` and wire it nowhere -> member 1, by field name. It COMPILES:
//      an unassigned delegate field is null, not a diagnostic.
//   2. hand-write a 25th `() => new MeshSessionEdit(...)` closure in `app.d`
//      instead of calling the builder -> member 2, with both construction
//      sites' line numbers.
//   3. change one wire name string -> member 3, with the frozen string and the
//      fresh one side by side.
//   4. add `alias VertexEditFactory = MeshSessionEdit delegate();` to a tool
//      module that does not use it -> member 4, naming both right-hand sides.
//      This is danger Б7 restored, and it compiles.
//   5. add a fourth `public void setUndoBindings(...)` declaration to a tool
//      -> member 5, as an UNROSTERED declaration with its file and line. Put
//      in a G4 tool (`edit/tack.d`) it reddens TWO censuses for two different
//      reasons — G4's member 4 says "no tool of this FAMILY declares a
//      binder", this member says "no file in `source/` declares an unrostered
//      one" — and the two were run in isolation, because druntime stops a
//      module at its first failed assert. Put where no family census looks at
//      all (`transform/move.d`, the transform zone) it reddens ONLY this one,
//      which is the honest statement of what member 5 adds: it is the only
//      watcher of the half of the tree the per-family files cannot see.
//   6. swap one registration's `bevelEditFactory` for `loopSliceEditFactory`
//      -> member 6, reddening TWO rows in one run (24 -> 23 and 1 -> 2). Both
//      are `MeshSessionEdit delegate()`, so it compiles and records a bevel
//      under the wire name and label of a loop slice.
//
// LANE: `dub test --config=tests`. (The mutation drill also runs this file
// standalone — `dmd -unittest -main -run` — because it imports nothing from
// the repo and reads the tree as TEXT at run time, so its own binary is
// rebuilt from this exact source every time and the mutated files are read
// fresh. That is a convenience for the drill, never a substitute for the gate.)
module tests.unit.tool_commit_seam_census_g8_test;

import std.algorithm : sort, uniq;
import std.array     : appender, array;
import std.conv      : to;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.path      : buildPath, dirName, relativePath;
import std.regex     : regex, matchAll;
import std.string    : indexOf, strip;

import tests.unit.census_symbols : blankNonCode, LedgerRow, LedgerHit,
    reconcile, symbolTokenHits;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// THE ONE READER. Every member goes through this, so the blinding drill has a
// single place to break: make it return "" and every scan below reads nothing.
// A member that then passes, or throws instead of printing its floor row, is a
// member whose floor is not an accumulator row.
// ---------------------------------------------------------------------------
private string readSource(string rel) {
    return readText(buildPath(repoRoot, rel));
}

// ---------------------------------------------------------------------------
// The stripper, because the count is the whole point. A doc comment that names
// `new MeshSessionEdit(` moves the number, and this file's job is to notice a
// real construction, not a sentence about one.
//
// Same shape as `tests/unit/tool_commit_seam_census_g4_test.d`'s, and with the
// same known gap: wysiwyg strings (`r"…"`) and character literals (`'"'`) can
// desync it. The guard against a silent desync is not a promise — it is the
// non-vacuity floor in every member below: a scanner that lost its place eats
// the rest of the file, and the totals collapse and redden with a message that
// says so.
// ---------------------------------------------------------------------------
private alias stripCommentsAndStrings = blankNonCode;

/// Comments only — string literals survive because the wire names are
/// literals in the registration census below.
private string stripCommentsOnly(string src) {
    auto sink = appender!string;
    size_t i = 0;
    while (i < src.length) {
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '/') {
            while (i < src.length && src[i] != '\n') { sink.put(' '); ++i; }
            continue;
        }
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '*') {
            i += 2; sink.put("  ");
            while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
                sink.put(src[i] == '\n' ? '\n' : ' '); ++i;
            }
            i = (i + 2 <= src.length) ? i + 2 : src.length;
            sink.put("  ");
            continue;
        }
        if (src[i] == '"') {
            sink.put(src[i]); ++i;
            while (i < src.length && src[i] != '"') {
                if (src[i] == '\\' && i + 1 < src.length) { sink.put(src[i]); ++i; }
                sink.put(src[i]); ++i;
            }
            if (i < src.length) { sink.put(src[i]); ++i; }
            continue;
        }
        sink.put(src[i]);
        ++i;
    }
    return sink.data;
}

private size_t countOccurrences(string hay, string needle) {
    size_t n = 0, i = 0;
    if (needle.length == 0) return 0;
    while (i + needle.length <= hay.length) {
        if (hay[i .. i + needle.length] == needle) { ++n; i += needle.length; }
        else ++i;
    }
    return n;
}

private size_t lineOf(string src, size_t pos) {
    size_t n = 1;
    foreach (i; 0 .. pos) if (src[i] == '\n') ++n;
    return n;
}

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

/// Line numbers of every occurrence of `needle` in `src`.
private size_t[] needleLines(string src, string needle) {
    size_t[] r;
    size_t i = 0;
    while (i + needle.length <= src.length) {
        if (src[i .. i + needle.length] == needle) { r ~= lineOf(src, i); i += needle.length; }
        else ++i;
    }
    return r;
}

/// Whole-identifier occurrences of `ident` in `src`, as line numbers.
private size_t[] identHits(string src, string ident) {
    size_t[] hits;
    size_t i = 0;
    while (true) {
        auto rel = src[i .. $].indexOf(ident);
        if (rel < 0) break;
        size_t p = i + cast(size_t) rel;
        i = p + ident.length;
        if (p > 0 && isIdentChar(src[p - 1])) continue;
        if (i < src.length && isIdentChar(src[i])) continue;
        hits ~= lineOf(src, p);
    }
    return hits;
}

/// Every `.d` under `source/`, repo-relative, sorted. The two walking members
/// (4 and 5) share it so their floors talk about the same population.
private string[] sourceTree() {
    string[] r;
    immutable root = buildPath(repoRoot, "source");
    if (!exists(root)) return r;
    foreach (e; dirEntries(root, "*.d", SpanMode.depth))
        r ~= relativePath(e.name, repoRoot);
    r.sort();
    return r;
}

private string joinLines(const(string)[] xs) {
    string r;
    foreach (x; xs) r ~= x ~ "\n";
    return r;
}

// ---------------------------------------------------------------------------
// THE TABLE. Twenty-four `MeshSessionEdit` rows plus the three factories that
// build a different carrier and therefore cannot share the builder
// (`MeshVertexEdit` / `MeshMorphEdit` / `LayerXformEdit`). The field name is
// the key everywhere below: `EditorApp` declares it, `app.d` assigns it,
// `registration.d` spends it.
// ---------------------------------------------------------------------------
private struct Row {
    string field;   // the EditorApp field and the app.d local, same spelling
    string wire;    // MeshSessionEdit.name() — frozen, dispatched on
    string label;   // the constructor's default label
    string scope_;  // the third builder argument, "" when the default is taken
    size_t binds;   // whole-identifier uses in source/registration.d
    string why;     // why this row's bind count is what it is
}

private enum Row[] kSessionRows = [
    Row("bevelEditFactory", "mesh.bevel_edit", "Bevel", "", 24,
        "the shared snapshot carrier: TWENTY-FOUR tool registrations bind it "
      ~ "under ONE wire name, which is why anything done to this row lands on "
      ~ "all twenty-four at once and why G5's mutations key on plane dumps "
      ~ "rather than on entryNames for the pair it moved"),
    Row("loopSliceEditFactory", "mesh.loop_slice_edit", "Loop Slice", "", 1,
        "mesh.loopSliceTool"),
    Row("reduceEditFactory", "mesh.reduce_edit", "Reduce", "", 1,
        "mesh.reduceTool"),
    Row("cloneEditFactory", "mesh.clone_edit", "Clone", "", 1,
        "mesh.clone"),
    Row("arrayEditFactory", "mesh.array_edit", "Array", "", 1,
        "mesh.array"),
    Row("edgeExtrudeEditFactory", "mesh.edge_extrude_edit", "Edge Extrude",
        "sessionGeomMarks", 1, "edge.extrude"),
    Row("edgeExtendEditFactory", "mesh.edge_extend_edit", "Edge Extend",
        "sessionGeomMarks", 1, "edge.extend"),
    Row("polyExtrudeEditFactory", "mesh.face_extrude_edit", "Face Extrude",
        "sessionGeomMarks", 1, "poly.extrude"),
    Row("radialArrayEditFactory", "mesh.radial_array_edit", "Radial Array",
        "sessionGeomMarks", 1, "mesh.radialArray"),
    Row("smoothShiftEditFactory", "mesh.smooth_shift_edit", "Smooth Shift",
        "", 1, "mesh.smoothShiftTool"),
    Row("strokeExtrudeEditFactory", "mesh.strokeExtrude_edit", "Stroke Extrude",
        "sessionGeomMarks", 1,
        "mesh.strokeExtrude — and the wire name is camelCase where every "
      ~ "sibling is snake_case, a pre-existing irregularity preserved byte for "
      ~ "byte because history and replay dispatch on the string"),
    // The thirteen Topology Pen rows. Each is spent ONCE, inside the single
    // `setPenFactories(...)` call, so the count says nothing about ORDER —
    // that is member 7 of the G7 census, deliberately not duplicated here.
    Row("topoPenBuildEditFactory", "mesh.topoPen_build", "Topology Build",
        "sessionGeomMarks", 1, "setPenFactories position 0"),
    Row("topoPenMoveEditFactory", "mesh.topoPen_move", "Topology Move",
        "MeshEditScope.Position", 1, "setPenFactories position 1"),
    Row("topoPenRemoveEditFactory", "mesh.topoPen_remove", "Topology Remove",
        "MeshEditScope.Geometry", 1, "setPenFactories position 2"),
    Row("topoPenAddLoopEditFactory", "mesh.topoPen_addloop", "Topology Add Loop",
        "sessionGeomMarks", 1, "setPenFactories position 3"),
    Row("topoPenSlideEditFactory", "mesh.topoPen_slide", "Topology Slide",
        "MeshEditScope.Position", 1, "setPenFactories position 4"),
    Row("topoPenSmoothEditFactory", "mesh.topoPen_smooth", "Topology Smooth",
        "MeshEditScope.Position", 1, "setPenFactories position 5"),
    Row("topoPenSplitEditFactory", "mesh.topoPen_split", "Topology Split",
        "MeshEditScope.Geometry", 1, "setPenFactories position 6"),
    Row("topoPenMoveLoopEditFactory", "mesh.topoPen_moveloop", "Topology Move Loop",
        "MeshEditScope.Position", 1, "setPenFactories position 7"),
    Row("topoPenDupLoopEditFactory", "mesh.topoPen_duploop", "Topology Duplicate Loop",
        "sessionGeomMarks", 1, "setPenFactories position 8"),
    Row("topoPenSmoothLoopEditFactory", "mesh.topoPen_smoothloop", "Topology Smooth Loop",
        "MeshEditScope.Position", 1, "setPenFactories position 9"),
    Row("topoPenFillEditFactory", "mesh.topoPen_fill", "Topology Fill",
        "MeshEditScope.Geometry", 1, "setPenFactories position 10"),
    Row("topoPenRemoveEdgeEditFactory", "mesh.topoPen_removeedge", "Topology Remove Edge",
        "MeshEditScope.Geometry", 1, "setPenFactories position 11"),
    Row("topoPenRemoveVertexEditFactory", "mesh.topoPen_removevertex", "Topology Remove Vertex",
        "MeshEditScope.Geometry", 1, "setPenFactories position 12"),
];

/// The three factories that build a DIFFERENT carrier and therefore cannot
/// share the builder. They are in the wiring census (member 1) because an
/// unwired one fails exactly the same silent way; they are not in the wire-name
/// census (member 3) because they carry no wire name — the carrier class's own
/// `name()` answers for them.
private struct OtherRow { string field; string carrier; size_t binds; string why; }

private enum OtherRow[] kOtherRows = [
    OtherRow("vxEditFactory", "MeshVertexEdit", 13,
        "TWELVE `setUndoBindings` calls in the transform zone plus ONE "
      ~ "`setGestureBindings` for xfrm.magnet. That split is the residue "
      ~ "member 5 rosters, and it does NOT close with this group: the "
      ~ "transform zone is out of task 1905's scope by decision D1"),
    OtherRow("morphEditFactory", "MeshMorphEdit", 4,
        "the four XfrmTransformTool registrations' third `setUndoBindings` "
      ~ "argument (task 1069's routed-gesture carrier)"),
    OtherRow("layerXformEditFactory", "LayerXformEdit", 4,
        "the four XfrmTransformTool registrations' `setItemUndoFactory`"),
];

// ---------------------------------------------------------------------------
// 1. EVERY FACTORY FIELD IS DECLARED ONCE AND WIRED ONCE.
//
//    `EditorApp` holds the factory as a delegate FIELD. An unassigned delegate
//    field is `null` — not a diagnostic, not a warning, nothing. The tool binds
//    it, `recordGestureEdit` finds a null carrier factory, refuses, and the
//    gesture edits the mesh with no undo entry behind it. That is the exact
//    failure mode this whole task exists to remove, and after the collapse the
//    wiring is a hand-maintained list of twenty-seven lines, so it is worth a
//    row of its own.
//
//    The field set is DERIVED from `editor_app.d`, not trusted: a
//    twenty-eighth field added tomorrow is a candidate member whether or not
//    anyone updates the roster.
// ---------------------------------------------------------------------------
unittest {
    string[] problems;

    // Anti-duplication first: a typo in the roster throws when the file is
    // read, but a DUPLICATE is silent and would leave one real field unscanned
    // and green forever.
    string[] names;
    foreach (r; kSessionRows) names ~= r.field;
    foreach (r; kOtherRows)   names ~= r.field;
    auto sorted = names.dup;
    sorted.sort();
    if (sorted.uniq.array.length != names.length)
        problems ~= "    · the roster names only "
                  ~ sorted.uniq.array.length.to!string ~ " DISTINCT field(s) "
                  ~ "across " ~ names.length.to!string ~ " rows — a duplicate "
                  ~ "leaves one factory unscanned, and its per-field checks "
                  ~ "below then pass by never running";

    immutable appSrc  = stripCommentsAndStrings(readSource("source/app.d"));
    immutable edSrc   = stripCommentsAndStrings(readSource("source/editor_app.d"));

    // (i) the declared field set, derived: `<Type> delegate() <name>EditFactory;`
    string[] declared;
    foreach (mt; edSrc.matchAll(regex(`delegate\s*\(\s*\)\s+(\w*EditFactory)\s*;`)))
        declared ~= mt[1];

    foreach (d; declared) {
        bool rostered = false;
        foreach (n; names) if (n == d) { rostered = true; break; }
        if (!rostered)
            problems ~= "    · `EditorApp." ~ d ~ "` is declared and is in no "
                      ~ "roster here. Every factory field must be wired in "
                      ~ "`source/app.d` and rostered here WITH ITS CONSUMER; an "
                      ~ "unassigned delegate field is null and fails silently";
    }
    foreach (n; names) {
        bool present = false;
        foreach (d; declared) if (d == n) { present = true; break; }
        if (!present)
            problems ~= "    · rostered factory field is gone from "
                      ~ "`source/editor_app.d`: " ~ n;
    }

    // (ii) each field is assigned exactly once in app.d, from the same-named
    //      local. `app.X = X;` — both halves matter: the left says the field is
    //      wired, the right says it is wired from the row built above.
    foreach (n; names) {
        immutable size_t lhs = countOccurrences(appSrc, "app." ~ n);
        if (lhs != 1)
            problems ~= "    · `source/app.d` names `app." ~ n ~ "` "
                      ~ lhs.to!string ~ " time(s); exactly one assignment is "
                      ~ "the wiring. Zero = the field stays null and every "
                      ~ "gesture bound to it records nothing";
    }

    if (declared.length < kSessionRows.length + kOtherRows.length)
        problems ~= "    · NON-VACUITY: the scan of `source/editor_app.d` found "
                  ~ declared.length.to!string ~ " factory field declaration(s), "
                  ~ "and the roster holds "
                  ~ (kSessionRows.length + kOtherRows.length).to!string
                  ~ ". The reader returned nothing, or the field spelling moved "
                  ~ "— the rows above are then measuring an empty list";

    assert(problems.length == 0,
        "G8 census: the app-level factory table is not wired the way it is "
      ~ "declared.\n" ~ joinLines(problems)
      ~ "  Add the field to `kSessionRows` (a MeshSessionEdit factory) or to "
      ~ "`kOtherRows` (any other carrier) WITH ITS CONSUMER, and wire it in "
      ~ "`source/app.d`. Do not delete the row that reddened.");
}

// ---------------------------------------------------------------------------
// 2. THE COLLAPSE ITSELF: ONE BUILDER, ONE CONSTRUCTION SITE, TWENTY-FOUR ROWS.
//
//    Before group G8 `source/app.d` held twenty-four separately written
//    `() => new MeshSessionEdit(&mesh(), cameraView, editMode, …)` lambdas.
//    They differed only in the last three arguments, and the first three —
//    the LIVE CONTEXT — were retyped twenty-four times; one of them wrong would
//    have read exactly like the other twenty-three. There is one lambda now.
//
//    This member also pins the builder's DEFAULT SCOPE. Five rows below name no
//    scope at all and take `MeshEditScope.None` from the builder's default
//    parameter; changing that default silently re-scopes all five, and no wire
//    name, no count and no plane dump moves.
// ---------------------------------------------------------------------------
private enum string kBuilderDecl = "MeshSessionEdit delegate() sessionEditFactory(";
private enum string kBuilderDefault = "MeshEditScope editScope = MeshEditScope.None";

unittest {
    string[] problems;

    immutable appSrc = stripCommentsAndStrings(readSource("source/app.d"));

    immutable size_t ctors = countOccurrences(appSrc, "new MeshSessionEdit(");
    if (ctors != 1) {
        problems ~= "    · `source/app.d` constructs MeshSessionEdit at "
                  ~ ctors.to!string ~ " site(s); after group G8 there is "
                  ~ "exactly ONE, inside `sessionEditFactory`. Lines: "
                  ~ (){
                        string r;
                        foreach (h; needleLines(appSrc, "new MeshSessionEdit("))
                            r ~= h.to!string ~ " ";
                        return r.strip();
                    }()
                  ~ ". A hand-written twenty-fifth closure re-opens the "
                  ~ "duplication this group closed, and its live context is "
                  ~ "then unchecked by anything";
    }

    immutable size_t builders = countOccurrences(appSrc, kBuilderDecl);
    if (builders != 1)
        problems ~= "    · `" ~ kBuilderDecl ~ "` is declared "
                  ~ builders.to!string ~ " time(s); exactly one is the point of "
                  ~ "the collapse. A zero also means the scan read nothing, so "
                  ~ "the row above is vacuous too";

    immutable size_t rows = countOccurrences(appSrc, "= sessionEditFactory(");
    if (rows != kSessionRows.length)
        problems ~= "    · `source/app.d` has " ~ rows.to!string
                  ~ " builder call(s), the roster holds "
                  ~ kSessionRows.length.to!string ~ ". A factory added without "
                  ~ "a roster row is a wire name nothing freezes";

    // The default. Read off the RAW-ish stripped text: the token is code, not a
    // string literal, so the full stripper keeps it.
    if (countOccurrences(appSrc, kBuilderDefault) != 1)
        problems ~= "    · the builder's default scope parameter is no longer "
                  ~ "spelled `" ~ kBuilderDefault ~ "`. Five rows name no scope "
                  ~ "and take this default; changing it re-scopes all five at "
                  ~ "once, and nothing else in this file, in the fixtures or on "
                  ~ "the wire moves when it does";

    assert(problems.length == 0,
        "G8 census: the collapsed factory builder moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 3. THE FROZEN (wire name, label, scope) TABLE.
//
//    `MeshSessionEdit.name()` returns `wireName_` VERBATIM. Undo history,
//    event-log replay and macro dispatch all key on that string, so it is not a
//    label to be tidied: changing one silently orphans every recorded history
//    entry and every replay log that names the old one. Before the collapse the
//    twenty-four strings sat in twenty-four separate statements; they now sit
//    in one table, where a careless edit reaches any of them, which is exactly
//    why the table is frozen HERE rather than described in prose beside it.
//
//    RAW-ish source here, not the full stripper, and that is the one place in
//    this file where it has to be: the wire name IS a string literal. Comments
//    are still stripped, so a paragraph that spells a wire name cannot be
//    mistaken for a row.
// ---------------------------------------------------------------------------
unittest {
    string[] problems;

    immutable appSrc = stripCommentsOnly(readSource("source/app.d"));

    struct Parsed { string field, wire, label, scope_; }
    Parsed[] fresh;
    foreach (mt; appSrc.matchAll(regex(
            `auto\s+(\w+EditFactory)\s*=\s*sessionEditFactory\(\s*"([^"]*)"\s*,\s*"([^"]*)"\s*(?:,\s*([^)]*?)\s*)?\)\s*;`)))
        fresh ~= Parsed(mt[1], mt[2], mt[3], mt[4].strip());

    foreach (f; fresh) {
        bool found = false;
        foreach (r; kSessionRows) {
            if (r.field != f.field) continue;
            found = true;
            if (r.wire != f.wire)
                problems ~= "    · " ~ f.field ~ ": wire name is `" ~ f.wire
                          ~ "`, frozen as `" ~ r.wire ~ "`. Undo history, "
                          ~ "event-log replay and macros dispatch on this "
                          ~ "string; if the rename is deliberate, re-freeze "
                          ~ "this roster AND say what happens to the recorded "
                          ~ "logs that still carry the old name";
            if (r.label != f.label)
                problems ~= "    · " ~ f.field ~ ": default label is `" ~ f.label
                          ~ "`, frozen as `" ~ r.label ~ "`. This one is only "
                          ~ "the FALLBACK — a tool that passes its own label to "
                          ~ "`setSnapshots` overrides it — so a change here is "
                          ~ "invisible to every tool that does";
            if (r.scope_ != f.scope_)
                problems ~= "    · " ~ f.field ~ ": editScope argument is `"
                          ~ (f.scope_.length ? f.scope_ : "<default>")
                          ~ "`, frozen as `"
                          ~ (r.scope_.length ? r.scope_ : "<default>") ~ "`";
            break;
        }
        if (!found)
            problems ~= "    · `source/app.d` builds " ~ f.field
                      ~ " (wire `" ~ f.wire ~ "`) and this roster does not "
                      ~ "hold it";
    }
    foreach (r; kSessionRows) {
        bool present = false;
        foreach (f; fresh) if (f.field == r.field) { present = true; break; }
        if (!present)
            problems ~= "    · rostered factory `" ~ r.field ~ "` (wire `"
                      ~ r.wire ~ "`) is built nowhere in `source/app.d`";
    }

    // Wire names must be pairwise distinct EXCEPT that they simply are today —
    // the sharing happens at the BINDING (bevelEditFactory serves 24
    // registrations), never at the table.
    {
        string[] wires;
        foreach (r; kSessionRows) wires ~= r.wire;
        auto ws = wires.dup;
        ws.sort();
        if (ws.uniq.array.length != wires.length)
            problems ~= "    · the frozen roster holds only "
                      ~ ws.uniq.array.length.to!string ~ " DISTINCT wire "
                      ~ "name(s) across " ~ wires.length.to!string ~ " rows. "
                      ~ "Two factories under one wire name are "
                      ~ "indistinguishable in history and in a replay";
    }

    if (fresh.length < kSessionRows.length)
        problems ~= "    · NON-VACUITY: the parse of `source/app.d` yielded "
                  ~ fresh.length.to!string ~ " builder row(s), the roster holds "
                  ~ kSessionRows.length.to!string ~ ". The reader returned "
                  ~ "nothing, or the row spelling moved away from `auto X = "
                  ~ "sessionEditFactory(\"wire\", \"label\"[, scope]);` — every "
                  ~ "comparison above is then against an empty list. Member 7 "
                  ~ "of `tool_commit_seam_census_g7_test.d` parses these same "
                  ~ "rows and will have gone red for the same reason";

    assert(problems.length == 0,
        "G8 census: the frozen wire-name table moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 4. `VertexEditFactory` NAMES EXACTLY ONE TYPE, TREE-WIDE.
//
//    Danger Б7 of the plan, and the only member here that pins a hazard rather
//    than a shape. The plan measured `VertexEditFactory` as ONE NAME FOR TWO
//    DIFFERENT DELEGATE TYPES and warned that "unify the alias" would re-type
//    two tools with both still compiling. Phases B and C removed the two
//    `MeshSessionEdit delegate()` spellings as a side effect of migrating the
//    tools that carried them, so the hazard is gone from the tree — and NOTHING
//    IN THE COMPILER KEEPS IT GONE. The declarations live in different modules;
//    a third one, in a module that does not use it, compiles silently.
//
//    So this member does not assert "there is one declaration" (there are two,
//    and both are legitimate — `transform.d` declares it, `xfrm_transform.d`
//    re-declares the same type beside its own selective import). It asserts
//    that every declaration in the tree names the SAME right-hand side, and
//    prints every distinct one it found when they disagree.
// ---------------------------------------------------------------------------
private enum string kAliasName = "VertexEditFactory";
private enum string kAliasType = "MeshVertexEdit delegate()";

unittest {
    string[] problems;

    struct Decl { string file; size_t line; string rhs; }
    Decl[] decls;
    size_t filesRead = 0;

    foreach (rel; sourceTree()) {
        auto src = stripCommentsAndStrings(readSource(rel));
        ++filesRead;
        foreach (mt; src.matchAll(regex(
                `alias\s+` ~ kAliasName ~ `\s*=\s*([^;]+);`)))
            decls ~= Decl(rel, lineOf(src, cast(size_t) src.indexOf(mt.hit)),
                          mt[1].strip());
    }

    string[] rhss;
    foreach (d; decls) {
        bool seen = false;
        foreach (x; rhss) if (x == d.rhs) { seen = true; break; }
        if (!seen) rhss ~= d.rhs;
    }

    if (rhss.length > 1) {
        problems ~= "    · `alias " ~ kAliasName ~ "` names "
                  ~ rhss.length.to!string ~ " DIFFERENT types in this tree:";
        foreach (d; decls)
            problems ~= "        · " ~ d.file ~ ":" ~ d.line.to!string
                      ~ "  = " ~ d.rhs;
    }
    foreach (d; decls)
        if (d.rhs != kAliasType)
            problems ~= "    · " ~ d.file ~ ":" ~ d.line.to!string
                      ~ ": `alias " ~ kAliasName ~ " = " ~ d.rhs
                      ~ ";`, expected `" ~ kAliasType ~ "`";

    if (decls.length < 2)
        problems ~= "    · NON-VACUITY: found " ~ decls.length.to!string
                  ~ " declaration(s) of `alias " ~ kAliasName ~ "` across "
                  ~ filesRead.to!string ~ " file(s) of `source/`; two are "
                  ~ "expected. A zero means the reader or the walk returned "
                  ~ "nothing, and the agreement asserted above is the "
                  ~ "agreement of an empty set";
    if (filesRead < 200)
        problems ~= "    · NON-VACUITY: the walk of `source/` visited only "
                  ~ filesRead.to!string ~ " file(s). The tree moved or the "
                  ~ "walk is reading the wrong root";

    assert(problems.length == 0,
        "G8 census: `" ~ kAliasName ~ "` is one name for more than one type "
      ~ "again (task 1905, danger Б7).\n" ~ joinLines(problems) ~ "\n"
      ~ "  This is the shape the plan measured before phase B: two modules "
      ~ "spelled the alias `MeshSessionEdit delegate()` and two spelled it "
      ~ "`MeshVertexEdit delegate()`, so a tool that called its factory through "
      ~ "an un-named local kept COMPILING after a swap while recording a "
      ~ "different carrier. Nothing in the compiler prevents that; this line "
      ~ "is the only witness. Do not \"unify\" by editing one side to match the "
      ~ "other — decide which carrier the tool records and rename the alias "
      ~ "that is wrong.");
}

// ---------------------------------------------------------------------------
// 5. THE `setUndoBindings` RESIDUE IS ENUMERATED, NOT MERELY PERMITTED.
//
//    Phases B, C and D moved thirty-ONE of the thirty-three declarations onto
//    `Tool.setGestureBindings`. TWO survive, for one reason the plan states and
//    this roster repeats so that a third cannot be born green under somebody
//    else's note.
//
//    THE THIRD SURVIVOR LEFT ON 2026-08-29 (group G6), and the row that
//    described it was WRONG ON A LOAD-BEARING WORD, which is worth recording
//    because the word was what kept it. It called the four registrations that
//    reached `CommandWrapperTool` (xfrm.smooth, xfrm.jitter, xfrm.quantize,
//    edge.slide) "transform-zone registrations". They are not: the transform
//    zone is enumerated in §6 of the plan and `tools/common/command_wrapper.d`
//    is not in it, nor is it among the three sites §8 rejects with a reason
//    (`transform.d:501`, `transform.d:503`, `xfrm_transform.d:5666`). So the
//    twelve `setUndoBindings` call sites were never 4+4+4 transform-zone; they
//    were EIGHT transform-zone (four `XfrmTransformTool` + xfrm.push, xfrm.bend,
//    xfrm.linearAlignTool, xfrm.radialAlignTool) and FOUR command-wrapper. The
//    mislabel put a G6 file behind decision D1's out-of-scope wall, where
//    nothing was going to move it.
//
//    THE NEEDLE, because the anchored one is blind. The predicate card 3200
//    used, `^\s*(private|protected|public|package )?void setUndoBindings`,
//    attaches its space only to `package`, so after `public` it demands `void`
//    immediately and finds nothing; measured on this tree it reads ONE
//    declaration of the three, and all three survivors are written
//    `public void …` or `override public void …`. This member therefore uses
//    the RAW needle `void setUndoBindings` over comment- and string-stripped
//    text: it is blind to no modifier chain, and it cannot match a CALL site
//    (`t.setUndoBindings(` has no `void`). A separate lane owns repairing the
//    anchored predicate in the sibling census files; this file does not use it
//    and does not touch it.
// ---------------------------------------------------------------------------
private enum LedgerRow[] kBinderRoster = [
    // The EIGHT surviving transform-zone bindings split FOUR / FOUR across
    // these two declarations, and the split matters: it is why neither is idle.
    LedgerRow("TransformTool|binder", 1,
        "`TransformTool`'s own binder, reached by FOUR of the eight "
      ~ "transform-zone registrations (xfrm.push, xfrm.bend, "
      ~ "xfrm.linearAlignTool, xfrm.radialAlignTool). The transform zone is "
      ~ "OUT OF task 1905's scope by decision D1, and group G8 does NOT close "
      ~ "it: the app-level closures collapsing changes nothing about which "
      ~ "binder a transform tool DECLARES"),
    LedgerRow("XfrmTransformTool|binder", 1,
        "an `override` of the above, reached by the other FOUR "
      ~ "`XfrmTransformTool` registrations (move / rotate / scale / "
      ~ "xfrm.transform) and forwarding to its three composed sub-tools"),
];

unittest {
    LedgerHit[] hits;
    size_t total = 0, filesRead = 0;

    foreach (rel; sourceTree()) {
        auto src = stripCommentsAndStrings(readSource(rel));
        ++filesRead;
        const found = symbolTokenHits(src, rel, "void setUndoBindings", "binder");
        total += found.length;
        hits ~= found;
    }
    const problems = reconcile(kBinderRoster, hits);
    assert(problems.length == 0,
        "G8 census: the `setUndoBindings` residue changed.\n" ~ problems);
    assert(total == 2 && filesRead >= 400,
        "G8 census: expected exactly two binders over a non-empty source walk");
}

// ---------------------------------------------------------------------------
// 6. WHERE EVERY FACTORY IS SPENT, name by name.
//
//    The twenty-four MeshSessionEdit factories are STRUCTURALLY IDENTICAL
//    delegates. Passing one where another belongs compiles, and the only thing
//    that then differs is the wire name and the label in the history — i.e. the
//    edit is recorded under another tool's name and nothing anywhere says so.
//    The count per identifier is the cheapest witness that exists for that, and
//    it is the reason `bevelEditFactory`'s TWENTY-FOUR is written down rather
//    than described: the number is the plan's own claim about this group, and a
//    swap moves TWO rows at once, which is what the accumulator is for.
//
//    Whole-identifier matching, over comment- and string-stripped text: a
//    paragraph naming `bevelEditFactory` (there are twelve) must not count, and
//    `topoPenRemoveEditFactory` must not be found inside
//    `topoPenRemoveEdgeEditFactory`.
// ---------------------------------------------------------------------------
unittest {
    string[] problems;
    size_t total = 0;

    immutable regSrc = stripCommentsAndStrings(readSource("source/registration.d"));

    void check(string field, size_t want, string why) {
        auto hits = identHits(regSrc, field);
        total += hits.length;
        if (hits.length == want) return;
        string at;
        foreach (h; hits) at ~= h.to!string ~ " ";
        problems ~= "    · `" ~ field ~ "` is spent " ~ hits.length.to!string
                  ~ " time(s) in `source/registration.d`, roster says "
                  ~ want.to!string ~ "  (" ~ why ~ ")"
                  ~ (at.length ? "  [lines " ~ at.strip() ~ "]" : "");
    }

    foreach (r; kSessionRows) check(r.field, r.binds, r.why);
    foreach (r; kOtherRows)   check(r.field, r.binds, r.why);

    if (total < 60)
        problems ~= "    · NON-VACUITY: the scan of `source/registration.d` "
                  ~ "found " ~ total.to!string ~ " factory use(s) in total; "
                  ~ "sixty-eight is the rostered sum. A number near zero means "
                  ~ "the reader or the stripper returned nothing, so every "
                  ~ "per-name row above is a comparison against zero and would "
                  ~ "be reported for a reason it does not have";

    assert(problems.length == 0,
        "G8 census: a factory changed hands in `source/registration.d`.\n"
      ~ joinLines(problems) ~ "\n"
      ~ "  All twenty-four MeshSessionEdit factories have the SAME type, so "
      ~ "passing one where another belongs compiles and records the edit under "
      ~ "the other tool's wire name and label. Nothing on the wire, in the "
      ~ "stack depth or in a plane dump distinguishes the two; these counts "
      ~ "are the witness.");
}
