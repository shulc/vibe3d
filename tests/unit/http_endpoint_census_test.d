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
module tests.unit.http_endpoint_census_test;

import std.algorithm : sort;
import std.ascii     : isDigit, isWhite;
import std.exception : enforce;
import std.file      : dirEntries, SpanMode, exists, readText;
import std.format    : format;
import std.path      : baseName, buildPath, dirName;
import std.string    : indexOf, split, splitLines, startsWith, stripLeft;

import tests.unit.census_symbols : blankNonCode;

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

private static immutable string[] kRootRouteSpellings = [`"/"`, "`/`"];
private static immutable string[] kRouteSelectionTerms = ["path ==", "startsWith("];
private static immutable string[] kContractHttpThreadRoutes = [
    "/api/changes", "/api/cache/rebuilds", "/api/gc/commands",
];
private static immutable string[] kContractHttpThreadHandlers = [
    "route_apiChanges", "route_apiCacheRebuilds", "route_apiGcCommands",
];

/// Blank comments while retaining string-literal bytes. Both lexer views keep
/// byte offsets stable; only comment bytes differ between them.
private string blankComments(string raw)
{
    const codeOnly = blankNonCode(raw);
    const withComments = blankNonCode(raw, true);
    assert(codeOnly.length == raw.length && withComments.length == raw.length,
        "6760 scanner control: lexer projections changed source byte length");
    auto result = raw.dup;
    foreach (i; 0 .. result.length)
        if (codeOnly[i] != withComments[i])
            result[i] = ' ';
    return result.idup;
}

private struct SourceProjection
{
    string code;
    string literals;
}

private SourceProjection projectSource(string raw)
{
    return SourceProjection(blankNonCode(raw), blankComments(raw));
}

private string sourceBody(string raw, string code, string marker)
{
    if (raw.length != code.length) return null;
    const markerAt = code.indexOf(marker);
    if (markerAt < 0) return null;
    const openRel = code[cast(size_t) markerAt .. $].indexOf('{');
    if (openRel < 0) return null;
    const open = cast(size_t) markerAt + cast(size_t) openRel;
    const close = matchingClose(code, open, '{', '}');
    if (close == code.length) return null;
    return raw[open .. close + 1];
}

private bool carriesHttpThreadRationale(string body)
{
    return body.indexOf("Answered.httpThread") >= 0
        && body.indexOf("unsynchron") >= 0;
}

private size_t matchingClose(string code, size_t open, char opening, char closing)
{
    if (code[open] != opening) return code.length;
    size_t depth;
    foreach (i; open .. code.length)
    {
        if (code[i] == opening) ++depth;
        else if (code[i] == closing && --depth == 0) return i;
    }
    return code.length;
}

private string[] presentTerms(string source, const string[] terms)
{
    string[] found;
    foreach (term; terms)
        if (source.indexOf(term) >= 0) found ~= term;
    return found;
}

private struct CompositionFindings
{
    string[] literalOffenders;
    string[] handlerOffenders;
    string[] selectionOffenders;
    size_t rootRouteRows;
    size_t codeBytes;
    size_t literalBytes;
}

private CompositionFindings compositionFindings(
        string transportCode, string transportLiterals,
        const string[] routeLiterals, const string[] handlerNames)
{
    CompositionFindings result;
    result.codeBytes = transportCode.length;
    result.literalBytes = transportLiterals.length;
    result.selectionOffenders = presentTerms(transportCode, kRouteSelectionTerms);
    foreach (path; routeLiterals)
    {
        if (path == "/") ++result.rootRouteRows;
        const spellings = path == "/" ? kRootRouteSpellings : [path];
        if (presentTerms(transportLiterals, spellings).length != 0)
            result.literalOffenders ~= path;
    }
    foreach (handler; handlerNames)
        if (presentTerms(transportCode, [handler]).length != 0)
            result.handlerOffenders ~= handler;
    return result;
}

private void classifyContractDisposition(
        string path, string routeFields,
        ref size_t contractRouteRows, ref string[] offenders)
{
    foreach (contractPath; kContractHttpThreadRoutes)
        if (path == contractPath)
        {
            ++contractRouteRows;
            if (routeFields.indexOf("Answered.httpThread") < 0)
                offenders ~= contractPath;
        }
}

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

