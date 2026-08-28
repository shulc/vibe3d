// version_poll_census_test — every production version-counter COMPARE must
// carry a written argument (task 1906 stage 2e,
// `doc/bus_sync_listeners_plan.md` §3.6, "the recorded remainder").
//
// WHAT THIS GATE IS FOR. Task 1906 moved the position-dependent caches off
// `Mesh.mutationVersion` and friends onto synchronous bus deliveries, because a
// gizmo drag is deliberately version-silent and every such cache went stale on
// the gesture users make most (task 0401 found three; 1906 found a fourth, the
// surface BVH). The counters were NOT deleted — several are still the right
// answer — so the outcome of the task is not "no version compares" but "no
// UN-ARGUED version compare". §3.6 of the plan lists the survivors with the
// reason each one survives. This census is the executable half of that table:
// it fails when a version poll exists in `source/**` with no `recorded
// remainder` note in the dozen lines above it.
//
// So the failure it is built to catch is not a wrong answer. It is a NEW
// version poll added by someone who did not know the counters had been
// re-classified — the exact way the four stale caches of 0401 were written in
// the first place, each of them a locally reasonable `!= mutationVersion`.
//
// WHAT COUNTS AS A COMPARE. Three shapes, and the second and third were added
// at the 2e review fold because a reviewer found three LIVE polls the
// first-shape-only scanner could not see (`xfrm_transform.d`, `rotate.d`,
// `scale.d`, all in the transform tools' selection/mutation staleness gate):
//
//   A. DIRECT — one line names a counter AND carries `==` or `!=`.
//   B. WRAPPED — one line names a counter and does not end the statement, and
//      the NEXT line carries the comparison. This is one expression split for
//      width, and a line scanner reading either half alone sees nothing.
//   C. TWO-HOP — a line assigns a local from an expression naming a counter
//      (`ulong curMutVer = mesh.mutationVersion;`) and a line within
//      `kTwoHopWindow` below compares that local (`curMutVer != lastMutVer`).
//      NOTE the second half is invisible on its own for a reason worth stating:
//      the names the codebase gives such locals — `lastMutationVersion`,
//      `curMutVer` — do not CONTAIN any counter name, because D's house style
//      capitalises the embedded word. So "just also match `…Version`" does not
//      work; the carrier has to be tracked from its assignment.
//
// Shape A over-counts in principle (a counter and an unrelated equality on one
// line) and the over-count is the safe direction: it demands an argument.
//
// WHY THE DETECTION IS BUILT ON THREE VIEWS OF THE SAME FILE. Each view keeps
// exactly what the question it answers needs, and blanking is done IN PLACE so
// every view still reports the real line number:
//
//   * the CODE view — comments, string/backtick/char literals and `unittest`
//     bodies all blanked — is where compares are looked for. A sentence that
//     quotes `x != mesh.mutationVersion` (this tree has many, mostly in notes
//     explaining why a compare was removed) is not a finding, and neither is a
//     test asserting `m.mutationVersion == before`, which is this census's own
//     subject matter rather than a production poll.
//   * the MARKER view — comments KEPT, literals blanked — is where the
//     argument is looked for. It is NOT the raw text, and that is the point:
//     on raw text a string literal reading `"… recorded remainder …"` silences
//     every compare below it for fourteen lines, which is a gate anyone can
//     turn off by accident. Cell: `markerInAStringDoesNotSilence`.
//   * `version (unittest)` blocks are LEFT ALONE in both. They hold PRODUCTION
//     seams (mock hooks, test-visible accessors) that a poll can hide in, and
//     `source/**` has ~195 of them. Only a real `unittest { … }` body is
//     blanked. The two are one token apart and the first scanner blanked both;
//     cell: `versionUnittestIsProductionCode`.
//
// WHAT IT STILL CANNOT SEE, stated plainly rather than left to be discovered:
//   * A STAMP into a struct that is later compared WHOLE — `_newKey.meshMutVer
//     = mesh.mutationVersion;` feeding `_newKey != _key` — names no counter at
//     the compare and no local carries it either. `viewport.DirtyKey`'s two
//     version terms are that shape; they carry their marker at the stamp and
//     are listed in §3.6. Closing this would need type-aware analysis, not a
//     bigger regex: the compare's operand is a struct whose FIELD is the
//     counter, and only a type checker knows that.
//   * A COUNTER LAUNDERED THROUGH A FUNCTION — `bool stale() { return v !=
//     m.mutationVersion; }` is seen (shape A, at its own line), but a caller
//     writing `if (stale())` is not, and does not need to be: the compare
//     itself is the site and it is the one that carries the note.
//
// AND ONE THING IT SEES TOO EASILY, which is the honest weakness of a
// window-based marker: a note silences its NEIGHBOURS as well as its own
// compare. With 41 notes in `source/**` and a fifteen-line window each, some
// six hundred lines of the tree are already "argued" before anyone writes a
// line there — so a new poll added directly beneath an existing note is born
// green. The window cannot shrink much (ten-plus lines of reasoning is the
// house style for these notes, and the note has to reach past the compare's
// own multi-line condition), so this is a stated limit, not a bug to fix here.
// ==> CLOSED AT STAGE 4 by the SET GATE at the bottom of this file. A poll
// born under someone else's note still slips the marker gate; it does NOT
// slip the set gate, because that file's recorded site COUNT goes up. The two
// gates are deliberately different questions — "is this compare argued" and
// "is this compare one of the ones we argued" — and only the second one
// notices an ADDITION that came with an argument attached to it.
// The resolution is the per-file COUNT, so a SWAP inside one file (one poll
// deleted, one added, both argued) is invisible to BOTH gates — measured at the
// stage-4 review; §3.6's symbol column is the human check for that cell, and
// `symbols` here is deliberately not matched against anything.
//
// THE FLOOR BELOW THE GATE. A scanner that lost its place (an unterminated
// literal, a stripper bug) finds nothing and the gate passes vacuously, so the
// site count is asserted AFTER the real assertion — a canary in front of the
// gate would bury the message that matters.
module tests.unit.version_poll_census_test;

