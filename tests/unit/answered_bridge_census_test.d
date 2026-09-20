// The route table's Answered column is the port census (task 6730).
// Every handler is keyed by its NAME: /api/camera deliberately has separate
// GET and POST handlers with opposite thread ownership, so a path-keyed scan
// collapses the one pair that proves the distinction.  The population and
// both sides of the biconditional are exact: a handler without a *Bridge is
// httpThread, and a handler with one is not.  The literal columns are 24
// httpThread / 35 mainThread / 2 kFramesAnswered; resolving the last column
// gives default 26 httpThread / 35 mainThread and PerfProbe 24 / 37.  Bridge
// reachability follows local named calls to a fixed point, rather than reading
// only the route handler's own text.  Both builds pin the same raw frame-handler
// bytes through one shared digest.
module tests.unit.answered_bridge_census_test;

import std.algorithm : endsWith, sort;
import std.array     : appender, join;
import std.digest.sha : sha256Of, toHexString;
import std.file      : readText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : count, indexOf, strip;

import tests.unit.census_symbols : blankNonCode, declaratorName;

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

private struct NamedBody
{
    string name;
    string code;
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

private bool hasAggregateKeyword(string declaration)
{
    foreach (word; ["class", "enum", "interface", "struct", "template", "union"])
        if (tokenCount(declaration, word) != 0) return true;
    return false;
}

/// Find named function bodies with the same code projection and brace walker
/// used for route handlers.  Anonymous delegates are deliberately not given a
/// name: a direct call cannot target one by source identifier.
private NamedBody[] namedFunctionBodies(string code)
{
    struct OpenBrace
    {
        size_t at;
        string name;
        bool isFunction;
    }

    NamedBody[] result;
    OpenBrace[] opens;
    size_t declarationStart;
    foreach (i, c; code)
    {
        switch (c)
        {
        case '{':
            const declaration = code[declarationStart .. i];
            const name = declaratorName(declaration);
            opens ~= OpenBrace(i, name,
                name.length != 0 && declaration.indexOf('(') >= 0
                && !hasAggregateKeyword(declaration));
            declarationStart = i + 1;
            break;
        case '}':
            assert(opens.length != 0,
                "6730 named-body scan found an unmatched closing brace");
            const open = opens[$ - 1];
            opens = opens[0 .. $ - 1];
            if (open.isFunction)
                result ~= NamedBody(open.name,
                    code[open.at .. i + 1].idup);
            declarationStart = i + 1;
            break;
        case ';':
            declarationStart = i + 1;
            break;
        default:
            break;
        }
    }
    assert(opens.length == 0,
        "6730 named-body scan found an unterminated brace-owning region");
    return result;
}

private string[] calledLocalNames(string codeBody, ref string[][string] bodies)
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
        size_t next = i;
        while (next < codeBody.length
            && (codeBody[next] == ' ' || codeBody[next] == '\t'
                || codeBody[next] == '\r' || codeBody[next] == '\n'))
            ++next;
        if (next < codeBody.length && codeBody[next] == '('
            && word in bodies)
            seen[word.idup] = true;
    }
    auto result = seen.keys;
    result.sort;
    return result;
}

private string[][string] namedFunctionBodyMap(string code)
{
    string[][string] bodies;
    foreach (body; namedFunctionBodies(code))
        bodies[body.name] ~= body.code;
    return bodies;
}

private string[] reachableBridgeIdentifiers(string root,
                                             ref string[][string] bodies)
{
    assert(root in bodies, "6730 route handler has no named body: " ~ root);

    bool[string] visited;
    string[] pending = [root];
    bool[string] bridges;
    while (pending.length != 0)
    {
        const name = pending[$ - 1];
        pending.length -= 1;
        if (name in visited) continue;
        visited[name] = true;
        foreach (body; bodies[name])
        {
            foreach (bridge; bridgeIdentifiers(body)) bridges[bridge] = true;
            foreach (callee; calledLocalNames(body, bodies))
                if (callee !in visited) pending ~= callee;
        }
    }
    auto result = bridges.keys;
    result.sort;
    return result;
}

private RouteRow[] scanRoutes(string raw)
{
    const code = blankNonCode(raw);
    const commentsBlanked = blankComments(raw);
    auto bodies = namedFunctionBodyMap(code);
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
        assert(row.body.length >= 100, format(
            "6730 handler body span is too short: %s covers %d bytes, expected at least 100",
            row.handler, row.body.length));
        row.bridges = reachableBridgeIdentifiers(row.handler, bodies);
    }
    return routes;
}

