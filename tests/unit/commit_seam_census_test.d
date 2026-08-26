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
// M-F1-MIXIN: the same for `mixin MeshLoopSliceOps;` (task 1903 Stage F1).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// ONE `unittest` BLOCK PER STAGE (task 1903 Stage F1 review, m7). Until F1's
// review these ~30 rows lived in ONE block spanning 1300 lines. The widening
// block below already carried the reasoning in its own header ("Its own
// `unittest`, not folded into the mixin census above: druntime stops a module
// at its first failed assert") — it was simply never applied to the block it
// was split from.
//
// WHAT THE SPLIT BUYS, AND WHAT IT DOES NOT — MEASURED, because the obvious
// reading of that header is WRONG and would have shipped as an inert change.
// druntime stops the whole MODULE at its first failing block, and splitting
// does NOT change that. Measured with two simultaneous mutations (D2's
// `reduceToTarget` receiver row and F1's `capShellCycles` absence row, both
// set to `== 99`): the run reported D2 at line 671 and F1 was NEVER REACHED.
// So do not read the split as "now all thirty rows report".
//
// What it does buy is real and is why it stands:
//
//   * ATTRIBUTION. The failure now names its stage in the stack —
//     `__unittest_L650_C1` under the title "Stage D2 …" instead of one
//     `__unittest_L504_C1` covering every stage's rows. Nine separate
//     mutations, one per block, each produced its own `__unittest_L<n>` and
//     its own message; the table is in the card's "Складка ревью Stage F1".
//   * CHEAP ISOLATION. To reach a later block, put `version (none)` on the
//     blocks before it — a one-line edit per block, not surgery inside a
//     1300-line body. That is the drill when a mutation must redden two rows
//     for two different reasons.
//
// The cost of the split is zero: every stage section already declared its own
// `<x>Path` / `<x>` locals and shared nothing across the boundaries except the
// module-level helpers (`repoRoot`, `stripCommentsAndStrings`,
// `countOccurrences`).
//
// A NEW STAGE ADDS A NEW BLOCK. Do not append to an existing one.
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
    // falls by TWO there and by one everywhere else); F1: MeshLoopSliceOps;
    // F2: MeshPolyBevelOps; G: MeshEdgeBevelOps. The ONE left is
    // `MeshExtrudeOps` (Stage H).
    enum size_t kExpected = 1;
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
                                            "MeshBevelVertexOps",       // Stage E4
                                            "MeshLoopSliceOps",         // Stage F1
                                            "MeshPolyBevelOps",        // Stage F2
                                            "MeshEdgeBevelOps"];       // Stage G
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
}


unittest // Stage C + D1 — the two pure-query families keep their receivers
{
    // The other half of the mixin claim above: the ops file must not be a
    // mixin template any more either. Deleting the instantiation while leaving
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
}


unittest // Stage D2 — the decimation family, the first mutating receiver
{
    // Stage D2 — the decimation family, and the FIRST MUTATING receiver in the
    // tree. Every family in the two blocks above is a read-only or
    // memo-touching query;
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
}


unittest // Stage D3 — the bridge family, both receivers in one file
{
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
}


unittest // Stage E1 — the mesh-hygiene / orientation-repair family
{
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
}


unittest // Stage E2 — the radial sweep / revolve + path-follow family
{
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
}


unittest // Stage E3 — the plane-cut family, first raw position write across the seam
{
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
}


