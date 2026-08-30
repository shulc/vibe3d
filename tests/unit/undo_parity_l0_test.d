// undo_parity_l0_test — the FROZEN parity fixture for stage L0's families
// (position / marks / material), and the reader that makes it an oracle.
//
// WHY THIS FILE EXISTS AT ALL, stated first because it is the whole point.
// Plan §6.3 requires each family to freeze its delta↔dense parity ONCE, as
// JSON, produced by the code that is about to be replaced — "measure once →
// freeze → the fixture is the regression from then on". L0 shipped with that
// item unmet: `tests/fixtures/undo_parity/position_marks.json` was named in its
// Definition of Done and never produced. L0 deleted no snapshot, so the window
// had not closed — but stage L1 deletes 27 of them, and a family that deletes
// its dense path destroys its own live oracle. This file closes L0's window
// before L1 opens.
//
// WHAT THE FIXTURE IS. For each cell: `reset → stand → op → undo`, dumping
// `http_json.meshPlanesJson` after the OP and again after the UNDO. Frozen at
// `a8cdb05d` — the last commit before `27da64c2` (L0-d: the nine position
// commands moved to `Kind.SetPos`) and `042ab1f9` (L0-b: transform/symmetrize).
// That SHA and not HEAD, and not "whatever is checked out": a fixture captured
// after the migration records the migrated behaviour and can then only prove
// the migration agrees with itself. `git merge-base --is-ancestor a8cdb05d
// <head>` is the reviewer's check; the field is `provenance.producedBy`.
//
// THE TWO DUMPS ARE NOT DECORATION. A fixture holding only the post-undo state
// is compared against a stand that the op is supposed to have left unchanged —
// so a cell whose forward silently stopped doing anything is GREEN, and so is
// a cell whose op and undo are both broken in the same direction. Freezing the
// POST-OP dump too makes the forward part of the record, and the reader's
// per-cell `postOp != postUndo` assert is the anti-vacuity guard that a
// no-longer-moving command cannot satisfy.
//
// WHAT `path` MEANS HERE, and why the two-valued vocabulary was not enough.
// `PlaneDumpMeta.path` was declared as "snapshot" | "delta". Measured at
// `a8cdb05d`: of L0's sixteen commands only `mesh.hide*` and
// `mesh.centerVertices` held a `MeshSnapshot` at all. The other fourteen
// restored from a per-command stored image — `origPos[]`, `origMaterial[]`,
// `origSubpatch[]` — replayed by their own `revert()`. That is neither a
// whole-mesh snapshot nor a delta replay, and writing "snapshot" over it would
// be a false provenance record in the one field a reviewer reads to decide
// whether the fixture predates the code. So the vocabulary gained a THIRD
// value, `"dense-inline"`, and `path` is recorded PER CELL rather than per
// file — a family is not on one path, and this one demonstrably was not.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.undo_parity_l0_test;

import std.format : format;
import std.json   : JSONValue, JSONType, parseJSON;

import command;
import mesh;
import view;
import editmode;
import math      : Vec3;
import http_json : meshPlanesJson, PlaneDumpMeta;

import tests.unit.fixtures : makeTaggedGridFull;

// ===========================================================================
// The shared plumbing. PUBLIC because `undo_parity_l1_test` reuses it, and
// because at the capture SHA this module is the only one of the pair present.
// ===========================================================================

/// One frozen cell: a command, the undo path it was on when the dump was
/// taken, and the two dumps.
struct ParityCell {
    string name;
    string path;      // "snapshot" | "dense-inline" | "delta"
    string postOp;
    string postUndo;
}

/// Set a param by name. Asserts rather than refuses: a renamed param must stop
/// the capture, not silently leave the command at its default and freeze a
/// dump of an operation nobody performed.
void setS(Command c, string n, string v) {
    foreach (ref p; c.params()) if (p.name == n) { *p.sptr = v; return; }
    assert(false, "no string/enum param `" ~ n ~ "` on " ~ c.name());
}
/// ditto
void setI(Command c, string n, int v) {
    foreach (ref p; c.params()) if (p.name == n) { *p.iptr = v; return; }
    assert(false, "no int param `" ~ n ~ "` on " ~ c.name());
}
/// ditto
void setF(Command c, string n, float v) {
    foreach (ref p; c.params()) if (p.name == n) { *p.fptr = v; return; }
    assert(false, "no float param `" ~ n ~ "` on " ~ c.name());
}
/// ditto
void setV(Command c, string n, Vec3 v) {
    foreach (ref p; c.params()) if (p.name == n) { *p.vptr = v; return; }
    assert(false, "no vec3 param `" ~ n ~ "` on " ~ c.name());
}
/// ditto
void setB(Command c, string n, bool v) {
    foreach (ref p; c.params()) if (p.name == n) { *p.bptr = v; return; }
    assert(false, "no bool param `" ~ n ~ "` on " ~ c.name());
}

