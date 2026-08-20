// The JSON float-emitter gate (task 1550, phase 4).
//
// WHAT THE CONTRACT IS. Every HTTP body in this tree is assembled by string
// concatenation. `format("%f", x)` on a non-finite float prints the bare token
// `inf` / `-inf` / `nan`, which is not JSON, so ONE such call anywhere in a
// response body makes the whole endpoint unparseable — the measured defect of
// task 1550. The fix routes all 100 float specifiers over the tree's 24 body
// sites through `json_num.jsonNum(value, spec)`, which prints `null` instead.
// The contract this guard holds is: **inside the files that assemble HTTP
// bodies, a float specifier may not appear in a format literal.** It must be
// the `spec` ARGUMENT of a `jsonNum` call, or carry an in-source exemption
// marker with a reason.
//
// WHY A SOURCE SCAN AND NOT A BEHAVIOURAL TEST. Two reasons, both measured.
// (1) A behavioural test cannot see a specifier change at all when the change
// is output-identical: `%f` and `%.6f` print the same six decimals, so a site
// silently switched between them is invisible to every parser downstream. (2)
// A behavioural test cannot see a NEW unguarded emitter until someone happens
// to make its endpoint's data non-finite. There is nothing to assert at run
// time; the property lives in the source.
//
// WHAT THIS SCANNER SEES, EXACTLY. A `%`-specifier ending in f/g/e (with the
// usual flags/width/precision) that occurs INSIDE a string literal, in one of
// the four scanned files. Comments are removed first; string literals are
// KEPT. That polarity is the exact INVERSE of tests/unit/
// mark_view_field_guard_test.d, from which the lexer shape is taken: that
// guard's subject is code, so it discards literals; this guard's subject lives
// inside the literals, so it discards only comments.
//
// WHAT IT DOES NOT SEE, stated so nobody mistakes it for the whole contract:
// a body assembled in a file outside the scanned four (a new endpoint in a new
// module is invisible to this gate — an acknowledged hole, recorded in the
// task card, not closed here because widening to all of source/ would need a
// negative control over the whole tree); a specifier built at run time from
// pieces; and `source/eventlog.d` / `source/ai/debug_trace.d`, which do print
// floats into JSON-shaped literals but whose output is a log file, not an
// endpoint body.
module tests.unit.json_emitter_scan_test;

import std.algorithm : canFind, sort;
import std.array     : appender, array, join;
import std.ascii     : isAlphaNum, isDigit;
import std.conv      : to;
import std.file      : exists, isFile, readText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : indexOf, splitLines, strip;

// ---------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------

struct SpecHit {
    size_t line;        /// 1-based
    string spec;        /// "%f", "%.6f", "%.9g", ...
    string text;        /// the source line, trimmed
    bool   viaJsonNum;  /// the literal is the 2nd argument of a jsonNum call
    bool   exempt;      /// an in-source `json-num-exempt:` marker covers it
    string reason;      /// the marker's reason text, when `exempt`
}

private bool isIdentChar(char c) { return isAlphaNum(c) || c == '_'; }

/// Blank out comments, keeping every other byte (and every newline) in place
/// so indices and line numbers still address the original text. String and
/// char literals are copied VERBATIM — they are what this scanner is looking
/// at.
private string maskComments(string src) {
    auto buf = new char[](src.length);
    buf[] = ' ';
    size_t i = 0;
    while (i < src.length) {
        immutable char c = src[i];
        if (c == '\n') { buf[i] = '\n'; i++; continue; }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
            while (i < src.length && src[i] != '\n') i++;   // '\n' copied next
            continue;
        }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
                if (src[i] == '\n') buf[i] = '\n';
                i++;
            }
            i = i + 1 < src.length ? i + 2 : src.length;
            continue;
        }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '+') {
            int depth = 1;
            i += 2;
            while (i + 1 < src.length && depth > 0) {
                if (src[i] == '/' && src[i + 1] == '+') { depth++; i += 2; continue; }
                if (src[i] == '+' && src[i + 1] == '/') { depth--; i += 2; continue; }
                if (src[i] == '\n') buf[i] = '\n';
                i++;
            }
            continue;
        }
        if (c == '"' || c == '`') {
            immutable char q = c;
            buf[i] = c;
            i++;
            while (i < src.length) {
                if (q == '"' && src[i] == '\\' && i + 1 < src.length) {
                    buf[i] = src[i]; buf[i + 1] = src[i + 1]; i += 2; continue;
                }
                buf[i] = src[i];
                immutable bool end = src[i] == q;
                i++;
                if (end) break;
            }
            continue;
        }
        if (c == '\'') {
            buf[i] = c;
            i++;
            while (i < src.length) {
                if (src[i] == '\\' && i + 1 < src.length) {
                    buf[i] = src[i]; buf[i + 1] = src[i + 1]; i += 2; continue;
                }
                buf[i] = src[i];
                immutable bool end = src[i] == '\'';
                i++;
                if (end) break;
            }
            continue;
        }
        buf[i] = c;
        i++;
    }
    return cast(string) buf;
}

