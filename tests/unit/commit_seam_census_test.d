// commit_seam_census_test — the tree-scan half of the mesh-edit seam gate
// (task 1903, `doc/mesh_edit_seam_plan.md` §3.2 L3).
//
// WHY A SCAN AND NOT A LANGUAGE FEATURE. Revision 1 of the plan expected
// `package` on `Mesh.commitChange` to make an out-of-module commit a COMPILE
// error. The Stage-0 probe ran it and the prediction was wrong in the worse
// direction: plain `package` on a member of a dotless root module
// (`module mesh;`) is reachable from NO other module at all, and `package(mesh)`
// is rejected outright ("module `mesh` … conflicts with package name mesh").
// So there is no spelling that admits the legitimate root-package callers, and
// this census carries the gate instead. That is a recorded downgrade, not an
// oversight.
//
// STAGE A SCOPE. Only the `commitStamps` caller census is live here — the
// version stamp's own door. The per-site `AllowEntry` list over the ~132
// `commitChange` sites arrives family by family, as each one moves behind a
// batch; an allowlist written before anything migrated would be a copy of
// today's tree, which is a check that cannot come out differently.
module tests.unit.commit_seam_census_test;

import std.file   : readText, exists;
import std.format : format;
import std.path   : buildPath, dirName;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// A comment stripper, because the count is the whole point.
//
// The plan's own §3.1 nit: a doc comment that NAMES `commitStamps(` moves the
// number, and this file's job is to notice a real fourth caller, not a
// sentence about one. Line comments, block comments, nested block comments and
// string literals are all removed before counting.
//
// WHAT IT DOES NOT HANDLE, and why that is survivable. Wysiwyg strings
// (`r"…"`, where a backslash is literal, so this scanner's escape rule runs
// past the closing quote) and character literals (`'"'`, which opens a string
// here) can DESYNC it: from that point on, code reads as string and strings
// read as code. `source/mesh.d` contains neither today. The guard against a
// silent desync is not a promise, it is the non-vacuity floor below — a
// scanner that has lost its place eats the rest of the file, and
// `commitChange(` then falls from dozens to near zero and reddens with a
// message that says the stripper ate the file. Add either construct to
// `mesh.d` and this scanner needs the case, not a bigger floor.
// ---------------------------------------------------------------------------
private string stripCommentsAndStrings(string src) {
    import std.array : appender;
    auto sink = appender!string;
    size_t i = 0;
    while (i < src.length) {
        // Line comment.
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '/') {
            while (i < src.length && src[i] != '\n') ++i;
            continue;
        }
        // Block comment.
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) ++i;
            i = (i + 2 <= src.length) ? i + 2 : src.length;
            sink.put(' ');
            continue;
        }
        // Nesting block comment.
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '+') {
            int depth = 0;
            while (i < src.length) {
                if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '+') { ++depth; i += 2; continue; }
                if (i + 1 < src.length && src[i] == '+' && src[i + 1] == '/') { --depth; i += 2; if (depth == 0) break; continue; }
                ++i;
            }
            sink.put(' ');
            continue;
        }
        // Double-quoted string (with escapes).
        if (src[i] == '"') {
            ++i;
            while (i < src.length && src[i] != '"') {
                if (src[i] == '\\' && i + 1 < src.length) ++i;
                ++i;
            }
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            sink.put(' ');
            continue;
        }
        // Backtick string (no escapes).
        if (src[i] == '`') {
            ++i;
            while (i < src.length && src[i] != '`') ++i;
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            sink.put(' ');
            continue;
        }
        sink.put(src[i]);
        ++i;
    }
    return sink.data;
}

private size_t countOccurrences(string haystack, string needle) {
    size_t n = 0, i = 0;
    while (i + needle.length <= haystack.length) {
        if (haystack[i .. i + needle.length] == needle) { ++n; i += needle.length; }
        else ++i;
    }
    return n;
}

// ---------------------------------------------------------------------------
// The `commitStamps` caller census.
//
// `commitStamps` is the ONLY writer of `mutationVersion` on an edited mesh.
// Because the handle lives inside `source/mesh.d` (plan §2.2 B1) the method is
// genuinely `private`, so this claim is machine-checkable rather than an
// allowlist sentence: nothing outside that file can name it at all, and inside
// it the callers are counted here BY NAME.
//
// The three legitimate callers, and why each is not the others:
//
//   commitChange   — the unbatched mutation path. Still the common case: only
//                    a migrated family opens a batch.
//   commitRestored — whole-state restoration (MeshSnapshot.restore ×2,
//                    MeshEditDelta.finalize). Identical work; it exists so
//                    those three doors do not tick the L2 traffic counter.
//   closeEditFrame — every batch close, whichever spelling opened it
//                    (`MeshEditBatch.close()` or the older
//                    `Mesh.endEditBatch()`). ONE function, so "one stamp per
//                    batch" cannot drift between the two spellings.
//
// The plan's §3.1 wrote this expectation as "2" while its own code block gave
// `commitChange` and `commitRestored` calls of their own; the number below is
// the measured one, and the assertion NAMES the callers so a fourth has to be
// argued for rather than added.
//
// M-C7: declare a second call to `commitStamps` anywhere in `mesh.d` → this
// block reddens with the count and the roster.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// §5.7's position-write predicate, ONCE — and its controls in their OWN
// unittest block below.
//
// It lived inline inside the mixin-census block until Stage D3 needed a second
// per-file count (bridge.d's, expected 0). A copy-pasted predicate is two
// predicates the day one of them is widened, and §5.7's own history is exactly
// that: Revision 2's narrower regex missed 15 writes in `source/commands`, all
// of them the per-component `vertices[i].x += d` shape. One string, one set of
// controls, N callers.
//
// The controls sit in a SEPARATE `unittest` deliberately: druntime stops a
// module at its first failed assert, so a control folded into the counting
// block would be invisible whenever anything above it in that block is red —
// and a predicate whose controls never ran is a predicate nobody measured
// (task 1903 Stage D1 review memo, "count-assert and roster-asserts in one
// unittest — only the first is visible").
//
// From the plan's Revision 3 text, one alternative per line, with ONE
// widening measured at Stage D3 and described below. (`[^\]]` for the plan's
// `[^]]`: same class, and it does not depend on the engine's reading of a
// leading `]`.)
//
// STAGE D3's WIDENING, and why it is not a liberty taken with the plan's text.
// Alternative 2 was written `(^|[^a-zA-Z_.])vertices…`, i.e. it refused to fire
// on a DOTTED receiver — so `ed.vertices ~= v;` and `m.vertices = pos;` were
// both invisible to it. That was not a cosmetic gap for this stage: the Bridge
// family APPENDS vertices and never index-assigns one, so `ed.vertices ~= v`
// is precisely the raw write bridge.d could plausibly regress to, and the row
// that scans bridge.d would have been green over it. It was measured, not
// argued: the drill that replaced `ed.addVertex(…)` with `ed.vertices ~= …`
// left this census GREEN under the narrow spelling.
//
// The widening lets alternative 2 accept one `word.` qualifier. What it costs
// and what it buys, both measured on this tree at Stage D3 (comment-stripped):
//
//   source/mesh_ops/   3 -> 8   (+4 `m.vertices = [` unittest fixtures in
//                                extrude.d, +1 in loop_slice.d; decimate.d and
//                                bridge.d stay at 0, which is what the two live
//                                rows below assert)
//   source/commands/  39 -> 49  (+9 fixture writes, and ONE production write
//                                the plan's own §5.7 table therefore missed:
//                                `source/commands/mesh/smooth.d`'s
//                                `mesh.vertices = prev;` — an L0 file, so the
//                                stage that builds the full scanner inherits it)
//
// So §5.7's measured table reads 4/39/47 for the three zones and the honest
// numbers are 8/49 for the two this census scans. Anyone budgeting the full
// scanner off the plan's table should use these instead.
// ---------------------------------------------------------------------------
private enum string kPosWritePredicate =
    // The index expression admits ONE level of nesting (`[^\[\]]` outside,
    // `\[[^\[\]]*\]` inside). WIDENED AT STAGE E3, and the widening is the
    // same class as Stage D3's dotted-receiver one: written `\[[^\]]*\]` the
    // predicate stops at the FIRST `]`, so `vertices[pr[0]] = …` never matched
    // — and that is exactly the spelling `mesh_ops/cut.d`'s gap block used for
    // the two seam-pair writes it owned. cut.d therefore read 0 under a
    // predicate structurally blind to the only two raw writes it had. Measured
    // on the E3 tree, the widening makes SEVEN further sites visible that the
    // narrow spelling missed — `mesh_ops/loop_slice.d` ×4 (Stage F1's to
    // classify) and `commands/mesh/{magnet,vertex_center,vertex_set}.d` ×3
    // (already L0 commands in plan §5.7's table) — so the counts below are the
    // WIDENED ones: mesh_ops 12 (was 8), commands 52 (was 49), tools 49
    // (unchanged); the two deltas are 4 + 3 = 7, which is the enumeration
    // above and nothing else. (An earlier draft of this comment said NINE: it
    // was counting cut.d's own two nested writes as well — real under the
    // widened predicate in the PRE-E3 tree, and RETIRED by this stage into the
    // single `ed.setVertexPositions` call, so they are not among the sites a
    // later scanner will find.)
      r"vertices\s*\[(?:[^\[\]]|\[[^\[\]]*\])*\]\s*(\.[xyz]\s*)?([-+*/]?)=[^=]"  // indexed (one nesting level), whole or per-component, any op-assign
    ~ r"|(^|[^a-zA-Z_.0-9])(\w+\s*\.\s*)?vertices\s*(~|[-+*/])?=[^=]" // whole-array assign / append, bare or `x.`-qualified
    ~ r"|vertices\s*\[[^\]]*\.\.[^\]]*\]\s*(\[\s*\])?\s*=[^=]"         // slice assign, incl. `[] =`
    ~ r"|foreach\s*\(\s*(size_t\s+\w+\s*,\s*)?ref\s+\w+\s*;\s*[a-zA-Z_.]*vertices"; // `foreach (ref v; vertices)`

/// Raw coordinate writes in `src` (already comment-stripped) under §5.7's
/// predicate; `firstHit` is the first matching text, for the failure message.
private size_t countRawPositionWrites(string src, out string firstHit) {
    import std.regex : regex, matchAll;
    auto posRe = regex(kPosWritePredicate);
    size_t n;
    foreach (mm; matchAll(src, posRe)) {
        if (n == 0) firstHit = mm.hit.idup;
        ++n;
    }
    return n;
}

unittest // the §5.7 position-write predicate discriminates
{
    import std.regex : regex, matchAll;
    auto posRe = regex(kPosWritePredicate);

    // POSITIVE CONTROL, and it goes FIRST. A count of 0 over a predicate that
    // matches nothing is the "gate reports clean over an empty input" shape;
    // these five samples are the four shapes §5.7 enumerates plus the exact
    // line M-V1 puts back into decimate.d.
    static immutable string[] kMustMatch = [
        "    vertices[i] = p;\n",
        "    ed.vertices[i] = pos[find(cast(int)i)];\n",
        "    m.vertices[j].x += d;\n",
        "    vertices[a .. b] = src;\n",
        "    foreach (ref v; vertices) v.y = 0;\n",
        // The two Stage D3 added (see the widening note on the predicate): a
        // DOTTED receiver. The first is the exact line the M-D3-RAW drill puts
        // into bridge.d in place of `ed.addVertex(…)`; the second is
        // `commands/mesh/smooth.d:292`, a production whole-array position write
        // the narrow spelling did not see.
        "    ed.vertices ~= bridgeTwistedVertex(m, a, b, k, t, w);\n",
        "    mesh.vertices = prev;\n",
        // The two Stage E3 added: a NESTED index expression. Both are the exact
        // lines `mesh_ops/cut.d`'s `splitAlongCutLoop` carried before the
        // conversion, and both were INVISIBLE to the pre-E3 spelling — which is
        // why cut.d's `== 0` row would have been green over two live raw writes.
        "    vertices[pr[0]] = vertices[pr[0]] + dir * loAmt;\n",
        "    ed.vertices[pr[1]].y -= hiAmt;\n",
    ];
    foreach (sample; kMustMatch)
        assert(!matchAll(sample, posRe).empty,
            format("the §5.7 position-write predicate does not match `%s` — it "
                 ~ "has been narrowed, and every count it reports is worthless "
                 ~ "until it matches this again", sample[0 .. $ - 1]));

    // NEGATIVE CONTROL: a predicate that matches every mention of `vertices`
    // would also report 0-is-impossible and pass its gates by being permanently
    // red, which is a different way of not measuring.
    static immutable string[] kMustNotMatch = [
        "    const n = ed.vertices.length;\n",
        "    if (vertices[i] == p) return;\n",
        "    Vec3[] pos = ed.vertices.dup;\n",
        "    ring[k] = ed.addVertex(vec3Lerp(ed.vertices[a[k]], ed.vertices[b[k]], t));\n",
        // …and the two the D3 widening must NOT have dragged in with it: an
        // identifier that merely ENDS in `vertices`, and a by-value foreach.
        "    auto subvertices = 3;\n",
        "    foreach (v; m.vertices) sum = sum + v;\n",
        // …and the two the E3 widening must NOT have dragged in with it: a
        // nested-index READ used as an argument, and a nested-index `==`.
        "    ring[k] = ed.addVertex(ed.vertices[pr[0]], ed.vertices[pr[1]]);\n",
        "    if (m.vertices[idx[k]] == p) return;\n",
    ];
    foreach (sample; kMustNotMatch)
        assert(matchAll(sample, posRe).empty,
            format("the §5.7 position-write predicate matches `%s`, which is a "
                 ~ "READ — a predicate that fires on reads cannot distinguish a "
                 ~ "migrated file from an unmigrated one", sample[0 .. $ - 1]));
}