// Task 6760 makes the transport-neutrality requirement executable. This is
// half A only: a composition census cannot prove how a route ANSWERS; the
// in-process route walk in http_server.d is the behavioural half, traversing
// all 61 bodies through the common dispatcher with a >= 30 non-degraded-
// response floor.
// Two apparent duplications are sanctioned controls, not implementation copies:
// tools/sanitizer/lane.d :: kSweepRoutes independently recounts all 61 routes,
// while /api/changes, /api/cache/rebuilds and /api/gc/commands are task 1906
// contracts that must remain Answered.httpThread.
unittest // scanner controls: both positive directions and both lexical hazards
{
    assert(matchingClose("[{}]", 0, '{', '}') == 4,
        "6760 brace control: matchingClose must reject a non-opener start");
    assert(presentTerms(`if (path == "/") return;`, kRootRouteSpellings)
            == [`"/"`],
        `6760 root-literal control: a body containing "/" must be marked`);
    assert(presentTerms("if (path == `/`) return;", kRootRouteSpellings)
            == ["`/`"],
        "6760 root-literal control: a body containing `/` must be marked");
    assert(presentTerms(`auto version_ = "HTTP/1.1";`, kRootRouteSpellings).length == 0,
        "6760 root-literal control: a body containing only HTTP/1.1 must not be marked");

    const compositionControl = compositionFindings(
        `if (path == kPingRoute) route_apiPing(request, response);`,
        `auto root = "/"; auto ping = "/api/ping";`,
        ["/", "/api/ping"], ["route_root", "route_apiPing"]);
    assert(compositionControl.rootRouteRows == 1
            && compositionControl.literalOffenders == ["/", "/api/ping"]
            && compositionControl.handlerOffenders == ["route_apiPing"]
            && compositionControl.selectionOffenders == ["path =="],
        "6760 composition control: root, non-root, handler and route-selection "
        ~ "leaks must all be marked");

    assert(presentTerms(blankNonCode(
            `if (path == kPingRoute) return;`), kRouteSelectionTerms)
            == ["path =="],
        "6760 route-selection control: path == a route constant must be marked");
    assert(presentTerms(blankNonCode(
            `if (path == "/api/" ~ "ping") return;`), kRouteSelectionTerms)
            == ["path =="],
        "6760 route-selection control: path == a concatenated route must be marked");
    assert(presentTerms(blankNonCode(
            `if (path.startsWith("/api/pin")) return;`), kRouteSelectionTerms)
            == ["startsWith("],
        "6760 route-selection control: a route-prefix test must be marked");

    size_t contractRows;
    string[] contractOffenders;
    classifyContractDisposition("/api/changes",
        "Match.exact, Answered.httpThread", contractRows, contractOffenders);
    classifyContractDisposition("/api/gc/commands",
        "Match.exact, Answered.mainThread", contractRows, contractOffenders);
    assert(contractRows == 2 && contractOffenders == ["/api/gc/commands"],
        "6760 contract-disposition control: a valid diagnostic row must pass "
        ~ "and a bridged diagnostic row must be marked");
    assert(carriesHttpThreadRationale(
            "Answered.httpThread because these counters are unsynchronised"),
        "6760 contract-rationale control: both the disposition and its "
        ~ "unsynchronised-source reason must be recognised");
    assert(!carriesHttpThreadRationale("Answered.httpThread without a reason"),
        "6760 contract-rationale control: a disposition without its "
        ~ "unsynchronised-source reason must not satisfy the pin");
    assert(!carriesHttpThreadRationale("unsynchronised but no disposition"),
        "6760 contract-rationale control: an unsynchronised-source comment "
        ~ "without Answered.httpThread must not satisfy the pin");

    enum rationaleSource = q"FIXTURE
private void route_fixture() {
    // Answered.httpThread because the diagnostic is unsynchronised.
}
FIXTURE";
    const rationaleProjection = projectSource(rationaleSource);
    assert(carriesHttpThreadRationale(sourceBody(rationaleSource,
            rationaleProjection.code, "private void route_fixture()")),
        "6760 source-body control: the complete named handler body must carry "
        ~ "its source rationale");
    assert(sourceBody(rationaleSource, rationaleProjection.code,
            "private void missing()" ).length == 0,
        "6760 source-body control: a missing handler marker must not borrow a body");
    assert(sourceBody("short", rationaleProjection.code,
            "private void route_fixture()" ).length == 0,
        "6760 source-body control: unequal lexical projections must be rejected");
    assert(sourceBody("private void unfinished()", "private void unfinished()",
            "private void unfinished()" ).length == 0,
        "6760 source-body control: a marker without a body must be rejected");
    assert(sourceBody("private void unfinished() {",
            "private void unfinished() {", "private void unfinished()" ).length == 0,
        "6760 source-body control: an unbalanced handler body must be rejected");

    enum bracesInLiteral = q"FIXTURE
final class InProcessHttpTransport {
    string response = "}}";
    void request(string path) {
        if (path == "/api/ping") return;
    }
}
FIXTURE";
    const bracesProjection = projectSource(bracesInLiteral);
    const bracesCode = bracesProjection.code;
    const bracesOpen = cast(size_t) bracesCode.indexOf('{');
    const bracesClose = matchingClose(bracesCode, bracesOpen, '{', '}');
    assert(bracesClose < bracesCode.length
            && bracesProjection.literals[bracesOpen .. bracesClose + 1]
                .indexOf("/api/ping") >= 0,
        "6760 scanner control: two extra } bytes inside a string must not "
        ~ "truncate the transport before a leaked /api/ping route");

    enum routeInComment = q"FIXTURE
final class InProcessHttpTransport {
    // A comment mentions "/api/ping" but selects no route.
    void request(string path) {}
}
FIXTURE";
    const commentProjection = projectSource(routeInComment);
    const commentCode = commentProjection.code;
    const commentOpen = cast(size_t) commentCode.indexOf('{');
    const commentClose = matchingClose(commentCode, commentOpen, '{', '}');
    assert(commentClose < commentCode.length
            && commentProjection.literals[commentOpen .. commentClose + 1]
                .indexOf("/api/ping") < 0,
        "6760 scanner control: a route literal in a comment must not be "
        ~ "reported as transport knowledge");
}