/// Match a float conversion at `code[i] == '%'`. Returns its length, or 0.
private size_t floatSpecLength(string code, size_t i) {
    size_t j = i + 1;
    if (j >= code.length) return 0;
    if (code[j] == '%') return 0;                    // `%%` is a literal percent
    while (j < code.length && (isDigit(code[j]) || code[j] == '-'
                               || code[j] == '+' || code[j] == '#')) j++;
    if (j < code.length && code[j] == '.') {
        j++;
        while (j < code.length && isDigit(code[j])) j++;
    }
    if (j >= code.length) return 0;
    immutable char conv = code[j];
    if (conv != 'f' && conv != 'F' && conv != 'g' && conv != 'G'
        && conv != 'e' && conv != 'E') return 0;
    // `%foo` in prose is not a conversion.
    if (j + 1 < code.length && isAlphaNum(code[j + 1])) return 0;
    return j + 1 - i;
}

/// Is the string literal starting at `litStart` the SECOND argument of a
/// `jsonNum(...)` call? Walks back over the argument separator and the
/// balanced argument text to the call's own `(`, then names the callee.
private bool isJsonNumSpecArg(string code, size_t litStart) {
    if (litStart == 0) return false;
    ptrdiff_t i = cast(ptrdiff_t) litStart - 1;
    while (i >= 0 && (code[i] == ' ' || code[i] == '\t' || code[i] == '\n'
                      || code[i] == '\r')) i--;
    if (i < 0 || code[i] != ',') return false;      // not an argument at all
    i--;
    int depth = 0;
    while (i >= 0) {
        immutable char c = code[i];
        if (c == ')' || c == ']' || c == '}') depth++;
        else if (c == '[' || c == '{') { if (depth == 0) return false; depth--; }
        else if (c == '(') {
            if (depth == 0) break;
            depth--;
        }
        i--;
    }
    if (i < 0) return false;
    i--;                                             // step off the '('
    while (i >= 0 && (code[i] == ' ' || code[i] == '\t' || code[i] == '\n'
                      || code[i] == '\r')) i--;
    immutable ptrdiff_t end = i + 1;
    while (i >= 0 && isIdentChar(code[i])) i--;
    if (end <= i + 1) return false;
    return code[i + 1 .. end] == "jsonNum";
}

/// The in-source exemption marker. It lives at the SITE and must carry a
/// reason, so a growing allowlist is a source edit somebody has to justify
/// rather than a line quietly added to a list in this file.
enum string kExemptMarker = "json-num-exempt:";

/// Scan one D source text for float specifiers in string literals.
SpecHit[] scanJsonFloatEmitters(string src) {
    auto out_ = appender!(SpecHit[]);
    immutable code  = maskComments(src);
    auto      lines = src.splitLines;

    // A marker is honoured on its own line or the line immediately above the
    // specifier — the two spellings a call site can reasonably use.
    string markerReason(size_t lineNo) {   // 1-based
        foreach (probe; [lineNo, lineNo - 1]) {
            if (probe == 0 || probe > lines.length) continue;
            const l  = lines[probe - 1];
            const at = l.indexOf(kExemptMarker);
            if (at >= 0) return l[at + kExemptMarker.length .. $].strip;
        }
        return null;
    }

    size_t i = 0, line = 1;
    while (i < code.length) {
        immutable char c = code[i];
        if (c == '\n') { line++; i++; continue; }
        if (c == '\'') {                                   // char literal
            i++;
            while (i < code.length) {
                if (code[i] == '\\' && i + 1 < code.length) { i += 2; continue; }
                if (code[i] == '\n') line++;
                immutable bool end = code[i] == '\'';
                i++;
                if (end) break;
            }
            continue;
        }
        if (c != '"' && c != '`') { i++; continue; }

        immutable char   q         = c;
        immutable size_t litStart  = i;
        immutable bool   viaJsonNum = isJsonNumSpecArg(code, litStart);
        i++;
        while (i < code.length) {
            if (q == '"' && code[i] == '\\' && i + 1 < code.length) {
                i += 2;
                continue;
            }
            if (code[i] == q) { i++; break; }
            if (code[i] == '\n') { line++; i++; continue; }
            if (code[i] == '%') {
                immutable n = floatSpecLength(code, i);
                if (n > 0) {
                    const reason = markerReason(line);
                    out_ ~= SpecHit(line, code[i .. i + n],
                                    line <= lines.length
                                        ? lines[line - 1].strip : "",
                                    viaJsonNum, reason !is null, reason);
                    i += n;
                    continue;
                }
            }
            i++;
        }
    }
    return out_.data;
}

