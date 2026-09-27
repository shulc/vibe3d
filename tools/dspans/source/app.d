/**
 * dspans -- print the spans a source census slices D code by, as JSON, from
 * libdparse's lexer and parser instead of a hand-written brace counter.
 *
 * Task 5330 (step 1 of the card's plan). This tool REPORTS spans; it does not
 * decide anything. Its first consumer is `tools/dspans/compare.py`, which
 * replays the prepared-protocol census and compares every span that census
 * cut with its own primitives against the spans printed here.
 *
 * Usage:
 *   dspans [--units=codepoints|bytes] [--lex-only] FILE...
 *   dspans [--units=...] [--lex-only] --list LISTFILE     (one path per line)
 *
 * UNITS. Every span is HALF-OPEN [start, end). The default unit is the
 * Unicode CODE POINT, because the consumer is Python and a Python `str` is
 * indexed by code point: in this tree 458 of 577 `source/**.d` files carry
 * non-ASCII text (mostly in comments), so a byte offset would land past the
 * character it names in every one of them after the first non-ASCII byte.
 * `--units=bytes` prints raw UTF-8 byte offsets instead (what a D consumer
 * slicing a `string` wants). A file that contains `\r` is reported with
 * `"crlf": true`: Python's `read_text()` translates newlines and its offsets
 * would no longer be either unit, so the consumer must refuse such a file
 * rather than compare it. A UTF-8 byte-order mark is skipped by the lexer; it
 * is reported as `"bom": true` and offsets still count from the file's first
 * byte.
 *
 * OUTPUT, per file:
 *   comments      [[s,e]...]            every comment token, nested `/+ +/` whole
 *   strings       [[s,e,kind]...]       every string / character literal token,
 *                                       kind = the literal's token type
 *   braces        [[open,close]...]     paired `{` `}` TOKENS: `close` is the
 *                                       offset OF the `}` (so the body text is
 *                                       [open+1, close) and a brace-balancer
 *                                       returning "offset after `}`" returns
 *                                       close+1)
 *   parens        [[open,close]...]     the same for `(` `)`
 *   unmatched     [offset...]           unpaired brace/paren tokens
 *   aggregates    [{kind,name,span,declStart,body,parent}]
 *                 span = keyword .. end of the declaration; declStart = start
 *                 of the enclosing Declaration, i.e. INCLUDING leading
 *                 attributes (`private final class` starts at `private`);
 *                 body = [`{`, `}`+1] or null for a forward declaration
 *                 (or for a body the error-recovering parser left without a
 *                 closing brace: a body is printed only when it closed)
 *   functions     [{name,aggregate,attrs,declStart,span,body}]  functions, methods,
 *                 constructors (`this`), destructors (`~this`), postblits,
 *                 static constructors; `aggregate` = innermost enclosing
 *                 aggregate name or null; attrs = keyword attributes of the
 *                 innermost Declaration (`private`, `static`, ...), NOT an
 *                 enclosing `private:` / `private { }`; body = the block statement
 *                 [`{`, `}`+1], or null for `=>` / declaration-only
 *   unittests     [{span,declStart,body}]  `unittest` blocks (span starts at
 *                 the keyword, declStart at its attributes)
 *   versionUnittest [{span,trueBody}]  `version(unittest)` conditional
 *                 declarations AND statements; trueBody is the braced true
 *                 branch or null for `version(unittest):` / a single
 *                 declaration
 *   lexErrors     [string...]          lexer diagnostics (an unterminated string
 *                 or comment; a literal the lexer gave up on is NOT in
 *                 `strings`, so a consumer must refuse a text with lexErrors
 *                 rather than trust its masks)
 *   parseErrors   [string...]          parser diagnostics (a fragment that is
 *                 not a module still lexes; its parse-level lists are then
 *                 whatever the error-recovering parser produced)
 */
module app;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import std.algorithm : canFind;
import std.array : appender, Appender;
import std.conv : to;
import std.file : read, readText;
import std.format : formattedWrite;
import std.stdio : File, stderr, stdout;
import std.string : lineSplitter, strip;

enum Units { codepoints, bytes }

/// Byte -> output-unit translation for one file.
struct OffsetMap
{
    uint[] cp;   // cp[b] = number of code points in src[0 .. b]; empty = identity