/// The `reset → stand → op → undo` recipe of plan §6.3, for one cell.
///
/// `apply()` and `revert()` are asserted, not merely called: a command that
/// refuses on the stand freezes a pair of identical dumps, which is a green
/// fixture recording nothing.
ParityCell runCell(string name, string path, string family, string stand,
                   string sha, Mesh* function() makeStand,
                   Command delegate(Mesh*, View) makeCmd)
{
    auto m = makeStand();
    auto v = new View(0, 0, 800, 600);
    auto c = makeCmd(m, v);

    auto meta = PlaneDumpMeta(sha, path, family, stand);

    assert(c.apply(), name ~ ": the forward must apply on this stand — a "
                    ~ "refusing command freezes a fixture of nothing");
    immutable postOp = meshPlanesJson(*m, meta);

    assert(c.revert(), name ~ ": the undo must succeed on this stand");
    immutable postUndo = meshPlanesJson(*m, meta);

    return ParityCell(name, path, postOp, postUndo);
}

/// The fixture file: a self-describing header plus one block per cell, with
/// each `meshPlanesJson` object INLINED (it is already a JSON object, so it
/// needs no escaping and stays diffable).
string fixtureJson(string family, string sha, string stand, ParityCell[] cells)
{
    import std.array : appender;
    auto s = appender!string();
    s ~= format("{\n  \"family\": \"%s\",\n  \"producedBy\": \"%s\",\n"
              ~ "  \"stand\": \"%s\",\n"
              ~ "  \"recipe\": \"reset -> stand -> op -> undo\",\n"
              ~ "  \"cells\": [\n", family, sha, stand);
    foreach (i, ref c; cells) {
        s ~= format("    {\"name\": \"%s\", \"path\": \"%s\",\n"
                  ~ "     \"postOp\": %s,\n     \"postUndo\": %s}%s\n",
                    c.name, c.path, c.postOp, c.postUndo,
                    i + 1 < cells.length ? "," : "");
    }
    s ~= "  ]\n}\n";
    return s.data;
}

/// Absolute path of a file under `tests/fixtures/undo_parity/`.
///
/// `__FILE_FULL_PATH__`-rooted rather than cwd-rooted: the unit lane's working
/// directory is the project root today, and a fixture reader that quietly finds
/// nothing when it is not is a test that passes for the wrong reason.
string fixturePath(string leaf)
{
    import std.path : dirName, buildPath;
    // …/tests/unit/<this file>  ->  …/tests/fixtures/undo_parity/<leaf>
    immutable here = dirName(__FILE_FULL_PATH__);          // tests/unit
    immutable tests = dirName(here);                       // tests
    return buildPath(tests, "fixtures", "undo_parity", leaf);
}