import std.algorithm : any, canFind, endsWith;
import std.array     : appender, array;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : splitLines, strip, toLower;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// The counters §3.6 tracks. `sourceVersion` / `sourceTopologyVersion` are
/// `SubpatchPreview`'s two freshness terms (row 10) — they are copies of the
/// mesh counters and belong to the same census.
private immutable string[] kCounters = [
    "mutationVersion", "structVersion", "topologyVersion", "marksVersion",
    "uploadVersion", "sourceVersion", "sourceTopologyVersion",
];

/// The marker a compare must carry, matched case-insensitively so both the
/// lower-case house style and the shouted `RECORDED REMAINDER` of the older
/// notes count.
private enum string kMarker = "recorded remainder";

/// How far above a compare the argument may sit. Ten-plus lines of reasoning is
/// normal here; the window has to reach past the compare's own multi-line
/// condition to the comment block that opens the statement.
private enum size_t kMarkerWindow = 14;

/// How far below its assignment a counter-carrying local stays interesting
/// (shape C). The three live sites compare one and two lines after the
/// assignment; six lines covers a `bool x = …;` intermediate without letting a
/// long-lived loop variable collect unrelated equalities.
private enum size_t kTwoHopWindow = 6;

// ---------------------------------------------------------------------------
// Blank comments and/or literals IN PLACE — same length, same line breaks, so a
// finding still reports the real line number. `keepComments` selects the MARKER
// view (comments kept, literals blanked) over the CODE view (both blanked);
// either way the walker still RECOGNISES comments, so a quote mark inside one
// can never open a literal.
//
// HANDLED SINCE TASK 2007: wysiwyg (`r"…"`) and delimited/token strings
// (`q"…"`, `q{…}`). This block used to claim "neither unhandled form appears in
// a scanned file today" and rest the whole no-parser argument on that. HALF of
// it was false, and the false half was the one that matters — MEASURED
// 2026-08-28 over `source/**` with an identifier-boundary test, which is what
// the original claim lacked:
//
//   * `q{…}` — REAL, and in THREE files: `source/gpu_select.d`,
//     `source/shader.d`, `source/subpatch_osd.d` (GLSL sources). `gpu_select.d`
//     is itself a `kRemainder` file, so the desync risk sat directly under a
//     recorded site.
//   * `q"…"` — ZERO occurrences. (A naive `grep q"` reports three, all of them
//     the two characters `q"` INSIDE an ordinary literal: `entry["seq"]`,
//     `` `{"seq":` ``. The card that raised this item counted that grep.)
//   * `r"…"` — ZERO occurrences as a LITERAL. The naive `grep r"` reports 166
//     files and the boundary-aware one still reports four, and all four are
//     `…"r"…` / `'\r'` inside ordinary literals — `File(path, "r")`,
//     `enabled["r"]`, `"\\r"`, `,"r":%d`. So the ORIGINAL claim happened to be
//     true for these two forms and false for the third.
//
// Both are lexed now rather than argued about, because "no such literal in the
// tree today" is a claim that decays silently with every commit, and the one
// that decayed took the argument down with it. Character literals ARE handled,
// including `'\''` and `'"'`. The floor at the bottom still notices a desync
// from any form nobody has thought of, because a desynced scanner eats the rest
// of the file and the site count collapses.
// ---------------------------------------------------------------------------
package string blankNonCode(string src, bool keepComments = false) {
    auto outBuf = new char[src.length];
    foreach (i, c; src) outBuf[i] = (c == '\n') ? '\n' : ' ';
    size_t codeStart = 0;
    void keep(size_t a, size_t b) {
        foreach (k; a .. b) if (src[k] != '\n') outBuf[k] = src[k];
    }
    // Blank [a, b) by closing the kept run before it and reopening after.
    void drop(size_t a, size_t b) { keep(codeStart, a); codeStart = b; }

    size_t i = 0;
    while (i < src.length) {
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '/') {
            const size_t s = i;
            while (i < src.length && src[i] != '\n') ++i;
            if (!keepComments) drop(s, i);
            continue;
        }
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '*') {
            const size_t s = i;
            i += 2;
            while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) ++i;
            i = (i + 2 <= src.length) ? i + 2 : src.length;
            if (!keepComments) drop(s, i);
            continue;
        }
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '+') {
            const size_t s = i;
            int depth = 0;
            while (i < src.length) {
                if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '+') { ++depth; i += 2; continue; }
                if (i + 1 < src.length && src[i] == '+' && src[i + 1] == '/') { --depth; i += 2; if (depth == 0) break; continue; }
                ++i;
            }
            if (!keepComments) drop(s, i);
            continue;
        }
        // TOKEN and WYSIWYG strings, before the plain `"` handler — they open
        // on a LETTER, so by the time the walker reaches the quote the prefix
        // is already behind it. See the block comment above for what was
        // measured and why this is not the "no such literal here" claim it
        // replaced.
        if ((src[i] == 'q' || src[i] == 'r')
            && (i == 0 || !isIdentChar(src[i - 1]))
            && i + 1 < src.length) {
            // `r"…"` — wysiwyg, no escape processing at all.
            if (src[i] == 'r' && src[i + 1] == '"') {
                const size_t s = i;
                i += 2;
                while (i < src.length && src[i] != '"') ++i;
                i = (i + 1 <= src.length) ? i + 1 : src.length;
                drop(s, i);
                continue;
            }
            // `q{…}` — token string, braces NEST.
            if (src[i] == 'q' && src[i + 1] == '{') {
                const size_t s = i;
                i += 2;
                int depth = 1;
                while (i < src.length && depth > 0) {
                    if (src[i] == '{') ++depth;
                    else if (src[i] == '}') --depth;
                    ++i;
                }
                drop(s, i);
                continue;
            }
            // `q"…"` — delimited. Bracket forms nest; anything else is the
            // heredoc form, closed by `<ident>"` on its own.
            if (src[i] == 'q' && src[i + 1] == '"') {
                const size_t s = i;
                const char open = (i + 2 < src.length) ? src[i + 2] : '\0';
                char close = '\0';
                switch (open) {
                    case '(': close = ')'; break;
                    case '[': close = ']'; break;
                    case '<': close = '>'; break;
                    case '{': close = '}'; break;
                    default:  break;
                }
                if (close != '\0') {
                    i += 3;
                    int depth = 1;
                    while (i < src.length && depth > 0) {
                        if (src[i] == open) ++depth;
                        else if (src[i] == close) --depth;
                        ++i;
                    }
                    if (i < src.length && src[i] == '"') ++i;
                } else {
                    // q"IDENT\n … \nIDENT"
                    size_t t = i + 2;
                    while (t < src.length && isIdentChar(src[t])) ++t;
                    const string tag = src[i + 2 .. t];
                    i = t;
                    if (tag.length) {
                        const string term = tag ~ "\"";
                        while (i + term.length <= src.length
                               && src[i .. i + term.length] != term) ++i;
                        i = (i + term.length <= src.length)
                            ? i + term.length : src.length;
                    }
                }
                drop(s, i);
                continue;
            }
        }
        if (src[i] == '"') {
            const size_t s = i;
            ++i;
            while (i < src.length && src[i] != '"') {
                if (src[i] == '\\' && i + 1 < src.length) ++i;
                ++i;
            }
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            drop(s, i);
            continue;
        }
        if (src[i] == '`') {
            const size_t s = i;
            ++i;
            while (i < src.length && src[i] != '`') ++i;
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            drop(s, i);
            continue;
        }
        if (src[i] == '\'') {
            const size_t s = i;
            ++i;
            while (i < src.length && src[i] != '\'') {
                if (src[i] == '\\' && i + 1 < src.length) ++i;
                ++i;
            }
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            drop(s, i);
            continue;
        }
        ++i;
    }
    keep(codeStart, src.length);
    return cast(string)outBuf;
}

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

