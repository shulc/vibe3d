// mesh_planes_census_test — L2 (the runtime name-prefix census) and the
// tree-scan gate (task 1902, `doc/reindex_primitive_plan.md` §3).
//
// L2 closes the blind spot L1 cannot: L1's two `static assert`s
// (`mesh_planes.d`) fire the instant `Mesh.tupleof.length` or its
// array-shaped subset moves, but they say only "look" — they name no field.
// L2 walks `Mesh.tupleof` at RUNTIME, selects every field whose identifier
// starts `face`/`vertex`/`vert` AND whose type has a `.length` (NOT
// `isDynamicArray` — that selector is blind to `FaceList`, which is exactly
// the wrapper-type case this whole task exists to handle: see
// `mesh_planes.d`'s header and `FaceList`'s own doc comment, "a CSR-backed
// equivalent" is coming), and asserts each selected name is classified —
// either a carried plane (`kFacePlanes`/`kVertPlanes`) or a documented
// exemption (`kExemptPlanes`). It reports BY NAME.
//
// The tree-scan gate is a SEPARATE concern living in this same file: it
// proves no hand-rolled `faces = …` / `vertices = …` rewrite can land in
// `source/mesh.d` / `source/mesh_ops/*.d` outside a named, reasoned
// allowlist. `source/mesh_edit_delta.d` is excluded from the scan root
// entirely (replay path, a distinct role — plan §6 Stage F).
module tests.unit.mesh_planes_census_test;

import mesh          : Mesh;
import mesh_planes    : kFacePlanes, kVertPlanes, kExemptPlanes;
import std.array      : appender, join;
import std.ascii      : isAlphaNum, isWhite;
import std.conv       : to;
import std.file       : dirEntries, readText, SpanMode, exists, isDir;
import std.format     : format;
import std.path       : buildPath, dirName, relativePath;
import std.string     : strip;
import std.traits     : FieldNameTuple;

// ===========================================================================
// L2 — the name-prefix census.
// ===========================================================================

private template hasElemPrefix(string name) {
    enum hasElemPrefix = (name.length >= 4 && name[0 .. 4] == "face")
                       || (name.length >= 6 && name[0 .. 6] == "vertex")
                       || (name.length >= 4 && name[0 .. 4] == "vert");
}

private bool inList(string name, const string[] arr) {
    foreach (a; arr) if (a == name) return true;
    return false;
}

// `kFacePlanes` / `kVertPlanes` / `kExemptPlanes` are D `enum`s (manifest
// constants) in `mesh_planes.d`: every USE SITE re-evaluates the
// initializer, so a bare reference INSIDE a loop rebuilds the array (or, for
// the AA, re-hashes the whole literal) on every single iteration. These
// `static immutable` copies are built exactly once and are what the in-loop
// lookups below read instead of the enum names directly.
private static immutable string[]       kFacePlanesOnce   = kFacePlanes;
private static immutable string[]       kVertPlanesOnce   = kVertPlanes;
private static immutable string[string] kExemptPlanesOnce = kExemptPlanes;

unittest // L2: every face/vertex-shaped Mesh field is a carried plane or a documented exemption
{
    // Selector: identifier starts face/vertex/vert AND `typeof(field).init`
    // has a `.length` — this is what makes the walk see `faces` (`FaceList`,
    // `alias this` to `uint[][]`) as well as a plain array; `isDynamicArray`
    // would silently skip both, the same blind spot L1's 34-only draft had
    // (plan §3 L1's revision history).
    string[] selected;
    static foreach (i, name; FieldNameTuple!Mesh) {
        static if (hasElemPrefix!name) {
            static if (is(typeof(typeof(Mesh.tupleof[i]).init.length))) {
                selected ~= name;
            }
        }
    }

    // Non-vacuity (mirrors tests/unit/mark_view_field_guard_test.d's
    // `filesScanned > 100`: "a walk that found no files would report a
    // clean tree"). Measured 2026-08-25: the true count is 16 — the floor is
    // 14, not 8, because a floor of 8 would let a selector that lost HALF
    // its yield (exactly what swapping `.length` for `isDynamicArray` does)
    // still pass. This is a non-vacuity guard, not a second census; L1's
    // `== 54` / `== 34` in mesh_planes.d is where the exactness lives.
    assert(selected.length >= 14,
           format("only %d face/vertex-shaped Mesh field(s) selected — the "
                ~ "walk is not reaching what it claims to guard (measured "
                ~ "2026-08-25: 16 today)", selected.length));

    // Named-membership pin, because the floor above does NOT pin the
    // selector itself. Swapping `is(typeof(typeof(f).init.length))` for
    // `isDynamicArray!(typeof(f))` drops exactly ONE field out of today's
    // 16 — `faces` (`FaceList`, not `isDynamicArray`) — leaving 15, which
    // still clears the >= 14 floor above invisibly. `faces` is therefore the
    // one name that must always survive the selector; assert it by name
    // rather than trusting a count that cannot see this exact loss.
    assert(inList("faces", selected),
           "the .length selector must see FaceList; an isDynamicArray "
         ~ "selector does not");

    string[] unclassified;
    foreach (name; selected) {
        if (inList(name, kFacePlanesOnce)) continue;
        if (inList(name, kVertPlanesOnce)) continue;
        if ((name in kExemptPlanesOnce) !is null) continue;
        unclassified ~= name;
    }
    assert(unclassified.length == 0,
           format("field(s) %s are per-face/per-vertex-shaped (name prefix "
                ~ "face/vertex/vert, type has .length) but appear in NEITHER "
                ~ "kFacePlanes/kVertPlanes NOR kExemptPlanes (all in "
                ~ "source/mesh_planes.d) — classify each: does rewriteFaces/"
                ~ "rewriteVertices need to carry it, or is it exempt (and "
                ~ "why)? If you just REMOVED this from kFacePlanes, that is "
                ~ "the mutation — do not exempt it.", unclassified));
}