/// Compare the freshly-run cells against the frozen file — or, under the
/// environment variable NAMED BY `captureKey`, WRITE the file instead.
///
/// The capture arm is what produced the committed fixture, and it lives beside
/// the reader deliberately: a capture script that is not the reader can drift
/// from it, and then the fixture records a recipe no test ever runs.
///
/// `captureKey` IS A PARAMETER AND NOT A CONSTANT, and that is task 1903 stage
/// L9-0 retiring a class rather than routing around it. It used to be the bare
/// literal `VIBE3D_PARITY_CAPTURE` inside this body, and three readers share
/// this function: L0's own, `undo_parity_l1_test.d:36` and
/// `undo_parity_l2_test.d:52`. Druntime runs every unittest module in ONE
/// process and `environment` is process-wide, so a capture run intended for
/// ONE of the three re-froze the other two's fixtures in the same run —
/// silently, and against a tree the other two's headers declare immutable.
/// L3 and L5 each dodged it by writing a private copy of this function with a
/// suffixed key; that is two copies of a mechanism, and a fourth and fifth
/// were owed here. So the key moves to the call site, one distinct key per
/// reader, and `tests/unit/parity_capture_key_census_test.d` asserts the
/// `leaf` -> `key` map is 1:1 over every `undo_parity_*_test.d`.
/// `exceptions` defaults to EMPTY, and a reader that passes one gets the
/// per-plane exception route instead of the raw compare. It is a parameter for
/// the same reason `captureKey` became one (task 2320, decision 1): L5's
/// reader needed exceptions and wrote a private copy of this whole body to get
/// them, which is how two copies of one mechanism start. An empty table makes
/// `compareWithExceptions` behave exactly as `comparePlanes` did.
void compareOrCapture(string leaf, string family, string sha, string stand,
                      ParityCell[] cells, string captureKey,
                      in PlaneException[] exceptions = null)
{
    import std.file   : exists, readText, write, mkdirRecurse;
    import std.path   : dirName;
    import std.process: environment;

    // ---- anti-vacuity, BEFORE anything is compared or written -------------
    // A cell whose op left the mesh where the undo leaves it cannot fail the
    // comparison below under any implementation of the undo.
    assert(cells.length > 0, family ~ ": no cells — the fixture is empty");
    foreach (ref c; cells)
        assert(c.postOp != c.postUndo,
               family ~ ": cell '" ~ c.name ~ "' has postOp == postUndo, so its "
             ~ "forward moved no plane this dump can see. Every assertion about "
             ~ "its undo is then satisfied by an undo that does nothing.");

    immutable path = fixturePath(leaf);

    // A caller that forgets the key must not fall back to "compare" and look
    // healthy: an empty key would make the capture arm unreachable and the
    // reader would silently stop being capturable at all.
    assert(captureKey.length > 0,
           leaf ~ ": compareOrCapture was given an EMPTY capture key — every "
         ~ "reader owns a distinct capture-key name; the map is asserted "
         ~ "1:1 by tests/unit/parity_capture_key_census_test.d");

    if (environment.get(captureKey, "") == "1") {
        mkdirRecurse(dirName(path));
        write(path, fixtureJson(family, sha, stand, cells));
        return;
    }

    assert(exists(path),
           "missing parity fixture " ~ path ~ " — plan §6.3 requires it to be "
         ~ "frozen BEFORE the family's dense path is deleted; re-run with "
         ~ captureKey ~ "=1 only on a tree that still HAS that path");

    auto frozen = parseJSON(readText(path));

    // §6.3 rule 2: the provenance must be there and non-empty, or the file
    // cannot be checked for ancestry by anyone.
    assert(frozen["producedBy"].str.length > 0,
           path ~ ": empty `producedBy` — a fixture with no provenance cannot "
         ~ "be shown to predate the code it is the oracle for");
    assert(frozen["stand"].str.length > 0, path ~ ": empty `stand`");

    auto fcells = frozen["cells"].array;
    assert(fcells.length == cells.length,
           format("%s: fixture holds %d cells, the recipe produced %d — a cell "
                ~ "added or removed without re-freezing", path, fcells.length,
                  cells.length));

    foreach (i, ref c; cells) {
        auto fc = fcells[i];
        assert(fc["name"].str == c.name,
               format("%s: cell %d is '%s' in the fixture and '%s' now — the "
                    ~ "roster was reordered", path, i, fc["name"].str, c.name));
        compareWithExceptions(path, c.name, "postOp",   fc["postOp"],
                              c.postOp,  exceptions);
        compareWithExceptions(path, c.name, "postUndo", fc["postUndo"],
                              c.postUndo, exceptions);
    }
}

/// Compare one frozen dump against one fresh dump, plane by plane, and NAME the
/// first plane that differs.
///
/// `provenance` is skipped on purpose and only that: it carries the capture
/// SHA, which is different by construction, and comparing it would redden every
/// cell for the one reason that is not a finding.
void comparePlanes(string file, string cell, string which,
                   const ref JSONValue frozenDump, const ref JSONValue fresh)
{
    import std.algorithm.sorting : sort;

    string[] keys;
    foreach (k, _; frozenDump.objectNoRef) keys ~= k;
    foreach (k, _; fresh.objectNoRef) if ((k in frozenDump.objectNoRef) is null) keys ~= k;
    keys.sort();

    foreach (k; keys) {
        if (k == "provenance") continue;
        auto pf = k in frozenDump.objectNoRef;
        auto pn = k in fresh.objectNoRef;
        assert(pf !is null,
               format("%s [%s/%s]: plane '%s' is NEW — the dump gained a plane "
                    ~ "the fixture predates; re-freeze deliberately, do not "
                    ~ "widen the skip list", file, cell, which, k));
        assert(pn !is null,
               format("%s [%s/%s]: plane '%s' is GONE from the dump", file,
                      cell, which, k));
        immutable string d = parityDiff(k, *pf, *pn);
        assert(d.length == 0,
               format("%s [%s/%s]: plane '%s' differs from the frozen "
                    ~ "capture\n    %s", file, cell, which, k, d));
    }
}

/// The `string`-fresh spelling, kept because every reader in the family calls
/// it. It parses and delegates, so there is still ONE walk.
void comparePlanes(string file, string cell, string which,
                   const ref JSONValue frozenDump, string freshText)
{
    auto fresh = parseJSON(freshText);
    comparePlanes(file, cell, which, frozenDump, fresh);
}