    this(const(ubyte)[] src, Units units)
    {
        if (units == Units.bytes) return;
        bool ascii = true;
        foreach (b; src) if (b >= 0x80) { ascii = false; break; }
        if (ascii) return;
        cp = new uint[src.length + 1];
        uint n = 0;
        foreach (i, b; src)
        {
            cp[i] = n;
            if ((b & 0xC0) != 0x80) ++n;
        }
        cp[src.length] = n;
    }

    size_t opCall(size_t byteOffset) const
    {
        return cp.length ? cp[byteOffset] : byteOffset;
    }
}

size_t tokenEnd(const ref Token t)
{
    return t.index + (t.text.length ? t.text.length : str(t.type).length);
}

/// The lexer runs a `/*` or `/+` comment to end of file without an error
/// when it never closes; report it, since a mask built from such a span
/// blanks the rest of the file.
bool commentCloses(const(char)[] c)
{
    if (c.length >= 2 && c[0 .. 2] == "/*")
        return c.length >= 4 && c[$ - 2 .. $] == "*/";
    if (c.length >= 2 && c[0 .. 2] == "/+")
    {
        size_t depth;
        for (size_t i = 0; i + 1 < c.length; ++i)
        {
            if (c[i] == '/' && c[i + 1] == '+') { ++depth; ++i; }
            else if (c[i] == '+' && c[i + 1] == '/') { if (--depth == 0) return i + 2 == c.length; ++i; }
        }
        return false;
    }
    return true;
}

bool isStringToken(IdType type)
{
    return type == tok!"stringLiteral" || type == tok!"wstringLiteral"
        || type == tok!"dstringLiteral" || type == tok!"characterLiteral";
}

struct Span { size_t s, e; }

struct Aggregate
{
    string kind, name, parent;
    Span span;
    size_t declStart;
    bool hasBody;
    Span body;
}

struct Function
{
    string name, aggregate;
    string[] attrs;
    size_t declStart;
    Span span;
    bool hasBody;
    Span body;
}

struct UnitTest { Span span; size_t declStart; Span body; }
struct VersionUnittest { Span span; bool hasTrueBody; Span trueBody; }

Span nodeSpan(const BaseNode n)
{
    return Span(n.tokens[0].index, tokenEnd(n.tokens[$ - 1]));
}

final class Collector : ASTVisitor
{
    alias visit = ASTVisitor.visit;

    Aggregate[] aggregates;
    Function[] functions;
    UnitTest[] unittests;
    VersionUnittest[] versionUnittests;
    const(size_t[size_t])* bracePairs;   // byte index of `{` -> byte index of `}`

    private size_t[] declStarts;
    private string[][] declAttrs;
    private string[] aggStack;

    this(const(size_t[size_t])* pairs) { bracePairs = pairs; }

    /// A body is printed only when the LEXER pairs its braces the same way:
    /// the error-recovering parser can close a body the token stream never
    /// closed (`class A { void f( { ... }` gives A a body from recovery).
    private bool paired(size_t open, size_t close) const
    {
        if (bracePairs is null) return false;
        auto c = open in *bracePairs;
        return c !is null && *c == close;
    }

    private size_t currentDeclStart(size_t fallback) const
    {
        return declStarts.length ? declStarts[$ - 1] : fallback;
    }

    override void visit(const Declaration d)
    {
        if (d.tokens.length) declStarts ~= d.tokens[0].index;
        else declStarts ~= size_t.max;
        string[] attrs;
        foreach (a; d.attributes)
            if (a !is null && a.attribute.type != tok!"")
                attrs ~= str(a.attribute.type);
        declAttrs ~= attrs;
        scope (exit)
        {
            declStarts = declStarts[0 .. $ - 1];
            declAttrs = declAttrs[0 .. $ - 1];
        }
        super.visit(d);
    }

    private void aggregate(N)(const N n, string kind, const StructBody sb)
    {
        if (!n.tokens.length) { super.visit(n); return; }
        auto sp = nodeSpan(n);
        size_t ds = currentDeclStart(sp.s);
        if (ds == size_t.max || ds > sp.s) ds = sp.s;
        Aggregate a;
        a.kind = kind;
        a.name = n.name.text.idup;
        a.parent = aggStack.length ? aggStack[$ - 1] : null;
        a.span = sp;
        a.declStart = ds;
        if (sb !is null && paired(sb.startLocation, sb.endLocation))
        {
            a.hasBody = true;
            a.body = Span(sb.startLocation, sb.endLocation + 1);
        }
        aggregates ~= a;
        aggStack ~= a.name;
        scope (exit) aggStack = aggStack[0 .. $ - 1];
        super.visit(n);
    }