// ---------------------------------------------------------------------------
// The O(n²) trap (plan §2.8): `mesh_planes.d`'s generated carry must read
// the raw `uint[]`/`int[]`/`ulong[]` planes directly and never ask a
// selection question — `selectedFaces`/`selectedVertices`/`isSubpatch` each
// materialise a fresh `bool[]` per call (memory `on2_traps_in_mesh`), which
// inside the primitive's per-face/per-vertex loop would turn one rewrite
// into O(planes × elements) allocations. The primitive's own header comment
// asserts these three names are structurally absent; this is what makes
// that assertion true rather than aspirational.
// ---------------------------------------------------------------------------

unittest // mesh_planes.d's own source text names none of the three allocating @property views
{
    immutable path = buildPath(repoRoot, "source", "mesh_planes.d");
    assert(exists(path), "cannot find source/mesh_planes.d at " ~ path);
    immutable src = readText(path);

    static immutable string[] forbidden =
        ["selectedFaces", "selectedVertices", "isSubpatch"];
    foreach (name; forbidden)
        assert(!hasSubstring(src, name),
               "source/mesh_planes.d names `" ~ name ~ "` — the primitive's "
             ~ "generated carry must read the raw per-face/per-vertex arrays "
             ~ "directly and never call an allocating @property view inside "
             ~ "its loop (memory on2_traps_in_mesh)");
}

private bool hasSubstring(string haystack, string needle) {
    import std.algorithm : canFind;
    return haystack.canFind(needle);
}

// ===========================================================================
// MeshOpEntry — the SECOND enumeration site (task 1902 Stage H, plan §7.3).
//
// `MeshOpEntry`'s `faceMat`/`facePrt`/`faceSub`/`faceSetMsk`/`faceOrd` group
// is a hand-maintained parallel-plane list, exactly like `kFacePlanes` — and
// until this task it was one short (no `faceOrd`, plan §7.3's own finding).
// L1's `static assert(Mesh.tupleof.length == 54, …)` fires when a new
// per-face FIELD lands on `Mesh`, but it names `mesh_planes.d`, never this
// struct — a plane added to `kFacePlanes` with no matching `MeshOpEntry`
// field is invisible to L1 and to L2 (L2 walks `Mesh.tupleof`, not
// `MeshOpEntry.tupleof`). This is that missing guard.
// ===========================================================================

/// `kFacePlanes` name -> `MeshOpEntry` field name (or `null` when the entry
/// deliberately carries something NARROWER, with the reason spelled out).
/// `faceMarks` has no direct counterpart: only its Subpatch BIT rides the
/// drop set, via `faceSub` — a pre-existing, documented limit of
/// `RemoveFaces`'s own reverse (Select/Hide are restored through their own
/// delta kinds, not this one; `FaceReindex` inherits the same limit rather
/// than inventing a new one, see its own Kind doc in mesh_edit_delta.d).
package enum string[string] kFacePlaneToEntryField = [
    "faceMarks":          "faceSub",
    "faceMaterial":       "faceMat",
    "facePart":           "facePrt",
    "faceSelectionOrder": "faceOrd",
    "faceSetMask":        "faceSetMsk",
];

unittest // L1/L2 for MeshOpEntry: every kFacePlanes name maps to a real MeshOpEntry field
{
    import mesh_edit_delta : MeshOpEntry;

    // Non-vacuity: the map itself must name every kFacePlanes entry — a plane
    // added to kFacePlanes with no corresponding line here is exactly the gap
    // this guard exists to close (§7.3 M-analogue: the mutation is "add a
    // plane, don't touch this file").
    foreach (name; kFacePlanesOnce)
        assert((name in kFacePlaneToEntryField) !is null,
               format("kFacePlanes entry `%s` has no corresponding line in "
                    ~ "kFacePlaneToEntryField (tests/unit/"
                    ~ "mesh_planes_census_test.d) — MeshOpEntry (source/"
                    ~ "mesh_edit_delta.d) is the SECOND enumeration site "
                    ~ "(plan §7.3): classify what, if anything, the op-log "
                    ~ "entry carries for this plane.", name));

    // Each mapped name must be a REAL field on MeshOpEntry — a typo or a
    // rename on either side reddens here, not silently.
    foreach (facePlane, entryField; kFacePlaneToEntryField) {
        bool found = false;
        static foreach (fieldName; FieldNameTuple!MeshOpEntry) {
            if (fieldName == entryField) found = true;
        }
        assert(found,
               format("kFacePlaneToEntryField[\"%s\"] = \"%s\", but "
                    ~ "MeshOpEntry (source/mesh_edit_delta.d) has no field "
                    ~ "of that name", facePlane, entryField));
    }

    // Symmetric direction: every per-face-shaped MeshOpEntry field used by
    // RemoveFaces/FaceReindex is named on the RIGHT side of the map above (or
    // is `faceOldOfNew`/`oldFaceCount`/`newFaceLists` — FaceReindex's own
    // correspondence/geometry payload, not a carried PLANE, so exempt by the
    // same reasoning kFacePlanes's own kExemptPlanes uses for `faces`).
    static immutable string[] kEntryPlaneExempt = [
        "faceOldOfNew", "oldFaceCount", "newFaceLists",
        // WINDING (geometry) payloads, not per-face PLANES — the same
        // distinction kFacePlanes's own kExemptPlanes draws for `faces`
        // itself ("the SUBJECT rewriteFaces assigns, not a plane it
        // carries"). AddFaces/RemoveFaces/FaceReindex's `faceLists` and
        // ReshapeFaces's `faceListsBefore`/`faceListsAfter` are all vertex-
        // index lists, never a per-face scalar/bitword/id.
        "faceLists", "faceListsBefore", "faceListsAfter",
        // Review finding B2 (task 1902 Stage H review): FaceReindex's own
        // captured PRE-rewrite winding for the subset of SURVIVORS whose
        // winding changed across the rewrite — same WINDING exemption as
        // `faceLists`/`newFaceLists` just above, not a kFacePlanes plane.
        "faceSurvivorIdx", "faceSurvivorLists",
    ];
    string[] mappedEntryFields;
    foreach (facePlane, entryField; kFacePlaneToEntryField) mappedEntryFields ~= entryField;
    static foreach (fieldName; FieldNameTuple!MeshOpEntry) {
        static if (fieldName.length >= 4 && fieldName[0 .. 4] == "face") {
            if (!inList(fieldName, mappedEntryFields) && !inList(fieldName, kEntryPlaneExempt))
                assert(false,
                       "MeshOpEntry field `" ~ fieldName ~ "` (source/"
                     ~ "mesh_edit_delta.d) is per-face-shaped by name but "
                     ~ "appears in NEITHER kFacePlaneToEntryField's value "
                     ~ "side NOR kEntryPlaneExempt (both in tests/unit/"
                     ~ "mesh_planes_census_test.d) — classify it: which "
                     ~ "kFacePlanes entry does it carry, or why is it exempt?");
        }
    }
}

