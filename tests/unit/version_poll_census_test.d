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
// What closes it is §4 stage 3's stricter census, which asserts the site SET
// against §3.6 verbatim.
//
// THE FLOOR BELOW THE GATE. A scanner that lost its place (an unterminated
// literal, a stripper bug) finds nothing and the gate passes vacuously, so the
// site count is asserted AFTER the real assertion — a canary in front of the
// gate would bury the message that matters.
module tests.unit.version_poll_census_test;

import std.algorithm : any, canFind, endsWith;
import std.array     : appender, array;
import std.file      : dirEntries, readText, SpanMode;
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
// Not handled: wysiwyg strings (`r"…"`) and delimited/token strings (`q"…"`,
// `q{…}`), any of which desyncs the scanner from that point on. Character
// literals ARE handled, including `'\''` and `'"'`. Neither unhandled form
// appears in a scanned file today; the floor at the bottom is what notices if
// one arrives, because a desynced scanner eats the rest of the file and the
// site count collapses.
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
/// `version (unittest)` is NOT such a block and must survive: it holds
/// PRODUCTION seams (mock hooks, test-visible accessors) that a poll can hide
/// in, and there are ~195 of them under `source/`. The two differ by one
/// character of context — the `(` that precedes the keyword — because a real
/// `unittest` block is a DECLARATION and can never be parenthesised. That is
/// the whole test below, and it is a cell (`versionUnittestIsProductionCode`)
/// rather than a comment because the first version of this scanner got it
/// wrong while the header claimed otherwise.
private string blankUnittestBodies(string code) {
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
