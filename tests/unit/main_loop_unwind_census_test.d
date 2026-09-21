module tests.unit.main_loop_unwind_census_test;

import std.algorithm : canFind, filter, map, startsWith;
import std.array : array;
import std.file : exists, mkdir, readText, rmdirRecurse, tempDir;
import std.format : format;
import std.path : buildPath, dirName;
import std.process : Config, execute, thisProcessID;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private struct Token
{
    string text;
    size_t offset;
    size_t line;
}

private bool isIdentStart(char c)
{
    return c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

private bool isIdentChar(char c)
{
    return isIdentStart(c) || (c >= '0' && c <= '9');
}

private Token[] lexLoweredAst(string code)
{
    Token[] result;
    size_t line = 1;
    for (size_t i; i < code.length;)
    {
        if (code[i] == '\n')
        {
            ++line;
            ++i;
            continue;
        }
        if (i + 1 < code.length && code[i .. i + 2] == "//")
        {
            while (i < code.length && code[i] != '\n') ++i;
            continue;
        }
        if (i + 1 < code.length
                && (code[i .. i + 2] == "/*" || code[i .. i + 2] == "/+"))
        {
            const close = code[i + 1] == '*' ? "*/" : "+/";
            i += 2;
            while (i + 1 < code.length && code[i .. i + 2] != close)
            {
                if (code[i] == '\n') ++line;
                ++i;
            }
            i = (i + 1 < code.length) ? i + 2 : code.length;
            continue;
        }
        if (code[i] == '"' || code[i] == '\'' || code[i] == '`')
        {
            const quote = code[i++];
            while (i < code.length)
            {
                if (code[i] == '\n') ++line;
                if (quote != '`' && code[i] == '\\' && i + 1 < code.length)
                {
                    i += 2;
                    continue;
                }
                if (code[i++] == quote) break;
            }
            continue;
        }
        if (isIdentStart(code[i]))
        {
            const begin = i++;
            while (i < code.length && isIdentChar(code[i])) ++i;
            result ~= Token(code[begin .. i], begin, line);
            continue;
        }
        if (code[i] >= '0' && code[i] <= '9')
        {
            const begin = i++;
            while (i < code.length && (isIdentChar(code[i]) || code[i] == '.')) ++i;
            result ~= Token(code[begin .. i], begin, line);
            continue;
        }
        if (code[i] > ' ')
            result ~= Token(code[i .. i + 1], i, line);
        ++i;
    }
    return result;
}

private struct AstView
{
    Token[] tokens;
    size_t[size_t] closeBrace;
    size_t mainOpen;
    size_t mainClose;
}

private AstView parseAst(string code)
{
    AstView result;
    result.tokens = lexLoweredAst(code);

    size_t[] stack;
    foreach (i, token; result.tokens)
    {
        if (token.text == "{") stack ~= i;
        else if (token.text == "}")
        {
            assert(stack.length > 0,
                format("W16-M lowered AST has an unmatched } at line %d", token.line));
            const open = stack[$ - 1];
            stack.length--;
            result.closeBrace[open] = i;
        }
    }
    assert(stack.length == 0, "W16-M lowered AST has unmatched { tokens");

    foreach (i; 0 .. result.tokens.length - 3)
    {
        if (result.tokens[i].text == "void"
                && result.tokens[i + 1].text == "main"
                && result.tokens[i + 2].text == "(")
        {
            size_t open = i + 3;
            while (open < result.tokens.length && result.tokens[open].text != "{") ++open;
            assert(open < result.tokens.length, "W16-M lowered AST main has no body");
            result.mainOpen = open;
            result.mainClose = result.closeBrace[open];
            return result;
        }
    }
    assert(false, "W16-M lowered AST has no void main(string[] args)");
    return result;
}

private size_t countSequence(const(Token)[] tokens, const(string)[] pattern)
{
    size_t count;
    if (pattern.length == 0 || tokens.length < pattern.length) return 0;
    foreach (i; 0 .. tokens.length - pattern.length + 1)
    {
        bool matches = true;
        foreach (j, expected; pattern)
            if (tokens[i + j].text != expected)
            {
                matches = false;
                break;
            }
        if (matches) ++count;
    }
    return count;
}

private size_t findAnchor(ref AstView ast, string config)
{
    size_t[] hits;
    foreach (i; ast.mainOpen + 1 .. ast.mainClose)
    {
        if (config == "web")
        {
            if (ast.tokens[i].text == "emscripten_set_main_loop_arg"
                    && i + 1 < ast.mainClose && ast.tokens[i + 1].text == "(")
                hits ~= i;
        }
        else if (i + 5 < ast.mainClose
                && ast.tokens[i].text == "for"
                && ast.tokens[i + 1].text == "("
                && ast.tokens[i + 2].text == ";"
                && ast.tokens[i + 3].text == "running"
                && ast.tokens[i + 4].text == ";"
                && ast.tokens[i + 5].text == ")")
            hits ~= i;
    }
    const label = config == "web"
        ? "emscripten_set_main_loop_arg call" : "for (; running;) loop";
    assert(hits.length == 1,
        format("W16-M %s anchor census: expected exactly 1 %s, got %d",
               config, label, hits.length));
    return hits[0];
}

private size_t[] enclosingFinallyLines(ref AstView ast, size_t anchor)
{
    size_t[] lines;
    foreach (i; ast.mainOpen + 1 .. ast.mainClose)
    {
        if (ast.tokens[i].text != "try" || i + 1 >= ast.mainClose
                || ast.tokens[i + 1].text != "{")
            continue;
        const open = i + 1;
        const close = ast.closeBrace.get(open, size_t.max);
        if (close == size_t.max || close + 1 >= ast.mainClose
                || ast.tokens[close + 1].text != "finally")
            continue;
        if (open < anchor && anchor < close)
            lines ~= ast.tokens[close + 1].line;
    }
    return lines;
}

private bool identifierLike(string token)
{
    return token.length > 0 && (isIdentStart(token[0])
        || (token[0] >= '0' && token[0] <= '9'));
}

private bool statementAssignsBefore(ref AstView ast, size_t amp)
{
    size_t begin = amp;
    while (begin > ast.mainOpen + 1
            && ![";", "{", "}"].canFind(ast.tokens[begin - 1].text))
        --begin;
    foreach (i; begin .. amp)
        if (ast.tokens[i].text == "=") return true;
    return false;
}

private struct AddressLocal
{
    string name;
    bool isStatic;
    size_t declarationLine;
}

private AddressLocal[] escapedAddressLocals(ref AstView ast, size_t anchor)
{
    // This deliberately recognizes only the lowered spelling `& x`. It does
    // not see `& x.f`, `cast(T) &x`, `return &x`, or addresses passed as
    // arguments; W16-M's writer-side IR check owns those escape forms.
    size_t frameOpen = size_t.max;
    size_t frameClose = size_t.max;
    foreach (i; ast.mainOpen + 1 .. anchor)
        if (i + 4 < anchor && ast.tokens[i].text == "void"
                && ast.tokens[i + 1].text == "frame"
                && ast.tokens[i + 2].text == "(")
        {
            size_t open = i + 3;
            while (open < anchor && ast.tokens[open].text != "{") ++open;
            if (open < anchor)
            {
                frameOpen = open;
                frameClose = ast.closeBrace[open];
            }
            break;
        }
    assert(frameOpen != size_t.max && frameClose != size_t.max,
        "W16-M lowered AST has no nested frame function");

    AddressLocal[string] found;
    foreach (amp; ast.mainOpen + 1 .. ast.mainClose - 1)
    {
        if (ast.tokens[amp].text != "&" || !isIdentStart(ast.tokens[amp + 1].text[0]))
            continue;
        if (amp > ast.mainOpen + 1
                && (identifierLike(ast.tokens[amp - 1].text)
                    || ["&", ")", "]"].canFind(ast.tokens[amp - 1].text)))
            continue; // Binary &, not address-of.
        if (amp + 2 < ast.mainClose && ast.tokens[amp + 2].text == ".")
            continue; // Binary `flags & Enum.member`.
        const insideFrame = frameOpen < amp && amp < frameClose;
        if (amp < anchor && !insideFrame && !statementAssignsBefore(ast, amp))
            continue; // Address consumed before main-loop installation.

        const name = ast.tokens[amp + 1].text;
        if (name in found) continue;

        size_t declaration = size_t.max;
        foreach (i; ast.mainOpen + 1 .. anchor)
            if (ast.tokens[i].text == name)
            {
                declaration = i;
                break;
            }
        if (declaration == size_t.max) continue;
        if (declaration + 1 >= anchor
                || !["=", ";", ","].canFind(ast.tokens[declaration + 1].text))
            continue; // Function/delegate name or ordinary use, not a local declaration.

        size_t declarationScope = size_t.max;
        foreach (open, close; ast.closeBrace)
            if (open < declaration && declaration < close
                    && (declarationScope == size_t.max || open > declarationScope))
                declarationScope = open;
        if (declarationScope == size_t.max
                || !(declarationScope < anchor
                    && anchor < ast.closeBrace[declarationScope]))
            continue;

        size_t statementBegin = declaration;
        while (statementBegin > ast.mainOpen + 1
                && ![";", "{", "}"].canFind(ast.tokens[statementBegin - 1].text))
            --statementBegin;
        bool isStatic;
        foreach (i; statementBegin .. declaration)
            if (ast.tokens[i].text == "static") isStatic = true;
        found[name] = AddressLocal(name, isStatic, ast.tokens[declaration].line);
    }

    auto result = found.values.array;
    import std.algorithm : sort;
    result.sort!((a, b) => a.name < b.name);
    return result;
}

private string lowerApp(string config)
{
    const scratchRoot = buildPath(tempDir(), format("vibe3d-w16-m-ast-%d-%s",
                                                    thisProcessID(), config));
    assert(scratchRoot.startsWith(tempDir()),
        format("W16-M scratch root must honor tempDir(): %s", scratchRoot));
    assert(!exists(scratchRoot),
        format("W16-M scratch path already exists: %s", scratchRoot));
    mkdir(scratchRoot);
    scope (exit) rmdirRecurse(scratchRoot);

    enum lowerScript = q"SH
set -euo pipefail
repo=$1
out=$2
config=$3
cp -a "$repo/source" "$out/source"
flags=$(dub describe --config="$config" \
  --data=import-paths,string-import-paths,versions,debug-versions)
mapfile -t files < <(find "$out/source" -name '*.d' -print | LC_ALL=C sort)
dmd -o- -vcg-ast -I"$out/source" $flags "${files[@]}"
SH";
    const run = execute(["bash", "-c", lowerScript, "w16-m-lower",
                         repoRoot, scratchRoot, config],
                        null, Config.none, size_t.max, repoRoot);
    assert(run.status == 0,
        format("W16-M %s lowered-AST compile failed (status %d):\n%s",
               config, run.status, run.output));
    const appCg = buildPath(scratchRoot, "source", "app.d.cg");
    assert(exists(appCg),
        format("W16-M %s lowered-AST compile produced no source/app.d.cg", config));
    return readText(appCg);
}

unittest
{
    // This census intentionally covers modeling and web only. WithRender has
    // a different cleanup population and is outside W16-M's permanent gate.
    foreach (config; ["modeling", "web"])
    {
        auto ast = parseAst(lowerApp(config));
        const anchor = ast.findAnchor(config);
        const finallyLines = ast.enclosingFinallyLines(anchor);
        const expectedFinally = config == "modeling" ? 27 : 0;
        assert(finallyLines.length == expectedFinally,
            format("W16-M %s cleanup census: expected %d finally blocks whose try "
                 ~ "contains the main-loop anchor, got %d; lowered-AST lines: %s",
                   config, expectedFinally, finallyLines.length, finallyLines));

        const addressLocals = ast.escapedAddressLocals(anchor);
        if (config == "modeling")
        {
            enum expectedAddressNames = 32;
            assert(addressLocals.length == expectedAddressNames,
                format("W16-M modeling address census: expected %d unique long-lived "
                     ~ "main-local names with explicit address expressions, got %d: %s",
                       expectedAddressNames, addressLocals.length, addressLocals));
            auto staticLocals = addressLocals.filter!(local => local.isStatic).array;
            assert(staticLocals.length == 0,
                format("W16-M modeling address census: expected no static locals, got %s",
                       staticLocals));
        }
        else
        {
            enum expectedAddressNames = [
                "activePanelIdx", "activeTool", "activeToolId", "evLog", "event",
                "gpu", "gpuUploadedPreview", "gridOnlyVertCount", "gridVao", "layout",
                "panels", "recLog", "reg", "running", "shortcuts", "statusLineGroups",
                "subpatchPreview", "toolHost", "winH", "winW",
            ];
            auto addressNames = addressLocals.map!(local => local.name).array;
            assert(addressNames == expectedAddressNames,
                format("W16-M web address census: expected exactly 20 long-lived "
                     ~ "addressed locals %s, got %d: %s",
                       expectedAddressNames, addressNames.length, addressNames));
            auto nonStatic = addressLocals.filter!(local => !local.isStatic).array;
            assert(nonStatic.length == 0,
                format("W16-M web address census: expected 0 non-static long-lived "
                     ~ "main locals with explicit address expressions, got %d: %s",
                       nonStatic.length, nonStatic));

            const mainTokens = ast.tokens[ast.mainOpen + 1 .. ast.mainClose];
            assert(ast.tokens.countSequence([
                    "version", "(", "Emscripten", ")", "{"]) == 1,
                "W16-M web platform census: expected version(Emscripten) exactly once");
            assert(ast.tokens.countSequence([
                    "version", "(", "WebAssembly", ")", "{",
                    "static", "assert", "(", "0", ",", ")", ";"]) == 1,
                "W16-M web platform census: the native stub must fail closed on wasm");
            assert(ast.tokens.countSequence([
                    "for", "(", ";", "!", "g_nativeMainLoopCancelled", ";", ")"]) == 1
                && ast.tokens.countSequence([
                    "g_nativeMainLoopCancelled", "=", "false", ";"]) == 1
                && ast.tokens.countSequence([
                    "g_nativeMainLoopCancelled", "=", "true", ";"]) == 1
                && ast.tokens.countSequence([
                    "(", "*", "callback", ")", "(", "arg", ")", ";"]) == 1,
                "W16-M native web-loop census: expected a resettable loop cancelled by its flag");
            assert(mainTokens.countSequence([
                    "args", "=", "array", "(", "map", "(", "args", ")", ")", ";"]) == 1,
                "W16-M web argv census: main must heap-copy every argument before parsing");
            assert(ast.tokens.countSequence([
                    "__gshared", "void", "delegate", "(", ")",
                    "g_webMainLoopFrame", ";"]) == 1,
                "W16-M web root census: the frame delegate must have exactly one "
              ~ "__gshared D-GC root");
            assert(ast.tokens.countSequence([
                    "g_webMainLoopFrame", "(", ")", ";"]) == 1,
                "W16-M web trampoline census: expected exactly one rooted delegate call");
            assert(mainTokens.countSequence([
                    "g_webMainLoopFrame", "=", "&", "frame", ";"]) == 1,
                "W16-M web install census: expected exactly one frame-to-root assignment");
            assert(mainTokens.countSequence([
                    "emscripten_set_main_loop_arg", "(", "&",
                    "webMainLoopTrampoline", ",", "null", ",", "0", ",", "1",
                    ")", ";"]) == 1,
                "W16-M web install census: main-loop registration must use the "
              ~ "trampoline, fps=0, and simulateInfiniteLoop=1");
            assert(mainTokens.countSequence([
                    "if", "(", "!", "running", ")", "{",
                    "emscripten_cancel_main_loop", "(", ")", ";"]) == 1,
                "W16-M web cancel census: expected one cancellation guarded by !running");
            assert(mainTokens.countSequence([
                    "g_webMainLoopFrame", "=", "cast", "(", "void", "delegate",
                    "(", ")", ")", "null", ";"]) == 1,
                "W16-M web cancel census: cancellation must release the D-GC root");
            assert(ast.tokens.countSequence([
                    "catch", "(", "Throwable", "error", ")", "{"]) == 1,
                "W16-M web trampoline census: expected one Throwable boundary");
            assert(ast.tokens.countSequence([
                    "makeGlobal", "(", ")", ".", "writefln", "(", ",",
                    "error", ")", ";"]) == 1,
                "W16-M web trampoline census: frame failure must be printed");
            assert(ast.tokens.countSequence([
                    "emscripten_cancel_main_loop", "(", ")", ";"]) == 3,
                "W16-M web trampoline census: expected the extern declaration plus "
              ~ "failure and normal-shutdown cancellation calls");
            assert(ast.tokens.countSequence([
                    "g_webMainLoopFrame", "=", "cast", "(", "void", "delegate",
                    "(", ")", ")", "null", ";"]) == 2,
                "W16-M web trampoline census: frame failure must release the root beside normal shutdown");
        }
    }
}