// ===========================================================================
// The tree-scan gate.
//
// Reuses the comment/string/scope-nesting lexer shape from
// tests/unit/mark_view_field_guard_test.d (a REAL D lexer, not a fifth
// regex — the plan is explicit that this is the right thing to reuse). What
// differs is the target: instead of a stored `MarkView` field, this scans
// for an ASSIGNMENT to `faces` / `vertices` (optionally `.length`, optionally
// dotted through a receiver) inside a function BODY (Block scope), and it
// additionally excludes anything nested inside a `unittest { … }` block —
// ad hoc local-mesh construction in a test fixture is not the class of bug
// this gate exists to catch, and the plan's own short allowlist (five named
// factories plus `Mesh.clear`) only makes sense if fixture-only construction
// is excluded structurally rather than allowlisted one test at a time.
//
// WHAT THIS SCANNER DOES NOT SEE, stated so nobody mistakes it for the whole
// contract (same discipline as the MarkView guard's own header): a
// `version (cond) singleDeclaration { … }` head — the ONE-STATEMENT form,
// not a `version (cond) { … many decls … }` block — is classified by the
// reused `headInherits` rule as INHERITING the enclosing scope rather than
// opening its own Block, because that rule (correctly) treats a `version`
// head ending in `)` as a wrapper. For a single function declaration the
// trailing `)` belongs to the PARAMETER LIST, not to `version`'s own
// condition, so the function's body is misclassified and its content is
// invisible to this scan. Measured effect: `mesh_ops/loop_slice.d`'s
// `version (unittest) private Mesh buildRawMesh(...)` is invisible to this
// scanner for that reason — which happens to be the right OUTCOME (it is a
// fixture-only fresh-mesh builder, same class as the named factories) but
// for the wrong MECHANICAL reason, and a future production kernel written in
// that exact single-statement `version` shape would escape the gate too.
// Fixing the classifier is a review matter for whoever next touches this
// file, not attempted here.
// ===========================================================================

struct Violation { string file; size_t line; string text; }

private enum Scope { Module, Aggregate, Block }
private bool isIdentChar(char c) { return isAlphaNum(c) || c == '_'; }

private bool headOpensAggregate(string head) {
    static immutable string[] kw = ["struct", "class", "union", "interface", "template"];
    foreach (k; kw) {
        for (size_t i = 0; i + k.length <= head.length; i++) {
            if (head[i .. i + k.length] != k) continue;
            if (i > 0 && isIdentChar(head[i - 1])) continue;
            size_t j = i + k.length;
            if (j < head.length && isIdentChar(head[j])) continue;
            while (j < head.length && isWhite(head[j])) j++;
            if (j < head.length && (isAlphaNum(head[j]) || head[j] == '_')) return true;
        }
    }
    return false;
}

private bool headInherits(string head) {
    auto h = head.strip;
    if (h.length == 0) return true;
    static immutable string[] starts = ["version", "static if", "static foreach",
                                        "else", "debug", "extern", "align",
                                        "private", "public", "protected",
                                        "package", "synchronized", "@", "nothrow",
                                        "pure", "final", "shared static",
                                        "static ~", "static this", "immutable",
                                        "const", "scope"];
    foreach (s; starts)
        if (h.length >= s.length && h[0 .. s.length] == s) {
            if (s == "static this" || s == "static ~") return false;
            if (h[$ - 1] == ')' && s != "version" && s != "static if"
                && s != "static foreach" && s != "extern" && s != "align"
                && s != "debug" && s != "synchronized")
                return false;
            return true;
        }
    return false;
}