// ---------------------------------------------------------------------------
// (b) NEGATIVE CONTROL — written BEFORE the gate, because everything LEGAL
// must stay silent or the guard gets deleted the first time it cries wolf.
// Every category below is taken from the real tree, not invented.
// ---------------------------------------------------------------------------

private SpecHit[] findings(string src) {
    SpecHit[] r;
    foreach (h; scanJsonFloatEmitters(src))
        if (!h.viaJsonNum && !h.exempt) r ~= h;
    return r;
}

unittest { // category 3: specifiers in COMMENTS are not emitters
    // This is not hypothetical: revision 1 of the task's plan read
    // http_providers.d's `// ... and a %.6f would print the fine end as
    // 0.000000` as a call site and listed it for conversion.
    assert(findings("// reported at %.9g rather than a fixed number\n").length == 0,
           "line comment");
    assert(findings("/* a %.6f would print the fine end as 0.000000 */\n").length == 0,
           "block comment");
    assert(findings("/+ %f /+ %.9g +/ %e +/\n").length == 0, "nested comment");
    assert(findings("/// `%.9g` is not decoration\nint x;\n").length == 0,
           "doc comment");
}

unittest { // category 4: non-float conversions are not this guard's business
    assert(findings(`auto s = format("%s %d %u %x %%", a, b, c, d);`).length == 0,
           "%s/%d/%u/%x/%% must stay silent");
    assert(findings(`auto s = "100% free";`).length == 0,
           "a bare percent in prose");
    assert(findings(`auto s = "%format is a word";`).length == 0,
           "`%f` followed by more letters is not a conversion");
}

unittest { // category 5: an already-converted site is the CORRECT shape
    assert(findings(`buf ~= jsonNum(v.x, "%f");`).length == 0,
           "the spec argument of jsonNum is the fixed form, not a violation");
    assert(findings(`x.put(jsonNum(m[mi], "%.6f"));`).length == 0);
    assert(findings("y.put(jsonNum(px > 0 ? gs / px : 0.0f, \"%.9g\"));").length == 0,
           "an expression argument containing parens and operators");
    assert(findings("z ~= format(\"[%s,%s]\",\n"
                  ~ "    jsonNum(a, \"%f\"),\n"
                  ~ "    jsonNum(b, \"%f\"));").length == 0,
           "arguments split across lines");

    // ... and the SAME text with the call renamed is a violation again, which
    // is what proves the exemption is keyed on `jsonNum` and not on shape.
    assert(findings(`buf ~= somethingElse(v.x, "%f");`).length == 1,
           "only jsonNum earns the pass");
    assert(findings(`buf ~= format("%f", v.x);`).length == 1,
           "a bare format is exactly what this guard is for");
}

unittest { // the exemption marker, and that it needs a reason to be found
    assert(findings("// " ~ kExemptMarker ~ " builds an argstring\n"
                  ~ `return format("%.9g", v.floating);`).length == 0,
           "a marker on the line ABOVE covers the site");
    assert(findings(`return format("%.9g", v.floating);  // ` ~ kExemptMarker
                  ~ " builds an argstring").length == 0,
           "a marker on the SAME line covers the site");
    assert(findings("// " ~ kExemptMarker ~ " reason\n"
                  ~ "int filler;\n"
                  ~ `return format("%.9g", v);`).length == 1,
           "a marker two lines up does NOT reach — the marker is per-site");

    auto ex = scanJsonFloatEmitters("// " ~ kExemptMarker
                                  ~ " builds an argstring, not a JSON body\n"
                                  ~ `return format("%.9g", v);`);
    assert(ex.length == 1 && ex[0].exempt);
    assert(ex[0].reason == "builds an argstring, not a JSON body",
           "the reason text is carried, and is what the gate matches on: "
           ~ ex[0].reason);
}