unittest // commitStamps has exactly one definition and three named callers
{
    immutable path = buildPath(repoRoot, "source", "mesh.d");
    assert(exists(path), "cannot find source/mesh.d at " ~ path);
    immutable src = stripCommentsAndStrings(readText(path));

    // Non-vacuity floor: if the stripper ever regressed to eating everything,
    // every count below would be 0 and this file would pass by saying nothing.
    assert(countOccurrences(src, "commitChange(") >= 20,
        "the comment stripper ate the file — `commitChange(` should appear "
      ~ "dozens of times in source/mesh.d");

    const size_t total = countOccurrences(src, "commitStamps(");
    const size_t defs  = countOccurrences(src, "private void commitStamps(uint flags)");
    assert(defs == 1,
        format("source/mesh.d declares `commitStamps` %d times; expected "
             ~ "exactly 1, and `private` — if it stopped being private, the "
             ~ "seam's one-writer claim is no longer machine-checkable", defs));

    assert(total == 4,
        format("`commitStamps(` appears %d times in source/mesh.d; expected 4 "
             ~ "— its definition plus exactly three callers: commitChange (the "
             ~ "unbatched path), commitRestored (whole-state restoration) and "
             ~ "closeEditFrame (every batch close). A fourth caller is a new "
             ~ "way to advance a version stamp: name it here and say why it is "
             ~ "not one of the three.", total));

    // …and they are those three, not any three. A rename that moved a call
    // into a different function would keep the count and break the meaning.
    static immutable string[] kCallers = [
        "    void commitChange(uint flags) {",
        "    void commitRestored(uint flags) {",
        "private MeshEditDelta closeEditFrame(Mesh* m, uint extraFlags) {",
    ];
    foreach (sig; kCallers)
        assert(countOccurrences(src, sig) == 1,
            format("source/mesh.d no longer declares `%s` — the commitStamps "
                 ~ "caller census names the three functions allowed to stamp, "
                 ~ "so a rename must update this list and say why", sig));
}

// ---------------------------------------------------------------------------
// The batch state is MODULE-LEVEL, not a field of `Mesh`.
//
// `source/mesh.d` already states the reason twice, for `g_hideDeriveDepth` and
// for `g_deliveryDepth`: a kernel of the form `*mesh = subdivide(...)` resets
// an in-struct counter mid-batch, and the close then finds depth 0, skips its
// stamp, and the edit never publishes. This is that rule for the third
// counter, as a check rather than a comment.
//
// Mutation: move `g_editBatchStack` (or a `batchDepth_` / `batchFlags_` /
// `editRecorderStore_` field) onto `struct Mesh` → this block reddens.
// ---------------------------------------------------------------------------

unittest // no batch state on struct Mesh
{
    immutable path = buildPath(repoRoot, "source", "mesh.d");
    immutable src  = stripCommentsAndStrings(readText(path));

    assert(countOccurrences(src, "private EditBatchFrame[] g_editBatchStack;") == 1,
        "source/mesh.d no longer declares the module-level `g_editBatchStack`. "
      ~ "It must stay module scope, keyed by `Mesh*`: a kernel that replaces "
      ~ "the whole struct (`*mesh = subdivide(...)`) would reset an in-struct "
      ~ "counter mid-batch, the close would find depth 0, and the edit would "
      ~ "never publish (task 1903 §2.2a; the same reason g_hideDeriveDepth and "
      ~ "g_deliveryDepth are module scope, stated at both).");

    static immutable string[] kForbiddenFields = [
        "batchDepth_", "batchFlags_", "editRecorderStore_",
    ];
    foreach (name; kForbiddenFields)
        assert(countOccurrences(src, name) == 0,
            "source/mesh.d names `" ~ name ~ "` — the batch state must not "
          ~ "become a field of `Mesh` again (task 1903 §2.2a).");

    // `editRecorder_` survives as an ACCESSOR over the stack, never as a
    // pointer field: a `*mesh = result` mid-batch would otherwise swap in the
    // new value's empty tracker and orphan the one the caller is recording to.
    assert(countOccurrences(src, "private MeshEditTracker* editRecorder_;") == 0,
        "`Mesh.editRecorder_` is a FIELD again — it must be a private accessor "
      ~ "over `g_editBatchStack`, or a wholesale `*mesh = …` mid-batch orphans "
      ~ "the recorder (task 1903 §2.2a item 2).");
}

// ---------------------------------------------------------------------------
// THE UNWIND-GUARD ROSTER (task 1903 S1).
//
// `MeshEditBatch` pops its frame from `~this`. `Mesh.beginEditBatch` has no
// handle, so an `Exception` escaping before the matching `endEditBatch`
// orphans the frame PERMANENTLY — every later `commitChange` on that mesh
// defers forever, the app keeps running and silently stops publishing, and
// `changeBus.batchLeaks` (the destructor's counter) stays 0. Each caller
// therefore spells `scope(failure) mesh.abortEditBatch();` right after its
// open.
//
// This is scanned rather than listed, on purpose: an allowlist of four
// filenames is a copy of today's tree and cannot fail when a FIFTH caller
// appears. The scan finds every `source/**` file that opens a batch through
// the older spelling and requires a guard in each, so both mutations redden —
// removing the guard from one of the four, and adding an unguarded caller.
// The unit-lane half (that the guard actually pops, and that it does not
// invent a leak after a clean close) is in `tests/unit/mesh_edit_batch_test.d`.
// ---------------------------------------------------------------------------

unittest // every beginEditBatch caller carries a scope(failure) abort
{
    import std.algorithm : sort;
    import std.array     : replace;
    import std.file      : dirEntries, SpanMode;
    import std.string    : indexOf;

    immutable srcRoot = buildPath(repoRoot, "source");
    assert(exists(srcRoot), "cannot find source/ at " ~ srcRoot);

    // `source/mesh.d` DEFINES both `beginEditBatch` and `abortEditBatch`; it
    // is the only exemption, and it is one name, not a family.
    immutable meshPath = buildPath(srcRoot, "mesh.d");

    // The spelling the four sites use, and the one this census requires. A
    // different receiver name is a real decision — it means the batch is no
    // longer opened on the command's own `mesh` — so it should redden here and
    // be argued for, not pass on a looser pattern.
    enum kGuard = "scope(failure) mesh.abortEditBatch();";

    string[] callers;
    foreach (e; dirEntries(srcRoot, "*.d", SpanMode.depth)) {
        if (e.name == meshPath) continue;
        immutable src = stripCommentsAndStrings(readText(e.name));
        const size_t opens = countOccurrences(src, "beginEditBatch(");
        if (opens == 0) continue;
        callers ~= e.name;

        const size_t guards = countOccurrences(src, kGuard);
        assert(guards >= opens,
            format("%s opens %d edit batch(es) through Mesh.beginEditBatch but "
                 ~ "carries only %d `%s`. An Exception escaping before "
                 ~ "endEditBatch orphans the frame on g_editBatchStack forever: "
                 ~ "every later commitChange on that mesh defers, the app "
                 ~ "silently stops publishing, and changeBus.batchLeaks stays 0 "
                 ~ "because that counter belongs to MeshEditBatch's destructor "
                 ~ "(task 1903 S1).", e.name, opens, guards, kGuard));

        // …and the guard is armed AFTER the open, or the throw it exists for
        // is not inside its scope.
        const iOpen  = src.indexOf("beginEditBatch(");
        const iGuard = src.indexOf(kGuard);
        assert(iGuard > iOpen,
            format("%s arms its abort guard BEFORE it opens a batch — "
                 ~ "scope(failure) must follow the open (task 1903 S1)",
                   e.name));
    }

    // The roster itself. A fifth legacy caller is a real decision (the handle
    // is the migration target and pops from its own destructor), so it should
    // have to be argued for here rather than appear.
    sort(callers);
    assert(callers.length == 4,
        format("source/ holds %d callers of the older Mesh.beginEditBatch "
             ~ "spelling; expected exactly 4 (commands/mesh/delete.d, "
             ~ "commands/mesh/remove.d, tools/edit/edge_extend.d, "
             ~ "tools/edit/edge_extrude.d). New edits open a MeshEditBatch: %s",
               callers.length, callers));

    // …and they are those four, not any four: a swap would keep the count.
    static immutable string[] kExpected = [
        "commands/mesh/delete.d", "commands/mesh/remove.d",
        "tools/edit/edge_extend.d", "tools/edit/edge_extrude.d",
    ];
    foreach (want; kExpected) {
        bool seen = false;
        foreach (got; callers)
            if (got.replace("\\", "/").indexOf("source/" ~ want) >= 0) {
                seen = true;
                break;
            }
        assert(seen,
            format("no source file matching `%s` opens a Mesh.beginEditBatch "
                 ~ "any more — if that family migrated to MeshEditBatch, drop "
                 ~ "it from this roster and say so", want));
    }
}

// ---------------------------------------------------------------------------
// THE MIXIN CENSUS (plan §4.5) — the track-1 conversion's only gate.
//
// `grep -c 'mixin Mesh*Ops' source/mesh.d` was 13 before Stage C and must
// reach 0. This block holds the running count and, more importantly, names the
// families already converted, because the count alone is a weak check: a stage
// that converted one family while someone re-added a mixin for another would
// keep the number and lose the meaning.
//
// WHY A NAMED ROSTER AND NOT JUST A NUMBER. A member reachable on the
// receiver BEATS a same-name UFCS free function — measured by the plan's
// Stage-0 probe. So a `mixin MeshSelectLoopOps;` reinstated NEXT TO the free
// functions is not a compile error and not an ambiguity: `mesh.selectLoopEdges(…)`
// silently binds back to the mixed-in method, the free functions go dead, and
// every select.loop test stays green while measuring the old body. That is a
// mutation no behavioural test in the tree can see, which is exactly why it
// has to be a text census here. Hence `kConverted`: the family is named, and
// reinstating its mixin reddens with the family's name in the message.
//
// The floor is a floor, never an equality on the converted side: a later stage
// converting another family lowers `mixin` count and raises the roster, and
// neither direction should need this block edited twice.
//
// M-C-MIXIN: paste `mixin MeshSelectLoopOps;` back into struct Mesh (keeping
// the free functions) → this block reddens naming MeshSelectLoopOps.
// M-D1-MIXIN: the same for `mixin MeshConnectedMaskOps;` (task 1903 Stage D1).
// M-D2-MIXIN: the same for `mixin MeshDecimateOps;` (task 1903 Stage D2).
// M-D3-MIXIN: the same for `mixin MeshBridgeOps;` (task 1903 Stage D3).
// M-E1-MIXIN: the same for `mixin MeshCleanupOps;` (task 1903 Stage E1).
// M-E2-MIXIN: the same for `mixin MeshRevolveOps;` (task 1903 Stage E2).
// M-E3-MIXIN: the same for `mixin MeshCutOps;` (task 1903 Stage E3).
// M-E4-MIXIN: the same for `mixin MeshBevelFinOps;` AND for
//   `mixin MeshBevelVertexOps;` — E4 converts TWO families in one stage, so
//   the drill is run twice, once per name (task 1903 Stage E4).
// ---------------------------------------------------------------------------