/// `id` appears in `ln` as a whole identifier, not as a substring of a longer
/// one. Shape C needs this: `ver` must not match `verify`.
private bool namesIdent(string ln, string id) {
    if (id.length == 0 || id.length > ln.length) return false;
    foreach (i; 0 .. ln.length - id.length + 1) {
        if (ln[i .. i + id.length] == id
            && (i == 0 || !isIdentChar(ln[i - 1]))
            && (i + id.length >= ln.length || !isIdentChar(ln[i + id.length])))
            return true;
    }
    return false;
}

/// Shape C, first half: the identifier a PLAIN assignment on this line writes,
/// when the value assigned comes from an expression naming a counter. `null`
/// when the line is not that shape. Compound assignments (`+=`) and any form of
/// `==`/`!=`/`<=`/`>=` are not assignments for this purpose.
private string assignedCounterCarrier(string ln) {
    foreach (i, c; ln) {
        if (c != '=') continue;
        if (i + 1 < ln.length && ln[i + 1] == '=') return null;
        if (i > 0 && "=!<>+-*/%&|^~".canFind(ln[i - 1])) continue;
        size_t e = i;
        while (e > 0 && (ln[e - 1] == ' ' || ln[e - 1] == '\t')) --e;
        size_t s = e;
        while (s > 0 && isIdentChar(ln[s - 1])) --s;
        if (s == e) return null;
        const rhs = ln[i + 1 .. $];
        if (!kCounters.any!(k => rhs.canFind(k))) return null;
        return ln[s .. e];
    }
    return null;
}

private struct Site {
    string file;
    size_t line;      // 1-based, into the ORIGINAL text
    string text;
    bool   argued;
    string shape;     // "direct" | "wrapped" | "two-hop"
}