// ===========================================================================
// THE LEAF COMPARISON IS NUMERIC, NOT TEXTUAL — and the tolerance below is
// derived from the STORAGE TYPE, never from a difference we have observed.
//
// WHAT WENT WRONG WITH TEXT. `JSONValue.toString()` equality asked the frozen
// capture and the fresh dump to agree DIGIT FOR DIGIT. Measured on
// `7a5ef294`, one tree, one `--config=tests --build=check-unit`, 389 modules
// on both sides: under ldc2 1.42.0 `2/389 modules FAILED`, under dmd 2.112.1
// `389 modules passed`. Nothing about the geometry differed between those two
// runs; the last digits of a rendered float did. A comparator that cannot
// separate those two things reports a COMPILER as a regression — and, the
// worse half, teaches the reader to re-freeze a fixture to silence it, which
// destroys the oracle the fixture exists to be.
//
// WHY A TOLERANCE IS LEGITIMATE HERE, AND WHAT SETS IT. These are not doubles
// that happen to print long. `math.Vec3` stores `float`, and
// `http_json.meshPlanesJson` widens with `cast(double)` at the serialiser and
// renders `%.9g` — nine digits being float32's round-trip width. So every
// coordinate in these fixtures is the end of a chain of SINGLE-PRECISION
// operations. Two compilers are each entitled to reassociate that chain and to
// contract `a*b + c` into an FMA; LLVM and DMD's backend make different
// choices even at -O0, and each such choice costs O(1) ulps OF THE STORAGE
// TYPE. The floor below which a difference is toolchain noise rather than
// geometry is therefore a small multiple of `float.epsilon`, relative.
//
// THE NUMBER IS NOT FITTED TO THE FAILURE, and the order of work is the
// evidence. The budget is eight ulps of `float` — written as
// `8 * float.epsilon` so the derivation travels with the constant instead of
// arriving as a magic `1e-6`. Eight is the ordinary slack for a short kernel
// chain: a neighbour average, a fit-and-project and a matrix multiply are each
// a handful of roundings deep. It was chosen from the SHAPE of the pipeline,
// and the two failing cells were then checked to fall inside it — in that
// order. Had they fallen outside, the finding would have been a real
// divergence and this comparator would not have been the fix. Sizing the
// threshold to the measurement it is meant to judge is the defect this file's
// own header warns about; it is avoided by deriving the bound from the type,
// which knows nothing about our two cells.
//
// WHAT THE TOLERANCE MUST NOT SWALLOW, and does not. Anything a wrong undo
// produces. A revert that restores the wrong vertex, loses a delta or applies
// an op twice moves a coordinate by a fraction of the stand's own scale —
// order 1e-3 and up on these unit-scale stands, three to five DECADES above
// this floor. And integers never enter the numeric path at all: two
// integer-valued nodes are compared EXACTLY, so an index, a count or an id
// cannot be tolerated by a budget meant for coordinates.

/// Eight ulps of the STORAGE type. `float`, not `double`: the `double` in the
/// JSON is a widening applied at the serialiser, and comparing tighter than
/// the type that actually held the value compares rendering, not geometry.
enum double kParityRelTol = 8 * float.epsilon;   // ~9.54e-07

/// The near-zero arm, for a coordinate whose exact value is 0 and which a
/// chain of cancelling floats lands beside — there is no relative scale to
/// measure against there. Same ulp budget taken against unit scale, which is
/// the scale these stands are built at.
enum double kParityAbsTol = 8 * float.epsilon;