unittest // the mixin count is falling, and the converted families stay converted
{
    import std.algorithm : canFind;
    import std.regex     : ctRegex, matchAll;

    immutable path = buildPath(repoRoot, "source", "mesh.d");
    immutable src  = stripCommentsAndStrings(readText(path));

    // Non-vacuity floor. The stripper eating the file, or a bad path, would
    // otherwise read as "every family is converted" — the strongest possible
    // green from the weakest possible evidence.
    assert(countOccurrences(src, "struct Mesh {") == 1,
        "the comment stripper ate source/mesh.d — `struct Mesh {` is gone, so "
      ~ "a zero mixin count below would mean nothing");

    auto re = ctRegex!(`mixin\s+(Mesh[A-Za-z]*Ops)\s*;`);
    string[] live;
    foreach (mo; matchAll(src, re))
        live ~= mo[1].idup;

    // 13 at the branch point; one family leaves per track-1 stage; 0 at Stage I.
    enum size_t kAtStart = 13;
    // C: MeshSelectLoopOps; D1: MeshConnectedMaskOps; D2: MeshDecimateOps;
    // D3: MeshBridgeOps; E1: MeshCleanupOps; E2: MeshRevolveOps;
    // E3: MeshCutOps; E4: MeshBevelFinOps AND MeshBevelVertexOps (the one
    // stage that converts two families, plan §12's E4 row — so this number
    // falls by TWO here and by one everywhere else).
    enum size_t kExpected = 4;
    assert(live.length == kExpected,
        format("source/mesh.d instantiates %d `mixin Mesh*Ops` templates; this "
             ~ "gate expects %d. Track 1 started at %d and every conversion "
             ~ "stage deletes its own line in its own commit, so a HIGHER count "
             ~ "is a reinstated mixin and a LOWER one is a stage that landed "
             ~ "without updating this number. Live: %s "
             ~ "(task 1903 §4.5)", live.length, kExpected, kAtStart, live));

    // …and these are gone BY NAME. A converted family cannot come back beside
    // its free functions without silently taking every call site with it.
    static immutable string[] kConverted = ["MeshSelectLoopOps",        // Stage C
                                            "MeshConnectedMaskOps",     // Stage D1
                                            "MeshDecimateOps",          // Stage D2
                                            "MeshBridgeOps",            // Stage D3
                                            "MeshCleanupOps",           // Stage E1
                                            "MeshRevolveOps",           // Stage E2
                                            "MeshCutOps",               // Stage E3
                                            "MeshBevelFinOps",          // Stage E4
                                            "MeshBevelVertexOps"];      // Stage E4
    foreach (name; kConverted)
        assert(!live.canFind(name),
            format("`mixin %s;` is back in struct Mesh. That family is free "
                 ~ "functions in source/mesh_ops/ now, and a member BEATS a "
                 ~ "same-name UFCS free function — so the mixin does not "
                 ~ "conflict with them, it SHADOWS them: every call site binds "
                 ~ "to the mixed-in body again, the free functions go "
                 ~ "unreachable, and every test on this family stays green "
                 ~ "while measuring the code the conversion replaced "
                 ~ "(task 1903, plan Revision 2 caveat 1).", name));

    // The other half of the same claim: the ops file must not be a mixin
    // template any more either. Deleting the instantiation while leaving
    // `mixin template MeshSelectLoopOps()` in place would leave a template
    // nothing instantiates — dead code that reads as the live implementation.
    immutable opsPath = buildPath(repoRoot, "source", "mesh_ops", "select_loop.d");
    assert(exists(opsPath), "cannot find source/mesh_ops/select_loop.d at " ~ opsPath);
    immutable ops = stripCommentsAndStrings(readText(opsPath));
    assert(countOccurrences(ops, "mixin template MeshSelectLoopOps") == 0,
        "source/mesh_ops/select_loop.d still declares `mixin template "
      ~ "MeshSelectLoopOps` — Stage C converted this family to free functions "
      ~ "over `ref const(Mesh)`; a surviving template is either dead or a "
      ~ "second implementation (task 1903 Stage C).");
    // THE TRAILING COMMA IS LOAD-BEARING in all four receiver pins below (D2
    // review, MINOR-1). Without it the needle is a PREFIX of the declaration,
    // so renaming the receiver `m` → `m2` (or `ed` → `edb`) leaves the pin
    // green while the name the pin exists to hold has changed. Measured:
    // `ed` → `edb` stayed green on the D2 row. Every one of these four
    // declarations takes a second parameter, so `,` is the delimiter that is
    // actually there; a nullary receiver would need `)` instead.
    assert(countOccurrences(ops, "selectLoopEdges(ref const(Mesh) m,") == 1,
        "source/mesh_ops/select_loop.d no longer declares `selectLoopEdges` as "
      ~ "a free function over `ref const(Mesh)` — if the receiver changed, say "
      ~ "why here: `ref const(Mesh)` is what keeps `mesh.selectLoopEdges(seed)` "
      ~ "compiling verbatim at ~40 call sites (task 1903 §4.1).");

    // Stage D1, the same two claims for the connected-mask family — written out
    // rather than folded into a loop, because the RECEIVER assertion below is
    // family-specific and its message is the whole point of having it.
    immutable cmPath = buildPath(repoRoot, "source", "mesh_ops", "connected_mask.d");
    assert(exists(cmPath), "cannot find source/mesh_ops/connected_mask.d at " ~ cmPath);
    immutable cm = stripCommentsAndStrings(readText(cmPath));
    assert(countOccurrences(cm, "mixin template MeshConnectedMaskOps") == 0,
        "source/mesh_ops/connected_mask.d still declares `mixin template "
      ~ "MeshConnectedMaskOps` — Stage D1 converted this family to free "
      ~ "functions; a surviving template is either dead or a second "
      ~ "implementation (task 1903 Stage D1).");

    // The receivers are DIFFERENT inside this one family, and that is the
    // finding D1 added to the plan's two-receiver table (§4.1): a query that
    // writes no mesh data can still be uncallable through `const`, because
    // `Mesh.vertexAdjacencyCSR` MEMOIZES. `ref Mesh` is the honest receiver for
    // that — and it is emphatically NOT a `MeshEditBatch`, which would defer
    // and publish a change for a call that changes nothing observable. If a
    // later stage widens `connectedComponentMask` to a batch receiver, that is
    // a decision to argue for here, not a mechanical follow-on.
    assert(countOccurrences(cm, "connectedComponentMask(ref Mesh m,") == 1,
        "source/mesh_ops/connected_mask.d no longer declares "
      ~ "`connectedComponentMask` over `ref Mesh` — if it became "
      ~ "`ref const(Mesh)` it cannot compile (`vertexAdjacencyCSR` memoizes and "
      ~ "is non-const), and if it became `ref MeshEditBatch` then a read-only "
      ~ "query now opens an edit batch, which is a behaviour change nothing "
      ~ "asked for (task 1903 Stage D1, plan §4.1).");
    assert(countOccurrences(cm, "connectedComponentMask(ref const(Mesh)") == 0,
        "a `ref const(Mesh)` overload of `connectedComponentMask` can only exist by "
      ~ "casting const away to reach the memoizing `vertexAdjacencyCSR` — that is the "
      ~ "receiver this family refused, not a second convenience (task 1903 Stage D1).");
    assert(countOccurrences(cm, "edgeCentroid(ref const(Mesh) m,") == 1,
        "source/mesh_ops/connected_mask.d no longer declares `edgeCentroid` "
      ~ "over `ref const(Mesh)` — it reads two vertices and nothing else, so "
      ~ "the const receiver is what states that, and it is what keeps "
      ~ "`mesh.edgeCentroid(ei)` compiling verbatim in xfrm_transform.d "
      ~ "(task 1903 Stage D1).");

    // Stage D2 — the decimation family, and the FIRST MUTATING receiver in the
    // tree. Everything above this point is a read-only or memo-touching query;
    // `reduceToTarget` is the first kernel whose receiver is the edit batch
    // itself, so these three lines are the ones D3…H are measured against.
    immutable dcPath = buildPath(repoRoot, "source", "mesh_ops", "decimate.d");
    assert(exists(dcPath), "cannot find source/mesh_ops/decimate.d at " ~ dcPath);
    immutable dc = stripCommentsAndStrings(readText(dcPath));
    assert(countOccurrences(dc, "mixin template MeshDecimateOps") == 0,
        "source/mesh_ops/decimate.d still declares `mixin template "
      ~ "MeshDecimateOps` — Stage D2 converted this family to a free function; "
      ~ "a surviving template is either dead or a second implementation "
      ~ "(task 1903 Stage D2).");

    // The RECEIVER, pinned WITH its parameter name. `ed` is not decoration:
    // plan §4.3 step 3 requires one stable name across the family because the
    // kernel's nested functions capture the enclosing parameter the way they
    // used to capture `this` — rename it per file and every nested body needs
    // threading instead of a prefix.
    assert(countOccurrences(dc, "reduceToTarget(ref MeshEditBatch ed,") == 1,
        "source/mesh_ops/decimate.d no longer declares `reduceToTarget` over "
      ~ "`ref MeshEditBatch ed`. That receiver is the enforcement, not the "
      ~ "style: it is what makes a batchless call a COMPILE error, so one "
      ~ "reduce stamps, derives and delivers once at close() instead of once "
      ~ "per internal commit — and it is what gives the recorded finalise "
      ~ "write somewhere to record TO at Stage L10 (task 1903 §4.1, §5.2 D2).");

    // …and the two wrong spellings, absent. A `ref Mesh` receiver would compile
    // and would silently take the batch away — the exact regression the row
    // above exists to stop, and one no behavioural test in the tree can see
    // while the undo path is still a whole-mesh snapshot.
    assert(countOccurrences(dc, "reduceToTarget(ref Mesh ") == 0,
        "`reduceToTarget` has a `ref Mesh` receiver again — that compiles, and "
      ~ "it drops the batch: the kernel's internal commits go back to stamping "
      ~ "one at a time and the finalise write has no frame to record into. If "
      ~ "this is deliberate it is an argument to make here, not a mechanical "
      ~ "follow-on (task 1903 Stage D2).");
    assert(countOccurrences(dc, "reduceToTarget(ref const(Mesh)") == 0,
        "`reduceToTarget` cannot have a `ref const(Mesh)` receiver — it welds, "
      ~ "drops faces and moves every cluster member. Such an overload could "
      ~ "only exist by casting const away (task 1903 Stage D2).");

    // The raw coordinate write is GONE from this file, which is the half of
    // Stage D2 that can be red today. The delta's `Kind.SetPos` has no reader
    // until Stage L10, so no undo fixture can tell a raw write from the
    // recorded one yet — plan §5.7 says so outright, and this text check is
    // what holds the line in between. It is deliberately narrower than §5.7's
    // full position-write scanner (a later stage builds that over all of
    // source/mesh_ops and source/commands); it is this ONE file's count.
    assert(countOccurrences(dc, "ed.setVertexPositions(") == 1,
        "source/mesh_ops/decimate.d no longer calls `setVertexPositions` — the "
      ~ "finalise that coincides every cluster member onto its representative "
      ~ "is the raw `vertices[i] = …` write again, and a raw write inside a "
      ~ "recording batch produces NO op-log entry: a delta undo would restore "
      ~ "the topology and leave every coordinate at its post-collapse value "
      ~ "(task 1903 §2.5, §5.7 M-D2).");
    // …and the raw write is gone under §5.7's OWN predicate, not under a
    // hand-narrowed one (D2 review, MINOR-2). The previous spelling of this
    // check counted the literal `vertices[i] =`, which is one of FOUR shapes a
    // raw coordinate write takes: `vertices[j].x += d`, a slice assign and a
    // `foreach (ref v; vertices)` all walk past it, and §5.7's Revision 3
    // re-measurement found 15 such writes in `source/commands` alone that the
    // narrow regex had missed. This file's expected count is 0 — decimate's
    // §5.7 entry was retired at Stage D2, which is what makes 0 the right
    // number here and not an `AllowEntry`.
    {
        string firstHit;
        immutable size_t rawWrites = countRawPositionWrites(dc, firstHit);
        assert(rawWrites == 0,
            format("source/mesh_ops/decimate.d: %d raw position write(s) under "
                 ~ "§5.7's predicate, expected 0 — this entry was retired at "
                 ~ "Stage D2. First hit: `%s`. `alias mesh this` means "
                 ~ "`ed.vertices[i] = p` COMPILES inside a recording batch and "
                 ~ "records nothing, which is why the boundary is a counted "
                 ~ "census and not a type (task 1903 §5.7, M-V1).",
                   rawWrites, firstHit));
    }

    // Stage D3 — the Bridge family, and the first family with BOTH receivers in
    // one file. `bridgeLoopsPaired`/`bridgeLoops`/`bridgeLoopsSpans`/
    // `bridgeStripPaired`/`bridgeOpenRows` mutate and take the batch;
    // `facesBoundedByLoop` and the three pairing helpers read and take
    // `ref const(Mesh)`. Both halves are pinned, because the interesting
    // regression is a mutating kernel drifting to the const receiver (it cannot
    // compile) or a read-only one drifting to the batch (it can, and it would
    // publish a change for a lookup that changes nothing).
    immutable brPath = buildPath(repoRoot, "source", "mesh_ops", "bridge.d");
    assert(exists(brPath), "cannot find source/mesh_ops/bridge.d at " ~ brPath);
    immutable br = stripCommentsAndStrings(readText(brPath));
    assert(countOccurrences(br, "mixin template MeshBridgeOps") == 0,
        "source/mesh_ops/bridge.d still declares `mixin template MeshBridgeOps` "
      ~ "— Stage D3 converted this family to free functions; a surviving "
      ~ "template is either dead or a second implementation (task 1903 Stage D3).");

    // WHAT THIS ROSTER DOES **NOT** COVER, and it is a convention, not an
    // oversight (Stage D3 review, forward note F-3): a converted helper with NO
    // RECEIVER AT ALL — `ceilDivHalfDown` here, and its class in later stages —
    // cannot have a receiver row, because there is no `(ref X y,` to pin. Those
    // names are held by the `static assert(!__traits(hasMember, Mesh, n))`
    // tripwire at the foot of `source/mesh_ops/bridge.d`, which lists EVERY
    // family name including the receiver-less ones and fires at `dub build`
    // time. So: absent from this roster is not unguarded — it means "guarded
    // over there". A later stage must add its receiver-less helpers to that
    // `static foreach` list, not invent a receiver for them here. Stage E1's
    // instance of the same class is a TYPE, not a function: `CollapsedFace_`
    // was a private nested struct the mixin injected into `Mesh`, it has no
    // signature to pin, and it is held by cleanup.d's own tripwire list.
    //
    // THE MUTATING RECEIVERS, each pinned WITH its parameter name AND the
    // delimiter after it. `ed` is not decoration: plan §4.3 step 3 requires one
    // stable name across the family because a kernel's nested functions capture
    // the enclosing parameter the way they used to capture `this` — this file
    // has three (`edgeAdjSubpatch`, one per face-emitting kernel) plus `base`
    // in `bridgeTwistedVertex`. Without the trailing `,` the needle is a PREFIX
    // and `ed` -> `edb` stays green (measured at D2, MINOR-1).
    static immutable string[] kBatchKernels = [
        "bridgeLoopsPaired", "bridgeLoops", "bridgeLoopsSpans",
        "bridgeStripPaired", "bridgeOpenRows", "bridgeFanRows",
    ];
    foreach (name; kBatchKernels)
        assert(countOccurrences(br, name ~ "(ref MeshEditBatch ed,") == 1,
            format("source/mesh_ops/bridge.d no longer declares `%s` over "
                 ~ "`ref MeshEditBatch ed`. That receiver is the enforcement, "
                 ~ "not the style: it is what makes a batchless call a COMPILE "
                 ~ "error, so one bridge stamps, derives and delivers once at "
                 ~ "close() instead of once per addFace/addVertex — and it is "
                 ~ "what the remaining intra-Mesh caller (Mesh.thickenSurface, "
                 ~ "removed at stage L2) has to open a transitional batch for. "
                 ~ "The second such caller, mesh_ops/revolve.d, lost its "
                 ~ "transitional batch at Stage E2 (task 1903 §4.1, §5.2 D3)."
                 , name));

    // …and the two wrong spellings, absent. A `ref Mesh` receiver would compile
    // and would silently take the batch away — the exact regression the rows
    // above exist to stop, and one no behavioural test in the tree can see
    // while this family's undo is still a whole-mesh snapshot.
    foreach (name; kBatchKernels) {
        assert(countOccurrences(br, name ~ "(ref Mesh ") == 0,
            format("`%s` has a `ref Mesh` receiver again — that compiles, and "
                 ~ "it drops the batch: the kernel's internal commits go back "
                 ~ "to stamping one per appended face. If this is deliberate it "
                 ~ "is an argument to make here, not a mechanical follow-on "
                 ~ "(task 1903 Stage D3).", name));
        assert(countOccurrences(br, name ~ "(ref const(Mesh)") == 0,
            format("`%s` cannot have a `ref const(Mesh)` receiver — it appends "
                 ~ "faces and stamps subpatch words. Such an overload could "
                 ~ "only exist by casting const away (task 1903 Stage D3).",
                   name));
    }

    // THE READ-ONLY RECEIVERS, same discipline. `facesBoundedByLoop` is the one
    // that matters outside this file: `tools/edit/bridge_tool.d`'s
    // `facesMatchingLoop` holds a `const ref Mesh` and could not call a batch
    // receiver at all, so the const cell is what keeps that call site compiling
    // verbatim.
    static immutable string[] kConstHelpers = [
        "facesBoundedByLoop", "pairBridgeLoop", "bridgeTwistedVertex",
        "orientOpenChainB",
    ];
    foreach (name; kConstHelpers) {
        assert(countOccurrences(br, name ~ "(ref const(Mesh) m,") == 1,
            format("source/mesh_ops/bridge.d no longer declares `%s` over "
                 ~ "`ref const(Mesh) m`. These four only READ positions to "
                 ~ "decide a pairing or a lookup; the const receiver is what "
                 ~ "states that, and for `facesBoundedByLoop` it is also what "
                 ~ "keeps `m.facesBoundedByLoop(loop)` compiling from a "
                 ~ "`const ref Mesh` in bridge_tool.d (task 1903 Stage D3, "
                 ~ "plan §4.1).", name));
        assert(countOccurrences(br, name ~ "(ref MeshEditBatch") == 0,
            format("`%s` took a `ref MeshEditBatch` receiver — that compiles, "
                 ~ "and it means a call that changes nothing now opens an edit "
                 ~ "batch and publishes a change. If a later stage wants that, "
                 ~ "it is a decision to argue for here (task 1903 Stage D3).",
                   name));
    }

    // The span cap left `struct Mesh` with the family (plan §2.7, §11: "keep it
    // an `enum` in the ops module after conversion"). Three test sites spelled
    // it `Mesh.maxBridgeSpans` and moved in the same commit.
    assert(countOccurrences(br, "enum size_t maxBridgeSpans = 512;") == 1,
        "source/mesh_ops/bridge.d no longer declares `maxBridgeSpans` at module "
      ~ "scope — it is the KERNEL layer of this family's two-layer DoS clamp "
      ~ "(the Param's `.min`/`.max` are UI hints and do not clamp the headless "
      ~ "path), and the mixin used to inject it into `Mesh` (task 1903 Stage D3, "
      ~ "plan §2.7 / §11).");

    // §5.7 over this file, under the SAME predicate decimate is measured with.
    // Expected 0, and 0 here is not a retirement but a statement about the
    // family: no bridge kernel moves an EXISTING vertex — every coordinate it
    // produces belongs to a vertex it created in the same call, which is why
    // `kBridgeEditScope` carries no `Position` bit. The behavioural twin of
    // this row is the `Kind.SetPos == 0` assertion in
    // tests/unit/mesh_ops/bridge_test.d's recording block.
    {
        string firstHit;
        immutable size_t rawWrites = countRawPositionWrites(br, firstHit);
        assert(rawWrites == 0,
            format("source/mesh_ops/bridge.d: %d raw position write(s) under "
                 ~ "§5.7's predicate, expected 0 — this family had none before "
                 ~ "the conversion and must gain none through it. First hit: "
                 ~ "`%s`. `alias mesh this` means `ed.vertices[i] = p` COMPILES "
                 ~ "inside a recording batch and records nothing, which is why "
                 ~ "the boundary is a counted census and not a type "
                 ~ "(task 1903 §5.7, M-V1).", rawWrites, firstHit));
    }

    // Stage E1 — the mesh-hygiene / orientation-repair family. Four mutating
    // entries over the batch, three read-only detectors `mesh_analysis.d`
    // SHARES over `ref const(Mesh)`, and that sharing is why the const half
    // matters more here than anywhere so far: `mesh_analysis.degenerateFaceIndices`
    // and friends hold a `const ref Mesh` and could not call a batch receiver
    // at all, so a detector drifting to `ref MeshEditBatch` would not merely
    // publish a change for a read — it would break the "the fix and the
    // detector call the SAME code" contract task 0402 built this family on.
    //
    // NO §2.6 WIDENING ROW: this stage widened nothing, and that is checkable
    // rather than assertable here. Every `Mesh` name cleanup.d reaches was
    // already public before this commit, and the PROOF is that the module now
    // compiles as its own translation unit with no mixin instantiation scope
    // behind it — a missed widening is a `dub build` error, not a silent pass.
    // Nor does it inherit anyone else's row: it calls none of §2.6's eleven
    // names. (D3's own drill M-W2 added a fake `orientFaceConsistent(` call to
    // THIS file to prove the caller-set scan below reddens; the scan walks
    // `source/**`, so it still would.)
    immutable clPath = buildPath(repoRoot, "source", "mesh_ops", "cleanup.d");
    assert(exists(clPath), "cannot find source/mesh_ops/cleanup.d at " ~ clPath);
    immutable cl = stripCommentsAndStrings(readText(clPath));
    assert(countOccurrences(cl, "mixin template MeshCleanupOps") == 0,
        "source/mesh_ops/cleanup.d still declares `mixin template "
      ~ "MeshCleanupOps` — Stage E1 converted this family to free functions; "
      ~ "a surviving template is either dead or a second implementation "
      ~ "(task 1903 Stage E1).");

    // THE MUTATING RECEIVERS. Three of the four take NO other parameter, so
    // the delimiter that keeps the needle from being a mere PREFIX is `)`,
    // not `,` (D2 review MINOR-1: without a delimiter, renaming `ed` -> `edb`
    // leaves the pin green). `cleanupMesh` does take a second parameter and
    // uses `,` like the D2/D3 rows.
    static immutable string[] kNullaryBatchKernels = [
        "unifyFaces", "cleanDegenerateFaces", "fixFaceOrientation",
    ];
    foreach (name; kNullaryBatchKernels)
        assert(countOccurrences(cl, name ~ "(ref MeshEditBatch ed)") == 1,
            format("source/mesh_ops/cleanup.d no longer declares `%s` over "
                 ~ "`ref MeshEditBatch ed`. That receiver is the enforcement, "
                 ~ "not the style: it is what makes a batchless call a COMPILE "
                 ~ "error, so one hygiene sweep stamps, derives and delivers "
                 ~ "once at close() instead of once per internal commit "
                 ~ "(deleteFacesByMask, rewriteFaces, each compactUnreferenced) "
                 ~ "(task 1903 §4.1, §5.2 E1).", name));
    assert(countOccurrences(cl,
            "cleanupMesh(ref MeshEditBatch ed, CleanupOptions o") == 1,
        "source/mesh_ops/cleanup.d no longer declares `cleanupMesh` over "
      ~ "`ref MeshEditBatch ed` with its CleanupOptions second parameter. That "
      ~ "receiver is the enforcement, not the style, and this is the caller "
      ~ "with the most to gain: a default sweep runs six committing stages "
      ~ "inside one frame (task 1903 §4.1, §5.2 E1).");

    // …and the two wrong spellings, absent, for all four.
    static immutable string[] kBatchKernelsE1 = [
        "unifyFaces", "cleanDegenerateFaces", "cleanupMesh",
        "fixFaceOrientation",
    ];
    foreach (name; kBatchKernelsE1) {
        assert(countOccurrences(cl, name ~ "(ref Mesh ") == 0,
            format("`%s` has a `ref Mesh` receiver again — that compiles, and "
                 ~ "it drops the batch: the kernel's internal commits go back "
                 ~ "to stamping one at a time. If this is deliberate it is an "
                 ~ "argument to make here, not a mechanical follow-on "
                 ~ "(task 1903 Stage E1).", name));
        assert(countOccurrences(cl, name ~ "(ref const(Mesh)") == 0,
            format("`%s` cannot have a `ref const(Mesh)` receiver — it drops "
                 ~ "or reshapes faces and compacts vertices away. Such an "
                 ~ "overload could only exist by casting const away "
                 ~ "(task 1903 Stage E1).", name));
    }

    // THE READ-ONLY RECEIVERS. `computeDuplicateFaceMask` and the nullary
    // `computeOrientationFlipMask` overload take the receiver ALONE, so their
    // delimiter is `)`; `isFaceDegenerate`, the bool overload and the two
    // private helpers take a second parameter and use `,`.
    foreach (name; ["computeDuplicateFaceMask", "computeOrientationFlipMask"])
        assert(countOccurrences(cl, name ~ "(ref const(Mesh) m)") == 1,
            format("source/mesh_ops/cleanup.d no longer declares `%s` over "
                 ~ "`ref const(Mesh) m` in its receiver-only form. These are "
                 ~ "the detectors source/mesh_analysis.d shares with the "
                 ~ "mutating fixes, and it holds a `const ref Mesh`: a batch "
                 ~ "receiver could not be called from there at all "
                 ~ "(task 1903 Stage E1, plan §4.1).", name));
    foreach (name; ["isFaceDegenerate", "computeCollapsedFace_",
                    "faceAreaApprox_"])
        assert(countOccurrences(cl, name ~ "(ref const(Mesh) m,") == 1,
            format("source/mesh_ops/cleanup.d no longer declares `%s` over "
                 ~ "`ref const(Mesh) m`. It only READS faces and positions to "
                 ~ "decide; the const receiver is what states that, and it is "
                 ~ "now ENFORCED at the seam rather than by a keyword the "
                 ~ "mixin could have dropped at any time "
                 ~ "(task 1903 Stage E1).", name));
    assert(countOccurrences(cl,
            "computeOrientationFlipMask(ref const(Mesh) m, bool restrictToSelection)") == 1,
        "source/mesh_ops/cleanup.d no longer declares the two-argument "
      ~ "`computeOrientationFlipMask` overload over `ref const(Mesh) m` — that "
      ~ "is the one `mesh_analysis.inconsistentWindingFaces` calls with "
      ~ "`false` so an analyze under an active selection still reports winding "
      ~ "problems in unselected components (task 0402 Phase 4 review S2, "
      ~ "task 1903 Stage E1).");
    foreach (name; ["computeDuplicateFaceMask", "isFaceDegenerate",
                    "computeOrientationFlipMask", "computeCollapsedFace_",
                    "faceAreaApprox_"])
        assert(countOccurrences(cl, name ~ "(ref MeshEditBatch") == 0,
            format("`%s` took a `ref MeshEditBatch` receiver — that compiles, "
                 ~ "and it means a call that changes nothing now opens an edit "
                 ~ "batch and publishes a change. It also makes the detector "
                 ~ "uncallable from source/mesh_analysis.d, which holds a "
                 ~ "`const ref Mesh` (task 1903 Stage E1).", name));

    // The family's declared scope lives ONCE, beside the kernels, for the
    // reason D2 gave for kReduceEditScope: N copies at N call sites is N
    // chances to drift, and the one that drifts is the one that stops matching
    // MeshEditDelta.scope_ when track 2 turns this family's undo into a delta.
    // The BEHAVIOURAL half — that the value is right, written out from the
    // enum independently — is in tests/unit/mesh_ops/cleanup_test.d's
    // recording block; this row only pins that there is one of it.
    assert(countOccurrences(cl, "enum uint kCleanupEditScope =") == 1,
        "source/mesh_ops/cleanup.d no longer declares `kCleanupEditScope` at "
      ~ "module scope — the three commands and every test batch pass it, and a "
      ~ "per-call-site literal is the drift this constant exists to prevent "
      ~ "(task 1903 Stage E1).");

    // §5.7 over this file, under the SAME predicate decimate and bridge are
    // measured with. Expected 0, and 0 here is not a retirement but a
    // statement about the family: no cleanup kernel moves an EXISTING vertex.
    // A weld keeps the survivor's own coordinates, a dissolve and a compaction
    // only DROP vertices, and the degenerate pass never touches `vertices`.
    // That is why `kCleanupEditScope` carries no `Position` bit, and the
    // behavioural twin of this row is the `Kind.SetPos == 0` assertion in
    // tests/unit/mesh_ops/cleanup_test.d's recording block.
    {
        string firstHit;
        immutable size_t rawWrites = countRawPositionWrites(cl, firstHit);
        assert(rawWrites == 0,
            format("source/mesh_ops/cleanup.d: %d raw position write(s) under "
                 ~ "§5.7's predicate, expected 0 — this family had none before "
                 ~ "the conversion and must gain none through it. First hit: "
                 ~ "`%s`. `alias mesh this` means `ed.vertices[i] = p` COMPILES "
                 ~ "inside a recording batch and records nothing, which is why "
                 ~ "the boundary is a counted census and not a type "
                 ~ "(task 1903 §5.7, M-V1).", rawWrites, firstHit));
    }

    // Stage E2 — the Radial Sweep / Revolve + Path-follow extrude family, and
    // the first stage whose job included DELETING a batch rather than adding
    // one. Three receiver shapes live in this one file (§4.1's first two cells
    // plus a receiver-less pair), and the rows below pin all three, because
    // each drifts in a different direction: a mutating kernel to `ref Mesh`
    // (compiles, silently drops the batch), a read-only helper to the batch
    // (compiles, publishes a change for a call that changes nothing), and a
    // pure predicate back to a `static` member of `Mesh` (which the tripwire
    // at the foot of revolve.d catches, not this roster).
    immutable rvPath = buildPath(repoRoot, "source", "mesh_ops", "revolve.d");
    assert(exists(rvPath), "cannot find source/mesh_ops/revolve.d at " ~ rvPath);
    immutable rv = stripCommentsAndStrings(readText(rvPath));
    assert(countOccurrences(rv, "mixin template MeshRevolveOps") == 0,
        "source/mesh_ops/revolve.d still declares `mixin template "
      ~ "MeshRevolveOps` — Stage E2 converted this family to free functions; a "
      ~ "surviving template is either dead or a second implementation "
      ~ "(task 1903 Stage E2).");

    // THE MUTATING RECEIVERS. All four take at least one further parameter, so
    // the delimiter is `,` (E1's three nullary kernels needed `)` instead).
    // Without a delimiter the needle is a PREFIX and `ed` -> `edb` stays green
    // (measured at D2, MINOR-1).
    static immutable string[] kBatchKernelsE2 = [
        "revolveProfile", "revolveProfileEx", "extrudePathStep_",
        "extrudeAlongPath",
    ];
    foreach (name; kBatchKernelsE2)
        assert(countOccurrences(rv, name ~ "(ref MeshEditBatch ed,") == 1,
            format("source/mesh_ops/revolve.d no longer declares `%s` over "
                 ~ "`ref MeshEditBatch ed`. That receiver is the enforcement, "
                 ~ "not the style: it is what makes a batchless call a COMPILE "
                 ~ "error — and on THIS family it is also what let the "
                 ~ "transitional batch Stage D3 had to open inside "
                 ~ "`revolveProfileEx` be deleted, because the batch now "
                 ~ "arrives from the caller (task 1903 §4.1, §4.4a, §5.2 E2).",
                   name));

    // …and the two wrong spellings, absent, for all four. Note that
    // `revolveProfile` is a PREFIX of `revolveProfileEx`, so a `ref Mesh`
    // overload of the latter would also satisfy a needle written for the
    // former — the trailing `(` in each needle is what keeps the two rows
    // independent.
    foreach (name; kBatchKernelsE2) {
        assert(countOccurrences(rv, name ~ "(ref Mesh ") == 0,
            format("`%s` has a `ref Mesh` receiver again — that compiles, and "
                 ~ "it drops the batch: the kernel's internal commits go back "
                 ~ "to stamping one per appended face. Plan §4.4a REJECTED "
                 ~ "exactly this overload for the in-mesh callers, by name, "
                 ~ "because nothing in the two lanes can see it — the geometry "
                 ~ "is identical and the receiver pin is satisfied by the "
                 ~ "`ref MeshEditBatch` overload that still exists. This row is "
                 ~ "the one thing that can (task 1903 Stage E2).", name));
        assert(countOccurrences(rv, name ~ "(ref const(Mesh)") == 0,
            format("`%s` cannot have a `ref const(Mesh)` receiver — it appends "
                 ~ "vertices and faces and rewrites the selection. Such an "
                 ~ "overload could only exist by casting const away "
                 ~ "(task 1903 Stage E2).", name));
    }

    // THE READ-ONLY RECEIVER — one, and it is the align-to-path pivot
    // `maskVertexCentroid_`. It only averages positions, and it was NOT a
    // `const` member before the conversion: nothing in a mixin body forces the
    // keyword. The const receiver here is therefore a widening of what the code
    // already did, now ENFORCED at the seam.
    assert(countOccurrences(rv, "maskVertexCentroid_(ref const(Mesh) m,") == 1,
        "source/mesh_ops/revolve.d no longer declares `maskVertexCentroid_` "
      ~ "over `ref const(Mesh) m`. It only READS faces and positions to average "
      ~ "a pivot; the const receiver is what states that, and it is the half of "
      ~ "§4.1 that a family with no const members would otherwise never grow "
      ~ "(task 1903 Stage E2).");
    assert(countOccurrences(rv, "maskVertexCentroid_(ref MeshEditBatch") == 0,
        "`maskVertexCentroid_` took a `ref MeshEditBatch` receiver — that "
      ~ "compiles, and it means a call that changes nothing now opens an edit "
      ~ "batch and publishes a change (task 1903 Stage E2).");

    // THE RECEIVER-LESS PAIR. `revolveSweepClosed` /
    // `revolveSweepClosedWithOffset` were `static` members reading no mesh
    // state at all, so they have no receiver row in the sense the others do —
    // what IS pinned is that they are still free functions here and did not
    // acquire one. `RadialSweepTool.toKernelParams` calls the second by its
    // bare name and is the ONLY decision point outside this file that must
    // agree with the kernel about what "closed" means.
    foreach (name; ["revolveSweepClosed(float angle)",
                    "revolveSweepClosedWithOffset(float angle, float offset)"])
        assert(countOccurrences(rv, "bool " ~ name) == 1,
            format("source/mesh_ops/revolve.d no longer declares `%s` as a "
                 ~ "plain module function. These two read no mesh state — they "
                 ~ "answer a question about an angle and an offset — and they "
                 ~ "are the single source of truth the tool layer's Count "
                 ~ "translation shares with the kernel's own wrap-bridge and "
                 ~ "cap-eligibility decisions (task 0326 review S1, task 1903 "
                 ~ "Stage E2).", name));

    // THE PARAMETER STRUCT MOVED TO MODULE SCOPE (§2.7, the route D3's
    // `maxBridgeSpans` took). `Mesh.RevolveParams` no longer resolves; the five
    // call sites that spelled it that way moved in the same commit, and the
    // `static assert(!__traits(hasMember, Mesh, "RevolveParams"))` at the foot
    // of revolve.d is what refuses an `alias` putting it back on the struct.
    assert(countOccurrences(rv, "\nstruct RevolveParams {") == 1,
        "source/mesh_ops/revolve.d no longer declares `struct RevolveParams` at "
      ~ "MODULE scope (column 0). The mixin used to inject it into `Mesh`, and "
      ~ "`tools/alignment/radial_sweep_tool.d` plus two tests spelled it "
      ~ "`Mesh.RevolveParams`; those call sites moved with this commit "
      ~ "(task 1903 Stage E2, plan §2.7).");

    // THE DEBT THIS STAGE PAID OFF, pinned as an ABSENCE. Stage D3 had to open
    // a `MeshEditBatch` INSIDE `revolveProfileEx` because the Bridge kernels had
    // crossed the seam while this file was still a mixin (plan §4.4a's fourth
    // cell). E2 removed it. A kernel opening a batch is what §2.3 rule 2
    // forbids, and no behavioural test can see it come back on the CLOSED
    // profile — `nestedBatchOpens` only ticks when a CALLER already holds one,
    // and `tests/test_mesh_sweep.d`'s delta is the suite half of that. This row
    // is the text half: the string must not appear in this file at all.
    assert(countOccurrences(rv, "MeshEditBatch.unrecorded(") == 0,
        "source/mesh_ops/revolve.d opens a `MeshEditBatch` of its own again. A "
      ~ "KERNEL never opens a batch — the command or the tool does (plan §4.1, "
      ~ "§2.3 rule 2). Stage D3 had to break that rule here, because "
      ~ "`revolveProfileEx` called the already-converted `bridgeLoopsPaired` "
      ~ "from inside `struct Mesh` with no caller-held batch to take; Stage E2 "
      ~ "gave the kernel a `ref MeshEditBatch` receiver and DELETED the "
      ~ "transitional block. If a new intra-kernel batch is genuinely needed, "
      ~ "§4.4a says what it costs: a TRANSITIONAL label, a named removing "
      ~ "stage, and a per-command nestedBatchOpens DELTA assert in that "
      ~ "command's own suite test (task 1903 Stage E2).");

    // The family's declared scope lives ONCE, beside the kernels — D2's reason
    // for `kReduceEditScope`, and this family has SIX call sites passing it
    // (two commands, three RadialSweepTool sites, one StrokeExtrudeTool drag
    // frame) plus the two test helpers, so it is the family with the most
    // chances to drift. The BEHAVIOURAL half — that the value is right, written
    // out from the enum independently — is in
    // tests/unit/mesh_ops/revolve_test.d's recording block; this row only pins
    // that there is one of it.
    assert(countOccurrences(rv, "enum uint kRevolveEditScope =") == 1,
        "source/mesh_ops/revolve.d no longer declares `kRevolveEditScope` at "
      ~ "module scope — six production call sites and two test helpers pass it, "
      ~ "and a per-call-site literal is the drift this constant exists to "
      ~ "prevent (task 1903 Stage E2).");

    // §5.7 over this file, under the SAME predicate decimate, bridge and
    // cleanup are measured with. Expected 0, and 0 here is not a retirement but
    // a statement about the family: neither kernel moves an EXISTING vertex.
    // Every coordinate they produce belongs to a vertex created in the same
    // call — `buildRing`'s `ed.addVertex(pos)` and `extrudePathStep_`'s
    // per-(island,vertex) clone — which is why `kRevolveEditScope` carries no
    // `Position` bit. The behavioural twin of this row is the
    // `Kind.SetPos == 0` assertion in revolve_test.d's recording block.
    {
        string firstHit;
        immutable size_t rawWrites = countRawPositionWrites(rv, firstHit);
        assert(rawWrites == 0,
            format("source/mesh_ops/revolve.d: %d raw position write(s) under "
                 ~ "§5.7's predicate, expected 0 — this family had none before "
                 ~ "the conversion and must gain none through it. First hit: "
                 ~ "`%s`. `alias mesh this` means `ed.vertices[i] = p` COMPILES "
                 ~ "inside a recording batch and records nothing, which is why "
                 ~ "the boundary is a counted census and not a type "
                 ~ "(task 1903 §5.7, M-V1).", rawWrites, firstHit));
    }

    // Stage E3 — the plane-cut family, and the FIRST family to bring a raw
    // position write across the seam with it. Three things are pinned here that
    // no earlier stage needed: a mutating receiver on EIGHT entries (the family
    // is a wrapper fan over one core), a nested type that moved to module scope
    // WITHOUT an in-struct alias, and a `setVertexPositions` call that replaced
    // two writes §5.7's own predicate could not see until this stage widened it.
    immutable ctPath = buildPath(repoRoot, "source", "mesh_ops", "cut.d");
    assert(exists(ctPath), "cannot find source/mesh_ops/cut.d at " ~ ctPath);
    immutable ct = stripCommentsAndStrings(readText(ctPath));
    assert(countOccurrences(ct, "mixin template MeshCutOps") == 0,
        "source/mesh_ops/cut.d still declares `mixin template MeshCutOps` — "
      ~ "Stage E3 converted this family to free functions; a surviving template "
      ~ "is either dead or a second implementation (task 1903 Stage E3).");

    // THE MUTATING RECEIVERS. All eight take at least one further parameter, so
    // the delimiter is `,`. Without a delimiter the needle is a PREFIX and
    // `ed` -> `edb` stays green (measured at D2, MINOR-1). Note also that
    // `cutByPlane` is a PREFIX of four of the others, so the `(` in each needle
    // is what keeps these rows independent of one another.
    static immutable string[] kBatchKernelsE3 = [
        "cutByPlane", "cutByPlaneRestricted", "cutByPlaneClipped",
        "cutByPlaneEx", "cutByPlaneSplitGap", "deleteComponentsInSlab",
        "planeCutCore", "splitAlongCutLoop",
    ];
    foreach (name; kBatchKernelsE3)
        assert(countOccurrences(ct, name ~ "(ref MeshEditBatch ed,") == 1,
            format("source/mesh_ops/cut.d no longer declares `%s` over "
                 ~ "`ref MeshEditBatch ed`. That receiver is the enforcement, "
                 ~ "not the style: it is what makes a batchless call a COMPILE "
                 ~ "error, so one plane cut stamps, derives and delivers once at "
                 ~ "close() instead of once per inserted crossing vertex and "
                 ~ "once per face-array rebuild — and on THIS family it is also "
                 ~ "the only thing the recorded `setVertexPositions` write in "
                 ~ "splitAlongCutLoop has to record INTO (task 1903 §4.1, "
                 ~ "§5.2 E3).", name));

    // …and the two wrong spellings, absent, for all eight.
    foreach (name; kBatchKernelsE3) {
        assert(countOccurrences(ct, name ~ "(ref Mesh ") == 0,
            format("`%s` has a `ref Mesh` receiver again — that compiles, and "
                 ~ "it drops the batch: the kernel's internal commits go back to "
                 ~ "stamping one at a time, and `setVertexPositions` is not even "
                 ~ "reachable from a bare mesh, so the gap block would have to "
                 ~ "go back to the raw `vertices[pr[0]] = …` write. Plan §4.4a "
                 ~ "REJECTED exactly this overload, by name, because nothing in "
                 ~ "the two lanes can see it — the geometry is identical and the "
                 ~ "receiver pin is satisfied by the `ref MeshEditBatch` "
                 ~ "overload that still exists. This row is the one thing that "
                 ~ "can (task 1903 Stage E3).", name));
        assert(countOccurrences(ct, name ~ "(ref const(Mesh)") == 0,
            format("`%s` cannot have a `ref const(Mesh)` receiver — it inserts "
                 ~ "crossing vertices, rewrites windings and deletes faces. Such "
                 ~ "an overload could only exist by casting const away "
                 ~ "(task 1903 Stage E3).", name));
    }

    // THE READ-ONLY RECEIVERS — two. `isConcaveFace` WAS a `const` member;
    // `extractCutLoops` was NOT, and nothing in a mixin body forces the keyword,
    // so its const receiver is a widening of what the code already did, now
    // ENFORCED at the seam. Both are called from a batch context as
    // `f(ed.mesh, …)` (the spelling E1 settled for `computeCollapsedFace_`),
    // which is why they are the two entries that must NOT drift to the batch.
    foreach (name; ["isConcaveFace", "extractCutLoops"]) {
        assert(countOccurrences(ct, name ~ "(ref const(Mesh) m,") == 1,
            format("source/mesh_ops/cut.d no longer declares `%s` over "
                 ~ "`ref const(Mesh) m`. `isConcaveFace` only walks one winding "
                 ~ "to look for a reflex corner and `extractCutLoops` only walks "
                 ~ "`edges` against a cut mask; the const receiver is what "
                 ~ "states that, and it is now ENFORCED at the seam rather than "
                 ~ "by a keyword the mixin could have dropped at any time "
                 ~ "(task 1903 Stage E3, plan §4.1).", name));
        assert(countOccurrences(ct, name ~ "(ref MeshEditBatch") == 0,
            format("`%s` took a `ref MeshEditBatch` receiver — that compiles, "
                 ~ "and it means a call that changes nothing now opens an edit "
                 ~ "batch and publishes a change. If a later stage wants that, "
                 ~ "it is a decision to argue for here (task 1903 Stage E3).",
                   name));
    }

    // THE RESULT TYPE MOVED TO MODULE SCOPE (§2.7 as rewritten at the E2 review;
    // the route D3's `maxBridgeSpans` and E2's `RevolveParams` took).
    // `Mesh.PlaneCutLoops` no longer resolves; the 11 call sites that spelled it
    // that way — 3 in tools/slice/slice_tool.d, 7 in
    // tests/unit/mesh_ops/cut_test.d, 1 in
    // tests/unit/tools/slice/slice_tool_test.d — moved in the same commit. The
    // `static assert(!__traits(hasMember, Mesh, "PlaneCutLoops"))` at the foot
    // of cut.d is what refuses an `alias` putting it back on the struct, and it
    // has to: measured at E2, an in-struct alias makes `Mesh.X` resolve AND
    // makes `hasMember` answer `true`, so the alias and the tripwire cannot both
    // stand.
    assert(countOccurrences(ct, "\nstruct PlaneCutLoops {") == 1,
        "source/mesh_ops/cut.d no longer declares `struct PlaneCutLoops` at "
      ~ "MODULE scope (column 0). The mixin used to inject it into `Mesh`, and "
      ~ "`tools/slice/slice_tool.d` plus two test modules spelled it "
      ~ "`Mesh.PlaneCutLoops`; those call sites moved with this commit "
      ~ "(task 1903 Stage E3, plan §2.7).");

    // The family's declared scope lives ONCE, beside the kernels — D2's reason
    // for `kReduceEditScope`. This family has SEVEN production call sites
    // passing it (two commands, five in tools/slice/slice_tool.d) plus the two
    // module unittests below and the test helpers, so it has as many chances to
    // drift as revolve did. The BEHAVIOURAL half — that the value is right,
    // written out from the enum independently — is in
    // tests/unit/mesh_ops/cut_test.d's recording block; this row only pins that
    // there is one of it.
    assert(countOccurrences(ct, "enum uint kCutEditScope =") == 1,
        "source/mesh_ops/cut.d no longer declares `kCutEditScope` at module "
      ~ "scope — seven production call sites pass it, and a per-call-site "
      ~ "literal is the drift this constant exists to prevent "
      ~ "(task 1903 Stage E3).");

    // A KERNEL NEVER OPENS A BATCH (§4.1, §2.3 rule 2) — the absence pin, and
    // this file cannot use revolve.d's `== 0` spelling because cut.d keeps TWO
    // module unittests that legitimately open one. So the pin is two-sided: the
    // TOTAL must be 2, and BOTH must be the unittest spelling. A kernel that
    // opened its own would take the total to 3; one that replaced a unittest's
    // would keep the total and drop the shaped count.
    assert(countOccurrences(ct, "MeshEditBatch.unrecorded(") == 2,
        format("source/mesh_ops/cut.d opens %d `MeshEditBatch`(es); expected "
             ~ "exactly 2, both in the module unittests at the foot of the file. "
             ~ "A KERNEL never opens a batch — the command or the tool does "
             ~ "(plan §4.1, §2.3 rule 2). If a new intra-kernel batch is "
             ~ "genuinely needed, §4.4a says what it costs: a TRANSITIONAL "
             ~ "label, a named removing stage, and a per-command "
             ~ "nestedBatchOpens DELTA assert in that command's own suite test "
             ~ "(task 1903 Stage E3).",
               countOccurrences(ct, "MeshEditBatch.unrecorded(")));
    assert(countOccurrences(ct,
            "auto ed = MeshEditBatch.unrecorded(m, kCutEditScope);") == 2,
        "the two `MeshEditBatch.unrecorded` opens in source/mesh_ops/cut.d are "
      ~ "no longer the two module unittests' — they are the only opens this "
      ~ "file is allowed, and the row above only counts them. One of them now "
      ~ "has a different subject or a different scope, which means a KERNEL is "
      ~ "opening it (task 1903 Stage E3).");

    // §5.7 over this file — and unlike decimate / bridge / cleanup / revolve,
    // this 0 is a RETIREMENT, not a statement that the family never had one.
    // `splitAlongCutLoop`'s gap block moved both members of every seam pair with
    // `vertices[pr[0]] = …`, and the predicate could not see a NESTED index
    // expression until this stage widened it (see kPosWritePredicate's own
    // comment and its two new positive controls). Both writes are one
    // `ed.setVertexPositions` now.
    assert(countOccurrences(ct, "ed.setVertexPositions(") == 1,
        "source/mesh_ops/cut.d no longer calls `setVertexPositions` — the Gap "
      ~ "option's seam separation is the raw `vertices[pr[0]] = …` write again, "
      ~ "and a raw write inside a recording batch produces NO op-log entry: a "
      ~ "delta undo would restore the topology and leave both halves of every "
      ~ "split edge at their pushed-apart coordinates (task 1903 §2.5, §5.7).");
    {
        string firstHit;
        immutable size_t rawWrites = countRawPositionWrites(ct, firstHit);
        assert(rawWrites == 0,
            format("source/mesh_ops/cut.d: %d raw position write(s) under "
                 ~ "§5.7's predicate, expected 0 — this entry was retired at "
                 ~ "Stage E3. First hit: `%s`. `alias mesh this` means "
                 ~ "`ed.vertices[i] = p` COMPILES inside a recording batch and "
                 ~ "records nothing, which is why the boundary is a counted "
                 ~ "census and not a type (task 1903 §5.7, M-V1).",
                   rawWrites, firstHit));
    }

    // ---------------------------------------------------------------------
    // Stage E4 — TWO families in one commit (plan §12's E4 row pairs them), and
    // the FIRST track-1 stage whose converted kernels are called from inside a
    // still-MIXIN sibling. Three things are pinned here that no earlier stage
    // needed:
    //
    //   * a family with NO read-only entry and NO batch of its own, whose only
    //     caller is `mesh_ops/edge_bevel.d` (Stage G) — so §4.4a's fourth cell
    //     applies and the batch is a TRANSITIONAL debt at the CALLER, pinned
    //     below by its exact spelling and its count;
    //   * a nested type moved to module scope that had ZERO outside call sites
    //     (`VertexBevelCorner`) — the §2.7 rule still applies, and the in-struct
    //     `alias` it forbids is refused by bevel_vertex.d's own tripwire;
    //   * two §2.6 widenings whose caller sets include files that are STILL
    //     mixins (extrude.d, edge_bevel.d) — see the widenings block below.
    // ---------------------------------------------------------------------
    immutable bfPath = buildPath(repoRoot, "source", "mesh_ops", "bevel_fin.d");
    assert(exists(bfPath), "cannot find source/mesh_ops/bevel_fin.d at " ~ bfPath);
    immutable bf = stripCommentsAndStrings(readText(bfPath));
    assert(countOccurrences(bf, "mixin template MeshBevelFinOps") == 0,
        "source/mesh_ops/bevel_fin.d still declares `mixin template "
      ~ "MeshBevelFinOps` — Stage E4 converted this family to free functions; a "
      ~ "surviving template is either dead or a second implementation "
      ~ "(task 1903 Stage E4).");

    immutable bvPath = buildPath(repoRoot, "source", "mesh_ops", "bevel_vertex.d");
    assert(exists(bvPath), "cannot find source/mesh_ops/bevel_vertex.d at " ~ bvPath);
    immutable bv = stripCommentsAndStrings(readText(bvPath));
    assert(countOccurrences(bv, "mixin template MeshBevelVertexOps") == 0,
        "source/mesh_ops/bevel_vertex.d still declares `mixin template "
      ~ "MeshBevelVertexOps` — Stage E4 converted this family to free "
      ~ "functions; a surviving template is either dead or a second "
      ~ "implementation (task 1903 Stage E4).");

    // THE MUTATING RECEIVERS — three across the two files, all with the
    // load-bearing trailing comma (D2 review, MINOR-1: without it the needle is
    // a PREFIX and `ed` -> `edb` stays green). Note `bevelIsolatedFinBundleSpine`
    // is NOT a prefix of its sibling, so unlike the plane-cut rows these three
    // are independent by their names alone.
    static immutable string[2][] kBatchKernelsE4 = [
        ["source/mesh_ops/bevel_fin.d",    "bevelIsolatedFinBundleSpine"],
        ["source/mesh_ops/bevel_fin.d",    "bevelFinBundleSpineMultiEdge"],
        ["source/mesh_ops/bevel_vertex.d", "bevelVerticesByMask"],
    ];
    foreach (row; kBatchKernelsE4) {
        immutable src4 = (row[0] == "source/mesh_ops/bevel_fin.d") ? bf : bv;
        assert(countOccurrences(src4, row[1] ~ "(ref MeshEditBatch ed,") == 1,
            format("%s no longer declares `%s` over `ref MeshEditBatch ed`. That "
                 ~ "receiver is the enforcement, not the style: it is what makes "
                 ~ "a batchless call a COMPILE error, so one chamfer stamps, "
                 ~ "derives and delivers once at close() instead of once per "
                 ~ "added rail/split vertex and once per face rewrite "
                 ~ "(task 1903 §4.1, §5.2 E4).", row[0], row[1]));
        assert(countOccurrences(src4, row[1] ~ "(ref Mesh ") == 0,
            format("`%s` has a `ref Mesh` receiver again — that compiles, and it "
                 ~ "drops the batch: the kernel's internal commits go back to "
                 ~ "stamping one at a time. Plan §4.4a REJECTED exactly this "
                 ~ "overload, by name, because nothing in the two lanes can see "
                 ~ "it — the geometry is identical and the receiver pin is "
                 ~ "satisfied by the `ref MeshEditBatch` overload that still "
                 ~ "exists. This row is the one thing that can "
                 ~ "(task 1903 Stage E4).", row[1]));
        assert(countOccurrences(src4, row[1] ~ "(ref const(Mesh)") == 0,
            format("`%s` cannot have a `ref const(Mesh)` receiver — it adds "
                 ~ "vertices, rewrites windings and appends faces. Such an "
                 ~ "overload could only exist by casting const away "
                 ~ "(task 1903 Stage E4).", row[1]));
    }

    // NEITHER FILE HAS A READ-ONLY ENTRY, and that is a claim worth a row: if a
    // later stage splits a const helper out of one of these kernels it must add
    // its own receiver pin here rather than let an unpinned `ref const(Mesh)`
    // appear. (§4.1 cell two is simply absent from this stage.)
    foreach (row; [["source/mesh_ops/bevel_fin.d", bf],
                   ["source/mesh_ops/bevel_vertex.d", bv]])
        assert(countOccurrences(row[1], "(ref const(Mesh) m,") == 0,
            format("%s now declares a `ref const(Mesh) m,` receiver. Stage E4 "
                 ~ "converted these two families with ONE receiver each because "
                 ~ "neither has a read-only entry; a new const entry is welcome "
                 ~ "but it needs its own pin in this block, or it is the only "
                 ~ "signature in the family nothing holds "
                 ~ "(task 1903 Stage E4, plan §4.1).", row[0]));

    // THE CORNER RECORD MOVED TO MODULE SCOPE (§2.7 as rewritten at the E2
    // review). Unlike `RevolveParams` and `PlaneCutLoops` this type had ZERO
    // outside call sites to carry — nothing ever spelled
    // `Mesh.VertexBevelCorner` — so the move is invisible to every behavioural
    // test in the tree and this row plus bevel_vertex.d's `static assert` are
    // the whole of its evidence. The alias §2.7 used to offer as a fallback is
    // refused there: measured at E2/E3, an in-struct alias makes
    // `__traits(hasMember, Mesh, "VertexBevelCorner")` answer `true`, so the
    // alias and the tripwire cannot both stand.
    assert(countOccurrences(bv, "\nstruct VertexBevelCorner {") == 1,
        "source/mesh_ops/bevel_vertex.d no longer declares `struct "
      ~ "VertexBevelCorner` at MODULE scope (column 0). The mixin used to inject "
      ~ "it into `Mesh`; Stage E4 moved it out, and an in-struct alias putting "
      ~ "the name back is what that file's tripwire refuses "
      ~ "(task 1903 Stage E4, plan §2.7).");

    // Each family's declared scope lives ONCE, beside its kernels — D2's reason
    // for `kReduceEditScope`. `kBevelFinEditScope` has TWO production call sites
    // (both inside edge_bevel.d's transitional block) and `kBevelVertexEditScope`
    // has THREE (the command plus the tool's two), so both have room to drift.
    // The BEHAVIOURAL half — that the value is right, written out from the enum
    // independently — is in each family's recording block; this row only pins
    // that there is one of it.
    assert(countOccurrences(bf, "enum uint kBevelFinEditScope =") == 1,
        "source/mesh_ops/bevel_fin.d no longer declares `kBevelFinEditScope` at "
      ~ "module scope — edge_bevel.d's two transitional batches pass it, and a "
      ~ "per-call-site literal is the drift this constant exists to prevent "
      ~ "(task 1903 Stage E4).");
    assert(countOccurrences(bv, "enum uint kBevelVertexEditScope =") == 1,
        "source/mesh_ops/bevel_vertex.d no longer declares "
      ~ "`kBevelVertexEditScope` at module scope — the vertex-bevel command and "
      ~ "the tool's two entry points pass it (task 1903 Stage E4).");

    // A KERNEL NEVER OPENS A BATCH (§4.1, §2.3 rule 2). Neither of these files
    // keeps a module unittest, so unlike cut.d the pin is the plain `== 0` that
    // revolve.d uses — and on THIS stage it is the sharper half of the
    // transitional-debt argument: the debt is allowed to live at the CALLER
    // (edge_bevel.d, pinned below), never inside the kernel.
    foreach (row; [["source/mesh_ops/bevel_fin.d", bf],
                   ["source/mesh_ops/bevel_vertex.d", bv]])
        assert(countOccurrences(row[1], "MeshEditBatch(") == 0
            && countOccurrences(row[1], "MeshEditBatch.unrecorded(") == 0,
            format("%s opens a `MeshEditBatch`. A KERNEL never opens one — the "
                 ~ "command, the tool, or (transitionally, §4.4a) the "
                 ~ "still-mixin caller does. If an intra-kernel batch is "
                 ~ "genuinely needed, §4.4a says what it costs: a TRANSITIONAL "
                 ~ "label, a named removing stage, and a per-command "
                 ~ "nestedBatchOpens DELTA assert in that command's own suite "
                 ~ "test (task 1903 Stage E4).", row[0]));

    // THE TRANSITIONAL DEBT ITSELF (§4.4a) — it lives at the caller, it is
    // scoped to the two converted calls ALONE, and it is UNRECORDED. The
    // narrowing is the part Stage D3's review MAJOR-3 made mandatory: a batch
    // spanning the enclosing block would change the publish shape of the
    // MANIFOLD bevel path, which this stage does not touch. Two opens, both
    // with the same subject and the same declared scope; a third would be a
    // kernel-side batch that escaped the rows above.
    immutable ebPath = buildPath(repoRoot, "source", "mesh_ops", "edge_bevel.d");
    assert(exists(ebPath), "cannot find source/mesh_ops/edge_bevel.d at " ~ ebPath);
    immutable eb = stripCommentsAndStrings(readText(ebPath));
    assert(countOccurrences(eb,
            "MeshEditBatch.unrecorded(this, kBevelFinEditScope);") == 2,
        format("source/mesh_ops/edge_bevel.d holds %d transitional "
             ~ "`MeshEditBatch.unrecorded(this, kBevelFinEditScope);` open(s); "
             ~ "expected exactly 2, one per fin-bundle early return. Fewer means "
             ~ "a converted kernel is being called with no batch to defer into "
             ~ "(and, since edge_bevel.d is still a mixin body, that is a "
             ~ "COMPILE error, so 0 here means the call itself went away); more "
             ~ "means the debt grew without a row saying so. Stage G removes "
             ~ "both (task 1903 §4.4a, Stage E4).",
               countOccurrences(eb, "MeshEditBatch.unrecorded(this, kBevelFinEditScope);")));
    assert(countOccurrences(eb, "MeshEditBatch(") == 0,
        "source/mesh_ops/edge_bevel.d opens a RECORDING `MeshEditBatch`. The "
      ~ "two transitional opens must stay `unrecorded`: `mesh.bevel` undoes "
      ~ "through a whole-mesh MeshSnapshot, so a recording batch would build an "
      ~ "op-log nothing reads and `close()` would drop "
      ~ "(task 1903 §4.4a, Stage E4).");
    {
        // …and the DEBT NAMES ITS REMOVING STAGE, in the source, in prose. This
        // one assert reads the RAW file rather than the stripped one — the
        // claim IS about the comment, and §4.4a requires the numbered stage to
        // be named there so the next reader does not have to reconstruct it
        // from the plan.
        immutable ebRaw = readText(ebPath);
        assert(countOccurrences(ebRaw, "TASK 1903 Stage E4 — A TRANSITIONAL BATCH") == 1
            && countOccurrences(ebRaw, "WHAT REMOVES IT: **stage G**") == 1,
            "source/mesh_ops/edge_bevel.d's transitional-batch comment lost "
          ~ "either its TRANSITIONAL label or the name of the stage that "
          ~ "removes it. §4.4a requires both: a debt whose removing stage is "
          ~ "not written down beside it becomes a pattern (task 1903 Stage E4).");
    }

    // §5.7 over both files. Neither has ever carried a raw position write —
    // both build every new coordinate through `ed.addVertex(...)` — so unlike
    // cut.d's these two zeroes are statements, not retirements. THE ZERO IS
    // ONLY WORTH SOMETHING IF THE PREDICATE CAN SEE THIS FAMILY'S SPELLING
    // (E3 memo 9): the drill that earns it is M-V1/E4, a raw
    // `ed.vertices[railA[0]] = …` written beside the good `addVertex` call —
    // an INDEXED whole-vertex assign, the predicate's first alternative and
    // its oldest positive control.
    foreach (row; [["source/mesh_ops/bevel_fin.d", bf],
                   ["source/mesh_ops/bevel_vertex.d", bv]]) {
        string firstHit4;
        immutable size_t rawWrites4 = countRawPositionWrites(row[1], firstHit4);
        assert(rawWrites4 == 0,
            format("%s: %d raw position write(s) under §5.7's predicate, "
                 ~ "expected 0. First hit: `%s`. `alias mesh this` means "
                 ~ "`ed.vertices[i] = p` COMPILES inside a recording batch and "
                 ~ "records nothing, which is why the boundary is a counted "
                 ~ "census and not a type (task 1903 §5.7, M-V1).",
                   row[0], rawWrites4, firstHit4));
    }

}

