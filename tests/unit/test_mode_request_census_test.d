// Task 6790: test-only route authorization is a property of one dispatched
// request. The population is derived from syntax — every production `if`
// condition containing the whole identifier `testMode` — rather than from a
// copied route list. That form has exactly nine members on the task baseline.
module tests.unit.test_mode_request_census_test;

import http_server : HttpRequestContext;
import std.algorithm : count;
import std.file : readText;
import std.format : format;
import std.path : buildPath, dirName;
import std.string : indexOf, join;
import tests.unit.census_symbols : balancedSpan, blankNonCode,
    blankUnittestBodies, isIdentChar;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private bool namesIdent(string text, string ident)
{
    if (ident.length == 0 || ident.length > text.length) return false;
    foreach (i; 0 .. text.length - ident.length + 1) {
        if (text[i .. i + ident.length] == ident
            && (i == 0 || !isIdentChar(text[i - 1]))
            && (i + ident.length == text.length
                || !isIdentChar(text[i + ident.length])))
            return true;
    }
    return false;
}

private string[] identifiers(string text)
{
    string[] result;
    size_t i;
    while (i < text.length) {
        if (!isIdentChar(text[i]) || (text[i] >= '0' && text[i] <= '9')) {
            ++i;
            continue;
        }
        immutable start = i++;
        while (i < text.length && isIdentChar(text[i])) ++i;
        result ~= text[start .. i];
    }
    return result;
}

private bool containsSequence(const string[] haystack,
                              const string[] needle)
{
    if (needle.length == 0 || needle.length > haystack.length) return false;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle) return true;
    return false;
}

private struct IfScan
{
    string[] conditions;
    string problem;
}

private IfScan scanTestModeIfs(string raw)
{
    immutable code = blankUnittestBodies(blankNonCode(raw));
    IfScan result;
    size_t i;
    while (i + 2 <= code.length) {
        if (code[i .. i + 2] != "if"
            || (i > 0 && isIdentChar(code[i - 1]))
            || (i + 2 < code.length && isIdentChar(code[i + 2]))) {
            ++i;
            continue;
        }
        size_t open = i + 2;
        while (open < code.length
               && (code[open] == ' ' || code[open] == '\t'
                   || code[open] == '\n' || code[open] == '\r')) ++open;
        if (open >= code.length || code[open] != '(') {
            i += 2;
            continue;
        }
        immutable condition = balancedSpan(code, open, '(', ')');
        if (condition.length == 0) {
            result.problem = format("unbalanced if condition at byte %d", i);
            return result;
        }
        if (namesIdent(condition, "testMode"))
            result.conditions ~= condition;
        i = open + condition.length;
    }
    return result;
}

private string functionBody(string code, string declaration)
{
    immutable start = code.indexOf(declaration);
    if (start < 0) return null;
    immutable openRel = code[start .. $].indexOf('{');
    if (openRel < 0) return null;
    return balancedSpan(code, start + cast(size_t) openRel, '{', '}');
}

unittest // lexer and whole-token controls precede the production floor
{
    enum sample = q{
        if (!request.context.testMode) {}
        // if (!request.context.testMode) {}
        auto quoted = "if (!request.context.testMode)";
        char quote = '"';
        if (enabled && !request.context.testMode) {}
        if (!request.context.other_testMode) {}
    };
    auto scan = scanTestModeIfs(sample);
    assert(scan.problem.length == 0 && scan.conditions.length == 2,
        "6790 scanner control: comments, literals, character literals or "
        ~ "identifier boundaries changed the two-condition result");
}

unittest // production floor -> request needle -> structural path
{
    immutable path = buildPath(repoRoot, "source", "http_server.d");
    immutable raw = readText(path);
    auto scan = scanTestModeIfs(raw);

    assert(scan.problem.length == 0,
        "6790 testMode condition census could not parse its production area: "
        ~ scan.problem);
    assert(scan.conditions.length == 9,
        format("6790 testMode condition population changed; expected 9 "
             ~ "production if-conditions from the syntax rule, found %d",
               scan.conditions.length));

    string[] wrongPaths;
    foreach (condition; scan.conditions) {
        auto ids = identifiers(condition);
        if (!containsSequence(ids, ["request", "context", "testMode"])
            || ids.count("testMode") != 1)
            wrongPaths ~= condition;
    }
    assert(wrongPaths.length == 0,
        "6790 testMode request needle: every discovered condition must read "
        ~ "the request context exactly once; offenders:\n"
        ~ wrongPaths.join("\n"));

    auto added = scanTestModeIfs(raw
        ~ "\nvoid task6790Probe(HttpRequest request) { "
        ~ "if (!request.context.testMode) {} }\n");
    assert(added.problem.length == 0 && added.conditions.length == 10,
        "6790 testMode census positive control: an unknown tenth condition "
        ~ "was not discovered by the syntax rule");
}

unittest // the route and service null gates are independent surfaces
{
    immutable raw = readText(buildPath(repoRoot, "source", "http_server.d"));
    immutable code = blankUnittestBodies(blankNonCode(raw));
    immutable providers = blankUnittestBodies(blankNonCode(readText(
        buildPath(repoRoot, "source", "http_providers.d"))));
    immutable service = functionBody(code, "private void serviceSubpatchHold(");
    immutable route = functionBody(code, "private void route_apiSubpatchHold(");

    assert(service.length != 0 && route.length != 0 && providers.length != 0,
        "6790 subpatch-hold area floor: service, route or provider wiring "
        ~ "source was not found");
    assert(service.count("if (subpatchHoldAction is null)") == 1,
        "6790 subpatch-hold service null gate changed");
    assert(route.count("if (subpatchHoldAction is null)") == 1,
        "6790 subpatch-hold route null gate changed");
    assert(code.count("&serviceSubpatchHold") == 1,
        "6790 subpatch-hold structural pin: bridge must bind the named "
        ~ "service method exactly once");
    assert(providers.count("httpServer.setSubpatchHoldAction(") == 1,
        "6790 subpatch-hold production wiring pin: provider composition must "
        ~ "install the action exactly once");
    assert(code.count("subpatchHoldHandler") == 0
        && code.count("SubpatchHoldHandler") == 0,
        "6790 subpatch-hold action role regressed to the retired handler name");
}

// The request authorization carrier is deliberately one field. Keep this pin
// textually after the population, request needle and structural assertions.
static assert([__traits(allMembers, HttpRequestContext)] == ["testMode"],
    "6790 HttpRequestContext composition changed");