private string routeLabel(ref const RouteRow row)
{
    return row.method ~ " " ~ row.path ~ " (" ~ row.handler ~ ")";
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

private void assertFrameBodyBytes()
{
    const raw = readText(kServerPath);
    const routes = scanRoutes(raw);
    const bytes = frameBodyBytes(routes);
    const digest = sha256Of(cast(const(ubyte)[]) bytes).toHexString;
    enum expectedBytes = 2632;
    enum expectedSha256 =
        "BCCDF6A5AC179CFCA0083BFCADCEB573C6EA779C154BE45BEB8E6B617460BC94";
    assert(bytes.length == expectedBytes, format(
        "6730 kFramesAnswered handler bytes changed: expected %d, found %d",
        expectedBytes, bytes.length));
    assert(digest == expectedSha256, format(
        "6730 kFramesAnswered handler bytes changed: expected sha256 %s, found %s",
        expectedSha256, digest));
}

unittest // scanner control: whole lower-case identifier, code only
{
    const probe = blankNonCode(`historyBridge;
        // modelBridge;
        "layersBridge";
        MainThreadBridge;
        historyBridgeSuffix;`);
    assert(bridgeIdentifiers(probe) == ["historyBridge"],
        "6730 *Bridge token classifier accepted a comment, literal, type, or suffix");
}

unittest // fixture: route-table comments and non-code bridge names stay blank
{
    enum fixture = q"FIXTURE
private enum RouteSpec[] kRoutes = [
    RouteSpec(/* comment, with comma */ "/fixture", "GET", Match.exact,
              Answered.httpThread, "route_fixture"),
    RouteSpec("/nested", "GET", Match.exact,
              Answered.mainThread, "route_nested"),
];
void route_fixture(HttpRequest request, HttpResponse response) {
    // historyBridge is prose, not a dependency.
    const diagnostic = "modelBridge is literal text";
    response.statusCode = request.path.length ? 200 : 500;
    response.body = diagnostic.length ? "{}" : "unreachable";
}
void route_nested(HttpRequest request, HttpResponse response) {
    nested_helper(request, response);
    response.statusCode = response.body.length ? 200 : 500;
    response.body ~= (request.path.length ? "" : "unreachable padding for span");
}
void nested_helper(HttpRequest request, HttpResponse response) {
    historyBridge.submitAndWait();
}
FIXTURE";
    const routes = scanRoutes(fixture);
    assert(routes.length == 2 && routes[0].bridges.length == 0,
        "6730 code projection treated a route-table comment, comment bridge, or literal bridge as code");
    assert(routes[1].bridges == ["historyBridge"],
        "6730 local-call closure did not reach a bridge named only by a helper body");
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
    size_t httpThread;
    size_t mainThread;
    size_t framesAnswered;
    foreach (ref const row; routes)
    {
        if (row.answered == "Answered.httpThread") ++httpThread;
        else if (row.answered == "Answered.mainThread") ++mainThread;
        else if (row.answered == "kFramesAnswered") ++framesAnswered;
        const isHttpThread = row.answered == "Answered.httpThread";
        const hasBridge = row.bridges.length != 0;
        if (hasBridge) ++bridged;
        else
        {
            ++portless;
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
    assert(httpThread == 24, format(
        "6730 Answered.httpThread column changed: expected 24, found %d", httpThread));
    assert(mainThread == 35, format(
        "6730 Answered.mainThread column changed: expected 35, found %d", mainThread));
    assert(framesAnswered == 2, format(
        "6730 kFramesAnswered column changed: expected 2, found %d", framesAnswered));

    // Reproduce the rejected key without depending on the two /api/camera
    // rows' order.  OR-folding by path still collapses 61 handlers to 60 paths
    // and yields the wrong 23/37 partition instead of 24/37 above.
    bool[string] pathHasBridge;
    foreach (ref const row; routes) pathHasBridge[row.path] |= row.bridges.length != 0;
    size_t pathPortless;
    size_t pathBridged;
    foreach (hasBridge; pathHasBridge)
    {
        if (!hasBridge) ++pathPortless;
        else ++pathBridged;
    }
    assert(pathPortless == 23 && pathBridged == 37,
        format("6730 path-key control stopped discriminating: "
             ~ "expected 23/37 over 60 paths, found %d/%d",
               pathPortless, pathBridged));
}

unittest
{
    assertFrameBodyBytes();
}