    override void visit(const ClassDeclaration n) { aggregate(n, "class", n.structBody); }
    override void visit(const StructDeclaration n) { aggregate(n, "struct", n.structBody); }
    override void visit(const InterfaceDeclaration n) { aggregate(n, "interface", n.structBody); }
    override void visit(const UnionDeclaration n) { aggregate(n, "union", n.structBody); }

    override void visit(const TemplateDeclaration n)
    {
        if (!n.tokens.length) { super.visit(n); return; }
        auto sp = nodeSpan(n);
        size_t ds = currentDeclStart(sp.s);
        if (ds == size_t.max || ds > sp.s) ds = sp.s;
        Aggregate a;
        a.kind = "template";
        a.name = n.name.text.idup;
        a.parent = aggStack.length ? aggStack[$ - 1] : null;
        a.span = sp;
        a.declStart = ds;
        // The template body is the last `{ ... }` of the node.
        if (n.tokens[$ - 1].type == tok!"}")
        {
            const close = n.tokens[$ - 1].index;
            foreach (open, c; *bracePairs)
                if (c == close) { a.hasBody = true; a.body = Span(open, close + 1); break; }
        }
        aggregates ~= a;
        aggStack ~= a.name;
        scope (exit) aggStack = aggStack[0 .. $ - 1];
        super.visit(n);
    }

    private void function_(N)(const N n, string name, const FunctionBody fb)
    {
        if (!n.tokens.length) { super.visit(n); return; }
        Function f;
        f.name = name;
        f.aggregate = aggStack.length ? aggStack[$ - 1] : null;
        f.span = nodeSpan(n);
        size_t ds = currentDeclStart(f.span.s);
        if (ds == size_t.max || ds > f.span.s) ds = f.span.s;
        f.declStart = ds;
        f.attrs = declAttrs.length ? declAttrs[$ - 1] : null;
        if (fb !is null && fb.specifiedFunctionBody !is null
            && fb.specifiedFunctionBody.blockStatement !is null
            && paired(fb.specifiedFunctionBody.blockStatement.startLocation,
                fb.specifiedFunctionBody.blockStatement.endLocation))
        {
            const bs = fb.specifiedFunctionBody.blockStatement;
            f.hasBody = true;
            f.body = Span(bs.startLocation, bs.endLocation + 1);
        }
        functions ~= f;
        super.visit(n);
    }

    override void visit(const FunctionDeclaration n) { function_(n, n.name.text.idup, n.functionBody); }
    override void visit(const Constructor n) { function_(n, "this", n.functionBody); }
    override void visit(const Destructor n) { function_(n, "~this", n.functionBody); }
    override void visit(const Postblit n) { function_(n, "this(this)", n.functionBody); }
    override void visit(const StaticConstructor n) { function_(n, "static this", n.functionBody); }
    override void visit(const StaticDestructor n) { function_(n, "static ~this", n.functionBody); }
    override void visit(const SharedStaticConstructor n) { function_(n, "shared static this", n.functionBody); }
    override void visit(const SharedStaticDestructor n) { function_(n, "shared static ~this", n.functionBody); }

    override void visit(const Unittest n)
    {
        if (n.tokens.length && n.blockStatement !is null
            && paired(n.blockStatement.startLocation, n.blockStatement.endLocation))
        {
            auto sp = nodeSpan(n);
            size_t ds = currentDeclStart(sp.s);
            if (ds == size_t.max || ds > sp.s) ds = sp.s;
            unittests ~= UnitTest(sp, ds, Span(n.blockStatement.startLocation,
                n.blockStatement.endLocation + 1));
        }
        super.visit(n);
    }

    private void versionBlock(const BaseNode n, const CompileCondition cc)
    {
        if (!n.tokens.length || cc is null || cc.versionCondition is null
            || cc.versionCondition.token.type != tok!"unittest" || !cc.tokens.length)
            return;
        VersionUnittest v;
        v.span = nodeSpan(n);
        const condEnd = tokenEnd(cc.tokens[$ - 1]);
        foreach (i, t; n.tokens)
        {
            if (t.index < condEnd) continue;
            if (t.type == tok!"{")
            {
                if (auto close = t.index in *bracePairs)
                {
                    v.hasTrueBody = true;
                    v.trueBody = Span(t.index, *close + 1);
                }
            }
            break;
        }
        versionUnittests ~= v;
    }

    override void visit(const ConditionalDeclaration n)
    {
        versionBlock(n, n.compileCondition);
        super.visit(n);
    }