/// Does a `swap(...)` argument list name the `faces` or `vertices` plane?
/// Whole-word, so `facesCount` / `vertexCount` do not match, and a dotted
/// receiver (`swap(m.faces, tmp)`) does because the test is on the identifier,
/// not on the whole argument.
///
/// WHY WHOLE-WORD CONTAINMENT AND NOT A PARSE: the two `swap(` calls under the
/// scanned tree today are `swap(v.x, v.y)` / `swap(v.y, v.z)`
/// (`mesh_ops/box_geom.d`), neither of which names a plane — so this test adds
/// no violation to correct code, which is the property that had to be measured
/// before widening the scanner at all.
private bool swapArgsNamePlane(string args) {
    static immutable string[] kPlanes = ["faces", "vertices"];
    foreach (pl; kPlanes) {
        if (args.length < pl.length) continue;
        foreach (i; 0 .. args.length - pl.length + 1) {
            if (args[i .. i + pl.length] != pl) continue;
            if (i > 0 && isIdentChar(args[i - 1])) continue;
            if (i + pl.length < args.length && isIdentChar(args[i + pl.length])) continue;
            return true;
        }
    }
    return false;
}

/// THE FORM THIS SCANNER DELIBERATELY DOES NOT MATCH, and the measurement
/// behind that decision (task 2007 finding #4, second half). The finding also
/// named the index-loop rebuild — `foreach (i, nf; newFaces) faces[i] = nf;` —
/// as a way to replace the whole array with no `faces =` token, and asked for
/// a separate decision.
///
/// DECIDED: NOT SCANNED. An indexed write is not a rewrite; it is the ordinary
/// spelling of a single in-place correction, and `source/mesh.d` +
/// `source/mesh_ops/*.d` contain 35 of them (22 + 13, counted 2026-08-28).
/// A trigger on `faces[<expr>] =` would therefore report 35 findings on code
/// that is correct today, and nothing textual separates "one in-place fix" from
/// "a loop that rebuilds the array" — the loop bound is a runtime value. A
/// census that reddens on correct code is the same defect as one that cannot
/// redden, so the honest move is to say so here rather than ship the false
/// positives. `swap` and `[]=` are scanned precisely because they carry the
/// whole-array meaning IN THE SYNTAX.
private enum kIndexLoopFormNotScanned = true;

/// Scan one D source text for a hand-rolled assignment to `faces` /
/// `vertices` (optionally `.length`, optionally through a dotted receiver)
/// at method (Block) scope, excluding anything inside a `unittest { }` body.
/// `file` is carried through into each `Violation` purely for reporting.
Violation[] scanForHandRolledRewrites(string file, string src) {
    auto out_ = appender!(Violation[]);
    Scope[] stack;
    bool[]  unitStack;      // parallel to `stack`: is this frame (or an ancestor) a unittest body?
    string  head;
    size_t  line = 1;
    int     paren = 0;

    Scope cur()   { return stack.length ? stack[$ - 1] : Scope.Module; }
    bool  inUnit(){ return unitStack.length ? unitStack[$ - 1] : false; }

    size_t i = 0;
    while (i < src.length) {
        immutable char c = src[i];

        // ---- skip comments and literals (their content is not code) ----
        if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
            while (i < src.length && src[i] != '\n') i++;
            continue;
        }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
                if (src[i] == '\n') line++;
                i++;
            }
            i += 2;
            continue;
        }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '+') {
            int depth = 1; i += 2;
            while (i + 1 < src.length && depth > 0) {
                if (src[i] == '/' && src[i + 1] == '+') { depth++; i += 2; continue; }
                if (src[i] == '+' && src[i + 1] == '/') { depth--; i += 2; continue; }
                if (src[i] == '\n') line++;
                i++;
            }
            continue;
        }
        if (c == '"' || c == '`' || c == '\'') {
            immutable char q = c;
            immutable bool raw = (q == '`');
            i++;
            while (i < src.length && src[i] != q) {
                if (!raw && src[i] == '\\') i++;
                if (i < src.length && src[i] == '\n') line++;
                i++;
            }
            i++;
            continue;
        }

        if (c == '\n') { line++; head ~= ' '; i++; continue; }
        if (c == '(')  { paren++; head ~= c; i++; continue; }
        if (c == ')')  { if (paren > 0) paren--; head ~= c; i++; continue; }

        if (c == '{') {
            immutable bool isUnitHead = (head.strip == "unittest");
            Scope k;
            if (headOpensAggregate(head))  k = Scope.Aggregate;
            else if (headInherits(head))   k = cur();
            else                            k = Scope.Block;
            stack     ~= k;
            unitStack ~= (inUnit() || isUnitHead);
            head = "";
            i++;
            continue;
        }
        if (c == '}') {
            if (stack.length)     stack     = stack[0 .. $ - 1];
            if (unitStack.length) unitStack = unitStack[0 .. $ - 1];
            head = "";
            i++;
            continue;
        }
        if (c == ';') { head = ""; i++; continue; }

        // ---- identifiers ----
        if (isAlphaNum(c) || c == '_') {
            size_t j = i;
            while (j < src.length && isIdentChar(src[j])) j++;
            immutable string word = src[i .. j];
            immutable bool boundary = (i == 0 || !isIdentChar(src[i - 1]));

            // TASK 2007 FINDINGS #4 AND (second pass) `[]=`: the SAME
            // whole-array replacement, spelled so that no `faces =` token
            // exists. `swap(faces, tmp)` puts the identifier INSIDE a paren, so
            // the `paren == 0` trigger below never sees it; the finding built
            // it and showed the scan green. Handled here, before that trigger,
            // because it is a different syntactic shape and not a variant of
            // one. See `swapArgsNamePlane` for the argument test.
            if (boundary && paren == 0 && cur() == Scope.Block && !inUnit()
                && word == "swap") {
                size_t k = j;
                while (k < src.length && isWhite(src[k])) k++;
                if (k < src.length && src[k] == '(') {
                    size_t e = k + 1;
                    int d = 1;
                    while (e < src.length && d > 0) {
                        if (src[e] == '(') d++;
                        else if (src[e] == ')') d--;
                        e++;
                    }
                    if (d == 0 && swapArgsNamePlane(src[k + 1 .. e - 1]))
                        out_ ~= Violation(file, line, lineTextAt(src, i));
                }
            }

            if (boundary && paren == 0 && cur() == Scope.Block && !inUnit()
                && (word == "faces" || word == "vertices")) {
                // Reject a DECLARATION (`immutable long faces = …;`): the
                // char immediately before this identifier (skipping
                // whitespace, via the comment/string-clean `head` buffer,
                // never raw `src`) must NOT be an identifier char — that
                // would mean `faces`/`vertices` is itself a NAME following a
                // TYPE, not an assignment target. A dotted receiver (`m.` /
                // `mesh.` / anything ending in `.`) or a true statement
                // start (empty `head`, or `head` ending in punctuation like
                // `)`/`;`-boundary) both pass.
                auto ht = head.strip;
                immutable bool prefixOk = (ht.length == 0) || !isIdentChar(ht[$ - 1]);
                if (prefixOk) {
                    size_t k = j;
                    void ws() { while (k < src.length && isWhite(src[k])) k++; }
                    ws();
                    if (k + 7 <= src.length && src[k .. k + 7] == ".length"
                        && !(k + 7 < src.length && isIdentChar(src[k + 7]))) {
                        k += 7;
                        ws();
                    }
                    // TASK 2007, second pass: `vertices[] = src[];`, the
                    // BYTE-WISE content assignment. The character after the
                    // identifier is `[`, so the bare-`=` test below never
                    // reaches its operator and the form scanned as ZERO — with
                    // one occurrence ALREADY in production
                    // (`Mesh.adoptVertexPositions`, which now carries its own
                    // reasoned kAllow entry). Consuming the empty `[]` here
                    // lets the same `=` test judge it.
                    else if (k + 1 < src.length && src[k] == '[') {
                        size_t b = k + 1;
                        while (b < src.length && isWhite(src[b])) b++;
                        if (b < src.length && src[b] == ']') { k = b + 1; ws(); }
                    }
                    // UFCS spelling of finding #4: `faces.swap(tmp)`.
                    if (k + 5 <= src.length && src[k .. k + 5] == ".swap"
                        && !(k + 5 < src.length && isIdentChar(src[k + 5]))) {
                        out_ ~= Violation(file, line, lineTextAt(src, i));
                    }
                    // A bare `=`, not `==` and not a compound op (those have
                    // a non-whitespace operator char between the identifier
                    // and `=`, which the whitespace-only skip above already
                    // refuses to cross).
                    if (k < src.length && src[k] == '='
                        && !(k + 1 < src.length && src[k + 1] == '=')) {
                        out_ ~= Violation(file, line, lineTextAt(src, i));
                    }
                }
            }

            head ~= word;
            i = j;
            continue;
        }

        head ~= c;
        i++;
    }
    return out_.data;
}

