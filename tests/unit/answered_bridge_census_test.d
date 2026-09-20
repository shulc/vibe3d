// The route table's Answered column is the port census (task 6730).
// Every handler is keyed by its NAME: /api/camera deliberately has separate
// GET and POST handlers with opposite thread ownership, so a path-keyed scan
// collapses the one pair that proves the distinction.  The population and
// both sides of the biconditional are exact: a handler without a *Bridge is
// httpThread, and a handler with one is not.  The two kFramesAnswered builds
// also pin the same raw handler bytes through one shared digest.
module tests.unit.answered_bridge_census_test;

import std.algorithm : endsWith, sort;
import std.array     : appender, join;
import std.digest.sha : sha256Of, toHexString;
import std.file      : readText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : count, indexOf, split, splitLines, strip;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum string kServerPath = buildPath(repoRoot, "source", "http_server.d");

private struct RouteRow
{
    string path;
    string method;
    string answered;
    string handler;
    string body;
    string[] bridges;
}

private bool isIdent(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

private bool isTokenAt(string source, size_t at, string token)
{
    if (at + token.length > source.length
        || source[at .. at + token.length] != token)
        return false;
    return (at == 0 || !isIdent(source[at - 1]))
        && (at + token.length == source.length
            || !isIdent(source[at + token.length]));
}

private size_t tokenCount(string source, string token)
{
    size_t result;
    size_t from;
    while (from < source.length)
    {
        const rel = source[from .. $].indexOf(token);
        if (rel < 0) break;
        const at = from + cast(size_t) rel;
        if (isTokenAt(source, at, token)) ++result;
        from = at + token.length;
    }
    return result;
}

private size_t matchingClose(string code, size_t open, char opening, char closing)
{
    if (open >= code.length || code[open] != opening) return code.length;
    size_t depth;
    foreach (i; open .. code.length)
    {
        if (code[i] == opening) ++depth;
        else if (code[i] == closing && --depth == 0) return i;
    }
    return code.length;
}

/// Blank comments while retaining literal bytes.  Both projections are
/// same-length lexer products; positions where only the comments projection
/// has text are comment bytes in the original.
private string blankComments(string raw)
{
    const codeOnly = blankNonCode(raw);
    const withComments = blankNonCode(raw, true);
    assert(codeOnly.length == raw.length && withComments.length == raw.length,
        "6730 comment projections changed http_server.d byte length");
    auto result = raw.dup;
    foreach (i; 0 .. result.length)
        if (codeOnly[i] != withComments[i] && result[i] != '\n')
            result[i] = ' ';
    return result.idup;
}

private string[] splitRouteArgs(string raw, string code)
{
    assert(raw.length == code.length,
        "6730 route argument projections have different byte lengths");
    auto result = appender!(string[]);
    size_t start;
    int parens, brackets, braces;
    foreach (i, c; code)
    {
        switch (c)
        {
        case '(': ++parens; break;
        case ')': --parens; break;
        case '[': ++brackets; break;
        case ']': --brackets; break;
        case '{': ++braces; break;
        case '}': --braces; break;
        case ',':
            if (parens == 0 && brackets == 0 && braces == 0)
            {
                result.put(raw[start .. i].strip.idup);
                start = i + 1;
            }
            break;
        default: break;
        }
    }
    result.put(raw[start .. $].strip.idup);
    return result.data;
}

private string quoted(string value, string field)
{
    assert(value.length >= 2 && value[0] == '"' && value[$ - 1] == '"',
        "6730 RouteSpec " ~ field ~ " is not a quoted literal: " ~ value);
    return value[1 .. $ - 1].idup;
}

private string[] bridgeIdentifiers(string codeBody)
{
    bool[string] seen;
    size_t i;
    while (i < codeBody.length)
    {
        if (!isIdent(codeBody[i]) || (codeBody[i] >= '0' && codeBody[i] <= '9'))
        {
            ++i;
            continue;
        }
        const start = i++;
        while (i < codeBody.length && isIdent(codeBody[i])) ++i;
        const word = codeBody[start .. i];
        if (word[0] >= 'a' && word[0] <= 'z' && word.endsWith("Bridge"))
            seen[word.idup] = true;
    }
    auto result = seen.keys;
    result.sort;
    return result;
}

private RouteRow[] scanRoutes(string raw)
{
    const code = blankNonCode(raw);
    const commentsBlanked = blankComments(raw);
    enum tableMarker = "private enum RouteSpec[] kRoutes = [";
    const tableAt = code.indexOf(tableMarker);
    assert(tableAt >= 0, "6730 census cannot find the kRoutes declaration");
    const tableOpen = cast(size_t) tableAt + tableMarker.length - 1;
    const tableClose = matchingClose(code, tableOpen, '[', ']');
    assert(tableClose < code.length, "6730 kRoutes declaration is unterminated");

    const tableCode = code[tableOpen + 1 .. tableClose];
    const tableRaw = commentsBlanked[tableOpen + 1 .. tableClose];
    RouteRow[] routes;
    size_t from;
    while (from < tableCode.length)
    {
        const rel = tableCode[from .. $].indexOf("RouteSpec");
        if (rel < 0) break;
        const at = from + cast(size_t) rel;
        if (!isTokenAt(tableCode, at, "RouteSpec"))
        {
            from = at + 9;
            continue;
        }
        size_t open = at + 9;
        while (open < tableCode.length && tableCode[open] != '(') ++open;
        assert(open < tableCode.length,
            "6730 RouteSpec token has no argument list");
        const close = matchingClose(tableCode, open, '(', ')');
        assert(close < tableCode.length,
            "6730 RouteSpec argument list is unterminated");
        const args = splitRouteArgs(tableRaw[open + 1 .. close],
                                    tableCode[open + 1 .. close]);
        assert(args.length == 5, format(
            "6730 RouteSpec must have five arguments; scanner found %d", args.length));
        RouteRow row;
        row.path = quoted(args[0], "path");
        row.method = quoted(args[1], "method");
        row.answered = args[3].strip.idup;
        row.handler = quoted(args[4], "handler");
        assert(row.answered == "Answered.httpThread"
            || row.answered == "Answered.mainThread"
            || row.answered == "kFramesAnswered",
            "6730 unknown Answered expression for " ~ row.handler ~ ": " ~ row.answered);
        routes ~= row;
        from = close + 1;
    }
    assert(tokenCount(tableCode, "RouteSpec") == routes.length, format(
        "6730 scanner parsed %d of %d RouteSpec tokens",
        routes.length, tokenCount(tableCode, "RouteSpec")));

    foreach (ref row; routes)
    {
        const marker = "void " ~ row.handler ~ "(";
        assert(code.count(marker) == 1, format(
            "6730 handler %s must have one void declaration; found %d",
            row.handler, code.count(marker)));
        const decl = code.indexOf(marker);
        const open = code.indexOf('{', cast(size_t) decl + marker.length);
        assert(open >= 0, "6730 handler has no body: " ~ row.handler);
        const close = matchingClose(code, cast(size_t) open, '{', '}');
        assert(close < code.length, "6730 handler body is unterminated: " ~ row.handler);
        row.body = raw[cast(size_t) open .. close + 1].idup;
        row.bridges = bridgeIdentifiers(code[cast(size_t) open .. close + 1]);
    }
    return routes;
}

private string routeLabel(ref const RouteRow row)
{
    return row.method ~ " " ~ row.path ~ " (" ~ row.handler ~ ")";
}

private string[] frameAnswerDefinitions(string raw)
{
    string[] result;
    foreach (line; blankNonCode(raw).splitLines)
    {
        const normalized = line.strip.split.join(" ");
        if (normalized.indexOf("enum Answered kFramesAnswered =") >= 0)
            result ~= normalized.idup;
    }
    result.sort;
    return result;
}

private string frameBodyBytes(const RouteRow[] routes)
{
    auto result = appender!string;
    size_t framesRows;
    foreach (ref const row; routes)
        if (row.answered == "kFramesAnswered")
        {
            ++framesRows;
            result.put(row.handler);
            result.put('\0');
            result.put(row.body);
            result.put('\0');
        }
    assert(framesRows == 2, format(
        "6730 kFramesAnswered population changed: expected 2, found %d", framesRows));
    return result.data;
}

private void assertFrameBodyBytes(string buildName)
{
    const raw = readText(kServerPath);
    const routes = scanRoutes(raw);
    const bytes = frameBodyBytes(routes);
    const digest = sha256Of(cast(const(ubyte)[]) bytes).toHexString;
    enum expectedBytes = 2632;
    enum expectedSha256 =
        "BCCDF6A5AC179CFCA0083BFCADCEB573C6EA779C154BE45BEB8E6B617460BC94";
    assert(bytes.length == expectedBytes, format(
        "6730 %s kFramesAnswered handler bytes changed: expected %d, found %d",
        buildName, expectedBytes, bytes.length));
    assert(digest == expectedSha256, format(
        "6730 %s kFramesAnswered handler bytes changed: expected sha256 %s, found %s",
        buildName, expectedSha256, digest));
}

unittest
{
    const raw = readText(kServerPath);
    const routes = scanRoutes(raw);

    // Population first: without this, every biconditional below is vacuous.
    assert(routes.length == 61, format(
        "6730 kRoutes population changed: expected 61, found %d", routes.length));

    bool[string] handlers;
    bool[string] paths;
    foreach (ref const row; routes)
    {
        handlers[row.handler] = true;
        paths[row.path] = true;
    }
    assert(handlers.length == 61, format(
        "6730 handler-key population changed: expected 61 distinct names, found %d",
        handlers.length));
    assert(paths.length == 60, format(
        "6730 path population changed: expected the measured 60, found %d",
        paths.length));

    string[] httpThreadWithBridge;
    string[] nonHttpThreadWithoutBridge;
    size_t portless;
    size_t bridged;
    bool allPortlessOnHttpThread = true;
    foreach (ref const row; routes)
    {
        const isHttpThread = row.answered == "Answered.httpThread";
        const hasBridge = row.bridges.length != 0;
        if (hasBridge) ++bridged;
        else
        {
            ++portless;
            allPortlessOnHttpThread = allPortlessOnHttpThread && isHttpThread;
        }
        if (isHttpThread && hasBridge)
            httpThreadWithBridge ~= routeLabel(row) ~ ": " ~ row.bridges.join(", ");
        if (!isHttpThread && !hasBridge)
            nonHttpThreadWithoutBridge ~= routeLabel(row) ~ ": " ~ row.answered;
    }

    // The two needles are intentionally separate: each half of the iff must
    // name its own offender before the exact partition pins run below.
    assert(httpThreadWithBridge.length == 0,
        "6730 Answered.httpThread handler names *Bridge: "
        ~ httpThreadWithBridge.join("; "));
    assert(nonHttpThreadWithoutBridge.length == 0,
        "6730 non-httpThread handler names no *Bridge: "
        ~ nonHttpThreadWithoutBridge.join("; "));

    // Exact sides, not a derived identity: changing every row and every body
    // in lockstep must still fail rather than preserve a vacuous iff.
    assert(portless == 24, format(
        "6730 portless route population changed: expected 24, found %d", portless));
    assert(bridged == 37, format(
        "6730 bridged route population changed: expected 37, found %d", bridged));
    assert(allPortlessOnHttpThread,
        "6730 not every portless handler is Answered.httpThread");

    // Reproduce the rejected key.  Last-row-wins path keying overwrites the
    // POST /api/camera body with the portless GET body, yielding the measured
    // wrong 25/36/false instead of the handler-keyed 24/37/true above.
    bool[string] pathHasBridge;
    foreach (ref const row; routes) pathHasBridge[row.path] = row.bridges.length != 0;
    size_t pathPortless;
    size_t pathBridged;
    bool pathPortlessAllHttp = true;
    foreach (ref const row; routes)
    {
        if (!pathHasBridge[row.path])
        {
            ++pathPortless;
            pathPortlessAllHttp = pathPortlessAllHttp
                && row.answered == "Answered.httpThread";
        }
        else ++pathBridged;
    }
    assert(pathPortless == 25 && pathBridged == 36 && !pathPortlessAllHttp,
        format("6730 path-key control stopped discriminating: "
             ~ "expected 25/36/false, found %d/%d/%s",
               pathPortless, pathBridged, pathPortlessAllHttp));

    const frameDefs = frameAnswerDefinitions(raw);
    assert(frameDefs == [
        "else private enum Answered kFramesAnswered = Answered.httpThread;",
        "version (PerfProbe) private enum Answered kFramesAnswered = Answered.mainThread;",
    ], "6730 kFramesAnswered must map default=>httpThread and PerfProbe=>mainThread: "
       ~ frameDefs.join(" | "));
}

version (PerfProbe) unittest
{
    assertFrameBodyBytes("PerfProbe");
}
else unittest
{
    assertFrameBodyBytes("default");
}