// ---------------------------------------------------------------------------
// THE §2.6 WIDENINGS, AND THE HALF THAT KEEPS THEM HONEST (task 1903 Stage D3).
//
// A mixin body is instantiated in its HOST's scope, so `mesh_ops/*.d` reached
// `private` names of `mesh.d` for free. Converting a family to free functions
// takes that away, and §2.6 lists eleven names that must be widened — but NOT
// in one go: Stage A shipped ten of them and the review REVERTED all ten,
// because at that point nothing outside `mesh.d` named any of them. Ten
// `private` doors stood open with no caller to justify one and nothing that
// could redden if a wrong caller appeared. The rule that replaced it: each
// widening lands in the stage that converts ITS caller, with a census row
// NAMING that caller.
//
// So every row below is a PAIR. The `private` spelling is gone from mesh.d,
// AND the file that needed it still calls it. Drop the call and the row
// reddens telling you to narrow the name back — which is the half a plain
// "is it public?" check cannot do.
//
// Its own `unittest`, not folded into the mixin census above: druntime stops a
// module at its first failed assert, and these rows must stay visible when the
// receiver pins are red (Stage D1 review memo).
//
// AND THE CENSUS IS TWO-SIDED, not one (Stage D3 review, MAJOR-2). The rows
// above answer "is the name still public, and does bridge.d still call it?" —
// which is blind in the direction §2.6 actually asks about: a widened name is
// public to the WHOLE tree, and a stage that inherits one must say who else
// uses it. Measured: adding `orientFaceConsistent(idx, ef);` to a new method in
// `source/mesh_ops/cleanup.d` left this block green. So each row also declares
// `callerFiles`, and the block walks `source/**` (comment-stripped) for a
// RECEIVER-AGNOSTIC needle and asserts the SET of caller files EQUALS the row.
// That reddens in both directions — a caller the row does not name, and a file
// the row names that no longer calls.
//
// M-D3-WIDEN-A: put `private` back on `mesh.smoothstep01` → `dub build` fails
//   first (bridge.d cannot see it), which is the point — the census row is the
//   REVERT tripwire for a tree that still compiles because someone also
//   duplicated the helper.
// M-D3-WIDEN-B: delete bridge.d's `orientFaceConsistent` calls → this block
//   reddens naming the widening as now caller-less.
// M-W2 (under-declared): add a second caller of `orientFaceConsistent` in
//   `source/mesh_ops/cleanup.d` → the set assert reddens naming that file.
// M-W3 (over-declared): add a file to a row's `callerFiles` that contains no
//   call → the same assert reddens from the other side.
// ---------------------------------------------------------------------------
unittest // every §2.6 widening this stage made still has the caller it names
{
    immutable meshPath = buildPath(repoRoot, "source", "mesh.d");
    assert(exists(meshPath), "cannot find source/mesh.d at " ~ meshPath);
    immutable md = stripCommentsAndStrings(readText(meshPath));
    immutable brPath = buildPath(repoRoot, "source", "mesh_ops", "bridge.d");
    assert(exists(brPath), "cannot find source/mesh_ops/bridge.d at " ~ brPath);
    immutable br = stripCommentsAndStrings(readText(brPath));
    immutable ctPath = buildPath(repoRoot, "source", "mesh_ops", "cut.d");
    assert(exists(ctPath), "cannot find source/mesh_ops/cut.d at " ~ ctPath);
    immutable ct = stripCommentsAndStrings(readText(ctPath));
    immutable bfPath2 = buildPath(repoRoot, "source", "mesh_ops", "bevel_fin.d");
    assert(exists(bfPath2), "cannot find source/mesh_ops/bevel_fin.d at " ~ bfPath2);
    immutable bf2 = stripCommentsAndStrings(readText(bfPath2));
    immutable bvPath2 = buildPath(repoRoot, "source", "mesh_ops", "bevel_vertex.d");
    assert(exists(bvPath2), "cannot find source/mesh_ops/bevel_vertex.d at " ~ bvPath2);
    immutable bv2 = stripCommentsAndStrings(readText(bvPath2));

    // The file each row's `callSite` is looked for in. D3's three rows are all
    // bridge.d's; E3 added three that are cut.d's, so the row carries its own
    // ops file rather than the block assuming one (task 1903 Stage E3). E4 adds
    // the two bevel files.
    immutable string[string] opsSrc = ["source/mesh_ops/bridge.d":       br,
                                       "source/mesh_ops/cut.d":          ct,
                                       "source/mesh_ops/bevel_fin.d":    bf2,
                                       "source/mesh_ops/bevel_vertex.d": bv2];

    // name, the `private` declaration that must be GONE from mesh.d, the
    // declaration that must be THERE, the call in the ops file that justifies it,
    // and — the MAJOR-2 half — the receiver-agnostic needle plus the COMPLETE
    // set of files under `source/` that may contain it (mesh.d excluded: it is
    // the declarer, and its own internal calls are not what §2.6 asks about).
    static struct Widening {
        string   name;        // for the message
        string   privateDecl; // must not appear in mesh.d
        string   publicDecl;  // must appear exactly once in mesh.d
        string   opsFile;     // which mesh_ops file `callSite` is looked for in
        string   callSite;    // must appear at least once in that ops file
        string   scanNeedle;  // receiver-AGNOSTIC; what the source/** walk counts
        string[] callerFiles; // every non-mesh.d file that contains scanNeedle
        string   why;
    }
    static immutable Widening[] kWidenings = [
        Widening("mesh.smoothstep01",
                 "private float smoothstep01(",
                 "float smoothstep01(float t)",
                 "source/mesh_ops/bridge.d",
                 "smoothstep01(t)",
                 "smoothstep01(",
                 ["source/mesh_ops/bridge.d"],
                 "a module-level free function of `mesh`, NOT a Mesh member — plan "
               ~ "§2.6 called it out by name as \"the one that will not compile "
               ~ "after conversion\". `bridgeTwistedVertex` is its only caller "
               ~ "anywhere in the tree."),
        Widening("Mesh.orientFaceConsistent",
                 "private void orientFaceConsistent(",
                 "void orientFaceConsistent(uint[] idx",
                 "source/mesh_ops/bridge.d",
                 "ed.orientFaceConsistent(",
                 "orientFaceConsistent(",
                 ["source/mesh_ops/bridge.d"],
                 "the task-0394 winding-consistency vote, shared by "
               ~ "`makePolygonFromVerts` (in mesh.d) and bridge.d's "
               ~ "`bridgeStripPaired` / `bridgeFanRows` (task 0395)."),
        Widening("Mesh.registerNewFaceEdges",
                 "private void registerNewFaceEdges(",
                 "void registerNewFaceEdges(ref int[2][ulong] liveEdgeFaces",
                 "source/mesh_ops/bridge.d",
                 "ed.registerNewFaceEdges(",
                 "registerNewFaceEdges(",
                 ["source/mesh_ops/bridge.d"],
                 "the incremental edgeFaces update that lets a LATER face in the "
               ~ "same strip/fan see its already-placed siblings; bridge.d is its "
               ~ "only caller."),
        // --- Stage E3's three, all reached by `mesh_ops/cut.d` -------------
        Widening("Mesh.edgeIndexOfVerts",
                 "private uint edgeIndexOfVerts(",
                 "uint edgeIndexOfVerts(uint a, uint b)",
                 "source/mesh_ops/cut.d",
                 "ed.edgeIndexOfVerts(",
                 "edgeIndexOfVerts(",
                 ["source/mesh_ops/cut.d"],
                 "the raw edge lookup by endpoint pair. It is NOT the same thing "
               ~ "as the public `edgeIndexOf` it already backed: that one is the "
               ~ "guarded accessor an outside module should reach for, and it "
               ~ "exists precisely so callers do not depend on the map lookup. "
               ~ "`planeCutCore` needs the raw form at three sites — the "
               ~ "restrict-set edge marking, the concave-guard scan (there is "
               ~ "exactly ONE: `isConcaveFace` has a single call site) and the "
               ~ "clipped chord-crossing lookup — all of them after a "
               ~ "buildLoops()."),
        Widening("Mesh.insertEdgePoint",
                 "private uint insertEdgePoint(",
                 "uint insertEdgePoint(uint ei, float t, ref bool[] isCutVert",
                 "source/mesh_ops/cut.d",
                 "ed.insertEdgePoint(",
                 "insertEdgePoint(",
                 ["source/mesh_ops/cut.d"],
                 "cutByPlane Pass-1: it splices one shared crossing vertex into "
               ~ "every face winding incident on a straddled edge, which is what "
               ~ "makes the cut T-junction-free. cut.d is its only caller "
               ~ "outside mesh.d."),
        Widening("Mesh.rebuildFacesWithChordSplits",
                 "private size_t rebuildFacesWithChordSplits(",
                 "size_t rebuildFacesWithChordSplits(",
                 "source/mesh_ops/cut.d",
                 "ed.rebuildFacesWithChordSplits(",
                 "rebuildFacesWithChordSplits(",
                 ["source/mesh_ops/cut.d"],
                 "cutByPlane Pass-2 + finalize: it emits the two sub-faces per "
               ~ "chord-split face, carrying faceMaterial / the whole faceMarks "
               ~ "word / faceSelectionOrder onto both halves. cut.d is its only "
               ~ "caller outside mesh.d."),
        // --- Stage E4's two, and BOTH have callers that are still MIXINS ---
        // This is the first pair of rows whose `callerFiles` names a file the
        // conversion has NOT reached. `extrude.d` (Stage H) and `edge_bevel.d`
        // (Stage G) are mixin bodies instantiated in mesh.d's scope, so they
        // reach these names for free today and the widening is not for them —
        // but the needle is TEXT, so they appear in the walk, and §2.6's rule
        // ("the stage that inherits a public name says who else uses it") is
        // exactly what that is for. When G and H convert, their calls change
        // spelling but not file, so these rows do not move.
        Widening("Mesh.finalizeTopologyEdit",
                 "private void finalizeTopologyEdit(",
                 "void finalizeTopologyEdit()",
                 "source/mesh_ops/bevel_fin.d",
                 "ed.finalizeTopologyEdit(",
                 "finalizeTopologyEdit(",
                 ["source/mesh_ops/bevel_fin.d",
                  "source/mesh_ops/bevel_vertex.d",
                  "source/mesh_ops/extrude.d"],
                 "the shared tail of a topology edit — rebuild edges + loops, "
               ~ "compact orphan vertices, rebuild loops AGAIN (the second "
               ~ "buildLoops is mandatory: compaction invalidates the face/vert "
               ~ "indices the half-edge loops carry). Both fin-bundle kernels "
               ~ "and the vertex chamfer end with it; `mesh_ops/extrude.d` names "
               ~ "it at three further sites and is still a mixin until Stage H."),
        Widening("Mesh.rebuildFaceWithVertexSubs",
                 "private static uint[] rebuildFaceWithVertexSubs(",
                 "static uint[] rebuildFaceWithVertexSubs(",
                 "source/mesh_ops/bevel_vertex.d",
                 "Mesh.rebuildFaceWithVertexSubs(",
                 "rebuildFaceWithVertexSubs(",
                 ["source/mesh_ops/bevel_vertex.d",
                  "source/mesh_ops/edge_bevel.d",
                  "source/mesh_ops/extrude.d"],
                 "the one-face substitution pass shared by the three kernels "
               ~ "that replace a vertex with several: it rebuilds one winding "
               ~ "with `oldV -> newVs` applied at EVERY position the old vertex "
               ~ "occupied, LAST-wins on a repeated `oldV`. It is `static`, so "
               ~ "UFCS through the batch handle cannot reach it and "
               ~ "bevel_vertex.d must spell it `Mesh.rebuildFaceWithVertexSubs` "
               ~ "— the one qualified member spelling this stage keeps, and it "
               ~ "is legal precisely because the name is a member of `Mesh` and "
               ~ "not of the converted family."),
    ];

    foreach (w; kWidenings) {
        assert(countOccurrences(md, w.privateDecl) == 0,
            format("`%s` is `private` again in source/mesh.d. It is %s Task 1903 "
                 ~ "widened it — in the track-1 stage that converted its caller, "
                 ~ "which is the rule §2.6 settled on after the Stage A review "
                 ~ "reverted ten widenings that had no caller yet (D3 for "
                 ~ "bridge.d's three, E3 for cut.d's three, E4 for the two bevel "
                 ~ "files'). A mixin body is instantiated in mesh.d's scope and "
                 ~ "sees a private name for free; a free function in "
                 ~ "`source/mesh_ops/` does not (plan §2.6, §4.3).",
                   w.name, w.why));
        assert(countOccurrences(md, w.publicDecl) == 1,
            format("source/mesh.d no longer declares `%s` as `%s` — count %d, "
                 ~ "expected 1. If the signature changed, update this row and "
                 ~ "say why; if the name is gone, bridge.d's call is gone too "
                 ~ "and the widening should be reverted with it (task 1903 §2.6).",
                   w.name, w.publicDecl, countOccurrences(md, w.publicDecl)));
        // Look the ops file up BEFORE indexing: a row naming a file this block
        // did not read would otherwise die on a RangeError with no row name in
        // it, and the reader would be debugging the harness instead of the row.
        assert(w.opsFile in opsSrc,
            format("row `%s` names ops file `%s`, which this block does not "
                 ~ "read — add it to `opsSrc` above (it reads bridge.d and "
                 ~ "cut.d today) or fix the row (task 1903 §2.6).",
                   w.name, w.opsFile));
        assert(countOccurrences(opsSrc[w.opsFile], w.callSite) >= 1,
            format("%s no longer contains `%s`, so the "
                 ~ "widening of `%s` in source/mesh.d now holds a `private` door "
                 ~ "open for NOBODY. That is exactly the state the Stage A review "
                 ~ "reverted ten widenings for (plan §2.6, review S3): narrow it "
                 ~ "back to `private` in the same change that removed the call, "
                 ~ "and delete this row.", w.opsFile, w.callSite, w.name));
    }

    // --- The other side: WHO ELSE calls it (review MAJOR-2) ----------------
    // One walk over `source/**`, comment- and string-stripped, collecting for
    // each row the set of files that contain its receiver-agnostic needle.
    // `source/mesh.d` is skipped: it declares the name, and its own calls are
    // not the question §2.6 asks.
    string[][string] callersOf;
    size_t filesScanned = 0;
    {
        import std.file : dirEntries, SpanMode;
        import std.path : relativePath;
        import std.string : replace;

        immutable srcRoot = buildPath(repoRoot, "source");
        foreach (e; dirEntries(srcRoot, "*.d", SpanMode.depth)) {
            immutable rel = relativePath(e.name, repoRoot).replace("\\", "/");
            if (rel == "source/mesh.d") continue;
            ++filesScanned;
            immutable src = stripCommentsAndStrings(readText(e.name));
            foreach (w; kWidenings)
                if (countOccurrences(src, w.scanNeedle) >= 1)
                    callersOf[w.name] ~= rel;
        }
    }

    // Non-vacuity floor for the WALK itself. If the root were wrong or the glob
    // matched nothing, every set would come back empty and the rows would still
    // redden — but with a message about a missing caller instead of a missing
    // walk, which is the wrong thing to go read.
    assert(filesScanned >= 100,
        format("the §2.6 caller walk visited only %d .d file(s) under "
             ~ "source/ (excluding mesh.d) — the tree has well over 100. The "
             ~ "walk is mis-rooted or the glob is wrong; the caller-set "
             ~ "assertions below would be measuring nothing.", filesScanned));

    static string joinSorted(const(string)[] xs) {
        import std.algorithm : sort;
        import std.array     : join;
        string[] tmp;
        foreach (x; xs) tmp ~= x;
        tmp.sort();
        return tmp.length == 0 ? "(none)" : tmp.join(", ");
    }

    foreach (w; kWidenings) {
        immutable string got  = joinSorted(callersOf.get(w.name, []));
        immutable string want = joinSorted(w.callerFiles);
        assert(got == want,
            format("`%s` was widened out of `private` by task 1903, and plan "
                 ~ "§2.6 requires the stage that inherits a public name to say "
                 ~ "WHO USES IT. The row declares its callers as [%s]; the tree "
                 ~ "actually has [%s] (needle `%s`, %d file(s) under source/ "
                 ~ "scanned, source/mesh.d excluded as the declarer).\n"
                 ~ "  * A file in the tree but NOT in the row: a second stage is "
                 ~ "now leaning on this widening. Add it to `callerFiles` with a "
                 ~ "note saying which stage owns it — a public door with an "
                 ~ "unlisted user is how `Mesh.faceAttrOr` ended up with callers "
                 ~ "in three files across three stages and no record of it.\n"
                 ~ "  * A file in the row but NOT in the tree: that caller is "
                 ~ "gone. If the row is now empty, narrow the name back to "
                 ~ "`private` in the same change and delete the row (plan §2.6, "
                 ~ "review S3).\n"
                 ~ "  Why this widening exists: it is %s",
                   w.name, want, got, w.scanNeedle, filesScanned, w.why));
    }
}