unittest { // the scanner reports WHERE and WHAT, not just how many
    auto v = scanJsonFloatEmitters("module a;\n\nvoid f() {\n"
                                 ~ "    x ~= format(\"[%.6f]\", y);\n}\n");
    assert(v.length == 1);
    assert(v[0].line == 4, format("expected line 4, got %d", v[0].line));
    assert(v[0].spec == "%.6f", v[0].spec);
    assert(v[0].text == `x ~= format("[%.6f]", y);`, v[0].text);

    // Multiple specs in one literal are reported individually, or the census
    // in the gate below could not count them.
    auto w = scanJsonFloatEmitters("auto s = format(\"[%f,%f,%f]\", a, b, c);");
    assert(w.length == 3, format("expected 3, got %d", w.length));

    // A brace/paren inside a string must not derail the backward walk.
    assert(findings(`f("(", jsonNum(a, "%f"));`).length == 0);
}

// ---------------------------------------------------------------------------
// (a) THE GATE, over the real tree, with a canary that lives IN THE TREE.
// ---------------------------------------------------------------------------

private enum gateRepoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// The files that assemble HTTP response bodies, plus the helper module (which
/// carries the canary). Adding an endpoint to a NEW file is the acknowledged
/// hole in this gate's scope — see the module header.
private immutable string[] kScanned = [
    "source/json_num.d",
    "source/http_json.d",
    "source/http_providers.d",
    "source/view.d",
];

unittest {
    size_t   filesScanned;
    size_t   totalSpecsSeen;
    string[] violations;
    string[] exemptions;      // "file :: reason"
    size_t[string][string] census;   // file -> spec -> count
    size_t   canaryLine;             // derived by READING json_num.d

    foreach (rel; kScanned) {
        const p = buildPath(gateRepoRoot, rel);
        assert(exists(p) && isFile(p),
            "the gate cannot find " ~ p ~ " — it is measuring nothing, which "
          ~ "is worse than being absent");
        const src = readText(p);
        filesScanned++;

        if (rel == "source/json_num.d") {
            foreach (i, l; src.splitLines)
                if (l.canFind("jsonNumScannerCanary")
                    && l.canFind("enum")) { canaryLine = i + 1; break; }
        }

        foreach (h; scanJsonFloatEmitters(src)) {
            totalSpecsSeen++;
            if (h.exempt) { exemptions ~= rel ~ " :: " ~ h.reason; continue; }
            if (h.viaJsonNum) { census[rel][h.spec]++; continue; }
            violations ~= format("%s:%d  %s  %s", rel, h.line, h.spec, h.text);
        }
    }

    // --- non-vacuity: an empty walk must FAIL, not report a clean tree -----
    // The 4 is a LITERAL and not `kScanned.length`. Measured: written as
    // `filesScanned == kScanned.length` this assertion is self-consistent —
    // emptying `kScanned` leaves it green, so it detects nothing. Only
    // `totalSpecsSeen > 0` caught mutation M7, and one witness for a
    // non-vacuity check is one too few.
    assert(filesScanned == 4,
        format("the gate must read all four body-assembling files, it read %d",
               filesScanned));
    assert(totalSpecsSeen > 0,
        "the scan saw no float specifier anywhere in four files that are full "
      ~ "of them — the reader, the masker or the matcher has stopped working, "
      ~ "and a gate that is clean over an empty input is not a gate");

    // --- positive control: the canary in source/json_num.d -----------------
    // Its LINE is read out of the file, not hard-coded, so moving the canary
    // is free and deleting it is the failure this control exists to catch.
    assert(canaryLine > 0,
        "source/json_num.d no longer declares `jsonNumScannerCanary`. That "
      ~ "enum is this gate's proof that it reads REAL FILES rather than its "
      ~ "own test strings; without it, every assertion below could be passing "
      ~ "over an empty scan.");
    assert(violations.length == 1
           && violations[0].canFind("source/json_num.d:"
                                    ~ canaryLine.to!string),
        format("the ONLY unguarded emitter in the scanned files must be the "
             ~ "canary at source/json_num.d:%d.\n"
             ~ "A float specifier in a format literal in one of these files "
             ~ "makes the endpoint's body unparseable the moment its value "
             ~ "goes non-finite (task 1550). Route it through "
             ~ "`json_num.jsonNum(value, \"<spec>\")`, or, if it genuinely "
             ~ "does not build a JSON body, mark the site\n"
             ~ "    // %s <why>\n"
             ~ "and raise the frozen exemption count below DELIBERATELY.\n"
             ~ "%d finding(s):\n  %s",
               canaryLine, kExemptMarker, violations.length,
               violations.join("\n  ")));

    // --- (c) exemptions: frozen at 2, matched by FILE + REASON -------------
    // Not by line number, which drifts. A third exemption is a red test, so
    // the allowlist cannot grow by quiet editing.
    auto ex = exemptions.dup;
    ex.sort();
    assert(ex.length == 2,
        format("the exemption list is frozen at 2 sites. A new "
             ~ "`%s` marker is a deliberate act: write the reason in the task "
             ~ "card and raise this number on purpose.\n%d exemption(s):\n  %s",
               kExemptMarker, ex.length, ex.join("\n  ")));
    assert(ex[0] == "source/http_providers.d :: builds an argstring, not a "
                  ~ "JSON body", ex[0]);
    assert(ex[1] == "source/http_providers.d :: clamped to the [0,1] weight "
                  ~ "contract above, task 1550 decision 4.1", ex[1]);
}