private string lineTextAt(string src, size_t p) {
    size_t a = p;
    while (a > 0 && src[a - 1] != '\n') a--;
    size_t b = p;
    while (b < src.length && src[b] != '\n') b++;
    return src[a .. b].strip;
}

// ---------------------------------------------------------------------------
// Scanner self-tests — it is not allowed to be inert either (plan §3 "The
// tree-scan gate", "its own mutation, run FIRST"; memory
// `pattern_blast_radius_and_phasing`: "a scanner whose regex matches
// nothing returns 0 and survives a deliberate-break check").
// ---------------------------------------------------------------------------

private size_t nFound(string src) { return scanForHandRolledRewrites("x.d", src).length; }

unittest // §8 mutation M5: the scanner's own non-vacuity — it must find the ONE hand-rolled rewrite it is shown
{
    assert(nFound("void f() { faces = newFaces; }") == 1,
           "expected exactly 1 hand-rolled rewrite in the synthetic sample, "
         ~ "found " ~ nFound("void f() { faces = newFaces; }").to!string
         ~ " — the scanner is inert");
}

unittest // legal shapes the scanner must NOT flag
{
    assert(nFound("struct S { uint[][] faces; }") == 0,
           "a field DECLARATION (Aggregate scope, no assignment) must not match");
    assert(nFound("void f() { immutable long faces = 5; }") == 0,
           "`long faces = …` is a LOCAL VARIABLE declaration, not an "
         ~ "assignment to Mesh.faces — the false positive the task card's "
         ~ "own naive grep hit at the `projectedLimitFaces` caller in mesh.d");
    assert(nFound("void f() { if (faces == vertices) {} }") == 0,
           "a COMPARISON must not match");
    assert(nFound("void f() { faces ~= x; }") == 0,
           "an APPEND (`~=`) is not a full-array rewrite and must not match");
    assert(nFound("void f() { auto n = faces.length == 3; }") == 0,
           "`.length == …` is a comparison, not an assignment");
    assert(nFound("void f() { foreach (x; faces) {} }") == 0,
           "reading `faces` (loop subject) must not match");
    assert(nFound("// faces = newFaces;") == 0, "a line comment must not match");
    assert(nFound("/* faces = newFaces; */") == 0, "a block comment must not match");
    assert(nFound(`enum s = "faces = newFaces;";`) == 0, "a string literal must not match");
    assert(nFound("unittest { faces = newFaces; }") == 0,
           "content inside a unittest{} body must not match — fixture-only "
         ~ "local-mesh construction is not the bug class this gate guards");
    assert(nFound("unittest { if (true) { faces = newFaces; } } ") == 0,
           "a NESTED block inside unittest{} must still be excluded");
}

