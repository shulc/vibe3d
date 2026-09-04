// sel_channel_census_test — every `changeBus.onSelectionChanged` registration
// in `source/**` (outside `change_bus.d` itself) is ENUMERATED, not merely
// counted (task 1931, `doc/tasks/work/1931-per-type-selection-delivery.md`
// stage 3, following the pattern of `tests/unit/version_poll_census_test.d`
// for task 1906 §3.6).
//
// WHAT THIS GATE IS FOR. Task 1931 measured that the change bus's selection
// channel has exactly ONE subscriber in the whole tree (`source/app.d`), that
// it is blind to which of the three geometry domains moved (it discards the
// `domains` argument outright — the accumulator that used to OR them into one
// word was deleted by this same task), and that no per-domain consumer exists
// either (a census over
// `totalSelVertex`/`totalSelEdge`/`totalSelFace` found zero readers). The
// task's outcome is therefore a MEASUREMENT, not a code change: per-type
// delivery is not built, because nothing would read it. That conclusion is
// only true today — the day a second subscriber appears, or a second
// registration lands, this file must say so LOUDLY rather than let the
// measurement silently go stale. This is the executable half of that
// re-check: the recorded remainder is `source/app.d` -> 1, and anything else
// is a finding, argued or not.
//
// WHAT COUNTS AS A SITE. The bare method name `onSelectionChanged`, matched
// as a whole identifier (not a substring of a longer one — there is no such
// longer identifier in this tree, but the check costs nothing). The FIRST
// revision of this census scanned the qualified form
// `changeBus.onSelectionChanged(`, which is a spelling, not the idiom it
// meant to catch: it misses a registration reached through `with (changeBus)`,
// through a helper taking `ref ChangeBus`, or through `auto b = &changeBus;
// b.onSelectionChanged(...)`. The bare name is the only thing all of those
// share — but it is NOT the only way in: the subscriber array `selSubs` is a
// public field, and `changeBus.selSubs ~= dg;` names no method at all. That
// hole was MEASURED green during this stage's review, so the scan matches the
// field name too (see `kField` below).
//
// WHY THREE VIEWS OF THE SAME FILE, taken verbatim from
// `version_poll_census_test.d` (task 1906 §3.6) because the traps are the
// same traps:
//
//   * the CODE view — comments and string/backtick/char literals blanked,
//     `unittest { … }` bodies blanked too — is where SITES are counted. A
//     comment that quotes `onSelectionChanged` (this file's own header does,
//     and so does the marker note this census requires at every real site) is
//     not a finding.
//   * the MARKER view — comments KEPT, literals blanked — is where the "does
//     this site carry its task-1931 marker" question is answered. Not the raw
//     text: a string literal that happens to contain "1931" must not silence
//     a real site with no comment above it.
//   * `version (unittest)` blocks are LEFT ALONE in both views (they hold
//     production seams, not test code); only a real `unittest { … }` body is
//     blanked. The two differ by one token of context (the `(` that precedes
//     the keyword) — get it wrong and a mock registration written for a test
//     fixture either hides a real site or manufactures a fake one.
//
// WHAT IT DELIBERATELY DOES NOT ASSERT: that the recorded remainder is the
// RIGHT one, or that a per-domain split would or would not help a future
// subscriber. That is the task's own measurement (see the card, stage 0's
// multiplicity table). What is mechanised is the weaker, checkable half: the
// SET of registration sites is closed, so nothing can join it — with or
// without a marker — without a human updating this file.
//
// THE FLOOR. A scanner that lost its place (an unterminated literal, a
// stripper bug) would find nothing anywhere and every gate below would pass
// for the wrong reason. `filesScanned` is asserted after the real assertions,
// for the same reason `version_poll_census_test.d` orders its floor last: a
// canary in front of the real message buries it.
module tests.unit.sel_channel_census_test;

import std.algorithm : canFind;
import std.array     : appender;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : splitLines, strip, toLower;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// The bare method name that constitutes a registration site.
private enum string kMethod = "onSelectionChanged";

// The SECOND spelling, and it is not a spelling of the method at all:
// `ChangeBus.selSubs` is a PUBLIC field, so `changeBus.selSubs ~= dg;`
// registers a real, delivered-to subscriber without ever naming
// `onSelectionChanged`. The review of this stage MEASURED that hole — the
// census was fully green with such a registration in `source/display_sync.d`.
// `selSubs` occurs in `source/**` only inside `change_bus.d`, which this walk
// excludes, so matching it adds no site today and closes the one path that
// could join the set silently. (Sealing the field would be the other fix; it
// is left alone because the sibling `meshSubs` is saved and restored by
// `tests/unit/delivery_after_hide_derive_test.d`, and an asymmetric `private`
// on one of three would be a trap of its own.)
private enum string kField = "selSubs";

/// The file the method itself is declared in — excluded from the scan, same
/// as the plan's premise P1 (`grep … | grep -v change_bus.d`).
private enum string kOwnFile = "source/change_bus.d";