// ---------------------------------------------------------------------------
// 4.3 — the frozen per-file census. THE SECOND WITNESS OF SPECIFIER DRIFT.
//
// Keyed on file + specifier and NOT on line number, so moving code around does
// not break it. Its whole reason to exist is the class of change no
// behavioural test can see: `%f` and `%.6f` produce BYTE-IDENTICAL output, so
// a site switched between them is invisible to every parser downstream and
// visible only here.
// ---------------------------------------------------------------------------
unittest {
    static struct Expect { string file; string spec; size_t count; }
    // Measured over the converted tree; 100 specifiers over 24 call sites.
    static immutable Expect[] kFrozen = [
        Expect("source/http_json.d",      "%f",   10),
        Expect("source/view.d",           "%.9g",  9),
        Expect("source/view.d",           "%f",   10),
        Expect("source/http_providers.d", "%.6f", 41),
        Expect("source/http_providers.d", "%.9g",  5),
        Expect("source/http_providers.d", "%f",   25),
    ];

    // `source/json_num.d` is deliberately NOT censused. It is scanned by the
    // gate above (for the canary, and so an unguarded emitter cannot hide in
    // the helper itself), but its `jsonNum(x, "%.3f")` occurrences are the
    // helper's own unittests, not wire sites — freezing them would make every
    // added test case a red gate for no contract reason.
    static immutable string[] kCensused = [
        "source/http_json.d", "source/http_providers.d", "source/view.d",
    ];

    size_t[string][string] census;
    foreach (rel; kCensused) {
        const src = readText(buildPath(gateRepoRoot, rel));
        foreach (h; scanJsonFloatEmitters(src))
            if (h.viaJsonNum && !h.exempt) census[rel][h.spec]++;
    }

    string[] drift;
    size_t   total;
    foreach (e; kFrozen) {
        const got = (e.file in census) && (e.spec in census[e.file])
                  ? census[e.file][e.spec] : 0;
        total += e.count;
        if (got != e.count)
            drift ~= format("%s  %s: frozen %d, found %d",
                            e.file, e.spec, e.count, got);
    }
    // And nothing OUTSIDE the frozen table, or a new specifier family could
    // appear without moving any frozen number.
    foreach (f, m; census)
        foreach (s, n; m) {
            bool known;
            foreach (e; kFrozen) if (e.file == f && e.spec == s) known = true;
            if (!known) drift ~= format("%s  %s: %d occurrence(s), not in the "
                                      ~ "frozen census", f, s, n);
        }

    assert(total == 100, format("the frozen table must add up to the 100 "
                              ~ "specifiers the conversion covered, got %d",
                                total));
    assert(drift.length == 0,
        "the per-file specifier census moved. This is the ONLY check that can "
      ~ "see a specifier change whose OUTPUT is identical (`%f` <-> `%.6f`), "
      ~ "so a surprise here is worth reading carefully: either a call site's "
      ~ "precision changed, or an emitter was added or removed. Update the "
      ~ "frozen table deliberately, in the same commit as the change.\n  "
      ~ drift.join("\n  "));
}
