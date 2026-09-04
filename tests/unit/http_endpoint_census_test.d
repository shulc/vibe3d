// A suite driver must not SPELL its endpoint (4055 review).
//
// THE DEFECT THIS CLOSES, and it was demonstrated, not argued. Until task 4055
// `run_test.d` rewrote the literal `localhost:8080` inside a per-worker scratch
// COPY of every test source, so a test could spell its base URL any way it
// liked and still be pointed at its own worker. That rewrite is gone: the port
// now arrives in the environment (`VIBE3D_TEST_PORT`) and only
// `tests/http_client.d` turns it into a URL. Nothing, however, stopped a test
// from spelling the literal again — and the first worker's port IS the old
// default 8080. The review's probe proved what that costs: a test hard-coding
// `http://localhost:8080`, scheduled onto worker 1, reached WORKER 0's
// instance, got a 200 and the run reported `Total: 2 Passed: 2 Failed: 0`. A
// green over another test's state is the worst possible failure here, because
// nothing anywhere goes red.
//
// The card's "518 to 0" was a one-off hand grep. This is the standing check
// that refuses the 519th.
//
// WHY HERE AND NOT IN run_test.d's PRE-COMPILE GATE. `gateViolations` is
// parameterised over an arbitrary directory (`./run_test.d --check-gate <dir>`,
// exercised by tests/test_liveness_gate.d over temp fixture dirs). The
// population floors below are properties of the REAL tests/ tree; making them
// conditional on "is this the real directory" is precisely the vacuous-guard
// shape CLAUDE.md warns about. Both lanes of the default gate run on every
// change, so this catches an offender before a commit either way — and it does
// so without a live app or a port.
//
// KNOWN LIMIT, stated so nobody reads this as total. It matches a literal, so a
// port assembled at runtime — `"http://localhost:" ~ somePortEnum.to!string` —
// is invisible to it. That shape has never been written here, and the value it
// would have to carry is still wrong for the same reason; if it ever appears,
// widen the rule rather than exempt the file. What the census DOES close is the
// only shape that has actually occurred: the base URL spelled out.
//
// MUTATION: add any `tests/*.d` file containing the text `localhost:8080`, or
// give one of them its own `getJson`/`postJson`/`postRaw` definition again, and
// the matching assert below names that file.
module http_endpoint_census_test;

import std.algorithm : sort;
import std.ascii     : isDigit, isWhite;
import std.exception : enforce;
import std.file      : dirEntries, SpanMode, exists, readText;
import std.format    : format;
import std.path      : baseName, buildPath, dirName;
import std.string    : indexOf, splitLines, startsWith, stripLeft;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// The ONE file allowed to name a host and a port: it owns the default a
// hand-run binary falls back to, and it is the only place that builds a base
// URL from the environment.
private enum string kTransport = "http_client.d";

// Hosts a test could reach a vibe3d instance at. Matched only when followed by
// digits, so `"http://localhost:" ~ port.to!string` (how the three self-hosted
// tests build their own instance's URL) and a bare `Host: localhost` header are
// not offences — they carry no port to be wrong about.
private static immutable string[] kHosts = [
    "localhost:", "127.0.0.1:", "0.0.0.0:", "[::1]:",
];

// Host-and-port literals that are NOT a vibe3d endpoint, pinned to the file
// that owns them. Keyed by the whole literal, so a new one in the same file
// still trips. Every row is asserted to still MATCH below: a rotted allowlist
// row is a hole nobody would see.
private static immutable string[2][] kAllowedLiterals = [
    // The ai3d worker URL, deliberately dead (port 1) to exercise the
    // connect-failure path. Not the editor's HTTP API.
    ["test_ai3d_ui.d", "127.0.0.1:1"],
];

// Return types a local copy of the shared trio has ever been written with.
private static immutable string[] kRetTypes = [
    "JSONValue", "string", "void", "auto", "bool", "long", "size_t",
];
private static immutable string[] kAttribs = ["private ", "public ", "static "];
private static immutable string[] kSharedFns = ["getJson", "postJson", "postRaw"];

/// Every `host:port` literal in `txt`, as it is spelled.
private string[] hostPortLiterals(string txt)
{
    string[] found;
    foreach (h; kHosts)
    {
        size_t from = 0;
        while (from < txt.length)
        {
            const at = txt[from .. $].indexOf(h);
            if (at < 0) break;
            const size_t start = from + cast(size_t)at;
            size_t d = start + h.length;
            while (d < txt.length && txt[d].isDigit) ++d;
            if (d > start + h.length) found ~= txt[start .. d];
            from = start + h.length;
        }
    }
    sort(found);
    return found;
}