// ---------------------------------------------------------------------------
// The scanner proper, over ONE file's text. Split out from the tree walk so the
// cells below can feed it a scratch buffer: a probe that has to be written into
// `source/` and taken out again is a probe nobody re-runs.
// ---------------------------------------------------------------------------
private Site[] scanSource(string label, string src) {
    const string code  = blankUnittestBodies(blankNonCode(src));
    const string marks = blankNonCode(src, /*keepComments=*/true);
    auto codeLines = code.splitLines();
    auto markLines = marks.splitLines();

    bool argumentAbove(size_t li) {
        const size_t lo = li >= kMarkerWindow ? li - kMarkerWindow : 0;
        foreach (k; lo .. li + 1)
            if (k < markLines.length && markLines[k].toLower.canFind(kMarker))
                return true;
        return false;
    }

    static struct Carrier { string name; size_t line; }
    Carrier[] carriers;

    auto sites = appender!(Site[]);
    void record(size_t li, string text, string shape) {
        sites.put(Site(label, li + 1, text.strip, argumentAbove(li), shape));
    }

    foreach (li, ln; codeLines) {
        const bool namesCounter = kCounters.any!(k => ln.canFind(k));
        const bool hasCompare   = ln.canFind("==") || ln.canFind("!=");

        if (namesCounter && hasCompare) {
            record(li, ln, "direct");                                  // A
        } else if (namesCounter && !ln.strip.endsWith(";")
                && li + 1 < codeLines.length
                && (codeLines[li + 1].canFind("==")
                 || codeLines[li + 1].canFind("!=")))
        {
            record(li, ln.strip ~ " | " ~ codeLines[li + 1].strip, "wrapped");  // B
        }

        if (namesCounter && !hasCompare) {
            const carrier = assignedCounterCarrier(ln);
            if (carrier !is null) carriers ~= Carrier(carrier, li);    // C, half 1
        }
        if (hasCompare && !namesCounter) {
            foreach (ref cr; carriers) {
                if (li > cr.line && li - cr.line <= kTwoHopWindow
                 && namesIdent(ln, cr.name))
                {
                    record(li, ln, "two-hop");                         // C, half 2
                    break;
                }
            }
        }
    }
    return sites.data;
}

/// Blank the body of every `unittest` block in an already-code-only view.
///
/// `package`, like `blankNonCode` above and for the same reason: the other
/// censuses in this package need the same two views and a second copy of a
/// stripper is a second thing to get wrong.
///
/// `version (unittest)` is NOT such a block and must survive: it holds
/// PRODUCTION seams (mock hooks, test-visible accessors) that a poll can hide
/// in, and there are ~195 of them under `source/`. The two differ by one
/// character of context — the `(` that precedes the keyword — because a real
/// `unittest` block is a DECLARATION and can never be parenthesised. That is
/// the whole test below, and it is a cell (`versionUnittestIsProductionCode`)
/// rather than a comment because the first version of this scanner got it
/// wrong while the header claimed otherwise.
package string blankUnittestBodies(string code) {
    auto buf = code.dup;
    void blankBlock(size_t from) {
        size_t j = from;
        while (j < buf.length && buf[j] != '{') {
            if (buf[j] == ';') return;      // `unittest` used as a name; bail
            ++j;
        }
        if (j >= buf.length) return;
        int depth = 0;
        for (; j < buf.length; ++j) {
            const char c = buf[j];
            if (c == '{') ++depth;
            else if (c == '}') { --depth; if (depth == 0) { buf[j] = ' '; return; } }
            if (c != '\n') buf[j] = ' ';
        }
    }
    // True when the keyword at `i` is the `unittest` of `version (unittest)` /
    // `debug (unittest)` — i.e. the nearest non-blank character before it is an
    // open parenthesis.
    bool parenthesised(size_t i) {
        size_t k = i;
        while (k > 0 && (buf[k - 1] == ' ' || buf[k - 1] == '\t'
                      || buf[k - 1] == '\n' || buf[k - 1] == '\r')) --k;
        return k > 0 && buf[k - 1] == '(';
    }
    enum kw = "unittest";
    size_t i = 0;
    while (i + kw.length <= buf.length) {
        if (buf[i .. i + kw.length] == kw
            && (i == 0 || !isIdentChar(buf[i - 1]))
            && (i + kw.length >= buf.length || !isIdentChar(buf[i + kw.length]))
            && !parenthesised(i))
        {
            blankBlock(i + kw.length);
            i += kw.length;
            continue;
        }
        ++i;
    }
    return cast(string)buf;
}

private Site[] scanTree() {
    auto sites = appender!(Site[]);
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
        sites.put(scanSource(de.name[repoRoot.length + 1 .. $], readText(de.name)));
    return sites.data;
}

// ---------------------------------------------------------------------------
// SCANNER CELLS, FIRST — because druntime stops a module at its first failing
// assert, and a broken scanner must say so in its own words instead of showing
// up as a strange tree verdict below.
// ---------------------------------------------------------------------------