/// Structural JSON comparison: identical shape, EXACT non-numeric and
/// integer leaves, floating leaves within the budget above.
///
/// Returns "" when the two agree, else a message naming the JSON PATH of the
/// first disagreement together with both values, the measured gap and the
/// budget it broke. The path is what the old character-offset window was
/// reaching for: `vertices[7][1]` says which coordinate of which vertex moved,
/// where "first difference at character 4213" did not.
///
/// `a` is the FROZEN side and `b` the FRESH one; the messages say so, because
/// a reader who has them the wrong way round re-freezes in the wrong
/// direction.
string parityDiff(string path, in JSONValue a, in JSONValue b)
{
    import std.math : fabs, isNaN;

    static bool isInt(JSONType t) {
        return t == JSONType.integer || t == JSONType.uinteger;
    }
    static bool isNum(JSONType t) {
        return isInt(t) || t == JSONType.float_;
    }
    static long asLong(in JSONValue v) {
        return v.type == JSONType.uinteger ? cast(long) v.uinteger : v.integer;
    }
    static double asNum(in JSONValue v) {
        if (v.type == JSONType.float_) return v.floating;
        return cast(double) asLong(v);
    }

    // --- numeric leaves: the ONLY place a tolerance exists ------------------
    if (isNum(a.type) && isNum(b.type)) {
        // Two integer-valued nodes compare EXACTLY. Indices, counts, ids and
        // flags live here, and a tolerance over them would let an off-by-one
        // through — the loosening this change must not become.
        if (isInt(a.type) && isInt(b.type)) {
            immutable long ia = asLong(a), ib = asLong(b);
            if (ia != ib)
                return format("%s: frozen %d, now %d — integers compare "
                            ~ "exactly, no tolerance applies", path, ia, ib);
            return "";
        }
        immutable double x = asNum(a), y = asNum(b);
        if (isNaN(x) || isNaN(y)) {
            if (isNaN(x) && isNaN(y)) return "";
            return format("%s: frozen %.17g, now %.17g — exactly one side is "
                        ~ "NaN", path, x, y);
        }
        immutable double d     = fabs(x - y);
        immutable double scale = fabs(x) > fabs(y) ? fabs(x) : fabs(y);
        if (d <= kParityAbsTol) return "";
        if (d <= kParityRelTol * scale) return "";
        return format("%s: frozen %.17g, now %.17g"
                    ~ "\n      gap    abs %.6g, rel %.6g"
                    ~ "\n      budget abs %.6g, rel %.6g  (8 ulps of float — "
                    ~ "a toolchain cannot move a value this far)",
                      path, x, y, d, scale > 0 ? d / scale : d,
                      kParityAbsTol, kParityRelTol);
    }

    if (a.type != b.type)
        return format("%s: node type frozen %s, now %s", path, a.type, b.type);

    switch (a.type) {
        case JSONType.object: {
            import std.algorithm.sorting : sort;
            string[] keys;
            foreach (k, _; a.objectNoRef) keys ~= k;
            foreach (k, _; b.objectNoRef)
                if ((k in a.objectNoRef) is null) keys ~= k;
            keys.sort();
            foreach (k; keys) {
                auto pa = k in a.objectNoRef;
                auto pb = k in b.objectNoRef;
                if (pa is null)
                    return format("%s.%s: NEW — absent from the frozen capture",
                                  path, k);
                if (pb is null)
                    return format("%s.%s: GONE — present in the frozen capture",
                                  path, k);
                immutable string d = parityDiff(path ~ "." ~ k, *pa, *pb);
                if (d.length) return d;
            }
            return "";
        }
        case JSONType.array: {
            auto aa = a.arrayNoRef, ba = b.arrayNoRef;
            if (aa.length != ba.length)
                return format("%s: length frozen %d, now %d", path,
                              aa.length, ba.length);
            foreach (i; 0 .. aa.length) {
                immutable string d =
                    parityDiff(format("%s[%d]", path, i), aa[i], ba[i]);
                if (d.length) return d;
            }
            return "";
        }
        case JSONType.string:
            if (a.str != b.str)
                return format("%s: string differs%s", path,
                              contrast(a.str, b.str));
            return "";
        default:
            // true_ / false_ / null_ — the type equality above settled them.
            return "";
    }
}

/// One plane, on one cell, on one of the two dumps, where the migrated path is
/// KNOWN and ARGUED to differ from the frozen snapshot oracle.
///
/// `check` receives the whole frozen dump and the whole fresh dump, so an entry
/// can pin the SHAPE of the divergence rather than merely tolerating it.
///
/// SHARED FROM STAGE L5 ON, and the move is the point rather than a tidy-up:
/// `undo_parity_l3_test` grew this for one normalisation
/// (`faceSelectionOrder` on an unselected face), stage L5's family hit the
/// IDENTICAL divergence for the identical reason, and the plan's own rule for
/// that case is "the same argument, not a new one". A second copy of the
/// struct and the driver would be a second place for that argument to drift.
/// The ARGUMENT itself stays where it was written — see
/// `undo_parity_l3_test.checkOrderNormalisation`.
struct PlaneException {
    string cell;
    string which;      // "postOp" | "postUndo"
    string plane;
    string why;
    void function(string cell, in JSONValue frozenDump, in JSONValue freshDump) check;
}