unittest // shapes the scanner MUST flag
{
    assert(nFound("void f() { m.faces = newFaces; }") == 1,
           "a dotted receiver (`m.faces = …`) must match");
    assert(nFound("void f() { if (x) faces = newFaces; }") == 1,
           "a bare assignment as the body of an `if` (no braces) must match");
    assert(nFound("void f() { faces.length = 0; }") == 1,
           "a `.length =` TRUNCATION must match — it is the class task 0921 "
         ~ "found the OTHER real gap in (front- vs tail-truncated survivors)");
    assert(nFound("void f() { vertices = newVerts; }") == 1,
           "`vertices`, not only `faces`, must match");
}

unittest // TASK 2007 FINDING #4 and its second-pass sibling: the two WHOLE-ARRAY
         // spellings that carry no `faces =` token. Both were built by the
         // finding and both scanned as ZERO; revert either arm of
         // `scanForHandRolledRewrites` and the matching assert here reddens.
{
    assert(nFound("void f() { swap(faces, tmp); }") == 1,
           "`swap(faces, tmp)` replaces the whole array and must match — the "
         ~ "identifier sits INSIDE a paren, which is exactly why the "
         ~ "`paren == 0` trigger alone could not see it (task 2007 #4)");
    assert(nFound("void f() { swap(m.vertices, tmp); }") == 1,
           "a dotted receiver inside swap must match too");
    assert(nFound("void f() { std.algorithm.mutation.swap(tmp, faces); }") == 1,
           "the plane may be the SECOND argument, and the call may be "
         ~ "fully qualified");
    assert(nFound("void f() { faces.swap(tmp); }") == 1,
           "the UFCS spelling of the same call must match");

    assert(nFound("void f() { vertices[] = src[]; }") == 1,
           "`vertices[] = src[];` is a byte-wise content assignment of the "
         ~ "whole array — this exact line is in production "
         ~ "(Mesh.adoptVertexPositions) and rode a fully green census until "
         ~ "task 2007's second pass");
    assert(nFound("void f() { m.faces[] = other[]; }") == 1,
           "…and with a dotted receiver");
}

unittest // …and the shapes the two new arms must NOT flag, because a census that
         // reddens on correct code is the same defect as one that cannot redden
{
    assert(nFound("void f() { swap(v.x, v.y); }") == 0,
           "the two `swap(` calls under the scanned tree today are exactly "
         ~ "this shape (mesh_ops/box_geom.d) — they name no plane and must "
         ~ "stay silent");
    assert(nFound("void f() { swap(facesCount, n); }") == 0,
           "`facesCount` merely CONTAINS `faces` — whole-word or nothing");
    assert(nFound("void f() { swap(a, b); }") == 0,
           "an unrelated swap must not match");
    assert(nFound("void f() { foreach (i, nf; newFaces) faces[i] = nf; }") == 0,
           "THE DECIDED EXCLUSION (see `kIndexLoopFormNotScanned`): an "
         ~ "INDEXED write is the ordinary spelling of a single in-place "
         ~ "correction and occurs 35 times in the scanned tree today, so "
         ~ "matching it would report 35 findings on correct code");
    assert(nFound("void f() { auto n = faces[i] == x; }") == 0,
           "an indexed COMPARISON must not match either");
    assert(nFound("void f() { auto n = vertices[]; }") == 0,
           "a whole-slice READ is not an assignment");
}

// ---------------------------------------------------------------------------
// The allowlist (Готово item 2 / plan §10: "an allowlist that is a diff
// line"). One entry per DISTINCT (file, exact matched line text) pair
// currently in the tree — derived directly from this scanner's own output
// against the current HEAD, not retyped by hand. As each family migrates
// onto `mesh_planes.rewriteFaces`/`rewriteVertices` (plan §6 Stages B–F),
// its hand-rolled line disappears from the source text, the scanner stops
// reporting it, and the corresponding entry below becomes DEAD — remove it
// in the SAME commit, so this list is always exactly what the tree still
// needs.
// ---------------------------------------------------------------------------

// `count`: the number of DISTINCT hits (file, line) this (file, text) key
// is expected to match TODAY. A membership check alone (just `file`+`text`)
// cannot see two failure modes the count closes (task 1902 review finding
// B1): (a) a NEW copy-pasted line landing next to an already-allowed one —
// `"faces              = newFaces;"` in `source/mesh.d` is exact-text-
// identical across FOUR distinct production sites
// (`applyVertexRemapAndRebuild`, `applyVertexRemap`, `dissolveVerticesByMask`,
// `triangulateFacesByMask`), so membership alone stays satisfied whether one
// of those sites exists or five do; (b) an entry going DEAD once its site
// migrates off the allowlist (plan §6) — membership has nothing left to miss
// once the text is gone from one of several sites sharing it, so the count
// dropping below its recorded value is the only signal. Measured 2026-08-25
// via a standalone scan (`scratch/count_allow.d` in this task's lane
// scratch): every count below is the exact current hit count for its
// (file, text) key.
private struct AllowEntry { string file; string text; string reason; size_t count; }