/// TASK 2007 item 9 — TOKEN AND WYSIWYG LITERALS ARE LEXED, not assumed
/// absent. Each probe hides ONE unbalanced `"` inside a literal form the
/// stripper used to walk straight through, and then puts a real site AFTER it.
/// Without the corresponding arm in `blankNonCode` that stray quote opens a
/// D string that runs to the end of the text, the site is blanked away, and the
/// assert reads 0 — which is exactly how a desynced scanner goes quietly green
/// over a whole file.
unittest {
    // `q{…}` — the form that is REALLY in the tree (gpu_select.d, shader.d,
    // subpatch_osd.d), one of which is a `kRemainder` file.
    //
    // THE DISCRIMINATOR IS "IS THE BODY CODE?", NOT "DOES A STRAY QUOTE EAT
    // THE FILE". A first draft of this cell hid an unbalanced `"` in a comment
    // inside the token string and asserted a later site survived — and it
    // passed with the `q{` arm DISABLED, because the comment stripper ate the
    // quote first. (D also forbids an unbalanced quote inside `q{…}`: the body
    // must lex as D tokens, so that probe was not even legal input.) What
    // actually changes is that the body is a STRING, so a compare written
    // inside it is NOT a site — walk into it and the scanner invents one.
    enum string tokenStr = q"PROBE
        private immutable string fragSrc = q{
            void main() { if (mesh.mutationVersion != cachedVer) rebuild(); }
        };
PROBE";
    auto t = scanSource("probe.d", tokenStr);
    assert(t.length == 0, format(
        "a version compare written INSIDE a `q{…}` token string was counted "
      ~ "as %d production site(s) — it is string CONTENT, not code, and the "
      ~ "stripper walked into the body. THREE source files carry `q{…}` today "
      ~ "and one of them (gpu_select.d) is a kRemainder file: %s",
        t.length, t));

    // `q"(…)"` — delimited, bracket form. Zero occurrences in `source/**`
    // today; lexed anyway, because "there are none today" is the argument
    // that already decayed once for `q{…}`.
    enum string delimStr = q"PROBE
        enum msg = q"(a stray " quote inside a delimited string)";
        void update() {
            if (mesh.mutationVersion != cachedVer) rebuild();
        }
PROBE";
    auto d = scanSource("probe.d", delimStr);
    assert(d.length == 1, format(
        "a site after a `q\"(…)\"` delimited string was not seen: %s", d));

    // `r"…"` — wysiwyg. The discriminating body is a lone backslash: read as
    // an ordinary string it ESCAPES the closing quote and the literal never
    // ends.
    enum string wysiwyg = q"PROBE
        enum sep = r"\";
        void update() {
            if (mesh.mutationVersion != cachedVer) rebuild();
        }
PROBE";
    auto w = scanSource("probe.d", wysiwyg);
    assert(w.length == 1, format(
        "a site after a `r\"\\\"` wysiwyg string was not seen: %s", w));

    // THE CONTROL, so none of the three above can pass for the wrong reason:
    // the identical probe with no literal at all must find the same one site.
    enum string plain = q"PROBE
        void update() {
            if (mesh.mutationVersion != cachedVer) rebuild();
        }
PROBE";
    assert(scanSource("probe.d", plain).length == 1,
        "the bare probe must find its one site — otherwise the three cells "
      ~ "above are measuring the probe, not the stripper");

    // …and the identifier-boundary term: `r` / `q` are ordinary letters, so a
    // name ENDING in one, followed by a string, must not be read as a prefix.
    // …and the identifier-BOUNDARY term, which is not decoration: an
    // identifier ending in `q` can sit IMMEDIATELY against an opening brace in
    // perfectly ordinary D, and without the boundary test the walker reads
    // those two characters as a token string and blanks the whole body.
    enum string notAPrefix = q"PROBE
        struct Fooq{
            void update() {
                if (mesh.mutationVersion != cachedVer) rebuild();
            }
        }
PROBE";
    assert(scanSource("probe.d", notAPrefix).length == 1,
        "`struct Fooq{` was read as a `q{…}` token string and its whole body "
      ~ "blanked — `q` here is the last letter of an identifier, not a "
      ~ "literal prefix, which is what the identifier-boundary term is for");
}

/// Shape C: the counter is read into a local on one line and compared on the
/// next. This is the shape of the transform tools' staleness gate — three live
/// sites the first scanner could not see — and note that NOTHING on the compare
/// line contains a counter name. (The probes are DELIMITED strings, not `q{…}`
/// token strings: the lexer discards comments inside a token string, which
/// would quietly delete the marker from the third probe and make it pass for
/// the wrong reason.)
unittest {
    enum string twoHop = q"PROBE
        void update() {
            ulong curMutVer = mesh.mutationVersion;
            if (curHash != lastSelectionHash
             || curMutVer != lastMutationVersion) { closeEdit(); }
        }
PROBE";
    auto s = scanSource("probe.d", twoHop);
    assert(s.length == 1, format("two-hop compare not seen: %s", s));
    assert(s[0].shape == "two-hop", s[0].shape);
    assert(!s[0].argued);

    // The discriminator: the SAME compare with the carrier assigned from
    // something that is not a counter is not a site. Without this the cell
    // would pass for a scanner that flags every `!=` in the tree.
    enum string notACounter = q"PROBE
        void update() {
            ulong curMutVer = mesh.vertices.length;
            if (curMutVer != lastMutationVersion) { closeEdit(); }
        }
PROBE";
    assert(scanSource("probe.d", notACounter).length == 0);

    // And the marker silences it, at the compare line like any other shape.
    enum string argued = q"PROBE
        void update() {
            ulong curMutVer = mesh.mutationVersion;
            // recorded remainder (1906 3.6): because reasons.
            if (curMutVer != lastMutationVersion) { closeEdit(); }
        }
PROBE";
    auto a = scanSource("probe.d", argued);
    assert(a.length == 1 && a[0].argued);
}