/// `comparePlanes` with an exception table applied.
///
/// Delegates to `comparePlanes` for every plane with no entry — ONE
/// implementation of the plane walk, so a fixture that gains a plane cannot be
/// silently ignored by a reader's private copy of it. A plane WITH an entry is
/// removed from both dumps first (so the shared walk does not see it) and then
/// scored by the entry itself.
void compareWithExceptions(string file, string cell, string which,
                           const ref JSONValue frozenDump,
                           string freshText,
                           in PlaneException[] table)
{
    JSONValue fresh  = parseJSON(freshText);
    JSONValue frozen = frozenDump;   // JSONValue is a value type; this copies

    foreach (ref e; table) {
        if (e.cell != cell || e.which != which) continue;
        assert((e.plane in frozen.objectNoRef) !is null,
            format("%s [%s/%s]: exception names plane '%s', which the frozen "
                 ~ "dump does not carry", file, cell, which, e.plane));
        // Routed through `parityDiff`, not through text: if this file had
        // two definitions of "differs", an exception could stay alive on a
        // plane that agrees to every digit that means anything.
        assert(parityDiff(e.plane, frozen[e.plane], fresh[e.plane]).length != 0,
            format("%s [%s/%s]: plane '%s' now AGREES with the frozen oracle, "
                 ~ "but this reader carries a standing exception for it (%s). "
                 ~ "The divergence was fixed — RETIRE THE EXCEPTION in the "
                 ~ "same commit, or it becomes a licence over a plane nobody "
                 ~ "is comparing", file, cell, which, e.plane, e.why));
        e.check(cell ~ "/" ~ which, frozen, fresh);
        frozen.object.remove(e.plane);
        fresh.object.remove(e.plane);
    }

    comparePlanes(file, cell, which, frozen, fresh);
}

/// The shared well-formedness gate on ONE reader's exception table.
///
/// MUTATION: add a `PlaneException` naming a plane no cell diverges on —
/// `compareWithExceptions`'s "now AGREES" assert reddens on the first cell it
/// applies to, naming the plane. An entry that silences a plane which is in
/// fact identical is exactly the blind spot a parity reader must not grow.
void assertExceptionTableWellFormed(string family, in PlaneException[] table,
                                    in string[] rosterNames)
{
    assert(table.length > 0,
        family ~ ": the exception table is empty — then `compareWithExceptions` "
      ~ "is dead code for this reader and the mutation above scores nothing");
    foreach (ref e; table) {
        assert(e.why.length > 8,
            family ~ ": exception on " ~ e.cell ~ "/" ~ e.plane
          ~ " carries no reason");
        assert(e.check !is null,
            family ~ ": exception on " ~ e.cell ~ "/" ~ e.plane
          ~ " has no shape check — a bare skip is not an exception, it is a "
          ~ "blind spot");
        assert(e.which == "postOp" || e.which == "postUndo",
            family ~ ": exception on " ~ e.cell ~ " names dump '" ~ e.which ~ "'");
        // No entry may name the geometry itself: an exception over `vertices`
        // or `faces` would let a wrong revert through wholesale.
        assert(e.plane != "vertices" && e.plane != "faces" && e.plane != "counts",
            family ~ ": exception on " ~ e.cell ~ " names '" ~ e.plane
          ~ "' — the geometry planes may never carry one");
        bool inRoster = false;
        foreach (n; rosterNames) if (n == e.cell) inRoster = true;
        assert(inRoster,
            family ~ ": exception names cell '" ~ e.cell ~ "', which is not in "
          ~ "the roster — it would then never be applied and never be retired");
    }
}

/// The two renderings of ONE STRING LEAF, WINDOWED ON THE FIRST CHARACTER
/// THAT DIFFERS. (It used to window whole planes; `parityDiff` now walks the
/// structure and reports a JSON path, so this is reached only for a genuine
/// string-valued leaf — where a path alone still would not say what changed.)
///
/// A leading clip is the wrong instrument for these planes and this is not a
/// style point. `meshMaps` renders as one string tens of kilobytes long whose
/// first term is the UV map's `data`; a flipped bit in a morph map's `present`
/// channel — the exact plane this family's undo is most likely to lose — is
/// thousands of characters in. A message that prints the first 300 characters
/// of each side then shows the reader TWO IDENTICAL STRINGS under the words
/// "differs", which reads as a broken test rather than as a finding. Measured:
/// that is precisely what this file's first mutation run produced.
private string contrast(string a, string b)
{
    size_t i = 0;
    immutable n = a.length < b.length ? a.length : b.length;
    while (i < n && a[i] == b[i]) ++i;

    immutable size_t ctx  = 90;
    immutable size_t from = i > ctx ? i - ctx : 0;

    static string window(string s, size_t from, size_t to) {
        immutable size_t hi = to > s.length ? s.length : to;
        if (from >= hi) return "<end of value>";
        return (from > 0 ? "…" : "") ~ s[from .. hi] ~ (hi < s.length ? "…" : "");
    }
    return format("\n    first difference at character %d of %d/%d"
                ~ "\n    frozen: %s\n    now   : %s",
                  i, a.length, b.length,
                  window(a, from, i + ctx), window(b, from, i + ctx));
}