// ---------------------------------------------------------------------------
// Task 1903 Stage E3 (review round 2, MINOR 3/4): two text pins the behavioural
// lanes cannot carry.
//
// (a) `slice_tool.d` has TWO `sliceSplitGap` guards — the interactive preview's
//     and `applyHeadless`'s — that its own comment says must stay in lockstep,
//     and no suite test reaches the preview one (a mutation there was INERT).
//     Each guard is pinned to its exact spelling; a drift in either reddens.
// (b) `axis_slice.d`'s two ladder blocks open ONE batch before the `foreach`
//     over the cuts. A batch opened INSIDE the loop is byte-identical on every
//     /api/changes counter (measured — delivery coalesces per frame), so the
//     only pins are `cut_test.d`'s mutationVersion ladder cell (unit-level,
//     never calls axis_slice.d) and this text order.
// ---------------------------------------------------------------------------
unittest {
    import std.algorithm : countUntil;
    immutable st = stripCommentsAndStrings(readText(buildPath(repoRoot, "source/tools/slice/slice_tool.d")));
    assert(countOccurrences(st, "if (gap != 0.0f && restrictFaces.length == 0)") == 1,
        "slice_tool.d: the interactive split+gap guard changed its spelling — the "
      ~ "two guards must stay in lockstep and this pin is the only thing that "
      ~ "notices the preview one moving (no suite test reaches it)");
    assert(countOccurrences(st, "if (gap_ != 0.0f && restrict.length == 0)") == 1,
        "slice_tool.d: the applyHeadless split+gap guard changed its spelling — "
      ~ "keep it in lockstep with the interactive guard above");

    immutable ax = stripCommentsAndStrings(readText(buildPath(repoRoot, "source/commands/mesh/axis_slice.d")));
    size_t pos = 0;
    foreach (which; ["MeshAxisSlice ladder", "MeshJulienne ladder"]) {
        auto rest = ax[pos .. $];
        immutable open = rest.countUntil("MeshEditBatch.unrecorded(");
        assert(open >= 0, which ~ ": no MeshEditBatch.unrecorded( found");
        immutable loop = rest.countUntil("foreach (k; 0 ..");
        assert(loop >= 0, which ~ ": no ladder foreach found");
        assert(open < loop, which ~ ": the batch must be opened BEFORE the ladder "
            ~ "foreach — one batch for the whole ladder. A batch per cut reads "
            ~ "identically on every /api/changes counter, so this order and "
            ~ "cut_test.d's mutationVersion cell are its only pins (task 1903 E3 "
            ~ "review round 2)");
        pos += loop + 1;
    }
}
