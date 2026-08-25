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
    enum size_t kExpected = 12;          // Stage C converted MeshSelectLoopOps
    assert(live.length == kExpected,
        format("source/mesh.d instantiates %d `mixin Mesh*Ops` templates; this "
             ~ "gate expects %d. Track 1 started at %d and every conversion "
             ~ "stage deletes its own line in its own commit, so a HIGHER count "
             ~ "is a reinstated mixin and a LOWER one is a stage that landed "
             ~ "without updating this number. Live: %s "
             ~ "(task 1903 §4.5)", live.length, kExpected, kAtStart, live));

    // …and these are gone BY NAME. `MeshSelectLoopOps` cannot come back beside
    // its free functions without silently taking every call site with it.
    static immutable string[] kConverted = ["MeshSelectLoopOps"];
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
    assert(countOccurrences(ops, "selectLoopEdges(ref const(Mesh) m") == 1,
        "source/mesh_ops/select_loop.d no longer declares `selectLoopEdges` as "
      ~ "a free function over `ref const(Mesh)` — if the receiver changed, say "
      ~ "why here: `ref const(Mesh)` is what keeps `mesh.selectLoopEdges(seed)` "
      ~ "compiling verbatim at ~40 call sites (task 1903 §4.1).");
}