/// The marker every recorded site must carry above it: a reference to this
/// task, so a reader who finds a NEW registration under someone else's note
/// (the same hole `version_poll_census_test.d`'s header names) still has to
/// write their own to pass the marker gate below.
private enum string kMarker = "1931";

/// How far above a site the marker may sit. `version_poll_census_test.d` uses
/// 14 for compares whose own condition can span several lines; a bus
/// registration's marker is a short prose note immediately above the call, so
/// 12 is generous without reaching into an unrelated block above it.
private enum size_t kMarkerWindow = 12;

// ---------------------------------------------------------------------------
// The stripper. Verbatim algorithm from `version_poll_census_test.d`
// (blankNonCode there, `package`-visibility so it is not duplicated here) —
// wysiwyg (`r"…"`) and token (`q"…"`, `q{…}`) strings are LEXED there since
// task 2007 — the note that used to stand here said none appeared in the
// scanned files, which was measured FALSE for `q{…}` (three source files carry
// it, one of them a kRemainder file). `filesScanned` below still notices a
// desync from any form nobody has thought of.
// ---------------------------------------------------------------------------
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
    enclosingSymbols, symbolAt, LedgerRow, LedgerHit, reconcile;

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

/// `id` occurs in `ln` as a whole identifier, not a substring of a longer one.
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

private struct Site {
    string file;
    string symbol;
    size_t line;    // 1-based
    string text;
    bool   argued;
}

/// One file's text -> its registration sites. `label` is the path reported in
/// findings (repo-root-relative, e.g. `source/app.d`).
private Site[] scanSource(string label, string src) {
    const string code  = blankUnittestBodies(blankNonCode(src));
    const symbols = enclosingSymbols(code);
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

    auto sites = appender!(Site[]);
    foreach (li, ln; codeLines)
        if (namesIdent(ln, kMethod) || namesIdent(ln, kField))
            sites.put(Site(label, symbolAt(symbols, li), li + 1, ln.strip,
                           argumentAbove(li)));
    return sites.data;
}

private Site[] scanTree() {
    auto sites = appender!(Site[]);
    size_t scanned = 0;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++scanned;
        const string label = de.name[repoRoot.length + 1 .. $];
        if (label == kOwnFile) continue;
        sites.put(scanSource(label, readText(de.name)));
    }
    assert(scanned >= 100, format(
        "the sel-channel census scanned only %d file(s) under source/ — it "
      ~ "has almost certainly lost its place (repoRoot resolved wrong, or the "
      ~ "tree walk found nothing), which would make every gate below vacuous. "
      ~ "Fix the scanner rather than trusting a green here.", scanned));
    return sites.data;
}

// ---------------------------------------------------------------------------
// SCANNER CELLS FIRST — druntime stops a module at its first failing assert,
// so a broken scanner must say so in its own words before the tree-wide gates
// below report something that looks like a tree finding.
// ---------------------------------------------------------------------------

unittest {
    // The bare name is found regardless of how it is reached — qualified,
    // through `with`, or through a `ref` alias — because none of those
    // spellings differ at the METHOD NAME, which is the whole reason this
    // census scans the bare identifier and not `changeBus.onSelectionChanged(`.
    enum string direct = q"PROBE
        void f() { changeBus.onSelectionChanged((uint d) { ++x; }); }
PROBE";
    assert(scanSource("probe.d", direct).length == 1);

    enum string viaWith = q"PROBE
        void f() { with (changeBus) { onSelectionChanged((uint d) { ++x; }); } }
PROBE";
    assert(scanSource("probe.d", viaWith).length == 1,
        "a `with (changeBus)` registration must still be seen");

    enum string viaRef = q"PROBE
        void register(ref ChangeBus b) { b.onSelectionChanged((uint d) { ++x; }); }
PROBE";
    assert(scanSource("probe.d", viaRef).length == 1,
        "a registration through a ref-alias parameter must still be seen");

    // The path that names no method: a raw append to the public subscriber
    // array. Measured green against the FIRST revision of this census during
    // the stage's review, which is why `kField` exists.
    enum string viaField = q"PROBE
        void f() { changeBus.selSubs ~= (uint d) nothrow {}; }
PROBE";
    assert(scanSource("probe.d", viaField).length == 1,
        "a raw `changeBus.selSubs ~= dg;` append registers a real subscriber "
      ~ "and must be seen — it names no method at all");
}

unittest {
    // A real `unittest { }` body is blanked (it is this census's own subject
    // matter, not production code); `version (unittest)` is NOT — it holds
    // production seams and must still count.
    enum string underUnittest = q"PROBE
        unittest { changeBus.onSelectionChanged((uint d) { ++x; }); }
PROBE";
    assert(scanSource("probe.d", underUnittest).length == 0,
        "a real unittest body is not a production registration site");

    enum string underVersion = q"PROBE
        version (unittest) {
            void hook() { changeBus.onSelectionChanged((uint d) { ++x; }); }
        }
PROBE";
    assert(scanSource("probe.d", underVersion).length == 1,
        "version (unittest) is production code and must still be seen");
}