/// Shape B: one expression split across two lines for width. Neither half is a
/// finding on its own.
unittest {
    enum string wrapped = q"PROBE
        void f() {
            if (cached.sourceVersion
                != source.mutationVersion) { rebuild(); }
        }
PROBE";
    auto s = scanSource("probe.d", wrapped);
    assert(s.length >= 1, "wrapped compare not seen");
    assert(!s[0].argued);

    // A counter named on a line that ENDS its statement does not reach forward
    // to an unrelated comparison below it.
    enum string closed = q"PROBE
        void f() {
            stamp = mesh.mutationVersion;
            if (a != b) { rebuild(); }
        }
PROBE";
    assert(scanSource("probe.d", closed).length == 0);
}

unittest { // a char literal holding a quote must not desync the literal blanker
    // `'"'` occurs in source/ (forms.d, http_server.d); if the blanker read it as
    // the start of a string, everything after it would be blanked and the compare
    // on the next line would vanish. Measured (2e review round 2): 1 site with
    // the char-literal branch, 0 without it.
    enum string charLit = q"PROBE
        void f(char c) {
            if (c == '"') return;
            if (cachedVer != mesh.mutationVersion) rebuild();
        }
PROBE";
    assert(scanSource("probe.d", charLit).length == 1,
        "the char literal '\"' swallowed the compare on the next line — the "
        ~ "blanker's char-literal branch is gone or broken");
}

/// `version (unittest)` is production code and is scanned; a real `unittest`
/// body is not. The two are one token apart and the scanner used to blank both
/// while this file's header claimed it did not.
unittest {
    enum string underVersion = q"PROBE
        version (unittest) {
            bool stale() { return cachedVer != mesh.mutationVersion; }
        }
PROBE";
    auto v = scanSource("probe.d", underVersion);
    assert(v.length == 1, format("version (unittest) body was blanked: %s", v));
    assert(!v[0].argued);

    enum string underBlock = q"PROBE
        unittest {
            assert(m.mutationVersion == before);
        }
PROBE";
    assert(scanSource("probe.d", underBlock).length == 0,
        "a real unittest body is the census's own subject matter");
}

/// The argument is read on the MARKER view, not on raw text: a string literal
/// that happens to contain the marker cannot silence the compare below it.
/// This is the difference between a gate and a gate anyone can switch off by
/// writing a sentence.
unittest {
    enum string inALiteral = q"PROBE
        void f() {
            log("cache key: recorded remainder (1906 3.6) note");
            if (cachedVer != mesh.mutationVersion) rebuild();
        }
PROBE";
    auto lit = scanSource("probe.d", inALiteral);
    assert(lit.length == 1);
    assert(!lit[0].argued,
        "a string literal quoting the marker silenced a real compare");

    enum string inAComment = q"PROBE
        void f() {
            // recorded remainder (1906 3.6): note.
            if (cachedVer != mesh.mutationVersion) rebuild();
        }
PROBE";
    auto com = scanSource("probe.d", inAComment);
    assert(com.length == 1 && com[0].argued,
        "a real comment marker must still count");
}

// ---------------------------------------------------------------------------
// THE GATE. Every production version compare carries its argument.
// ---------------------------------------------------------------------------
unittest {
    auto sites = scanTree();

    auto unargued = appender!string;
    size_t nBad = 0;
    foreach (ref s; sites) {
        if (s.argued) continue;
        ++nBad;
        unargued.put(format("\n    %s:%d  [%s]\n        %s",
                            s.file, s.line, s.shape, s.text));
    }

    assert(nBad == 0, format(
        "task 1906 §3.6: %d production version-counter compare(s) carry no "
      ~ "`// recorded remainder (1906 §3.6): …` note within %d lines above "
      ~ "them.%s\n\n"
      ~ "  A version compare is not wrong by itself — §3.6 of "
      ~ "doc/bus_sync_listeners_plan.md lists the ones that are right. What is "
      ~ "wrong is an UN-ARGUED one: task 0401's four stale caches were each a "
      ~ "locally reasonable `!= mutationVersion`, and a gizmo drag never moves "
      ~ "that counter. Either key the cache on `mesh_dirty`'s bus epochs, or "
      ~ "write the note saying which counter owns the compare and why a change "
      ~ "class cannot answer it — and add the row to §3.6.",
        nBad, kMarkerWindow, unargued.data));

    // Vacuity floor, AFTER the assertion it protects: a scanner that lost its
    // place (see the stripper caveat above) reports nothing and the gate above
    // passes for the wrong reason. 19 sites stood at stage 2e (14 direct + 5 two-hop); the floor is set
    // below that so a legitimate migration can retire rows without touching
    // this file, but far enough above zero to catch a dead scanner.
    assert(sites.length >= 8, format(
        "the version-poll scanner found only %d compare site(s) in source/ — "
      ~ "it has almost certainly lost its place (an unterminated literal, a "
      ~ "wysiwyg string, or a stripper bug), which makes the gate above "
      ~ "vacuous. Fix the scanner, do not lower this floor. (A marker that "
      ~ "stopped matching does NOT show up here — it shows up as a long list "
      ~ "on the assertion above, which is the right place for it.)",
        sites.length));
}