// ===========================================================================
// The L0 roster.
//
// THE STAND is `makeTaggedGridFull()` — §6.3's, so the fixture covers every
// plane the burn-in class covers — WITH THREE VERTICES PUSHED OFF THE PLANE.
// The perturbation is not flavour: on a uniform planar grid the discrete
// laplacian of an interior vertex IS that vertex, so `mesh.smooth` is the
// IDENTITY there and its cell would freeze `postOp == postUndo`; it also breaks
// the collinearity that makes `linear_align`'s targets the row it started from.
// The same trap in two commands, and the anti-vacuity assert in
// `compareOrCapture` is what refuses if a later edit takes the perturbation
// out.
//
// WHAT IS NOT IN THE ROSTER AND WHY. `mesh.transform` (L0-b's other half) is
// driven by a transform PACKET on the operator stack, not by params, so
// `Command.apply()`'s minimal `VectorStack` cannot carry a non-identity
// transform into it. Freezing it here would freeze an identity — a cell that
// cannot fail. It is named as a gap rather than filled with a decoy.
// ===========================================================================

import commands.mesh.smooth          : MeshSmooth;
import commands.mesh.jitter          : MeshJitter;
import commands.mesh.quantize        : MeshQuantize;
import commands.mesh.magnet          : MeshMagnet;
import commands.mesh.linear_align    : MeshLinearAlign;
import commands.mesh.radial_align    : MeshRadialAlign;
import commands.mesh.vertex_center   : MeshCenterVertices;
import commands.mesh.vertex_set      : MeshSetPosition;
import commands.mesh.edge_slide      : MeshEdgeSlide;
import commands.mesh.hide            : MeshHide, MeshHideUnselected,
                                       MeshHideInvert, MeshUnhideAll;
import commands.mesh.set_material    : MeshSetMaterial;
import commands.mesh.set_part        : MeshSetPart;
import commands.mesh.subpatch_toggle : SubpatchToggle;
import commands.mesh.move_vertex     : MeshMoveVertex;
import commands.mesh.symmetrize      : MeshSymmetrize;

enum string kL0Family = "position_marks";
enum string kL0Stand  = "makeTaggedGridFull(3)+perturbed";

private Mesh* l0Stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    m.vertices[5].y += 0.37f;   // interior, out of plane
    m.vertices[6].x += 0.11f;
    m.vertices[9].y -= 0.23f;
    return m;
}

private void selectRow(Mesh* m) { foreach (vi; [4u, 5u, 6u, 7u]) m.selectVertex(vi); }