    override void visit(const ConditionalStatement n)
    {
        versionBlock(n, n.compileCondition);
        super.visit(n);
    }
}

void writeJsonString(ref Appender!string o, const(char)[] s)
{
    o.put('"');
    foreach (dchar c; s)
    {
        switch (c)
        {
            case '"': o.put(`\"`); break;
            case '\\': o.put(`\\`); break;
            case '\n': o.put(`\n`); break;
            case '\r': o.put(`\r`); break;
            case '\t': o.put(`\t`); break;
            default:
                if (c < 0x20) o.formattedWrite!`\u%04x`(cast(uint) c);
                else o.put(c);
        }
    }
    o.put('"');
}

void writeSpan(ref Appender!string o, Span s, const ref OffsetMap m)
{
    o.formattedWrite!"[%d,%d]"(m(s.s), m(s.e));
}

void writeNullableSpan(ref Appender!string o, bool has, Span s, const ref OffsetMap m)
{
    if (has) writeSpan(o, s, m); else o.put("null");
}

void writeNullableString(ref Appender!string o, string s)
{
    if (s is null) o.put("null"); else writeJsonString(o, s);
}

void processFile(ref Appender!string o, string path, Units units, bool lexOnly,
    ref StringCache cache)
{
    const(ubyte)[] src = cast(const(ubyte)[]) read(path);
    const bom = src.length >= 3 && src[0] == 0xef && src[1] == 0xbb && src[2] == 0xbf;
    const crlf = (cast(const(char)[]) src).canFind('\r');
    auto m = OffsetMap(src, units);

    Span[] comments;
    string[] lexErrors;
    Span[] strings;
    string[] stringKinds;
    size_t[size_t] bracePairs;
    Span[] braces, parens;
    size_t[] unmatched;
    {
        LexerConfig config;
        config.fileName = path;
        config.whitespaceBehavior = WhitespaceBehavior.include;
        config.commentBehavior = CommentBehavior.noIntern;
        size_t[] braceStack, parenStack;
        auto lexer = DLexer(src, config, &cache);
        for (; !lexer.empty; lexer.popFront())
        {
            const t = lexer.front;
            if (t.type == tok!"comment")
            {
                comments ~= Span(t.index, tokenEnd(t));
                if (!commentCloses(t.text))
                    lexErrors ~= to!string(t.line) ~ ":" ~ to!string(t.column)
                        ~ ": unterminated comment (runs to end of file)";
            }
            else if (isStringToken(t.type))
            {
                strings ~= Span(t.index, tokenEnd(t));
                stringKinds ~= str(t.type);
            }
            else if (t.type == tok!"{") braceStack ~= t.index;
            else if (t.type == tok!"(") parenStack ~= t.index;
            else if (t.type == tok!"}")
            {
                if (braceStack.length)
                {
                    braces ~= Span(braceStack[$ - 1], t.index);
                    bracePairs[braceStack[$ - 1]] = t.index;
                    braceStack = braceStack[0 .. $ - 1];
                }
                else unmatched ~= t.index;
            }
            else if (t.type == tok!")")
            {
                if (parenStack.length)
                {
                    parens ~= Span(parenStack[$ - 1], t.index);
                    parenStack = parenStack[0 .. $ - 1];
                }
                else unmatched ~= t.index;
            }
        }
        unmatched ~= braceStack;
        unmatched ~= parenStack;
        foreach (msg; lexer.messages)
            if (msg.isError)
                lexErrors ~= to!string(msg.line) ~ ":" ~ to!string(msg.column) ~ ": " ~ msg.message;
    }

    string[] errors;
    auto collector = new Collector(cast(const(size_t[size_t])*) null);
    if (!lexOnly)
    {
        LexerConfig config;
        config.fileName = path;
        auto tokens = getTokensForParser(src, config, &cache);
        RollbackAllocator rba;
        void onMessage(string file, size_t line, size_t column, string message, bool isError)
        {
            if (isError)
                errors ~= to!string(line) ~ ":" ~ to!string(column) ~ ": " ~ message;
        }
        auto mod = parseModule(tokens, path, &rba, &onMessage);
        auto pairsForCollector = bracePairs;
        collector = new Collector(cast(const(size_t[size_t])*) &pairsForCollector);
        collector.visit(mod);
    }

    o.put(`{"path":`);
    writeJsonString(o, path);
    o.formattedWrite!`,"units":"%s","size":%d,"bom":%s,"crlf":%s`(
        units == Units.bytes ? "bytes" : "codepoints", m(src.length), bom, crlf);

    o.put(`,"comments":[`);
    foreach (i, c; comments) { if (i) o.put(','); writeSpan(o, c, m); }
    o.put(`],"strings":[`);
    foreach (i, s; strings)
    {
        if (i) o.put(',');
        o.formattedWrite!`[%d,%d,"%s"]`(m(s.s), m(s.e), stringKinds[i]);
    }
    o.put(`],"braces":[`);
    foreach (i, b; braces) { if (i) o.put(','); writeSpan(o, b, m); }
    o.put(`],"parens":[`);
    foreach (i, b; parens) { if (i) o.put(','); writeSpan(o, b, m); }
    o.put(`],"unmatched":[`);
    foreach (i, u; unmatched) { if (i) o.put(','); o.formattedWrite!"%d"(m(u)); }
    o.put(`],"aggregates":[`);
    foreach (i, a; collector.aggregates)
    {
        if (i) o.put(',');
        o.put(`{"kind":`); writeJsonString(o, a.kind);
        o.put(`,"name":`); writeJsonString(o, a.name);
        o.put(`,"parent":`); writeNullableString(o, a.parent);
        o.put(`,"span":`); writeSpan(o, a.span, m);
        o.formattedWrite!`,"declStart":%d`(m(a.declStart));
        o.put(`,"body":`); writeNullableSpan(o, a.hasBody, a.body, m);
        o.put('}');
    }
    o.put(`],"functions":[`);
    foreach (i, f; collector.functions)
    {
        if (i) o.put(',');
        o.put(`{"name":`); writeJsonString(o, f.name);
        o.put(`,"aggregate":`); writeNullableString(o, f.aggregate);
        o.put(`,"attrs":[`);
        foreach (j, at; f.attrs) { if (j) o.put(','); writeJsonString(o, at); }
        o.put(']');
        o.formattedWrite!`,"declStart":%d`(m(f.declStart));
        o.put(`,"span":`); writeSpan(o, f.span, m);
        o.put(`,"body":`); writeNullableSpan(o, f.hasBody, f.body, m);
        o.put('}');
    }
    o.put(`],"unittests":[`);
    foreach (i, u; collector.unittests)
    {
        if (i) o.put(',');
        o.put(`{"span":`); writeSpan(o, u.span, m);
        o.formattedWrite!`,"declStart":%d`(m(u.declStart));
        o.put(`,"body":`); writeSpan(o, u.body, m);
        o.put('}');
    }
    o.put(`],"versionUnittest":[`);
    foreach (i, v; collector.versionUnittests)
    {
        if (i) o.put(',');
        o.put(`{"span":`); writeSpan(o, v.span, m);
        o.put(`,"trueBody":`); writeNullableSpan(o, v.hasTrueBody, v.trueBody, m);
        o.put('}');
    }
    o.put(`],"lexErrors":[`);
    foreach (i, e; lexErrors) { if (i) o.put(','); writeJsonString(o, e); }
    o.put(`],"parseErrors":[`);
    foreach (i, e; errors) { if (i) o.put(','); writeJsonString(o, e); }
    o.put("]}");
}