// ---------------------------------------------------------------------------
// THE SET GATE (task 1906 stage 4). The remainder is not just argued — it is
// ENUMERATED, and nothing may join it quietly.
//
// WHY A SECOND GATE OVER THE SAME SCAN. The marker gate above asks "does this
// compare carry an argument". That question is answered by the fifteen lines
// above the compare, so a NEW poll written directly under an EXISTING note is
// born green — stated as a known hole in the header, and it is the same hole
// task 0401's four stale caches went through (each was locally reasonable).
// This gate asks the other question: "is this compare one of the nineteen we
// argued". A new site is red here whether or not it came with prose.
//
// WHY THE TABLE LIVES HERE AND NOT IN THE PLAN DOC. `doc/` is a gitignored
// symlink in this checkout and does not exist in a clean clone, so a gate that
// parsed §3.6 would be unrunnable in CI — i.e. exactly the "the run never
// happened" green this repo keeps paying for. The tracked copy is therefore
// the one below; §3.6 of `doc/bus_sync_listeners_plan.md` carries the same
// nineteen rows with a paragraph of reasoning each, and the two are edited
// together. Precedent: `tests/unit/census_ledger.txt`.
//
// WHY PER-FILE COUNTS AND NOT `file:line`. A `file:line` table reddens on
// every unrelated edit ABOVE a row, which trains people to bump a number
// instead of to think — the objection is recorded in the plan (§4 stage 3) and
// it is why the 2e census stopped short of this. A per-file count is immune to
// line drift and to reformatting, and still reddens in BOTH directions the
// stage-4 validation names: delete a row from the table without deleting the
// code and the file is over its count; add a poll without adding a row and the
// file is over its count the other way round.
//
// WHAT IT DELIBERATELY DOES NOT ASSERT: that no consumer both subscribes to
// the bus and polls a version on the SAME change class. That property is true
// of all nineteen rows and is what each row's note argues, but it is not
// derivable from source text — row 10 (`SubpatchPreview`) is BOTH a bus
// consumer and a version poller, and is correct precisely because the epoch
// carries `Position|Points|Polygons` while the poll carries `Marks|Material`.
// A scanner cannot see a change class. What is mechanised is the weaker,
// checkable half: the set is closed, so no consumer can START doing both
// without a human writing the row.
//
// IT IS SELF-DEFENDING AGAINST VACUITY without a separate floor: if the
// scanner loses its place, every recorded file reports "0 found, expected N"
// and this gate is the loudest thing in the lane.
//
// It runs AFTER the marker gate on purpose. druntime stops a module at its
// first failed assert, and when someone adds an un-argued poll BOTH gates
// have something to say — "write the note" is the more useful of the two.
// ---------------------------------------------------------------------------

/// One row per FILE of §3.6's site-by-site table. `symbols` is for the failure
/// message only: it is what a reader needs in order to go and find the rows,
/// and it is not matched against anything.
private struct RemainderFile {
    string file;
    size_t sites;
    string symbols;
}

/// §3.6, "The remainder, SITE BY SITE" — 19 production compares over 9 files,
/// complete as of stage 4 (2026-08-26). Line numbers are deliberately absent;
/// the SYMBOL is the reference.
private static immutable RemainderFile[] kRemainder = [
    RemainderFile("source/app.d", 3,
        "rebuildLoopHoverMask (row 20) | the missedPublishers shadow check "
      ~ "| the cage/preview upload fast path (row 3)"),
    RemainderFile("source/bvh_pick.d", 1,
        "BvhPick.pickFace (row 6) — keys on the VBO content it rasterises from"),
    RemainderFile("source/gpu_select.d", 1,
        "GpuSelectBuffer.ensureSlot (row 5) — same, uploadVersion"),
    RemainderFile("source/mesh_edit_delta.d", 1,
        "finalize's fast-path structVersion backstop (task 1903 L0.P1) — an "
      ~ "ASSERT that the replay wrote no edges, not a freshness poll: nothing "
      ~ "is memoised on it and `e0.sv` is read from the same mesh a few "
      ~ "statements earlier, inside the same call"),
    RemainderFile("source/mesh.d", 8,
        "MeshCacheKey/MeshStructKey/MeshTopoKey.matches (the key TYPES) "
      ~ "| vertexAdjacencyCSR (row 12) | loopsValid + edgeMapUsable (row 13) "
      ~ "| SubpatchPreview.rebuildIfStale's two terms (row 10)"),
    RemainderFile("source/render/render_mvp.d", 1,
        "shadowCheckMeshChanged — diagnostic only, behind VIBE3D_RENDER_HASH_CHECK"),
    RemainderFile("source/toolpipe/stages/actcenter.d", 1,
        "bboxMembershipCached's marksVersion key (task 2006) — the same "
      ~ "argument as computeSelectionHash's below, one layer up: no watcher "
      ~ "carries `Marks`, and the thing this counter stands in for is the "
      ~ "O(V) `selectionSignature()` the cache used to call on EVERY "
      ~ "evaluation. Measured at 1M faces (ldc2 -O3 -release): the hash cost "
      ~ "2.23 ms in Vertices/Polygons and 4.46 ms in Edges, against a 1.02 ms "
      ~ "bbox pass — i.e. the key was more expensive than the walk it guarded"),
    RemainderFile("source/tools/transform/rotate.d", 1,
        "RotateTool's gesture boundary (§3.6 row 21's family)"),
    RemainderFile("source/tools/transform/scale.d", 1,
        "ScaleTool's gesture boundary (same family)"),
    RemainderFile("source/tools/transform/transform.d", 1,
        "computeSelectionHash's marksVersion memo"),
    RemainderFile("source/tools/transform/xfrm_transform.d", 2,
        "the gesture staleness gate (row 21) + the wrapper's gesture boundary"),
];