private immutable AllowEntry[] kAllow = [
    // --- source/mesh.d: production face/vertex-rewrite sites (Stage B/vertex family) ---
    // Stage B (task 1902) migrated sites 1/2/3/4/5/6/7 onto
    // mesh_planes.rewriteFaces — their hand-rolled `faces = newFaces;` /
    // `faces              = keptFaces;` lines are gone from the source text,
    // so both former entries here are DEAD and removed in this same commit,
    // per this file's own header comment ("its hand-rolled line disappears
    // from the source text ... the corresponding entry below becomes DEAD —
    // remove it in the SAME commit"). Site 8 (mirrorFacesPlane) is a RESTORE,
    // not a reindex — see its own kAllow entries and the doc comment at its
    // call site (mesh.d) for why it stays hand-rolled.
    AllowEntry("source/mesh.d", "vertices = newVerts;",
        "vertex-rewrite site: compactUnreferenced", 1),
    AllowEntry("source/mesh.d", "vertices             = rbVertices;",
        "vertex-rewrite site: mirrorFacesPlane rollback", 1),
    AllowEntry("source/mesh.d", "faces                = rbFaces;",
        "site 8: mirrorFacesPlane (0678 §4 verified-clean list — pure substitution only)", 1),

    // --- source/mesh.d: permanent exemptions (never migrate) ---
    AllowEntry("source/mesh.d", "vertices = []; edges = []; faces = [];",
        "Mesh.clear() — whole-mesh reset, nothing to carry. count=2: the "
      ~ "scanner emits ONE violation per matched identifier (`faces` AND "
      ~ "`vertices` both match on this single line), not one per line", 2),
    // MOVED FILE, NOT MOVED CODE (task 3240, plan 2910 step 3): the
    // edge-slice family left `struct Mesh` for `source/mesh_edge_slice.d`,
    // so this rollback's file and its receiver spelling both changed while
    // the site itself is byte-identical. It is retargeted rather than
    // deleted, and the scan root below GREW to include the new file in the
    // same commit — deleting the entry would have turned this census green
    // by removing the code from its field of view, which is the failure
    // shape CLAUDE.md names first.
    AllowEntry("source/mesh_edge_slice.d", "m.vertices.length = vertsBeforePass1;",
        "edgeSliceEx TRUE no-op rollback — restores the exact PRE-Pass-1 "
      ~ "vertex count, not a renumbering (`.length =` truncation class, "
      ~ "plan §6 Stage F's sibling: nothing to carry, nothing moved)", 1),
    AllowEntry("source/mesh.d", "m.vertices = [",
        "fresh-mesh factories: makeCube / makeDiamond / makeOctahedron / makeLShape", 4),
    AllowEntry("source/mesh.d", "m.vertices.length = cast(size_t)side * side;",
        "fresh-mesh factory: makeGridPlane", 1),
    AllowEntry("source/mesh.d", "m.vertices = preview.vertices.dup;",
        "subdivide builder: subdivideCube (re-adds OsdAccel's preview into a fresh Mesh)", 1),
    AllowEntry("source/mesh.d", "result.vertices.length = outVCount;",
        "subdivide builder: facetedSubdivide — `result` is a FRESH local Mesh", 1),
    AllowEntry("source/mesh.d", "sub.vertices = cur;",
        "subdivide builder: smoothSubdivide — `sub` is a working-copy local Mesh", 1),

    // --- source/mesh_ops/*.d: production sites ---
    // Stage E (task 1902) migrated sites 10/11/12/13/19 onto
    // mesh_planes.rewriteFaces — their hand-rolled `faces = newFaces;` /
    // `faces = mergedFaces;` lines are gone from the source text, so all
    // five former entries here are DEAD and removed in this same commit,
    // per this file's own header comment. `poly_bevel.d` was never in this
    // list: measured (plan §6 Stage E), it has no `faces = …` rewrite site
    // at all (append-only) — the card's family list overstated it.
    // TASK 1903 Stage G RE-SPELLED THIS ENTRY'S TEXT, and nothing else about
    // it. `bevelEdgesByMask` became a free function over `ref MeshEditBatch`,
    // so the two rollback lines read `ed.vertices.length = …` where they read
    // `vertices.length = …` from inside the mixin body. The exemption's REASON
    // is unchanged — it restores a saved COUNT, not a renumbering — and so is
    // the count. (This entry is why a conversion stage must re-read the
    // censuses in OTHER files that quote its text: `dub build` is green over a
    // stale allowlist and only `dub test --config=tests` says otherwise.)
    AllowEntry("source/mesh_ops/edge_bevel.d",
        "ed.vertices.length = savedVertCount; // undo any addVertex from the per-vertex pass",
        "bevelEdgesByMask early-return rollback (both call sites) — restores "
      ~ "a saved count, not a renumbering", 2),
    AllowEntry("source/mesh_ops/loop_slice.d", "m.vertices = [",
        "fresh-mesh test helper: makeTwoDisjointCubes (fixture-only, not version(unittest)-gated)", 1),

    // TASK 2007, second pass. `vertices[] = src[];` is a BYTE-WISE content
    // assignment, and until this commit the scanner could not see the form at
    // all (the char after the identifier is `[`, so the bare-`=` test never
    // reached its operator) — the finding's own point was that this occurrence
    // was ALREADY in production and riding through a fully green census.
    //
    // JUDGED SAFE, and the argument is the method's own, not an assumption:
    // `adoptVertexPositions` refuses on a length mismatch, so it can only
    // overwrite positions IN PLACE — no vertex is added, removed or renumbered,
    // and there is nothing for `rewriteVertices` to carry. It publishes
    // `MeshEditScope.Position` deliberately (NOT Geometry) so `topologyVersion`
    // does not move, which is the whole reason the method exists (task 1620:
    // the subpatch preview keys its index space on that counter). Its own doc
    // comment already states the tracker decision — "No tracker hook, matching
    // the other `commitChange(Position)` sites" — so this entry records a
    // decision that was argued at the site, rather than granting a new one.
    AllowEntry("source/mesh.d", "vertices[] = src[];",
        "Mesh.adoptVertexPositions — in-place, length-checked POSITION "
      ~ "overwrite; no vertex is added, removed or renumbered, so there is no "
      ~ "plane to carry and rewriteVertices has nothing to do", 1),
];

private bool allowed(string file, string text) {
    foreach (a; kAllow)
        if (a.file == file && a.text == text) return true;
    return false;
}