int main(string[] args)
{
    Units units = Units.codepoints;
    bool lexOnly;
    string[] files;
    for (size_t i = 1; i < args.length; ++i)
    {
        const a = args[i];
        if (a == "--units=bytes") units = Units.bytes;
        else if (a == "--units=codepoints") units = Units.codepoints;
        else if (a == "--lex-only") lexOnly = true;
        else if (a == "--list" && i + 1 < args.length)
        {
            foreach (line; readText(args[++i]).lineSplitter)
                if (line.strip.length) files ~= line.strip.idup;
        }
        else if (a.length > 1 && a[0] == '-')
        {
            stderr.writeln("dspans: unknown option ", a);
            return 2;
        }
        else files ~= a;
    }
    if (!files.length)
    {
        stderr.writeln("usage: dspans [--units=codepoints|bytes] [--lex-only] "
            ~ "(FILE... | --list LISTFILE)");
        return 2;
    }
    auto cache = StringCache(StringCache.defaultBucketCount);
    auto o = appender!string;
    o.put(`{"tool":"dspans","schema":1,"files":[`);
    foreach (i, f; files)
    {
        if (i) o.put(",\n");
        processFile(o, f, units, lexOnly, cache);
    }
    o.put("]}\n");
    stdout.rawWrite(o.data);
    return 0;
}