unittest {
    // The marker is read on the MARKER view (comments kept), not on raw text:
    // a string literal quoting "1931" must not silence a site with no real
    // comment above it, and a real comment must count even though the CODE
    // view (which counts SITES) blanks it.
    enum string inALiteral = q"PROBE
        void f() {
            log("cache key: task 1931 note");
            changeBus.onSelectionChanged((uint d) { ++x; });
        }
PROBE";
    auto lit = scanSource("probe.d", inALiteral);
    assert(lit.length == 1 && !lit[0].argued,
        "a string literal quoting the marker must not argue a real site");

    enum string inAComment = q"PROBE
        void f() {
            // Task 1931 — the one recorded registration in probe.d.
            changeBus.onSelectionChanged((uint d) { ++x; });
        }
PROBE";
    auto com = scanSource("probe.d", inAComment);
    assert(com.length == 1 && com[0].argued,
        "a real comment marker within the window must argue the site");
}

unittest {
    // A char literal holding a quote must not desync the blanker — the same
    // hazard `version_poll_census_test.d` guards, and this tree's
    // `http_server.d` / `forms.d` both carry `'"'`.
    enum string charLit = q"PROBE
        void f(char c) {
            if (c == '"') return;
            // Task 1931 marker.
            changeBus.onSelectionChanged((uint d) { ++x; });
        }
PROBE";
    auto s = scanSource("probe.d", charLit);
    assert(s.length == 1 && s[0].argued,
        "the char literal '\"' desynced the blanker and lost the site or its "
      ~ "marker");
}

// ---------------------------------------------------------------------------
// THE MARKER GATE. Every found site — recorded or not — must carry a task
// reference within kMarkerWindow lines above it. Runs first: "write the note"
// is the more useful message when a site fails both gates at once.
// ---------------------------------------------------------------------------
unittest {
    auto sites = scanTree();

    auto unargued = appender!string;
    size_t nBad = 0;
    foreach (ref s; sites) {
        if (s.argued) continue;
        ++nBad;
        unargued.put(format("\n    %s:%d\n        %s", s.file, s.line, s.text));
    }

    assert(nBad == 0, format(
        "task 1931: %d `onSelectionChanged` registration(s) carry no comment "
      ~ "naming task 1931 within %d lines above them.%s\n\n"
      ~ "  This census exists because the selection channel's ONE subscriber "
      ~ "is the whole reason per-type delivery was measured and not built "
      ~ "(doc/tasks/work/1931-per-type-selection-delivery.md, or done/ once "
      ~ "landed) — a second, unmarked registration is exactly the kind of "
      ~ "change that measurement needs to be re-checked against. Add a short "
      ~ "comment above the registration referencing task 1931, and add the "
      ~ "row below if this is a genuinely new site.",
        nBad, kMarkerWindow, unargued.data));
}

// ---------------------------------------------------------------------------
// THE SET GATE. The recorded remainder is not just argued — it is
// ENUMERATED, per FILE, and nothing may join it (or leave it, or grow inside
// an already-recorded file) without this file changing too. Runs second, same
// order as `version_poll_census_test.d`'s two gates and the same reason: an
// un-marked NEW site is more informative reported as "write the note" first.
// ---------------------------------------------------------------------------

/// Task 1931's measured remainder (2026-08-26): ONE registration, in
/// `source/app.d`, wiring `fboSelEpoch`. Complete as of stage 3.
private static immutable LedgerRow[] kRemainder = [
    LedgerRow("main", 1, "the one subscriber wiring fboSelEpoch"),
];

unittest {
    auto sites = scanTree();
    LedgerHit[] hits;
    foreach (ref s; sites)
        hits ~= LedgerHit(s.symbol, s.file, s.line, s.text);
    const bad = reconcile(kRemainder, hits);

    assert(bad.length == 0, format(
        "task 1931: the onSelectionChanged registration SET no longer matches "
      ~ "the recorded remainder.%s\n\n"
      ~ "  The task's conclusion — per-type selection delivery is measured, "
      ~ "not built, because the ONE subscriber is blind to domain either way "
      ~ "— depends on there being exactly one registration site. So:\n"
      ~ "    * MORE than recorded, in a KNOWN file — a second registration in "
      ~ "`source/app.d` is exactly the census's own mutation drill; re-open "
      ~ "the task's premise before adding one.\n"
      ~ "    * a file that is not listed at all — a NEW subscriber, which is "
      ~ "the named condition (the card's \"what makes it ripe\" section) for "
      ~ "revisiting the whole question.\n"
      ~ "    * FEWER than recorded — a registration was migrated or deleted; "
      ~ "drop the row here in the same commit.",
        bad));
    assert(hits.length == 1,
        format("selection-channel population changed: expected 1, found %d",
               hits.length));
}