/// The name this line DEFINES, if it declares one of the shared trio.
/// Deliberately not a parser: it matches `[attribs] <type> <name>(`, which is
/// how all 42 copies task 4055 removed were written. `return getJson(...)` does
/// not match because `return` is not one of the return types.
private string definedSharedFn(string line)
{
    auto s = line.stripLeft;
    bool stripped = true;
    while (stripped)
    {
        stripped = false;
        foreach (a; kAttribs)
            if (s.startsWith(a)) { s = s[a.length .. $].stripLeft; stripped = true; }
    }
    foreach (t; kRetTypes)
    {
        if (!s.startsWith(t)) continue;
        auto rest = s[t.length .. $];
        if (rest.length == 0 || !rest[0].isWhite) continue;
        rest = rest.stripLeft;
        foreach (f; kSharedFns)
        {
            if (!rest.startsWith(f)) continue;
            auto tail = rest[f.length .. $].stripLeft;
            if (tail.startsWith("(")) return f;
        }
    }
    return null;
}

unittest
{
    const testsDir = buildPath(repoRoot, "tests");
    enforce(exists(testsDir), "tests/ not found under " ~ repoRoot);

    string[] scanned;          // every tests/*.d read
    string[] drivers;          // those importing the shared client
    string[] callers;          // those calling one of the trio
    string[] literalOffenders;
    string[] copyOffenders;
    bool[string] allowedSeen;

    foreach (e; dirEntries(testsDir, "*.d", SpanMode.shallow))
    {
        const name = baseName(e.name);
        string txt;
        try { txt = readText(e.name); } catch (Exception) { continue; }
        scanned ~= name;

        if (txt.indexOf("import http_client") >= 0) drivers ~= name;

        if (name != kTransport)
        {
            foreach (f; kSharedFns)
                if (txt.indexOf(f ~ "(") >= 0) { callers ~= name; break; }

            foreach (lit; hostPortLiterals(txt))
            {
                bool allowed = false;
                foreach (row; kAllowedLiterals)
                    if (row[0] == name && row[1] == lit)
                    {
                        allowed = true;
                        allowedSeen[name ~ " " ~ lit] = true;
                    }
                if (!allowed) literalOffenders ~= format("%s: %s", name, lit);
            }

            foreach (i, line; txt.splitLines)
            {
                const fn = definedSharedFn(line);
                if (fn.length)
                    copyOffenders ~= format("%s:%d: %s", name, i + 1, fn);
            }
        }
    }

    sort(scanned);
    sort(drivers);
    sort(callers);
    sort(literalOffenders);
    sort(copyOffenders);

    // --- Floors FIRST: everything below is vacuous over an empty file list ---
    // Measured on the tree that added this file, 2026-09-04: 770 scanned,
    // 526 drivers, 365 callers. The floors sit below those with room for the
    // tree to shrink, and far above zero, which is the number they exist to
    // refuse.
    enforce(scanned.length >= 700, format(
        "expected at least 700 files in tests/, scanned %d. The glob found "
      ~ "nothing to census — an empty population passes every assert below for "
      ~ "the wrong reason.", scanned.length));

    enforce(drivers.length >= 400, format(
        "expected at least 400 tests/*.d importing http_client, found %d. "
      ~ "Either the shared client was renamed or the drivers stopped using it; "
      ~ "either way this census is no longer looking at the population the "
      ~ "rule is about.", drivers.length));

    enforce(callers.length >= 300, format(
        "expected at least 300 tests/*.d calling getJson/postJson/postRaw, "
      ~ "found %d. The copy census below would pass over a tree that no longer "
      ~ "contains the thing it forbids duplicating.", callers.length));

    // --- 1. No test spells a host and a port ------------------------------
    assert(literalOffenders.length == 0, format(
        "these tests/*.d files hard-code a host-and-port literal: %s\n"
      ~ "Under `run_test.d -j N` each worker owns its OWN vibe3d instance and "
      ~ "worker 0's port is the historical default 8080, so a spelled literal "
      ~ "does not fail to connect — it connects to ANOTHER worker's app and "
      ~ "passes green against that test's state. Nothing rewrites test sources "
      ~ "any more (task 4055). Fix: `import http_client : getJson, postJson, "
      ~ "postRaw;` and pass a path, or, for a test that launches its own "
      ~ "instance, build the URL from that instance's port. A literal that is "
      ~ "genuinely not a vibe3d endpoint goes in kAllowedLiterals above, with "
      ~ "its file and a reason.", literalOffenders));

    // --- 2. One copy of the transport, not 519 ----------------------------
    assert(copyOffenders.length == 0, format(
        "these tests/*.d files define their own getJson/postJson/postRaw: %s\n"
      ~ "tests/http_client.d is the single implementation (task 4055 removed "
      ~ "538 copies from 318 files); a local one re-forks the endpoint that "
      ~ "census 1 above exists to keep correct, and a later fix to the shared "
      ~ "client will not reach it. Fix: import the shared function. If you need "
      ~ "a local assertion around it, give the wrapper its own name and call "
      ~ "the shared transport from inside it — see postOk in "
      ~ "test_hide_derive_deferral.d.", copyOffenders));

    // --- 3. The allowlist must not rot ------------------------------------
    foreach (row; kAllowedLiterals)
        enforce((row[0] ~ " " ~ row[1]) in allowedSeen, format(
            "kAllowedLiterals names \"%s\" in %s, and it is no longer there. "
          ~ "A stale exemption is a standing hole: delete the row.",
            row[1], row[0]));
}