/// Every L0 cell, in a fixed order. `path` is what the command's `revert()`
/// actually restored FROM at the capture SHA, read off the source there — see
/// the module header on why the vocabulary needed a third value.
ParityCell[] l0Cells(string sha)
{
    ParityCell[] out_;

    void cell(string name, string path, Command delegate(Mesh*, View) mk) {
        out_ ~= runCell(name, path, kL0Family, kL0Stand, sha, &l0Stand, mk);
    }

    // ---- L0-d, the nine plain position commands -------------------------
    cell("mesh.smooth", "dense-inline", (m, v) {
        auto c = new MeshSmooth(m, v, EditMode.Vertices);
        setI(c, "iter", 2); setF(c, "strn", 0.8f); return cast(Command)c; });
    cell("mesh.jitter", "dense-inline", (m, v) {
        auto c = new MeshJitter(m, v, EditMode.Vertices);
        setF(c, "rangeX", 0.2f); setF(c, "rangeY", 0.2f); setF(c, "rangeZ", 0.2f);
        setI(c, "seed", 7); return cast(Command)c; });
    cell("mesh.quantize", "dense-inline", (m, v) {
        auto c = new MeshQuantize(m, v, EditMode.Vertices);
        setF(c, "X", 0.3f); setF(c, "Y", 0.3f); setF(c, "Z", 0.3f);
        return cast(Command)c; });
    cell("mesh.magnet", "dense-inline", (m, v) {
        auto c = new MeshMagnet(m, v, EditMode.Vertices);
        setV(c, "target", Vec3(6, 0, 0)); setF(c, "strength", 0.5f);
        setF(c, "dist", 100.0f); return cast(Command)c; });
    cell("mesh.linear_align", "dense-inline", (m, v) {
        selectRow(m);
        auto c = new MeshLinearAlign(m, v, EditMode.Vertices);
        setF(c, "weight", 1.0f); return cast(Command)c; });
    cell("mesh.radial_align", "dense-inline", (m, v) {
        selectRow(m);
        auto c = new MeshRadialAlign(m, v, EditMode.Vertices);
        setF(c, "weight", 1.0f); return cast(Command)c; });
    cell("mesh.centerVertices", "snapshot", (m, v) {
        foreach (vi; [1u, 5u, 6u, 9u]) m.selectVertex(vi);
        auto c = new MeshCenterVertices(m, v, EditMode.Vertices);
        setS(c, "axis", "y"); return cast(Command)c; });
    cell("mesh.setPosition", "dense-inline", (m, v) {
        foreach (vi; [1u, 5u, 6u, 9u]) m.selectVertex(vi);
        auto c = new MeshSetPosition(m, v, EditMode.Vertices);
        setS(c, "axis", "z"); setF(c, "value", 0.25f); return cast(Command)c; });
    cell("mesh.edge_slide", "dense-inline", (m, v) {
        const uint ei = m.edgeIndex(5, 6);
        assert(ei != ~0u, "the stand has no edge 5-6 — makeGridPlane's "
                        ~ "numbering changed and this cell picks at random");
        m.selectEdge(ei);
        auto c = new MeshEdgeSlide(m, v, EditMode.Edges);
        setF(c, "t", 0.6f); return cast(Command)c; });

    // ---- L0-a, hide ------------------------------------------------------
    cell("mesh.hide", "snapshot", (m, v) =>
        cast(Command) new MeshHide(m, v, EditMode.Polygons));
    cell("mesh.hideUnselected", "snapshot", (m, v) =>
        cast(Command) new MeshHideUnselected(m, v, EditMode.Polygons));
    cell("mesh.hideInvert", "snapshot", (m, v) =>
        cast(Command) new MeshHideInvert(m, v, EditMode.Polygons));
    cell("mesh.unhideAll", "snapshot", (m, v) =>
        cast(Command) new MeshUnhideAll(m, v, EditMode.Polygons));

    // ---- L0-c, material / part ------------------------------------------
    cell("mesh.setMaterial", "dense-inline", (m, v) {
        // 0, NOT 1. `makeTaggedGridFull` sets `faceMaterial[fi] = fi % 2`
        // and the stand's polygon selection is face 7, whose material is
        // therefore ALREADY 1 — `materialId = 1` is a write of the value that
        // is there, `postOp == postUndo`, and the cell records nothing. The
        // anti-vacuity assert in `compareOrCapture` caught exactly that on this
        // file's first run; the comment is here so it is not re-introduced.
        auto c = new MeshSetMaterial(m, v, EditMode.Polygons);
        setI(c, "materialId", 0); return cast(Command)c; });
    cell("mesh.setPart", "dense-inline", (m, v) {
        auto c = new MeshSetPart(m, v, EditMode.Polygons);
        setI(c, "partId", 3); return cast(Command)c; });

    // ---- L0-f, subpatch --------------------------------------------------
    cell("mesh.subpatch_toggle", "dense-inline", (m, v) =>
        cast(Command) new SubpatchToggle(m, v, EditMode.Polygons));

    // ---- L0-e, move_vertex ----------------------------------------------
    cell("mesh.move_vertex", "dense-inline", (m, v) {
        auto c = new MeshMoveVertex(m, v, EditMode.Vertices);
        setV(c, "from", m.vertices[5]);
        setV(c, "to",   Vec3(m.vertices[5].x + 0.4f, m.vertices[5].y + 0.2f,
                             m.vertices[5].z - 0.15f));
        return cast(Command)c; });

    // ---- L0-b, symmetrize ------------------------------------------------
    cell("mesh.symmetrize", "dense-inline", (m, v) {
        auto c = new MeshSymmetrize(m, v, EditMode.Vertices);
        setS(c, "axis", "X"); setS(c, "side", "positive");
        setB(c, "topology", false); setF(c, "offset", 0.0f);
        setF(c, "epsilon", 1e-3f); return cast(Command)c; });

    return out_;
}

// ---------------------------------------------------------------------------
// THE READER. This is what turns the file from a record into an oracle.
//
// MUTATION THAT REDDENS IT: perturb one recorded plane value in
// `tests/fixtures/undo_parity/position_marks.json` — see the card. The message
// names the cell, which of the two dumps, and the plane.
// ---------------------------------------------------------------------------
unittest
{
    import std.process : environment;
    immutable sha = environment.get("VIBE3D_PARITY_SHA", "");
    compareOrCapture("position_marks.json", kL0Family, sha, kL0Stand,
                     l0Cells(sha), "VIBE3D_PARITY_CAPTURE_L0");
}