private string allowKey(string file, string text) { return file ~ "\x01" ~ text; }

// ---------------------------------------------------------------------------
// Its own mutation, run FIRST (plan §3 "The tree-scan gate", verbatim):
// "point the scanner at a synthetic string containing one hand-rolled
// `faces = newFaces;` and assert it finds exactly one" — already exercised
// above as §8's M5 unittest. The gate below is the real scan.
// ---------------------------------------------------------------------------

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest // the gate: every hand-rolled faces/vertices rewrite in mesh.d + mesh_ops/*.d is in kAllow
{
    string[] targets = [buildPath(repoRoot, "source", "mesh.d")];
    immutable opsDir = buildPath(repoRoot, "source", "mesh_ops");
    assert(exists(opsDir) && isDir(opsDir),
           "the gate cannot find source/mesh_ops/ at " ~ opsDir);

    // THE SATELLITES THAT GREW OUT OF `struct Mesh` ARE SCANNED TOO
    // (task 3240). Plan 2910 is moving families out of the struct into
    // `source/mesh_*.d` one step at a time, and a site that leaves mesh.d
    // for such a file would otherwise leave this census's field of view
    // silently — the entry would redden as "DEAD" and the honest-looking
    // fix (delete it) would be the vacuous one. Each future step must add
    // its own file here in the same commit that moves the code.
    // `mesh_visibility.d` (step 2) carries zero hits today and is listed so
    // the rule is the list, not the hits.
    foreach (sat; ["mesh_visibility.d", "mesh_edge_slice.d"]) {
        immutable satPath = buildPath(repoRoot, "source", sat);
        assert(exists(satPath),
               "the gate cannot find the struct-Mesh satellite " ~ satPath
             ~ " — if plan 2910's step that created it was reverted, remove "
             ~ "it from this list in the same change");
        targets ~= satPath;
    }

    size_t filesScanned = 3;   // mesh.d + the two satellites, counted above
    foreach (entry; dirEntries(opsDir, SpanMode.shallow)) {
        if (!entry.isFile || entry.name.length < 2
            || entry.name[$ - 2 .. $] != ".d") continue;
        targets ~= entry.name;
        filesScanned++;
    }
    assert(filesScanned >= 10,
           format("only %d file(s) scanned — the walk is not reaching the "
                ~ "tree it claims to guard (source/mesh_ops/ has 15 files "
                ~ "as of this writing)", filesScanned));

    Violation[] hits;
    foreach (f; targets)
        hits ~= scanForHandRolledRewrites(relativePath(f, repoRoot), readText(f));

    // Non-vacuity on the RAW hit count, before allowlist filtering: proves
    // the scan is actually finding real code, not silently matching
    // nothing. Set well below the 34 measured 2026-08-25 (not equal to it —
    // that count SHRINKS by design as Stages B-F migrate sites off the
    // allowlist, and this floor must stay true after every one of them).
    assert(hits.length >= 10,
           format("only %d raw hit(s) found across %d file(s) — the scanner "
                ~ "may have regressed to matching nothing (see §8 mutation "
                ~ "M5's synthetic-sample check above for the unit-level "
                ~ "version of this same guard)", hits.length, filesScanned));

    string[] unlisted;
    foreach (v; hits)
        if (!allowed(v.file, v.text))
            unlisted ~= format("%s:%d  %s", v.file, v.line, v.text);

    assert(unlisted.length == 0,
           "a hand-rolled `faces`/`vertices` rewrite was found OUTSIDE "
         ~ "mesh_planes.rewriteFaces/rewriteVertices and outside the "
         ~ "allowlist (kAllow) in this file — route it through the "
         ~ "primitive, or add a reasoned allowlist entry if it is a "
         ~ "genuine exemption (Mesh.clear, a fresh-mesh factory, a pure "
         ~ "rollback):\n  " ~ unlisted.join("\n  "));

    // Per-entry hit-count EQUALITY (task 1902 review finding B1). Membership
    // alone (`allowed()` above) cannot count: `kAllow`'s
    // `"faces              = newFaces;"` entry in `source/mesh.d` is
    // exact-text-identical across FOUR distinct sites, so a membership check
    // stays satisfied whether all four still exist, a fifth (copy-pasted)
    // one landed, or one of the four migrated away and only three remain.
    // Counting closes both directions: a NEW copy-pasted line pushes an
    // entry's actual count ABOVE its recorded `count` (redden — route it
    // through the primitive or give it its own reasoned entry); a site that
    // migrated off the allowlist (plan §6 Stages B–F) pushes it BELOW
    // (redden — the entry is now DEAD, remove it in the same commit).
    size_t[string] actual;
    foreach (v; hits) {
        immutable string k = allowKey(v.file, v.text);
        actual[k] = (k in actual ? actual[k] : 0) + 1;
    }
    foreach (a; kAllow) {
        immutable string k = allowKey(a.file, a.text);
        immutable size_t got = (k in actual) ? actual[k] : 0;
        assert(got == a.count,
               format("kAllow entry %s %s (%s): expected %d hand-rolled "
                    ~ "hit(s), found %d. got > count means a NEW "
                    ~ "copy-pasted line landed next to this allowed one — "
                    ~ "route it through mesh_planes.rewriteFaces/"
                    ~ "rewriteVertices, or give it its OWN reasoned kAllow "
                    ~ "entry if it is a genuine exemption. got < count "
                    ~ "means a site this entry named has migrated off the "
                    ~ "allowlist — this entry is now DEAD; remove it (or "
                    ~ "shrink its count and its reason) in the SAME commit.",
                      a.file, a.text, a.reason, a.count, got));
    }
}
