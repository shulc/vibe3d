// parity_capture_key_census_test — every undo-parity reader owns a DISTINCT
// capture key and a DISTINCT fixture leaf, and the two maps are 1:1
// (task 1903 stage L9-0; witness W-KEY).
//
// THE INCIDENT THIS RETIRES, and it is a shipped one rather than a
// hypothetical. `VIBE3D_PARITY_CAPTURE` was a bare literal inside
// `undo_parity_l0_test.compareOrCapture`, and that function is IMPORTED and
// reused by two more readers (`undo_parity_l1_test.d:36`,
// `undo_parity_l2_test.d:52`). `environment` is process-wide and druntime runs
// every unittest module in ONE process, so a capture run meant for ONE family
// re-froze `position_marks.json` and `uv_maps_sets.json` in the same run —
// silently, and against trees whose own headers declare those files immutable.
// Stage L3 dodged it by writing a private `compareOrCaptureL3` with a suffixed
// key; stage L5 wrote a third copy of the same body for the same reason. Two
// copies of one mechanism, and stages L7 and L9 owed a fourth and a fifth.
//
// So the key became a PARAMETER (`compareOrCapture(..., string captureKey)`)
// and this census is what keeps the parameterisation honest. Without it the
// class is not retired, only moved: passing `"VIBE3D_PARITY_CAPTURE"` — or
// L5's key — from a new reader is one token, compiles, and reintroduces the
// exact cross-freeze.
//
// WHAT IT CHECKS, on the CODE view only (comments and string-literal prose
// mentioning a key must not inflate the count — this very header would):
//
//   1. every `tests/unit/undo_parity_*_test.d` names EXACTLY ONE distinct
//      `VIBE3D_PARITY_CAPTURE*` key and EXACTLY ONE distinct `*.json` fixture
//      leaf;
//   2. no two readers share a key;
//   3. no two readers share a leaf;
//   4. the BARE `VIBE3D_PARITY_CAPTURE` (no `_L*` suffix) appears in NO
//      reader — it is the one name that cannot be owned by anybody.
//
// MUTATION THAT REDDENS IT: give L9's reader `VIBE3D_PARITY_CAPTURE_L7` (or
// the bare name). Items 2 and 4 name BOTH files. Run in isolation — druntime
// stops a module at its first failing assert.
//
// A NOTE ON THE FILE FLOOR. The scan is `__FILE_FULL_PATH__`-rooted, not
// cwd-rooted, and it asserts it found at least ten readers: a glob that
// silently matches nothing is a census that passes because it looked at
// nothing, which is this repository's most-paid-for defect class.
module tests.unit.parity_capture_key_census_test;

import std.algorithm : sort, startsWith;
import std.array     : appender;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.format    : format;
import std.path      : baseName, buildPath, dirName;

import tests.unit.revert_entry_census_test : blankNonCode;

private enum unitDir = dirName(__FILE_FULL_PATH__);

/// Every distinct `VIBE3D_PARITY_CAPTURE…` token appearing in a string
/// literal in CODE.
///
/// Read off the RAW text but only where `blankNonCode` left code standing:
/// `blankNonCode` blanks string literals too (it is written for a census that
/// wants none), so the two views are intersected by POSITION — a token whose
/// offset falls inside a blanked COMMENT is dropped, one inside a blanked
/// string LITERAL is kept. That distinction is the whole point: the keys live
/// in literals, the prose that must not count lives in comments.
private string[] scanTokens(string raw, string needle)
{
    // `keepComments = false` blanks BOTH comments and string literals;
    // `keepComments = true` blanks the literals ONLY and leaves comments
    // standing. So a position blank in the first and NON-blank in the second
    // was a COMMENT; blank in both was a string LITERAL, which is exactly
    // where the keys live and must be kept.
    const noComments = blankNonCode(raw, false);
    const noLiterals = blankNonCode(raw, true);
    bool[string] seen;
    size_t i = 0;
    while (i + needle.length <= raw.length) {
        if (raw[i .. i + needle.length] == needle) {
            // in a comment <=> blank in `noComments` and NOT blank in
            // `noLiterals` (a literal is blank in both).
            immutable inComment = noComments[i] == ' ' && noLiterals[i] != ' ';
            if (!inComment) {
                size_t j = i;
                while (j < raw.length &&
                       (raw[j] == '_' || (raw[j] >= 'A' && raw[j] <= 'Z') ||
                        (raw[j] >= '0' && raw[j] <= '9'))) ++j;
                seen[raw[i .. j]] = true;
            }
            i += needle.length;
            continue;
        }
        ++i;
    }
    string[] outv;
    foreach (k; seen.byKey) outv ~= k;
    outv.sort();
    return outv;
}