unittest
{
    const serverPath = buildPath(repoRoot, "source", "http_server.d");
    const raw = readText(serverPath);
    const projection = projectSource(raw);
    const code = projection.code;
    const commentsBlanked = projection.literals;
    assert(code.indexOf(`"HTTP/1.1"`) < 0
            && commentsBlanked.indexOf(`"HTTP/1.1"`) >= 0,
        "6760 projection control: the real source code view must blank string "
        ~ "literals while the literal-preserving view retains HTTP/1.1");

    string[] contractRationaleOffenders;
    foreach (i, path; kContractHttpThreadRoutes)
    {
        const body = sourceBody(raw, code,
            "private void " ~ kContractHttpThreadHandlers[i] ~ "(");
        if (!carriesHttpThreadRationale(body))
            contractRationaleOffenders ~= path;
    }
    assert(contractRationaleOffenders.length == 0, format(
        "6760 transport composition census: task-1906 diagnostic route "
      ~ "handler(s) must retain their Answered.httpThread + unsynchronised "
      ~ "source rationale: %s. The test-side source pin keeps the reason for "
      ~ "the table disposition visible where each route is implemented.",
        contractRationaleOffenders));

    enum transportMarker = "final class InProcessHttpTransport";
    const transportAt = code.indexOf(transportMarker);
    assert(transportAt >= 0,
        "6760 transport composition census: InProcessHttpTransport disappeared");
    const transportOpenRel = code[cast(size_t) transportAt .. $].indexOf('{');
    assert(transportOpenRel >= 0,
        "6760 transport composition census: InProcessHttpTransport has no body");
    const transportOpen = cast(size_t) transportAt
        + cast(size_t) transportOpenRel;
    const transportClose = matchingClose(code, transportOpen, '{', '}');
    assert(transportClose < code.length,
        "6760 transport composition census: InProcessHttpTransport body is unbalanced");
    const transportCode = code[transportOpen .. transportClose + 1];
    const transportLiterals = commentsBlanked[transportOpen .. transportClose + 1];
    assert(transportCode.length >= 300,
        "6760 transport composition census: transport-body domain fell below "
        ~ "300 bytes; below this floor are the route-selection, route-literal "
        ~ "and handler-name absence checks, so none would be reached on an "
        ~ "empty/truncated body");

    enum routesMarker = "private enum RouteSpec[] kRoutes = [";
    const routesAt = code.indexOf(routesMarker);
    assert(routesAt >= 0,
        "6760 transport composition census: kRoutes disappeared");
    const routesEndRel = code[cast(size_t) routesAt .. $].indexOf("];\n");
    assert(routesEndRel >= 0,
        "6760 transport composition census: kRoutes has no closing delimiter");
    const routesText = commentsBlanked[cast(size_t) routesAt
        .. cast(size_t) routesAt + cast(size_t) routesEndRel];

    string[] routeLiterals;
    string[] handlerNames;
    string[] contractDispositionOffenders;
    size_t contractRouteRows;
    foreach (line; routesText.splitLines)
    {
        const stripped = line.stripLeft;
        if (!stripped.startsWith("RouteSpec(")) continue;
        const fields = stripped.split('"');
        assert(fields.length == 7,
            "6760 transport composition census: a kRoutes row no longer has "
            ~ "the path/method/handler literal shape: " ~ stripped);
        routeLiterals ~= fields[1];
        handlerNames ~= fields[5];
        classifyContractDisposition(fields[1], fields[4], contractRouteRows,
            contractDispositionOffenders);
    }

    // Independent population floors for the two narrowed domains. These are
    // measured route ROWS, not distinct paths (/api/camera has GET and POST).
    assert(routeLiterals.length == 61,
        "6760 transport composition census: route-literal domain must contain "
        ~ "all 61 kRoutes rows, found " ~ format("%d", routeLiterals.length)
        ~ ". The exact population check runs before the leakage diagnostics "
        ~ "below: an added route that also leaks reports here as found 62, "
        ~ "not at the leakage assert");
    assert(handlerNames.length == 61,
        "6760 transport composition census: handler-name domain must contain "
        ~ "all 61 kRoutes rows, found " ~ format("%d", handlerNames.length)
        ~ ". Below this floor are the contract-disposition and handler-leak "
        ~ "checks, so neither runs over a changed handler population");
    assert(contractRouteRows == 3,
        "6760 transport composition census: the source table must retain the "
        ~ "three task-1906 diagnostic-route dispositions");
    assert(contractDispositionOffenders.length == 0, format(
        "6760 transport composition census: task-1906 diagnostic route(s) "
      ~ "must remain Answered.httpThread in the source table: %s. Their "
      ~ "unsynchronised scalar-diagnostic rationale is recorded at the route "
      ~ "handlers; moving one behind a bridge requires resolving that contract.",
        contractDispositionOffenders));

    auto findings = compositionFindings(transportCode, transportLiterals,
        routeLiterals, handlerNames);
    assert(findings.codeBytes == transportCode.length
            && findings.literalBytes == transportLiterals.length,
        "6760 transport composition census: the absence classifier did not "
        ~ "scan the complete extracted transport body");
    assert(findings.rootRouteRows == 1,
        "6760 transport composition census: root-literal special-case domain "
        ~ "must contain exactly 1 kRoutes row");
    sort(findings.literalOffenders);
    sort(findings.handlerOffenders);

    assert(findings.selectionOffenders.length == 0, format(
        "6760 transport composition census: route-selection operation(s) "
      ~ "leaked into InProcessHttpTransport: %s. Literal extraction cannot "
      ~ "see a route moved to a constant or assembled from fragments; path "
      ~ "equality and prefix selection stay in HttpServer.handleRequest.",
        findings.selectionOffenders));
    assert(findings.literalOffenders.length == 0, format(
        "6760 transport composition census: concrete route handling leaked "
      ~ "into InProcessHttpTransport via route literal(s): %s. The transport "
      ~ "may construct a request and call HttpServer.handleRequest; route "
      ~ "selection stays in the server dispatcher.", findings.literalOffenders));
    assert(findings.handlerOffenders.length == 0, format(
        "6760 transport composition census: handler name(s) leaked into "
      ~ "InProcessHttpTransport: %s. The transport must not select or invoke "
      ~ "a route handler; HttpServer.handleRequest owns dispatch.",
        findings.handlerOffenders));
}