/// The two sites §3.6 keeps by HAND because no line scanner can reach them:
/// a counter stamped into a struct that is later compared WHOLE names no
/// counter at the compare and no local carries it. Named here so that "19"
/// below is never mistaken for "every version-keyed site in the tree".
private enum string kHandMaintained =
    "source/app.d's two stamps into `viewport.DirtyKey` — `.meshMutVer` from "
  ~ "`mesh.mutationVersion` and `.gpuUploadVer` from `gpu.uploadVersion`, "
  ~ "compared ~90 lines later as `_newKey != _cv.lastKey` "
  ~ "(stamp-then-compare-whole; §3.6's second table)";

unittest {
    // Every recorded file must still exist — checked FIRST so a moved module
    // gets this diagnosis rather than the set gate's "recorded N, found 0"
    // (stage-4 review: the assert used to sit after the gate and never ran).
    foreach (ref r; kRemainder)
        assert(buildPath(repoRoot, r.file).exists, format(
            "§3.6 records %d version poll(s) in %s and that file is gone. If "
          ~ "the module moved, move the row; if the polls went with it, delete "
          ~ "the row and the §3.6 rows together.", r.sites, r.file));
    auto sites = scanTree();

    size_t[string] found;
    foreach (ref s; sites) found[s.file] = found.get(s.file, 0) + 1;

    auto bad = appender!string;
    size_t recordedTotal = 0;

    foreach (ref r; kRemainder) {
        recordedTotal += r.sites;
        const size_t n = found.get(r.file, 0);
        if (n == r.sites) continue;
        bad.put(format(
            "\n    %s — recorded %d, scanner found %d\n        rows: %s",
            r.file, r.sites, n, r.symbols));
        foreach (ref s; sites)
            if (s.file == r.file)
                bad.put(format("\n        found  %s:%d [%s]  %s",
                               s.file, s.line, s.shape, s.text));
    }

    foreach (f, n; found) {
        bool recorded = false;
        foreach (ref r; kRemainder) if (r.file == f) { recorded = true; break; }
        if (recorded) continue;
        bad.put(format(
            "\n    %s — NOT IN THE REMAINDER AT ALL, scanner found %d site(s)",
            f, n));
        foreach (ref s; sites)
            if (s.file == f)
                bad.put(format("\n        found  %s:%d [%s]  %s",
                               s.file, s.line, s.shape, s.text));
    }

    assert(bad.data.length == 0, format(
        "task 1906 §3.6: the surviving version-poll SET no longer matches the "
      ~ "recorded remainder.%s\n\n"
      ~ "  Recorded: %d compare(s) over %d file(s). Scanner: %d over %d.\n\n"
      ~ "  A version compare is not wrong by itself — §3.6 of "
      ~ "doc/bus_sync_listeners_plan.md lists the ones that are right, each "
      ~ "with the reason a bus change class cannot answer it. What is wrong is "
      ~ "a compare JOINING that set without anyone arguing it, which the marker "
      ~ "gate above cannot see when the new line lands under an existing note. "
      ~ "So:\n"
      ~ "    * MORE than recorded — either key the cache on `mesh_dirty`'s bus "
      ~ "epochs (a gizmo drag is version-SILENT: task 0401 lost four caches to "
      ~ "exactly this), or write the §3.6 row AND bump the count here.\n"
      ~ "    * FEWER than recorded — a poll was migrated or deleted, which is "
      ~ "the direction this task exists to move in: drop the §3.6 row and this "
      ~ "count together, in one commit.\n"
      ~ "    * a file that is not listed at all — same as MORE, and note that "
      ~ "the file did not previously contain a single version compare.\n\n"
      ~ "  Not counted here, by construction: %s",
        bad.data, recordedTotal, kRemainder.length,
        sites.length, found.length, kHandMaintained));
}

/// The set gate's own discriminator, on scratch buffers rather than on the
/// tree — a probe that has to be written into `source/` and taken out again is
/// a probe nobody re-runs. Both directions of §4's validation line, and the
/// thing the MARKER gate cannot do: an ARGUED addition is still an addition.
unittest {
    enum string arguedButNew = q"PROBE
        void f() {
            // recorded remainder (1906 3.6): a brand-new poll, fully argued.
            if (cachedVer != mesh.mutationVersion) rebuild();
        }
PROBE";
    auto s = scanSource("source/newcomer.d", arguedButNew);
    assert(s.length == 1 && s[0].argued,
        "PREMISE: the marker gate is GREEN on this probe — which is the whole "
      ~ "reason the set gate exists. If this ever fails, the two gates have "
      ~ "stopped being different questions and the cell below proves nothing.");

    // The set gate's arithmetic, run by hand over the probe: a file nobody
    // recorded, carrying one site, is a finding.
    bool recorded = false;
    foreach (ref r; kRemainder) if (r.file == "source/newcomer.d") recorded = true;
    assert(!recorded && s.length > 0,
        "an unrecorded file with a site must be a finding");

}