unittest // Stage E4 — the two bevel families, one commit
{
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
    // for `kReduceEditScope`. `kBevelVertexEditScope` has THREE production call
    // sites (the command plus the tool's two), so it has room to drift.
    //
    // `kBevelFinEditScope` HAS NONE ANY MORE, and that is a measured consequence
    // of Stage G rather than rot: its two production callers were exactly
    // edge_bevel.d's transitional batches, and G removed them. The fin kernels
    // now run inside the batch `bevelEdgesByMask`'s CALLER opened, which passes
    // `kEdgeBevelEditScope`. The constant survives as the fin family's own
    // declared class — the value its `commitChange` should agree with, asserted
    // by `tests/unit/mesh_ops/bevel_fin_test.d`'s recording block — and Stage
    // L7 is what gives it a production caller again, when those kernels get a
    // RECORDING batch of their own. Deleting it now would delete the only
    // written-down statement of what class they declare.
    // The BEHAVIOURAL half — that the value is right, written out from the enum
    // independently — is in each family's recording block; this row only pins
    // that there is one of it.
    assert(countOccurrences(bf, "enum uint kBevelFinEditScope =") == 1,
        "source/mesh_ops/bevel_fin.d no longer declares `kBevelFinEditScope` at "
      ~ "module scope. It has had NO production caller since Stage G removed "
      ~ "edge_bevel.d's two transitional batches — the fin kernels run inside "
      ~ "the edge bevel caller's batch now — but it is still the one written "
      ~ "statement of the class those kernels declare, which bevel_fin_test.d's "
      ~ "recording block asserts and which Stage L7 will pass again "
      ~ "(task 1903 Stage E4, re-anchored at Stage G).");
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

    // THE TRANSITIONAL DEBT IS GONE — Stage G REMOVED IT, and the three rows
    // that pinned it went with it in the same commit.
    //
    // E4 converted these two kernels while `mesh_ops/edge_bevel.d` was still a
    // mixin body, so `bevelEdgesByMask`'s two fin-bundle early returns had to
    // open an `unrecorded` `MeshEditBatch` each (§4.4a's debt shape). Three
    // rows lived here: the `MeshEditBatch.unrecorded(this, kBevelFinEditScope);`
    // == 2 count, the `MeshEditBatch(` == 0 companion, and a RAW-text row
    // requiring the comment to name "stage G" as the removing stage. Stage G is
    // that stage; keeping any of the three would have been a row asserting the
    // debt is still there.
    //
    // WHAT REPLACES THEM, and it is not nothing: edge_bevel.d's own Stage-G
    // block below carries `MeshEditBatch.unrecorded(` == 0 AND
    // `MeshEditBatch(` == 0 over that file — the kernel opens NO batch of any
    // kind now, which is the §4.1 rule the debt was an exception to. Note what
    // could NOT hold this: `tests/test_bevel_fin_bundle.d`'s per-command
    // `nestedBatchOpens` delta read 0 BEFORE (the transitional open was the
    // outermost batch) and reads 0 AFTER (there is no second open at all), so
    // it is blind to the removal by construction. It is still the right row for
    // what it does watch — that no LATER caller nests one.
    //
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


unittest // Stage F1 — the Loop Slice ring-walk + insertion family
{
    // ---------------------------------------------------------------------
    // Stage F1 — the Loop Slice ring-walk + insertion family. Four things are
    // pinned here that no earlier stage needed:
    //
    //   * BOTH receivers in one file AND a receiver-LESS group in the same
    //     file: `capShellCycles` / `ngonExitEdge` / `curvatureSplinePoint`
    //     were `static` members with no `this`, so they have no `(ref X y,`
    //     to pin and are held by the file's own tripwire instead (the D3
    //     review's forward note F-3, first exercised on a `static` member
    //     rather than a local helper);
    //   * a nested type moved to module scope that STAYED `private` — the
    //     first of the four to do so. `collectEdgeRing` returns
    //     `EdgeRingEntry[]` to four callers outside this module, and every
    //     one binds it with `auto` and reads only `.length`. **`private` at
    //     MODULE scope hides the NAME, and that is all it does** (F1 review,
    //     M3): it is not an encapsulation boundary in D, and the compiler
    //     cannot tell "reads only `.length`" from "reads `.fi`" — probed,
    //     both compile through `auto`/`typeof`, and a field WRITE compiles
    //     too. So the build is NOT what answers this; a green build here
    //     would be green whatever those four callers read. THIS ROW is what
    //     holds the decision, because a text census can see the spelling the
    //     compiler cannot. Widening it later is a decision somebody argues
    //     for, not a mechanical follow-on;
    //   * `capShellCycles` — the one name E3 left spelled `Mesh.` — going
    //     BARE again. cut.d converted first, so between E3 and F1 the only
    //     way to reach a `static` member of `Mesh` from a plain module
    //     function was the qualifier. F1 deletes the member, so the two call
    //     sites had to move in this same commit; the compiler enforces that
    //     half, and the row below is what refuses the qualifier coming BACK
    //     (it would only compile again if somebody re-added the member,
    //     which is exactly the state the tripwire and the roster refuse);
    //   * the §5.7 row is a RETIREMENT OF FOUR that does NOT land on zero.
    //     This file keeps one allowed write, and the row says which.
    // ---------------------------------------------------------------------
    immutable lsPath = buildPath(repoRoot, "source", "mesh_ops", "loop_slice.d");
    assert(exists(lsPath), "cannot find source/mesh_ops/loop_slice.d at " ~ lsPath);
    immutable ls = stripCommentsAndStrings(readText(lsPath));
    assert(countOccurrences(ls, "mixin template MeshLoopSliceOps") == 0,
        "source/mesh_ops/loop_slice.d still declares `mixin template "
      ~ "MeshLoopSliceOps` — Stage F1 converted this family to free functions; "
      ~ "a surviving template is either dead or a second implementation "
      ~ "(task 1903 Stage F1).");

    // THE MUTATING RECEIVERS. `insertEdgeLoops` is OVERLOADED (2-arg and
    // 3-arg), so its needle must count 2 and not 1 — a row that expected 1
    // would go red the moment both overloads were correct, and a row that
    // expected 1 and got it would mean one overload had drifted. The trailing
    // comma is load-bearing on all three (D2 review, MINOR-1: without it the
    // needle is a PREFIX and `ed` -> `edb` stays green). Note
    // `insertEdgeLoops` IS a prefix of `insertEdgeLoopsMulti`, which is why
    // the needle carries `(` — without it the two rows would not be
    // independent.
    assert(countOccurrences(ls, "insertEdgeLoops(ref MeshEditBatch ed,") == 2,
        format("source/mesh_ops/loop_slice.d declares %d `insertEdgeLoops` "
             ~ "overload(s) over `ref MeshEditBatch ed,`; expected exactly 2 "
             ~ "(the 2-arg forwarder and the 3-arg entry that reports the new "
             ~ "face indices). That receiver is the enforcement, not the "
             ~ "style: it is what makes a batchless call a COMPILE error, so "
             ~ "one loop insert STAMPS AND DERIVES once at close() instead of "
             ~ "once per appended rail vertex and once per face-array rebuild "
             ~ "— and it is the only thing the two recorded "
             ~ "`setVertexPositions` writes below have to record INTO "
             ~ "(task 1903 §4.1, §5.2 F1). STAMP, NOT DELIVERY (F1 review): "
             ~ "an edit batch is `g_editBatchStack` and a delivery batch is "
             ~ "`g_deliveryDepth`; `deliverPending()` consults only the "
             ~ "second, and the kernel's tail resetSelection() therefore "
             ~ "delivers from INSIDE the edit batch.",
               countOccurrences(ls, "insertEdgeLoops(ref MeshEditBatch ed,")));
    assert(countOccurrences(ls, "insertEdgeLoopsMulti(ref MeshEditBatch ed,") == 1,
        "source/mesh_ops/loop_slice.d no longer declares `insertEdgeLoopsMulti` "
      ~ "over `ref MeshEditBatch ed`. It is the ONE kernel of this family — "
      ~ "both `insertEdgeLoops` overloads forward to it — so its receiver is "
      ~ "the whole seam for the Loop Slice tool, the two slice commands and "
      ~ "the topology pen's Add Loop (task 1903 §4.1, §5.2 F1).");

    // …and the two wrong spellings, absent, for both entries.
    foreach (name; ["insertEdgeLoops", "insertEdgeLoopsMulti"]) {
        assert(countOccurrences(ls, name ~ "(ref Mesh ") == 0,
            format("`%s` has a `ref Mesh` receiver again — that compiles, and "
                 ~ "it drops the batch: the kernel's internal commits go back "
                 ~ "to stamping one at a time, and `setVertexPositions` is not "
                 ~ "even reachable from a bare mesh, so the Gap and Profile "
                 ~ "blocks would have to go back to the raw "
                 ~ "`vertices[pr[0]] = …` writes. Plan §4.4a REJECTED exactly "
                 ~ "this overload, by name, because nothing in the two lanes "
                 ~ "can see it — the geometry is identical and the receiver "
                 ~ "pin is satisfied by the `ref MeshEditBatch` overload that "
                 ~ "still exists. This row is the one thing that can "
                 ~ "(task 1903 Stage F1).", name));
        assert(countOccurrences(ls, name ~ "(ref const(Mesh)") == 0,
            format("`%s` cannot have a `ref const(Mesh)` receiver — it appends "
                 ~ "rail vertices, replaces the whole face array and clears "
                 ~ "the selection. Such an overload could only exist by "
                 ~ "casting const away (task 1903 Stage F1).", name));
    }

    // THE READ-ONLY RECEIVERS — four, and this is the first family where the
    // const half outnumbers the mutating one. All four WERE `const` members;
    // nothing in a mixin body forces the keyword, so the const receiver states
    // what the code already did and now ENFORCES it at the seam. `walkRingSide`
    // and `railContinuation` are `private` helpers of the walk;
    // `collectEdgeRing` and `loopSliceRingEdges` are the outside API — the
    // latter is why `app.d`, `tools/slice/loop_slice_tool.d` and
    // `tools/edit/topology_pen/render.d` keep calling it with no batch in
    // sight.
    foreach (name; ["railContinuation", "walkRingSide", "loopSliceRingEdges",
                    "collectEdgeRing"]) {
        assert(countOccurrences(ls, name ~ "(ref const(Mesh) m,") == 1,
            format("source/mesh_ops/loop_slice.d no longer declares `%s` over "
                 ~ "`ref const(Mesh) m`. Every one of these four only WALKS "
                 ~ "the ring — no vertex is added, no winding rewritten — and "
                 ~ "the const receiver is what states that, now enforced at "
                 ~ "the seam rather than by a keyword the mixin could have "
                 ~ "dropped at any time. It is also what keeps "
                 ~ "`mesh.loopSliceRingEdges(seed)` compiling verbatim in "
                 ~ "app.d's loop-hover mask (task 1903 Stage F1, plan §4.1).",
                   name));
        assert(countOccurrences(ls, name ~ "(ref MeshEditBatch") == 0,
            format("`%s` took a `ref MeshEditBatch` receiver — that compiles, "
                 ~ "and it means a ring WALK now opens an edit batch and "
                 ~ "publishes a change for a call that changes nothing. The "
                 ~ "hover path calls this one per frame. If a later stage "
                 ~ "wants that, it is a decision to argue for here "
                 ~ "(task 1903 Stage F1).", name));
    }

    // THE RING RECORD MOVED TO MODULE SCOPE (§2.7), AND STAYED `private`.
    // The needle carries `private` deliberately, and THIS ROW — not the
    // build — is what holds that decision (F1 review, M3). `private` at
    // MODULE scope in D restricts NAME LOOKUP only. It is not a seal: every
    // public field of `EdgeRingEntry` stays readable AND writable from any
    // module through `auto`/`typeof`, measured with `dmd -o- -c` —
    // `r[0].fi`, `r[0].ngon` and `typeof(r[0]) x; x.fi = 3;` all compile from
    // outside, while only the bare name `EdgeRingEntry` and a selective
    // `import … : EdgeRingEntry` are refused. So "the build is green with
    // `private`" is a check that cannot come out differently: it would be
    // green whether the four outside callers read `.length` or `.fi`. A TEXT
    // census can see the spelling the compiler cannot, which is why the
    // decision lives here. Widening it to public would be a decision about
    // this type's contract, not a mechanical follow-on, and this row is what
    // makes that decision visible. The `static assert` at the foot of
    // loop_slice.d is the other half — it refuses an in-struct
    // `alias EdgeRingEntry = …` putting the name back on `Mesh`, which
    // (measured at E2 and repeated at E3/E4) would make `hasMember` answer
    // `true` and blind the tripwire.
    assert(countOccurrences(ls, "\nprivate struct EdgeRingEntry {") == 1,
        "source/mesh_ops/loop_slice.d no longer declares `private struct "
      ~ "EdgeRingEntry` at MODULE scope (column 0). The mixin used to inject "
      ~ "it into `Mesh`; Stage F1 moved it out and kept it `private` because "
      ~ "the four outside callers take it through `auto` and read only "
      ~ "`.length`. NOTE WHAT `private` DOES AND DOES NOT DO (F1 review): at "
      ~ "module scope it hides the NAME only — the fields stay readable and "
      ~ "WRITABLE from outside via `auto`/`typeof`, so no build can enforce "
      ~ "the `.length`-only contract and THIS ROW is the enforcement. If it "
      ~ "had to widen, say why here (task 1903 Stage F1, plan §2.7).");

    // The family's declared scope lives ONCE, beside the kernels — D2's reason
    // for `kReduceEditScope`. This family has FIVE production call sites
    // passing it (two commands, the tool's commit and its per-frame preview,
    // and the topology pen's Add Loop) plus the module unittests and two suite
    // test helpers, so it has as many chances to drift as the plane cut did.
    // The BEHAVIOURAL half — that the value is right, written out from the
    // enum independently — is in loop_slice_test.d's recording block; this row
    // only pins that there is one of it.
    assert(countOccurrences(ls, "enum uint kLoopSliceEditScope =") == 1,
        "source/mesh_ops/loop_slice.d no longer declares `kLoopSliceEditScope` "
      ~ "at module scope — five production call sites pass it, and a "
      ~ "per-call-site literal is the drift this constant exists to prevent "
      ~ "(task 1903 Stage F1).");

    // A KERNEL NEVER OPENS A BATCH (§4.1, §2.3 rule 2) — the absence pin, and
    // like cut.d this file cannot use the plain `== 0` spelling because it
    // keeps TWO module unittests that legitimately open one through their own
    // `sliceOnce` helper. So the pin is two-sided: the TOTAL must be 1 (the
    // helper is the only open, and the two unittests share it), and it must be
    // the unittest helper's exact spelling. A kernel that opened its own would
    // take the total to 2; one that replaced the helper's would keep the total
    // and drop the shaped count.
    assert(countOccurrences(ls, "MeshEditBatch.unrecorded(") == 1
        && countOccurrences(ls, "MeshEditBatch(") == 0,
        format("source/mesh_ops/loop_slice.d opens %d unrecorded "
             ~ "`MeshEditBatch`(es) and %d RECORDING one(s); expected exactly "
             ~ "1 and 0 — the one is the `sliceOnce` helper the two module "
             ~ "unittests at the foot of the file share, and a recording open "
             ~ "anywhere in this file would build an op-log nothing reads. A "
             ~ "KERNEL never opens a batch at all — the command or the tool "
             ~ "does (plan §4.1, §2.3 rule 2). If a new intra-kernel batch is "
             ~ "genuinely needed, §4.4a says what it costs: a TRANSITIONAL "
             ~ "label, a named removing stage, and a per-command "
             ~ "nestedBatchOpens DELTA assert in that command's own suite test "
             ~ "(task 1903 Stage F1).",
               countOccurrences(ls, "MeshEditBatch.unrecorded("),
               countOccurrences(ls, "MeshEditBatch(")));
    assert(countOccurrences(ls,
            "auto ed = MeshEditBatch.unrecorded(m, kLoopSliceEditScope);") == 1,
        "the one `MeshEditBatch.unrecorded` open in source/mesh_ops/loop_slice.d "
      ~ "is no longer the module unittests' `sliceOnce` helper — it is the only "
      ~ "open this file is allowed, and the row above only counts them. It now "
      ~ "has a different subject or a different scope, which means a KERNEL is "
      ~ "opening it (task 1903 Stage F1).");

    // §5.7 over this file — a RETIREMENT OF FOUR that lands on ONE, not zero,
    // and the one is named. `insertEdgeLoopsMulti`'s Gap block moved both
    // members of every seam pair with `vertices[pr[0]] = …` and its Profile
    // block moved both copies of every displaced rail mid with
    // `vertices[r.midsVa[i]] = …`; all four are NESTED index expressions, the
    // shape §5.7's predicate could not see until Stage E3 widened it (cut.d's
    // sibling pair is what forced that, and E3's re-measurement named these
    // four as F1's to classify). All four are `ed.setVertexPositions` now —
    // two calls, one per block.
    //
    // The survivor is `makeTwoDisjointCubes`'s `m.vertices = [ … ]`, a
    // module-scope `private` factory that builds a LOCAL mesh for the two
    // module unittests. It is a `kAllow` entry with the reason plan §5.7
    // already recorded for it at the D3 review (and the same reason
    // `box_geom.d:1231`/`:1252`, `remesh.d:85` and `load_mesh.d:88` carry): a
    // temp mesh has no batch and needs none. It is pinned by its own text as
    // well as by the count, so "retire it by deleting the fixture" is not a
    // way to make this row green.
    assert(countOccurrences(ls, "ed.setVertexPositions(") == 2,
        "source/mesh_ops/loop_slice.d no longer makes TWO `setVertexPositions` "
      ~ "calls — the Gap option's seam separation and the Profile cutter's "
      ~ "normal displacement are the raw `vertices[pr[0]] = …` / "
      ~ "`vertices[r.midsVa[i]] = …` writes again, and a raw write inside a "
      ~ "recording batch produces NO op-log entry: a delta undo would restore "
      ~ "the topology and leave every seam half and every profiled rail at its "
      ~ "displaced coordinate (task 1903 §2.5, §5.7).");
    {
        string firstHitLs;
        immutable size_t rawWritesLs = countRawPositionWrites(ls, firstHitLs);
        assert(rawWritesLs == 1,
            format("source/mesh_ops/loop_slice.d: %d raw position write(s) "
                 ~ "under §5.7's predicate, expected exactly 1 — Stage F1 "
                 ~ "retired FOUR (the Gap pair and the Profile pair, all four "
                 ~ "nested-index writes) and the survivor is "
                 ~ "`makeTwoDisjointCubes`'s local-mesh fixture write, a "
                 ~ "kAllow entry. First hit: `%s`. `alias mesh this` means "
                 ~ "`ed.vertices[i] = p` COMPILES inside a recording batch and "
                 ~ "records nothing, which is why the boundary is a counted "
                 ~ "census and not a type (task 1903 §5.7, M-V1).",
                   rawWritesLs, firstHitLs));
        assert(countOccurrences(ls, "m.vertices = [") == 1,
            "source/mesh_ops/loop_slice.d's ONE allowed raw position write is "
          ~ "no longer `makeTwoDisjointCubes`'s `m.vertices = [ … ]`. The "
          ~ "count row above would still read 1 if a production write had "
          ~ "replaced the fixture one, so this is the half that says WHICH "
          ~ "write the allowance is for (task 1903 §5.7, Stage F1).");
    }

    // `Mesh.capShellCycles` IS GONE FROM THE WHOLE TREE, and this is the row
    // that flipped rather than being deleted. Stage E3 converted cut.d while
    // loop_slice.d was still a mixin, so cut.d's two cap calls had to reach a
    // `static` MEMBER of `Mesh` and were spelled `Mesh.capShellCycles(…)`;
    // loop_slice.d's header, cut.d's header, `tools/slice/slice_tool.d` (×3)
    // and `mesh.d` all carried notes saying so, and F1 was named in each of
    // them as the stage that removes the qualifier. It did. The compiler
    // enforces the forward direction (the member no longer exists, so the
    // qualified spelling does not compile); this row enforces the reverse —
    // it reddens if the qualifier comes back, which can only happen if
    // somebody re-adds the member and defeats the roster and the tripwire too.
    {
        import std.file : dirEntries, SpanMode;
        import std.path : relativePath;
        import std.string : replace;
        immutable srcRoot2 = buildPath(repoRoot, "source");
        string[] qualified;
        size_t scanned2 = 0;
        foreach (e; dirEntries(srcRoot2, "*.d", SpanMode.depth)) {
            ++scanned2;
            immutable src2 = stripCommentsAndStrings(readText(e.name));
            if (countOccurrences(src2, "Mesh.capShellCycles(") >= 1)
                qualified ~= relativePath(e.name, repoRoot).replace("\\", "/");
        }
        assert(scanned2 >= 100,
            format("the `Mesh.capShellCycles` walk visited only %d .d file(s) "
                 ~ "under source/ — the tree has well over 100, so the walk is "
                 ~ "mis-rooted and the assertion below would be measuring "
                 ~ "nothing.", scanned2));
        assert(qualified.length == 0,
            format("`Mesh.capShellCycles(` is spelled in %s. Stage F1 made "
                 ~ "`capShellCycles` a module-level free function of "
                 ~ "mesh_ops.loop_slice — it is no longer a `static` member of "
                 ~ "`Mesh`, so the qualified spelling can only compile if "
                 ~ "somebody re-added the member, which the roster above and "
                 ~ "loop_slice.d's own tripwire also refuse. cut.d's two cap "
                 ~ "calls are BARE (%d file(s) scanned) "
                 ~ "(task 1903 Stage F1, §2.7).", qualified, scanned2));
        immutable ct2 = stripCommentsAndStrings(readText(buildPath(repoRoot,
                            "source", "mesh_ops", "cut.d")));
        assert(countOccurrences(ct2, "capShellCycles(ed.faces,") == 2,
            "source/mesh_ops/cut.d no longer makes its two BARE "
          ~ "`capShellCycles(ed.faces, …)` calls. Those two sites are the "
          ~ "other half of Stage F1's §2.7 move: the Slice tool's Cap Sections "
          ~ "option and Loop Slice's share this geometry, and the sharing is "
          ~ "what makes the two produce byte-identical caps "
          ~ "(task 1903 Stage F1).");
    }

}

unittest // Stage F2 — the polygon bevel / inset / spike family
{
    // ---------------------------------------------------------------------
    // Stage F2 — poly.bevel + poly.inset + poly.spike. FIVE things are pinned
    // here that no earlier stage needed:
    //
    //   * THREE receiver classes in ONE file — three mutating entries, TWO
    //     `ref const(Mesh)` readers, and FIVE helpers with NO receiver at all.
    //     F1 had all three too, but its receiver-less group was `static`
    //     MEMBERS; here two of the five (`aveNormal`, `boundaryContourInset`)
    //     were static and THREE (`insetCorner`, `insetCornerBisector`,
    //     `maxSafeUniformInset`) were ordinary private members that simply
    //     never touched `this`. The rows below pin the `static` GONE as well
    //     as the receiver absent, because "still a static free function"
    //     would compile and would mean the classification was never made.
    //   * A QUALIFIER REMOVED, not added. E3 had to spell
    //     `Mesh.capShellCycles` and E4 `Mesh.rebuildFaceWithVertexSubs`
    //     because those names were `static` members of a struct their caller
    //     had already left. F2 is the mirror: the sixth unittest block wrote
    //     `Mesh.boundaryContourInset(...)` from INSIDE the template, of a
    //     static this very file DECLARES. Once the family leaves `Mesh` that
    //     qualifier stops resolving, so the three call sites are BARE — and
    //     the walk below refuses the qualifier coming back anywhere under
    //     `source/`.
    //   * SEVEN private module-scope helpers, held by TEXT and not by the
    //     build (plan §2.7 as corrected at the F1 review; памятка 32).
    //     `private` at module scope in D hides the NAME and nothing else, so
    //     a green build proves only that nobody SPELLS them. What the rows
    //     below hold is the DECISION: `mesh.d`'s `public import
    //     mesh_ops.poly_bevel;` re-exports this module's public names to
    //     every `import mesh;` client, and none of the seven has a caller
    //     outside this file — publishing them would open seven doors for
    //     nobody.
    //   * THE §5.7 ROW IS A `== 0` STATEMENT, not a retirement. This family
    //     has never carried a raw position write: every new coordinate goes
    //     through `ed.addVertex`. The zero is earned by M-V1/F2 (a raw write
    //     through a NESTED index, the shape the predicate was blind to before
    //     E3 widened it), not by the count.
    //   * THE FOUR INDEXED `ed.faces[fi] = …` INSTALLS, counted. There is no
    //     `rewriteFaces` in this family, so plan §5.3's K audit — whose needle
    //     is `rewriteFaces` — does not carry it, and its OTHER audit does.
    //     MEASURED (Stage F2): under a RECORDING batch every entry's op-log is
    //     `[AddVerts AddFaces]` per processed face and names NO face reshape,
    //     `revert()` THROWS, and arming `MeshEditTracker.wantsFaceReindex`
    //     leaves the log BYTE-IDENTICAL — the ABSENT-publisher diagnosis, not
    //     the disarmed one (памятка 12/21). Counting the installs is what
    //     makes a FIFTH one visible to the stage that owns the remedy.
    // ---------------------------------------------------------------------
    immutable pbPath = buildPath(repoRoot, "source", "mesh_ops", "poly_bevel.d");
    assert(exists(pbPath), "cannot find source/mesh_ops/poly_bevel.d at " ~ pbPath);
    immutable pb = stripCommentsAndStrings(readText(pbPath));
    assert(countOccurrences(pb, "mixin template MeshPolyBevelOps") == 0,
        "source/mesh_ops/poly_bevel.d still declares `mixin template "
      ~ "MeshPolyBevelOps` — Stage F2 converted this family to free functions; "
      ~ "a surviving template is either dead or a second implementation "
      ~ "(task 1903 Stage F2).");

    // THE THREE MUTATING RECEIVERS. The trailing comma is load-bearing (D2
    // review, MINOR-1: without it the needle is a PREFIX and `ed` -> `edb`
    // stays green).
    static immutable string[3] kEntries = ["insetFacesByMask", "bevelFacesByMask",
                                           "spikeFacesByMask"];
    foreach (name; kEntries) {
        assert(countOccurrences(pb, name ~ "(ref MeshEditBatch ed,") == 1,
            format("source/mesh_ops/poly_bevel.d no longer declares `%s` over "
                 ~ "`ref MeshEditBatch ed,`. That receiver is the enforcement, "
                 ~ "not the style: it is what makes a batchless call a COMPILE "
                 ~ "error, so one inset / bevel / spike STAMPS AND DERIVES once "
                 ~ "at close() instead of once per appended corner or apex "
                 ~ "vertex, once per appended ring quad or fan triangle and "
                 ~ "once at the tail. MEASURED on a 3x3 tagged grid: the "
                 ~ "batched `mutationVersion` delta is 1 for every selection "
                 ~ "size, where the unbatched ladder is 10 / 34 / 66 for "
                 ~ "inset and bevel and 6 / 18 / 34 for spike "
                 ~ "(task 1903 §4.1, §5.2 F2).", name));
        assert(countOccurrences(pb, name ~ "(ref Mesh ") == 0,
            format("`%s` has a `ref Mesh` receiver again — that compiles, and "
                 ~ "it drops the batch: the kernel's internal commits go back "
                 ~ "to stamping one at a time. Plan §4.4a REJECTED exactly "
                 ~ "this overload, by name, because nothing in the two lanes "
                 ~ "can see it — the geometry is identical and the receiver "
                 ~ "pin is satisfied by the `ref MeshEditBatch` overload that "
                 ~ "still exists. This row is the one thing that can "
                 ~ "(task 1903 Stage F2).", name));
        assert(countOccurrences(pb, name ~ "(ref const(Mesh)") == 0,
            format("`%s` cannot have a `ref const(Mesh)` receiver — it appends "
                 ~ "vertices and faces and replaces a winding in place. Such "
                 ~ "an overload could only exist by casting const away "
                 ~ "(task 1903 Stage F2).", name));
    }

    // THE TWO READ-ONLY RECEIVERS. Both WERE `const` members; nothing in a
    // mixin body forces the keyword, so the const receiver states what the
    // code already did and now ENFORCES it at the seam. Reached from inside
    // `bevelFacesByMask` as `f(ed.mesh, …)` — the spelling Stage E1 settled on.
    foreach (name; ["cornerNormalAt", "findGroupBoundaryContour"]) {
        assert(countOccurrences(pb, name ~ "(ref const(Mesh) m,") == 1,
            format("source/mesh_ops/poly_bevel.d no longer declares `%s` over "
                 ~ "`ref const(Mesh) m`. Both of these only READ — the corner "
                 ~ "cross-product normal and the group-boundary contour walk — "
                 ~ "and the const receiver is what states that, now enforced at "
                 ~ "the seam rather than by a keyword the mixin could have "
                 ~ "dropped at any time (task 1903 Stage F2, plan §4.1).", name));
        assert(countOccurrences(pb, name ~ "(ref MeshEditBatch") == 0,
            format("`%s` took a `ref MeshEditBatch` receiver — that compiles, "
                 ~ "and it means a pure READ now opens an edit batch and "
                 ~ "publishes a change for a call that changes nothing. "
                 ~ "`bevelFacesByMask`'s group pre-pass calls one of these "
                 ~ "once per (vertex, selected face) pair. If a later stage "
                 ~ "wants that, it is a decision to argue for here "
                 ~ "(task 1903 Stage F2).", name));
    }

    // THE SEVEN HELPERS STAY `private` AT MODULE SCOPE (column 0), AND THIS
    // ROW — not the build — IS WHAT HOLDS THAT (памятка 32, F1 review M3).
    // `private` at MODULE scope in D restricts NAME LOOKUP only: it is not an
    // encapsulation boundary, and probed with `dmd -o- -c` on `EdgeRingEntry`
    // both a field READ and a field WRITE compile from outside through
    // `auto`/`typeof`. So "the build is green with `private`" would be green
    // whatever any caller did. A TEXT census can see the spelling the compiler
    // cannot, which is why the decision lives here: widening any of these to
    // public would publish it through `mesh.d`'s `public import
    // mesh_ops.poly_bevel;` to every `import mesh;` client, and none of the
    // seven has a caller outside this file.
    static immutable string[7] kPrivateHelpers = [
        "\nprivate Vec3 insetCorner(",          "\nprivate Vec3 insetCornerBisector(",
        "\nprivate float maxSafeUniformInset(", "\nprivate Vec3 cornerNormalAt(",
        "\nprivate Vec3 aveNormal(",            "\nprivate bool findGroupBoundaryContour(",
        "\nprivate bool boundaryContourInset("];
    foreach (needle; kPrivateHelpers)
        assert(countOccurrences(pb, needle) == 1,
            format("source/mesh_ops/poly_bevel.d no longer declares `%s` at "
                 ~ "MODULE scope (column 0) with `private`. All seven helpers "
                 ~ "of this family are module-private BY DECISION, not by "
                 ~ "accident: `mesh.d` re-exports this module's PUBLIC names to "
                 ~ "every `import mesh;` client and not one of the seven has a "
                 ~ "caller outside this file. NOTE WHAT `private` DOES AND DOES "
                 ~ "NOT DO: at module scope it hides the NAME only, so no build "
                 ~ "can enforce this and THIS ROW is the enforcement. If one "
                 ~ "has to widen, say why here (task 1903 Stage F2, plan §2.7).",
                   needle[1 .. $]));

    // …and `static` is GONE from the two that carried it. A module-level
    // `private static` function still compiles and still has no receiver, so
    // the row above alone cannot tell "classified as receiver-less" from
    // "dedented with the keyword still attached" — this is the half that can.
    foreach (needle; ["private static Vec3 aveNormal(",
                      "private static bool boundaryContourInset("])
        assert(countOccurrences(pb, needle) == 0,
            format("source/mesh_ops/poly_bevel.d still spells `%s`. Both were "
                 ~ "`private static` MEMBERS of `Mesh`; at module scope the "
                 ~ "keyword is noise that reads as if a struct were still "
                 ~ "involved (task 1903 Stage F2).", needle));

    // The family's declared scope lives ONCE, beside the kernels — D2's reason
    // for `kReduceEditScope`. ONE constant for all three entries, because all
    // three declare the same class (measured: `scope_` reads 0xe on a recording
    // batch around each). SEVEN production call sites pass it.
    assert(countOccurrences(pb, "enum uint kPolyBevelEditScope =") == 1,
        "source/mesh_ops/poly_bevel.d no longer declares `kPolyBevelEditScope` "
      ~ "at module scope — SEVEN production call sites pass it (three commands, "
      ~ "the two tools' commit paths and their two per-frame previews), and a "
      ~ "per-call-site literal is the drift this constant exists to prevent "
      ~ "(task 1903 Stage F2).");

    // The constant is declared once beside the kernels, but each of the three
    // ENTRIES spells its own `commitChange` call independently — `d.scope_`
    // comes from the BATCH DECLARATION (`pushEditFrame` -> `rec.declare`), not
    // from this tail call, so a kernel's `commitChange` argument can drift
    // from `kPolyBevelEditScope` with no test noticing (review round 1,
    // MINOR-2, 2026-08-26): `poly_bevel_test.d`'s own scope-declared unittest
    // pins the CONSTANT against a hand-written `Points|Polygons|Marks`
    // duplicate and never reads a kernel's own `commitChange` line. Pin the
    // three call sites' TEXT instead — one row, all three kernels, exact
    // spelling.
    assert(countOccurrences(pb,
            "ed.commitChange(MeshEditScope.Geometry | MeshEditScope.Marks)") == 3,
        "source/mesh_ops/poly_bevel.d: the three kernels' own "
      ~ "`ed.commitChange(MeshEditScope.Geometry | MeshEditScope.Marks)` tail "
      ~ "calls no longer number exactly 3 (one per entry) with this exact "
      ~ "spelling — `kPolyBevelEditScope` above is what a RECORDING batch "
      ~ "declares, not what a kernel stamps at `commitChange`, and those two "
      ~ "can drift independently. G's `edge_bevel.d` and H's `extrude.d` "
      ~ "inherit this same hole and need their own row (task 1903 Stage F2).");

    // A KERNEL NEVER OPENS A BATCH (§4.1, §2.3 rule 2) — the absence pin, and
    // like cut.d and loop_slice.d this file cannot use the plain `== 0`
    // spelling because it keeps FIVE MUTATING module unittests that
    // legitimately open one through their own `bevelOnce` helper. So the pin
    // is two-sided: the TOTAL must be 1 (the helper is the only open, and the
    // five unittests share it), and it must be the helper's exact spelling. A
    // kernel that opened its own would take the total to 2; one that replaced
    // the helper's would keep the total and drop the shaped count.
    assert(countOccurrences(pb, "MeshEditBatch.unrecorded(") == 1
        && countOccurrences(pb, "MeshEditBatch(") == 0,
        format("source/mesh_ops/poly_bevel.d opens %d unrecorded "
             ~ "`MeshEditBatch`(es) and %d RECORDING one(s); expected exactly "
             ~ "1 and 0 — the one is the `bevelOnce` helper the five MUTATING "
             ~ "module unittests share, and a recording open anywhere in this "
             ~ "file would build an op-log nothing reads. A KERNEL never opens "
             ~ "a batch at all — the command or the tool does (plan §4.1, §2.3 "
             ~ "rule 2). If a new intra-kernel batch is genuinely needed, "
             ~ "§4.4a says what it costs: a TRANSITIONAL label, a named "
             ~ "removing stage, and a per-command nestedBatchOpens DELTA "
             ~ "assert in that command's own suite test (task 1903 Stage F2).",
               countOccurrences(pb, "MeshEditBatch.unrecorded("),
               countOccurrences(pb, "MeshEditBatch(")));
    assert(countOccurrences(pb,
            "auto ed = MeshEditBatch.unrecorded(m, kPolyBevelEditScope);") == 1,
        "the one `MeshEditBatch.unrecorded` open in source/mesh_ops/poly_bevel.d "
      ~ "is no longer the module unittests' `bevelOnce` helper — it is the only "
      ~ "open this file is allowed, and the row above only counts them. It now "
      ~ "has a different subject or a different scope, which means a KERNEL is "
      ~ "opening it (task 1903 Stage F2).");

    // §5.7 over this file — a `== 0` STATEMENT, not a retirement. Nothing in
    // this family has ever moved an EXISTING vertex: every new corner, ring
    // and apex coordinate is an `ed.addVertex` argument, which is also why
    // `kPolyBevelEditScope` carries no `Position` bit. The zero is earned by
    // the drill rather than by the count — M-V1/F2 writes the raw line through
    // a NESTED index (`ed.vertices[origFaceVerts[i]].x += 0.0f;`), the exact
    // spelling the predicate was blind to before Stage E3 widened it, and this
    // row reddens naming it.
    {
        string firstHitPb;
        immutable size_t rawWritesPb = countRawPositionWrites(pb, firstHitPb);
        assert(rawWritesPb == 0,
            format("source/mesh_ops/poly_bevel.d: %d raw position write(s) "
                 ~ "under §5.7's predicate, expected 0. First hit: `%s`. "
                 ~ "`alias mesh this` means `ed.vertices[i] = p` COMPILES "
                 ~ "inside a recording batch and records nothing, which is why "
                 ~ "the boundary is a counted census and not a type. This "
                 ~ "family declares no `Position` scope bit precisely because "
                 ~ "it moves no existing vertex; a write here breaks both "
                 ~ "statements at once (task 1903 §5.7, M-V1/F2).",
                   rawWritesPb, firstHitPb));
    }

    // THE FOUR INDEXED `ed.faces[fi] = …` INSTALLS, plan §5.3's OTHER audit.
    // `insetFacesByMask` replaces the source face's winding with the inset
    // ring in its own slot; `bevelFacesByMask` does the same with the cap and
    // ALSO rewrites an UNSELECTED neighbour's winding on the `square` splice;
    // `spikeFacesByMask` replaces the source face with the first fan triangle.
    // NONE of them calls `rewriteFaces` — MEASURED comment-stripped, the row
    // below — so K's audit needle cannot see any of it, and arming
    // `wantsFaceReindex` was measured to leave the op-log BYTE-IDENTICAL.
    assert(countOccurrences(pb, "rewriteFaces") == 0
        && countOccurrences(pb, "rewriteVertices") == 0,
        "source/mesh_ops/poly_bevel.d now calls `rewriteFaces`/"
      ~ "`rewriteVertices`. It did not when Stage F2 measured this family, and "
      ~ "that ABSENCE is the whole diagnosis: the op-log names no face change "
      ~ "because the primitive is never reached, not because its publisher is "
      ~ "disarmed. If the primitive is here now, Stage K's per-rewrite arming "
      ~ "DOES reach this family and the recording block's "
      ~ "\"STAGE K/L7/L2 FLIPS THIS\" comment has to be re-measured "
      ~ "(task 1903 §5.3, Stage F2).");
    assert(countOccurrences(pb, "ed.faces[fi] = ") == 4,
        format("source/mesh_ops/poly_bevel.d makes %d indexed `ed.faces[fi] = "
             ~ "…` installs; Stage F2 measured exactly 4 (the inset ring, the "
             ~ "bevel cap, the square splice into the UNSELECTED neighbour, "
             ~ "and the spike's first fan triangle). Every one of them is a "
             ~ "face reshape no mutation hook sees — plan §5.3's OTHER audit, "
             ~ "the class whose needle is NOT `rewriteFaces`. A fifth install "
             ~ "is a fifth silent reshape and the owning L stage (L7 for "
             ~ "bevel/inset, L2 for spikey) has to know about it "
             ~ "(task 1903 §5.3, Stage F2).",
               countOccurrences(pb, "ed.faces[fi] = ")));

    // `Mesh.boundaryContourInset` IS GONE FROM THE WHOLE TREE — the MIRROR of
    // Stage F1's `Mesh.capShellCycles` row. There the qualifier had to be
    // ADDED at E3 because cut.d converted before loop_slice.d did; here the
    // qualifier existed only because a `unittest` block INSIDE the template
    // body could reach a `static` member of the struct it was mixed into. The
    // compiler enforces the forward direction (the member no longer exists);
    // this row enforces the reverse — it reddens if the qualifier comes back,
    // which can only happen if somebody re-adds the member and defeats the
    // roster and the tripwire too.
    {
        import std.file : dirEntries, SpanMode;
        import std.path : relativePath;
        import std.string : replace;
        immutable srcRootF2 = buildPath(repoRoot, "source");
        string[] qualifiedF2;
        size_t scannedF2 = 0;
        foreach (e; dirEntries(srcRootF2, "*.d", SpanMode.depth)) {
            ++scannedF2;
            immutable srcF2 = stripCommentsAndStrings(readText(e.name));
            if (countOccurrences(srcF2, "Mesh.boundaryContourInset(") >= 1)
                qualifiedF2 ~= relativePath(e.name, repoRoot).replace("\\", "/");
        }
        assert(scannedF2 >= 100,
            format("the `Mesh.boundaryContourInset` walk visited only %d .d "
                 ~ "file(s) under source/ — the tree has well over 100, so the "
                 ~ "walk is mis-rooted and the assertion below would be "
                 ~ "measuring nothing.", scannedF2));
        assert(qualifiedF2.length == 0,
            format("`Mesh.boundaryContourInset(` is spelled in %s. Stage F2 "
                 ~ "made `boundaryContourInset` a module-private free function "
                 ~ "of mesh_ops.poly_bevel — it is no longer a `static` member "
                 ~ "of `Mesh`, so the qualified spelling can only compile if "
                 ~ "somebody re-added the member, which the roster above and "
                 ~ "poly_bevel.d's own tripwire also refuse (%d file(s) "
                 ~ "scanned) (task 1903 Stage F2, §2.7).",
                   qualifiedF2, scannedF2));
        assert(countOccurrences(pb, "assert(boundaryContourInset(") == 1
            && countOccurrences(pb, "assert(!boundaryContourInset(") == 2,
            format("source/mesh_ops/poly_bevel.d's degeneracy-gate unittest no "
                 ~ "longer makes its three BARE `boundaryContourInset(…)` "
                 ~ "calls (%d positive, %d negated; expected 1 and 2). Those "
                 ~ "three are the other half of the qualifier removal: they "
                 ~ "read `Mesh.boundaryContourInset(...)` while the block lived "
                 ~ "inside the mixin template, and the walk above only refuses "
                 ~ "the qualifier coming back — this says the calls are still "
                 ~ "there to make it (task 1903 Stage F2).",
                   countOccurrences(pb, "assert(boundaryContourInset("),
                   countOccurrences(pb, "assert(!boundaryContourInset(")));
    }

    // THE SIX MOVED `unittest` BLOCKS (§2.7), and the ledger they must not
    // move. `tests/unit/census_gate.d` counts blocks LEXICALLY over
    // `source/ ∪ tests/unit/`, so a block inside a `mixin template` and a
    // block at module scope count the same and this move is a ledger no-op —
    // which is exactly the claim §2.7 makes ("Expected: 0 dropped") and which
    // the gate itself is what verifies. What THIS row adds is that all six are
    // still HERE rather than quietly deleted: the ledger arithmetic would also
    // close if someone removed a block and added an unrelated one elsewhere in
    // the same lane.
    assert(countOccurrences(pb, "\nunittest {") == 6,
        format("source/mesh_ops/poly_bevel.d holds %d module `unittest` "
             ~ "block(s) at column 0; Stage F2 moved SIX out of the template "
             ~ "body (the `boundaryContourInset` degeneracy gate, the three "
             ~ "GROUP-accumulator findings G1/G2/G3, the WARPED isolated-face "
             ~ "law W1 and the FLAT byte-identity guard). Five of the six "
             ~ "MUTATE and reach the kernels through `bevelOnce` "
             ~ "(task 1903 §2.7, Stage F2).",
               countOccurrences(pb, "\nunittest {")));
}

// ---------------------------------------------------------------------------
// STAGE G — the MANIFOLD EDGE BEVEL family (`mesh_ops/edge_bevel.d`).
//
// One kernel, `bevelEdgesByMask`, and it is the file with the deepest nesting
// in the whole conversion (depth 7). What is DIFFERENT about this stage, and
// therefore what these rows exist to hold:
//
//   * THREE DATA FIELDS the template used to INJECT into `struct Mesh`
//     (`bevelPinnedOrphans_`, `bevelCapCoincidentPos_`, `bevelCapOrphanPos_`),
//     read by a THIRD module. A free function cannot inject a field, so their
//     DECLARATION moved into `struct Mesh` itself and every spelling at every
//     site is unchanged. That is a DECISION (plan §2.7's rule for this family)
//     and — по памятке 32 — the build cannot hold it: `private` in D restricts
//     NAME LOOKUP only, so a green build would be green whatever the readers
//     did. The rows below name the declaration site AND both reader files,
//     BOTH WAYS. The alternative (return them in a result struct) was declined
//     because it rewrites three call sites in two modules this conversion
//     otherwise does not touch — a second edit hiding inside a move.
//   * THE THIRD MODULE `dub build` CANNOT SEE. `source/mesh_bevel_census.d`
//     calls this kernel at ELEVEN sites, ALL below a module-level
//     `version (unittest):`. A signature change there is invisible to a plain
//     build; only `dub test --config=tests` and the suite binary go red. The
//     eleven now go through ONE `bevelEdgesOnce` helper, pinned two-sided.
//   * TWO `rewriteFaces` SITES IN ONE FUNCTION, under ONE shared
//     `beginCornerRewrite` handle — 1902 §2.6's shared-`rwB` constraint, which
//     plan §5.3's K-audit row records as "two sites, one function, TWO scopes".
//     The counts are pinned here so a third site, or a second handle, cannot
//     arrive unremarked.
//   * NO INDEXED `ed.faces[fi] = …` INSTALL AT ALL, which is what separates
//     this family from `bevel_fin.d` (E4) and `poly_bevel.d` (F2): both of
//     those bypass the primitive and are rows of §5.3's OTHER audit. This one
//     calls the primitive and is a DISARMED publisher — measured, not read:
//     arming `MeshEditTracker.wantsFaceReindex` turns its op-log from
//     `[AddVerts RemoveVerts Reindex]` into
//     `[AddVerts FaceReindex FaceReindex RemoveVerts Reindex]`, TWO entries,
//     ONE PER REWRITE. So Stage K reaches this half and cannot reach the
//     fin-bundle half, in one file (памятка 21, one stage carrying two
//     diagnoses — here it is one FILE carrying two).
//   * THE §5.7 ROW IS A `== 0` STATEMENT, not a retirement: this family has
//     never moved an EXISTING vertex — every new coordinate is an
//     `ed.addVertex` argument, which is also why `kEdgeBevelEditScope` carries
//     no `Position` bit. The zero is earned by M-V1/G, a raw write through a
//     NESTED index, not by the count.
// ---------------------------------------------------------------------------
unittest // Stage G — the manifold edge bevel family
{
    immutable ebPath = buildPath(repoRoot, "source", "mesh_ops", "edge_bevel.d");
    assert(exists(ebPath), "cannot find source/mesh_ops/edge_bevel.d at " ~ ebPath);
    immutable eb = stripCommentsAndStrings(readText(ebPath));
    assert(countOccurrences(eb, "mixin template MeshEdgeBevelOps") == 0,
        "source/mesh_ops/edge_bevel.d still declares `mixin template "
      ~ "MeshEdgeBevelOps` — Stage G converted this family to a free function "
      ~ "over `ref MeshEditBatch`; a surviving template is either dead or a "
      ~ "second implementation (task 1903 Stage G).");

    // THE ONE MUTATING RECEIVER. The trailing comma is load-bearing (D2 review,
    // MINOR-1): without it the needle is a PREFIX of the declaration, so
    // renaming the receiver `ed` -> `edb` would leave this pin green while the
    // name the pin exists to hold had changed.
    assert(countOccurrences(eb, "bevelEdgesByMask(ref MeshEditBatch ed,") == 1,
        "source/mesh_ops/edge_bevel.d no longer declares `bevelEdgesByMask` "
      ~ "over `ref MeshEditBatch ed,`. That receiver is the enforcement, not "
      ~ "the style: it is what makes a batchless call a COMPILE error, so one "
      ~ "edge bevel STAMPS AND DERIVES once at close() instead of once per "
      ~ "appended rail vertex, once per appended chamfer strip, once per "
      ~ "rebuildEdges and once at the tail. MEASURED on the tagged cube stand: "
      ~ "the batched `mutationVersion` delta is 1 for every selection size and "
      ~ "every round level, where the unbatched ladder is 8 / 10 / 13 / 28 for "
      ~ "1 edge L0 / 1 edge L1 / 3 edges / all 12 "
      ~ "(task 1903 §4.1, §5.2 G).");
    assert(countOccurrences(eb, "bevelEdgesByMask(ref Mesh ") == 0,
        "`bevelEdgesByMask` has a `ref Mesh` receiver again — that compiles, "
      ~ "and it drops the batch: the kernel's internal commits go back to "
      ~ "stamping one at a time. Plan §4.4a REJECTED exactly this overload, by "
      ~ "name, because nothing in the two lanes can see it — the geometry is "
      ~ "identical and the receiver pin is satisfied by the `ref MeshEditBatch` "
      ~ "overload that still exists. This row is the one thing that can "
      ~ "(task 1903 Stage G).");
    // THE TRIPWIRE ITSELF IS NOW PINNED, and this row exists because deleting
    // the whole `static assert(!__traits(hasMember, ...))` block at the foot of
    // `edge_bevel.d` was measured GREEN on both lanes (Stage G review) — it is
    // the SOLE catcher for a hand-written member or an in-struct alias of the
    // family names, and nothing was watching the catcher. Pre-existing across
    // all eight converted families; G is where it stops.
    assert(countOccurrences(eb, "static assert(!__traits(hasMember, Mesh, n)") == 1,
        "source/mesh_ops/edge_bevel.d no longer carries its "
      ~ "`static assert(!__traits(hasMember, Mesh, n), ...)` tripwire exactly "
      ~ "once. That block is the ONLY thing that fails the build when someone "
      ~ "hand-writes `Mesh.bevelEdgesByMask` or an in-struct alias of it — a "
      ~ "member BEATS a same-name UFCS free function silently, so without the "
      ~ "tripwire the family quietly stops being converted and every other row "
      ~ "here stays green. Deleting the tripwire was measured green on both "
      ~ "lanes before this row existed (task 1903 Stage G review).");
    assert(countOccurrences(eb, "bevelEdgesByMask(ref const(Mesh)") == 0,
        "`bevelEdgesByMask` cannot have a `ref const(Mesh)` receiver — it "
      ~ "appends vertices and faces, rewrites `faces` twice and compacts. Such "
      ~ "an overload could only exist by casting const away "
      ~ "(task 1903 Stage G).");

    // A KERNEL NEVER OPENS A BATCH (§4.1, §2.3 rule 2) — and on THIS file that
    // row is also the proof that Stage G removed E4's transitional debt. Both
    // spellings, because `MeshEditBatch(` alone does not catch
    // `MeshEditBatch.unrecorded(` and vice versa.
    assert(countOccurrences(eb, "MeshEditBatch(") == 0
        && countOccurrences(eb, "MeshEditBatch.unrecorded(") == 0,
        "source/mesh_ops/edge_bevel.d opens a `MeshEditBatch`. A KERNEL never "
      ~ "opens one — the command, the tool, or (transitionally, §4.4a) a "
      ~ "still-mixin caller does. Until Stage G this file held exactly TWO such "
      ~ "opens, at the fin-bundle early returns, because it was itself a mixin "
      ~ "body with no caller-held batch to hand on; Stage G converted it and "
      ~ "both went away. This row is what says so — the per-command "
      ~ "`nestedBatchOpens` delta in tests/test_bevel_fin_bundle.d CANNOT: it "
      ~ "read 0 with the transitional opens (they were the OUTERMOST batch) and "
      ~ "reads 0 without them (task 1903 Stage G, §4.4a).");

    // …and the two fin-bundle hand-offs are PLAIN CALLS, in tail position.
    assert(countOccurrences(eb, "return ed.bevelIsolatedFinBundleSpine(") == 1
        && countOccurrences(eb, "return ed.bevelFinBundleSpineMultiEdge(") == 1,
        "source/mesh_ops/edge_bevel.d no longer hands a fin bundle straight to "
      ~ "`bevel_fin.d`'s two kernels inside the CALLER's batch. Stage E4 had to "
      ~ "wrap each in an `unrecorded` batch of its own because this body was a "
      ~ "mixin; Stage G's whole change to these two arms is that the wrapper is "
      ~ "gone and the call is direct. A re-wrapped call would also trip the "
      ~ "`MeshEditBatch` row above, which is why both exist "
      ~ "(task 1903 Stage G, §4.4a).");

    // THE FAMILY'S DECLARED SCOPE, ONE HOME — D2's reason for
    // `kReduceEditScope`. THREE production call sites pass it (the command's
    // edge arm, the tool's commit, the tool's per-frame preview) plus three
    // test helpers, so it has room to drift.
    assert(countOccurrences(eb, "enum uint kEdgeBevelEditScope =") == 1,
        "source/mesh_ops/edge_bevel.d no longer declares `kEdgeBevelEditScope` "
      ~ "at module scope — three production call sites and three test helpers "
      ~ "pass it, and a per-call-site literal is the drift this constant exists "
      ~ "to prevent (task 1903 Stage G).");

    // …AND THE KERNEL'S OWN `commitChange` FLAGS ARE BOUND TO IT. Stage F2's
    // review (MINOR-2) found this hole on poly_bevel.d: `kEdgeBevelEditScope`
    // is what a RECORDING batch DECLARES, and the literal below is what the
    // kernel STAMPS — two different spellings of the same intent, able to
    // drift independently with nothing watching. Stage H's `extrude.d`
    // inherits the same hole and needs its own row.
    assert(countOccurrences(eb,
            "ed.commitChange(MeshEditScope.Geometry | MeshEditScope.Marks)") == 1,
        "source/mesh_ops/edge_bevel.d: the kernel's own "
      ~ "`ed.commitChange(MeshEditScope.Geometry | MeshEditScope.Marks)` tail "
      ~ "call no longer appears exactly once with this exact spelling — "
      ~ "`kEdgeBevelEditScope` above is what a RECORDING batch declares, not "
      ~ "what the kernel stamps at `commitChange`, and those two can drift "
      ~ "independently. H's `extrude.d` inherits this same hole and needs its "
      ~ "own row (task 1903 Stage G, Stage F2 review MINOR-2).");

    // THE TWO REWRITES UNDER ONE HANDLE (1902 §2.6's shared-`rwB` constraint,
    // plan §5.3's K-audit row). BOTH numbers matter and in opposite directions:
    // a THIRD rewrite is a face change nobody audited, and a SECOND
    // `beginCornerRewrite` would split the shared handle the corner-provenance
    // capture depends on.
    assert(countOccurrences(eb, "rewriteFaces(ed,") == 2,
        format("source/mesh_ops/edge_bevel.d calls `rewriteFaces(ed, …)` %d "
             ~ "time(s); Stage G measured exactly 2 — the rebuild pass and the "
             ~ "new-vertex merge pass, in ONE function, under ONE "
             ~ "`beginCornerRewrite` handle. That pairing is 1902 §2.6's "
             ~ "shared-`rwB` constraint and plan §5.3's K-audit row for this "
             ~ "family (\"two sites, one function, TWO scopes\"): Stage K owes "
             ~ "this family TWO per-rewrite arming scopes, not one, and a third "
             ~ "site would silently need a third (task 1903 Stage G).",
               countOccurrences(eb, "rewriteFaces(ed,")));
    assert(countOccurrences(eb, "ed.beginCornerRewrite()") == 1,
        "source/mesh_ops/edge_bevel.d no longer opens exactly ONE "
      ~ "`beginCornerRewrite` handle for its two `rewriteFaces` calls. The "
      ~ "shared handle is the constraint 1902 §2.6 states: this kernel declares "
      ~ "corner provenance ONCE, after the SECOND rewrite (task 1903 Stage G).");

    // …and NO indexed install, which is what puts this family on the ARMABLE
    // side of §5.3's split. `bevel_fin.d` and `poly_bevel.d` install windings
    // with `ed.faces[fi] = …` and reach no hook at all; this one goes through
    // the primitive every time.
    {
        import std.regex : ctRegex, matchAll;
        size_t installs = 0;
        foreach (_; matchAll(eb, ctRegex!(`ed\.faces\s*\[[^\]]*\]\s*=[^=]`))) ++installs;
        assert(installs == 0,
            format("source/mesh_ops/edge_bevel.d makes %d indexed "
                 ~ "`ed.faces[…] = …` install(s); Stage G measured ZERO. Every "
                 ~ "winding this family writes goes through "
                 ~ "`mesh_planes.rewriteFaces`, and that is exactly why its "
                 ~ "publisher is DISARMED rather than ABSENT — arming "
                 ~ "`wantsFaceReindex` changes its op-log, where it leaves "
                 ~ "bevel_fin.d's and poly_bevel.d's byte-identical. An indexed "
                 ~ "install here would move this family into §5.3's OTHER "
                 ~ "audit, out of Stage K's reach, with no other row noticing "
                 ~ "(task 1903 Stage G, plan §5.3).", installs));
    }

    // THE THREE `Mesh.`-QUALIFIED STATICS. `faceAttrOr` and
    // `combineFaceMarksWords` were widened at F1 and `rebuildFaceWithVertexSubs`
    // at E4; all three are `static`, so UFCS through the batch handle cannot
    // reach them and this file must SPELL the qualifier. The §2.6 rows'
    // needles are receiver-agnostic and did not change — verified by the walk
    // in the widenings block below, not assumed.
    assert(countOccurrences(eb, "Mesh.faceAttrOr(") == 2
        && countOccurrences(eb, "Mesh.combineFaceMarksWords(") == 1
        && countOccurrences(eb, "Mesh.rebuildFaceWithVertexSubs(") == 1,
        format("source/mesh_ops/edge_bevel.d spells `Mesh.faceAttrOr(` %d "
             ~ "time(s), `Mesh.combineFaceMarksWords(` %d and "
             ~ "`Mesh.rebuildFaceWithVertexSubs(` %d; Stage G measured 2 / 1 / "
             ~ "1. All three are `static` MEMBERS of `Mesh`, so a bare call "
             ~ "cannot resolve from a free function and the qualifier is not "
             ~ "decoration — it is the one qualified member spelling this "
             ~ "family keeps (task 1903 Stage G, §2.6).",
               countOccurrences(eb, "Mesh.faceAttrOr("),
               countOccurrences(eb, "Mesh.combineFaceMarksWords("),
               countOccurrences(eb, "Mesh.rebuildFaceWithVertexSubs(")));

    // …and the two nested TYPES the mixin body used to reach unqualified.
    assert(countOccurrences(eb, "Mesh.VertSub") == 6
        && countOccurrences(eb, "Mesh.Marks.Select") == 2,
        format("source/mesh_ops/edge_bevel.d spells `Mesh.VertSub` %d time(s) "
             ~ "and `Mesh.Marks.Select` %d; Stage G measured 6 and 2. Both are "
             ~ "NESTED TYPES of `Mesh` that a mixin body saw unqualified "
             ~ "(plan §4.3 step 4). A bare spelling does not compile from a "
             ~ "free function, so a drop here is a compile error — but a GROWTH "
             ~ "is a new use nobody counted (task 1903 Stage G).",
               countOccurrences(eb, "Mesh.VertSub"),
               countOccurrences(eb, "Mesh.Marks.Select")));

    // THE SCOPED IMPORT THE TEMPLATE BODY CARRIED. `import mesh_ops.bevel_curves;`
    // sat INSIDE the template because a mixin body resolves free names at its
    // INSTANTIATION site, so a module-level import here did not reach it
    // (measured, task 0717). With the template gone it is an ordinary
    // module-level import — and it must stay in THIS file rather than migrate
    // to mesh.d, which is what the column-0 needle says.
    assert(countOccurrences(eb, "\nimport mesh_ops.bevel_curves;") == 1,
        "source/mesh_ops/edge_bevel.d no longer imports `mesh_ops.bevel_curves` "
      ~ "at MODULE scope (column 0). It was a SCOPED import inside the mixin "
      ~ "template body — the shape a mixin forces — and Stage G's conversion is "
      ~ "what made an ordinary import possible. Moving it to mesh.d instead "
      ~ "would put this file's dependency somewhere it is not used "
      ~ "(task 1903 Stage G, plan §4.3 step 2).");

    // §5.7 — a `== 0` STATEMENT, not a retirement (E4's pair and F2 are the
    // other two of this shape). Earned by M-V1/G: a raw write through a NESTED
    // index (`ed.vertices[vEdges[0]].x += 0.0f;`), the spelling the predicate
    // was blind to before Stage E3 widened it.
    {
    string ebFirstHit;
    immutable size_t ebRaw = countRawPositionWrites(eb, ebFirstHit);
    assert(ebRaw == 0,
        format("source/mesh_ops/edge_bevel.d: %d raw position write(s) under "
             ~ "§5.7's predicate, expected 0. First hit: `%s`. This family has "
             ~ "never moved an EXISTING vertex — every rail, miter, hub and cap "
             ~ "coordinate is an `ed.addVertex` argument — which is the same "
             ~ "property that keeps the `Position` bit OUT of "
             ~ "`kEdgeBevelEditScope`. A raw write here would move a vertex "
             ~ "with nothing recorded and nothing stamped "
             ~ "(task 1903 Stage G, plan §5.7).",
               ebRaw, ebFirstHit));
    }

    // ---- THE THREE PARITY FIELDS, BOTH WAYS --------------------------------
    //
    // They are MEMBERS OF `Mesh` and that is Stage G's recorded decision, not
    // an oversight (plan §2.7's rule for this family). Their VISIBILITY is
    // unchanged: a mixin-injected member with no access specifier is PUBLIC, so
    // these three have always been public members and this stage neither widens
    // nor narrows anything. What holds the decision is THIS ROW, not the build
    // (памятка 32: `private` in D restricts NAME LOOKUP only, so a green build
    // would be green whatever the readers did) — and the tripwire at the foot
    // of edge_bevel.d deliberately does NOT list them, because for these three
    // `__traits(hasMember, Mesh, …)` answers `true` and always will.
    immutable meshPath = buildPath(repoRoot, "source", "mesh.d");
    immutable meshSrc  = stripCommentsAndStrings(readText(meshPath));
    static immutable string[3] kParityDecls = ["uint[] bevelPinnedOrphans_;",
                                               "Vec3[] bevelCapCoincidentPos_;",
                                               "Vec3[] bevelCapOrphanPos_;"];
    foreach (decl; kParityDecls)
        assert(countOccurrences(meshSrc, decl) == 1,
            format("source/mesh.d no longer declares `%s` exactly once. "
                 ~ "`mixin MeshEdgeBevelOps;` used to INJECT this field into "
                 ~ "`struct Mesh`; a free function cannot inject a field, so "
                 ~ "Stage G moved the DECLARATION into the struct that already "
                 ~ "owned it and changed no spelling at any site. Returning it "
                 ~ "in a result struct instead was DECLINED: that rewrites "
                 ~ "three call sites in two modules this conversion does not "
                 ~ "otherwise touch, which plan §2.7 calls a second edit hiding "
                 ~ "inside a move (task 1903 Stage G, §2.7).", decl));
    assert(countOccurrences(eb, "bevelPinnedOrphans_") >= 1
        && countOccurrences(eb, "bevelCapCoincidentPos_") >= 1
        && countOccurrences(eb, "bevelCapOrphanPos_") >= 1,
        "source/mesh_ops/edge_bevel.d no longer WRITES the three parity fields "
      ~ "it owns. They are `Mesh` state kept for ONE reader — the free-end cap "
      ~ "census — and a declaration with no writer is three public fields open "
      ~ "for nobody (task 1903 Stage G).");
    // …and BOTH readers, named. A row that only pins the declaration is
    // satisfied by a field nobody reads.
    {
        static immutable string[] kReaders =
            ["source/mesh_bevel_census.d", "tests/unit/mesh_ops/edge_bevel_test.d"];
        foreach (rel; kReaders) {
            immutable rp = buildPath(repoRoot, rel);
            assert(exists(rp), "cannot find " ~ rel ~ " at " ~ rp);
            immutable txt = stripCommentsAndStrings(readText(rp));
            assert(countOccurrences(txt, "bevelCapCoincidentPos_") >= 1
                && countOccurrences(txt, "bevelCapOrphanPos_") >= 1,
                rel ~ " no longer reads `bevelCapCoincidentPos_` / "
              ~ "`bevelCapOrphanPos_`. These three fields exist ONLY so a "
              ~ "reader outside `mesh_ops/edge_bevel.d` can exempt the "
              ~ "valence-4 free-end cap's intended coincident pair and orphan "
              ~ "slide from a soundness census. With no reader left, the right "
              ~ "change is to DELETE them, not to keep three public `Mesh` "
              ~ "fields alive for a caller that went away "
              ~ "(task 1903 Stage G, §2.7).");
        }
    }

    // ---- THE THIRD MODULE `dub build` CANNOT SEE ---------------------------
    //
    // `source/mesh_bevel_census.d` is a `source/` module whose entire body sits
    // below a module-level `version (unittest):`. It calls this kernel at
    // ELEVEN sites; when Stage G changed the signature, `dub build` stayed
    // green and only `dub test --config=tests` / the suite binary went red.
    // That is why this stage's gate is BOTH lanes.
    immutable mbcPath = buildPath(repoRoot, "source", "mesh_bevel_census.d");
    assert(exists(mbcPath), "cannot find source/mesh_bevel_census.d at " ~ mbcPath);
    immutable mbc = stripCommentsAndStrings(readText(mbcPath));
    assert(countOccurrences(mbc, "\nversion (unittest):") == 1,
        "source/mesh_bevel_census.d no longer gates its whole body behind a "
      ~ "module-level `version (unittest):`. That gate is why a signature "
      ~ "change in `mesh_ops/edge_bevel.d` is INVISIBLE to `dub build` here, "
      ~ "and why Stage G's gate is both lanes (task 1903 Stage G).");
    assert(countOccurrences(mbc, "bevelEdgesOnce(") == 12,
        format("source/mesh_bevel_census.d makes %d `bevelEdgesOnce(` "
             ~ "reference(s); Stage G measured 12 — the helper's own "
             ~ "declaration plus the ELEVEN census call sites it replaced. A "
             ~ "LOWER count is a site that went back to calling the kernel "
             ~ "directly (which no longer compiles on a bare `Mesh`, so it "
             ~ "would have to have opened its own batch); a HIGHER one is a new "
             ~ "site nobody counted (task 1903 Stage G).",
               countOccurrences(mbc, "bevelEdgesOnce(")));
    // The two-sided helper pin, F1's `sliceOnce` shape: ONE unrecorded open
    // with this exact spelling, and ZERO recording ones. A site that started
    // opening its own batch is caught either by the count or by the shape.
    assert(countOccurrences(mbc, "MeshEditBatch.unrecorded(m, kEdgeBevelEditScope)") == 1
        && countOccurrences(mbc, "MeshEditBatch(") == 0,
        format("source/mesh_bevel_census.d opens %d unrecorded "
             ~ "`MeshEditBatch`(es) with the helper's exact spelling and %d "
             ~ "RECORDING one(s); expected exactly 1 and 0. The eleven census "
             ~ "sites go through ONE helper so there is ONE place that says why "
             ~ "the batch is unrecorded — nothing in this census reads an "
             ~ "op-log, so a recording batch would build a delta for no reader "
             ~ "and `close()` would drop it (task 1903 Stage G).",
               countOccurrences(mbc, "MeshEditBatch.unrecorded(m, kEdgeBevelEditScope)"),
               countOccurrences(mbc, "MeshEditBatch(")));

    // ---- THE ABSENCE PIN ---------------------------------------------------
    //
    // `Mesh.bevelEdgesByMask(` must appear NOWHERE under `source/`. The mirror
    // of E3's `Mesh.capShellCycles` row and F2's `Mesh.boundaryContourInset`
    // one — except that here the qualifier never existed to begin with, so this
    // row is NEW rather than flipped (памятка 25: a brief's "there is a row to
    // flip" is a hypothesis; grepped, there was none). The non-vacuity floor is
    // what stops a broken walk from reading as a clean tree.
    {
        import std.file : dirEntries, SpanMode;
        size_t scanned = 0;
        string[] offenders;
        foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
            ++scanned;
            immutable t = stripCommentsAndStrings(readText(de.name));
            if (countOccurrences(t, "Mesh.bevelEdgesByMask(") > 0)
                offenders ~= de.name;
        }
        assert(scanned >= 100,
            format("the source/** walk found only %d .d files — a walk that "
                 ~ "stopped looking reports a clean tree for free", scanned));
        assert(offenders.length == 0,
            format("`Mesh.bevelEdgesByMask(` is spelled in %s. Stage G moved "
                 ~ "this kernel OUT of `struct Mesh`, so that qualifier can "
                 ~ "only resolve again if the family came back as a member — "
                 ~ "which is what edge_bevel.d's `static assert` tripwire "
                 ~ "refuses, and which this row catches from the call-site side "
                 ~ "(task 1903 Stage G, §2.7).", offenders));
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
    immutable lsPath2 = buildPath(repoRoot, "source", "mesh_ops", "loop_slice.d");
    assert(exists(lsPath2), "cannot find source/mesh_ops/loop_slice.d at " ~ lsPath2);
    immutable ls2 = stripCommentsAndStrings(readText(lsPath2));
    immutable pbPath2 = buildPath(repoRoot, "source", "mesh_ops", "poly_bevel.d");
    assert(exists(pbPath2), "cannot find source/mesh_ops/poly_bevel.d at " ~ pbPath2);
    immutable pb2 = stripCommentsAndStrings(readText(pbPath2));

    // The file each row's `callSite` is looked for in. D3's three rows are all
    // bridge.d's; E3 added three that are cut.d's, so the row carries its own
    // ops file rather than the block assuming one (task 1903 Stage E3). E4 adds
    // the two bevel files.
    immutable string[string] opsSrc = ["source/mesh_ops/bridge.d":       br,
                                       "source/mesh_ops/cut.d":          ct,
                                       "source/mesh_ops/bevel_fin.d":    bf2,
                                       "source/mesh_ops/bevel_vertex.d": bv2,
                                       "source/mesh_ops/loop_slice.d":   ls2,
                                       "source/mesh_ops/poly_bevel.d":   pb2];

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
               ~ "not of the converted family. `mesh_ops/edge_bevel.d` (Stage G) "
               ~ "spells it the same way since its own conversion; "
               ~ "`mesh_ops/extrude.d` is still a mixin until Stage H."),
        // --- Stage F1's two, both `static`, both first needed HERE ---------
        // Neither was widened by an earlier stage: `cut.d` (E3) and the two
        // bevel files (E4) name neither, so F1 is the first converted caller
        // and pays for both. Like `rebuildFaceWithVertexSubs` they are
        // `static`, so UFCS through the batch handle cannot reach them and
        // loop_slice.d spells them `Mesh.faceAttrOr(...)` /
        // `Mesh.combineFaceMarksWords(...)` — the two qualified member
        // spellings this stage keeps.
        //
        // MEASURED CORRECTION TO PLAN §2.6 (2026-08-26): that table credits
        // `loop_slice.d` with FIVE `faceAttrOr` sites and totals 17. On the
        // pre-conversion file the CALL count is FOUR — the fifth occurrence is
        // inside a `//` comment at what was `loop_slice.d:970`, and §2.6's own
        // preamble says its numbers were taken comment-stripped. The tree
        // total is 16 (extrude.d 10, loop_slice.d 4, edge_bevel.d 2), and the
        // needle below is what keeps that honest from now on.
        Widening("Mesh.faceAttrOr",
                 "private static T faceAttrOr(",
                 "static T faceAttrOr(T)(in T[] attr, size_t fi)",
                 "source/mesh_ops/loop_slice.d",
                 "Mesh.faceAttrOr(",
                 "faceAttrOr(",
                 ["source/mesh_ops/edge_bevel.d",
                  "source/mesh_ops/extrude.d",
                  "source/mesh_ops/loop_slice.d"],
                 "the bounds-defended per-face attribute read — `fi < attr.length "
               ~ "? attr[fi] : T.init` — that every kernel emitting faces uses "
               ~ "instead of indexing `faceMarks`/`faceMaterial`/`facePart`/"
               ~ "`faceSetMask` directly, because those arrays are allowed to "
               ~ "run SHORT of `faces` between a topology edit and its "
               ~ "finalize. It is the largest of §2.6's eleven: "
               ~ "`mesh_ops/extrude.d` (Stage H) names it at ten sites and is "
               ~ "STILL A MIXIN — the needle is TEXT, so it appears in the walk, "
               ~ "and §2.6's rule (\"the stage that inherits a public name says "
               ~ "who else uses it\") is exactly what that is for. "
               ~ "`mesh_ops/edge_bevel.d` names it at two sites and CONVERTED at "
               ~ "Stage G, which changed their spelling to `Mesh.faceAttrOr(` "
               ~ "and this row not at all — the needle is receiver-agnostic, "
               ~ "verified by the walk rather than assumed."),
        Widening("Mesh.combineFaceMarksWords",
                 "private static uint combineFaceMarksWords(",
                 "static uint combineFaceMarksWords(uint a, uint b)",
                 "source/mesh_ops/loop_slice.d",
                 "Mesh.combineFaceMarksWords(",
                 "combineFaceMarksWords(",
                 ["source/mesh_ops/edge_bevel.d",
                  "source/mesh_ops/loop_slice.d"],
                 "the per-bit fold of two faces' mark words, used where ONE new "
               ~ "face has SEVERAL source faces and no single one to inherit "
               ~ "from: Loop Slice's Cap Sections arm folds every ring face's "
               ~ "word into the cap's. `mesh_ops/edge_bevel.d` is the other "
               ~ "caller — it folds the two host faces' words into each chamfer "
               ~ "strip's — and it CONVERTED at Stage G, which changed its "
               ~ "spelling to `Mesh.combineFaceMarksWords(` and left this row "
               ~ "alone (the needle is receiver-agnostic)."),
        // --- Stage F2's one, and it is NOT a `Mesh` member ------------------
        // The same CLASS as `mesh.smoothstep01` (Stage D3): a module-level
        // free function of `mesh` that a converted family names, whose privacy
        // was an artefact of the mixin body being looked up in `mesh.d`'s
        // scope. The difference is that this one is `version (unittest)`, so
        // the surface it opens exists only in a unittest build — but the row
        // is the same shape and for the same reason, and it is what refuses a
        // re-privatisation that would break `dub test --config=tests` while
        // leaving `dub build` green.
        //
        // WHY NOT A LOCAL COPY IN poly_bevel.d, which would have needed no
        // widening at all: measured, not preferred. A copy carries
        // `m.vertices = verts;`, which §5.7's predicate counts, and it would
        // turn Stage F2's clean `== 0` raw-position-write row into a `kAllow`
        // entry — trading a five-line duplicate for a permanently weaker
        // census row.
        Widening("mesh.buildRawMesh",
                 "version (unittest) private Mesh buildRawMesh(",
                 "version (unittest) Mesh buildRawMesh(Vec3[] verts, uint[][] faceList)",
                 "source/mesh_ops/poly_bevel.d",
                 "buildRawMesh(",
                 "buildRawMesh(",
                 ["source/mesh_ops/poly_bevel.d"],
                 "the raw fixture builder (`vertices = …; faces = …; "
               ~ "rebuildEdgesFromFaces(); buildLoops(); resetSelection();`) "
               ~ "shared by `mesh.d`'s own T-S1 grid and by the five "
               ~ "`bevelFacesByMask` unittest blocks Stage F2 moved out of the "
               ~ "template body. Those blocks reached it only because a mixin "
               ~ "body — unittest blocks included — is looked up in its "
               ~ "INSTANTIATION scope; as module unittests of "
               ~ "mesh_ops.poly_bevel they cannot. CALLER WALK IS "
               ~ "`source/**`-SCOPED (review round 1, MINOR-3, 2026-08-26): "
               ~ "the walk below reads `source/` only, so a `tests/**` caller "
               ~ "of this `version (unittest)` name — none exists today — "
               ~ "would be invisible to it and this row would stay green over "
               ~ "a caller it cannot see."),
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