/// Every distinct `"<something>.json"` literal in CODE.
private string[] scanLeaves(string raw)
{
    const noComments = blankNonCode(raw, false);
    const noLiterals = blankNonCode(raw, true);
    bool[string] seen;
    size_t i = 0;
    while (i + 5 <= raw.length) {
        if (raw[i .. i + 5] == ".json") {
            immutable inComment = noComments[i] == ' ' && noLiterals[i] != ' ';
            if (!inComment) {
                // walk back to the opening quote of the literal
                size_t s = i;
                while (s > 0 && raw[s - 1] != '"' && raw[s - 1] != '\n') --s;
                if (s > 0 && raw[s - 1] == '"') seen[raw[s .. i + 5]] = true;
            }
            i += 5;
            continue;
        }
        ++i;
    }
    string[] outv;
    foreach (k; seen.byKey) outv ~= k;
    outv.sort();
    return outv;
}

unittest // the two scanners tell a comment from a literal
{
    enum string probe =
        "// VIBE3D_PARITY_CAPTURE_LX and \"prose.json\" in a COMMENT\n"
      ~ "void f() { g(\"real.json\", \"VIBE3D_PARITY_CAPTURE_L9\"); }\n";
    auto keys = scanTokens(probe, "VIBE3D_PARITY_CAPTURE");
    assert(keys == ["VIBE3D_PARITY_CAPTURE_L9"],
        format("the key scanner counted a COMMENT mention: %s — every reader's "
             ~ "header discusses the other readers' keys in prose, so a "
             ~ "comment-blind scanner reports every file as owning every key",
               keys));
    auto leaves = scanLeaves(probe);
    assert(leaves == ["real.json"],
        format("the leaf scanner counted a COMMENT mention: %s", leaves));
}

unittest // THE CENSUS
{
    struct Reader { string file; string[] keys; string[] leaves; }
    Reader[] readers;

    foreach (de; dirEntries(unitDir, "undo_parity_*_test.d", SpanMode.shallow)) {
        immutable raw = readText(de.name);
        readers ~= Reader(baseName(de.name),
                          scanTokens(raw, "VIBE3D_PARITY_CAPTURE"),
                          scanLeaves(raw));
    }
    readers.sort!((a, b) => a.file < b.file);

    // Vacuity floor FIRST, so a glob that matched nothing is diagnosed as
    // that and not as "every check passed".
    assert(readers.length >= 12, format(
        "the parity-key census found %d reader(s) under %s — the tree has at "
      ~ "least eleven "
      ~ "(`undo_parity_l0/l1/l2/l3/l5/l6/l7/l7d/l8/l9/l10_test.d`; L6 and L7d "
      ~ "arrived with task 1903 stages L6 and L7-d, L8 with stage L8-0). A "
      ~ "glob that silently matches nothing makes every assertion below "
      ~ "vacuous; fix the walk, do not lower this floor.",
        readers.length, unitDir));

    auto bad = appender!string;
    string[string] keyOwner;   // key  -> file
    string[string] leafOwner;  // leaf -> file

    foreach (ref r; readers) {
        // 1. exactly one of each.
        if (r.keys.length != 1)
            bad.put(format("\n    %s names %d distinct capture key(s) %s — "
                         ~ "exactly one is owed", r.file, r.keys.length, r.keys));
        if (r.leaves.length != 1)
            bad.put(format("\n    %s names %d distinct fixture leaf(s) %s — "
                         ~ "exactly one is owed", r.file, r.leaves.length,
                           r.leaves));
        // 4. the bare name belongs to nobody.
        foreach (k; r.keys)
            if (k == "VIBE3D_PARITY_CAPTURE")
                bad.put(format("\n    %s uses the BARE key "
                             ~ "`VIBE3D_PARITY_CAPTURE` — it is process-wide "
                             ~ "and shared by every reader that imports "
                             ~ "`compareOrCapture`, so a capture run for this "
                             ~ "family re-freezes the others' fixtures too. "
                             ~ "That is the shipped incident this census "
                             ~ "retires.", r.file));
        // 2 + 3. no sharing.
        foreach (k; r.keys) {
            if (auto o = k in keyOwner)
                bad.put(format("\n    capture key %s is claimed by BOTH %s and "
                             ~ "%s — one capture run would write both "
                             ~ "fixtures", k, *o, r.file));
            else keyOwner[k] = r.file;
        }
        foreach (l; r.leaves) {
            if (auto o = l in leafOwner)
                bad.put(format("\n    fixture leaf %s is claimed by BOTH %s and "
                             ~ "%s", l, *o, r.file));
            else leafOwner[l] = r.file;
        }
    }

    assert(bad.data.length == 0, format(
        "task 1903 L9-0 (W-KEY): the undo-parity readers' `leaf <-> capture "
      ~ "key` map is no longer 1:1.%s\n\n  Scanned %d reader(s) under %s.",
        bad.data, readers.length, unitDir));
}
