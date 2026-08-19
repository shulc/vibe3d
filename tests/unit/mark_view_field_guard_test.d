// The `MarkView` lifetime-contract guard (task 0585, review SF-2).
//
// WHAT THE CONTRACT IS. `MarkView` (source/mesh.d) is a BORROWED slice of a
// mesh's live `vertexMarks`/`edgeMarks`/`faceMarks` array. Anything that
// changes that array's length invalidates it, which every topological
// operation does. So a `MarkView` is a one-draw-call value: it must never be
// stored where it can outlive the mutation that invalidates it.
//
// WHY A SOURCE SCAN AND NOT AN ASSERT. There is nothing to assert. The bug
// this prevents is a FIELD that exists — a stored view read on a later frame
// against a resized marks array — and by the time it is read there is no
// signal left to check: the slice still points at valid GC memory, just the
// wrong length of it, and `MarkView.opIndex` answers `false` past its end
// instead of faulting. The failure is a silently missing highlight. Also
// `-release` strips asserts, and this must hold in the shipped binary.
//
// WHY NOT A GREP. The task's first draft carried one, in `scratch/`, which is
// not in the worktree and not in the diff — a contract comment citing a check
// that no longer exists anywhere is worse than one citing nothing. And the
// grep matched a literal `MarkView x;`: blind to `MarkView[]`, to `MarkView*`,
// to a declaration wrapped in `version {}` inside the aggregate, and to the
// `auto`-typed spelling `auto v = m.selectedFaceView();`.
//
// WHAT THIS SCANNER SEES, EXACTLY:
//   * a declarator of type `MarkView` (with any of `[]`, `[N]`, `*`, and any
//     leading attributes) at AGGREGATE or MODULE scope — i.e. a field or a
//     global, not a local and not a parameter;
//   * a call to one of the `selected*View()` accessors at aggregate or module
//     scope, which is what an `auto`-typed field initializer looks like.
//
// WHAT IT DOES NOT SEE, stated so nobody mistakes it for the whole contract:
// a field reached through an `alias`, a field whose type comes from a template
// parameter, and a view captured by a closure or a nested struct that outlives
// the draw call. Those remain review matters. The guard exists so the COMMON
// spellings cannot land silently.
module tests.unit.mark_view_field_guard_test;

import std.array     : appender, join;
import std.ascii     : isAlphaNum, isWhite;
import std.file      : dirEntries, exists, isDir, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName, relativePath;
import std.string    : strip;

// ---------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------

struct Violation {
    size_t line;
    string kind;    /// "field" or "auto-field"
    string text;    /// the offending source line, trimmed
}

private enum Scope { Module, Aggregate, Block }

private bool isIdentChar(char c) { return isAlphaNum(c) || c == '_'; }

/// Does `head` -- the code between the previous statement boundary and a `{`
/// -- open an AGGREGATE body?
private bool headOpensAggregate(string head) {
    static immutable string[] kw = ["struct", "class", "union", "interface",
                                    "template"];
    foreach (k; kw) {
        for (size_t i = 0; i + k.length <= head.length; i++) {
            if (head[i .. i + k.length] != k) continue;
            if (i > 0 && isIdentChar(head[i - 1])) continue;
            size_t j = i + k.length;
            if (j < head.length && isIdentChar(head[j])) continue;
            // Must be followed by a NAME: `struct Foo`, `class Bar : Baz`.
            // `is(T == struct)` and `enum : int` do not qualify.
            while (j < head.length && isWhite(head[j])) j++;
            if (j < head.length && (isAlphaNum(head[j]) || head[j] == '_'))
                return true;
        }
    }
    return false;
}

/// Is `head` a wrapper that does NOT change the declaration scope --
/// `version (X) {`, `static if (...) {`, `else {`, `debug {`, an attribute
/// block (`private {`, `@safe {`, `extern (C) {`), or a bare `{`?
private bool headInherits(string head) {
    auto h = head.strip;
    if (h.length == 0) return true;
    static immutable string[] starts = ["version", "static if", "static foreach",
                                        "else", "debug", "extern", "align",
                                        "private", "public", "protected",
                                        "package", "synchronized", "@", "nothrow",
                                        "pure", "final", "shared static",
                                        "static ~", "static this", "immutable",
                                        "const", "scope"];
    foreach (s; starts)
        if (h.length >= s.length && h[0 .. s.length] == s) {
            // `static this() {` / `static ~this() {` are functions, but their
            // bodies inheriting Aggregate would only ADD false positives for
            // locals, so exclude them explicitly.
            if (s == "static this" || s == "static ~") return false;
            // An attribute head that ends in `)` after a name is a function
            // signature (`pure nothrow bool f()`), not a wrapper.
            if (h[$ - 1] == ')' && s != "version" && s != "static if"
                && s != "static foreach" && s != "extern" && s != "align"
                && s != "debug" && s != "synchronized")
                return false;
            return true;
        }
    return false;
}

/// Scan one D source text. Returns every aggregate/module-scope `MarkView`
/// declarator and `selected*View()` call it can see.
Violation[] scanForStoredViews(string src) {
    auto out_ = appender!(Violation[]);
    Scope[] stack;                       // innermost last; empty == Module
    string head;                         // code since the last boundary
    size_t line = 1;
    int paren = 0;

    Scope cur() { return stack.length ? stack[$ - 1] : Scope.Module; }
    bool declScope() { return cur() == Scope.Module || cur() == Scope.Aggregate; }

    size_t i = 0;
    while (i < src.length) {
        immutable char c = src[i];

        // ---- skip comments and literals (their braces are not scopes) ----
        if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
            while (i < src.length && src[i] != '\n') i++;
            continue;
        }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
                if (src[i] == '\n') line++;
                i++;
            }
            i += 2;
            continue;
        }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '+') {
            int depth = 1; i += 2;
            while (i + 1 < src.length && depth > 0) {
                if (src[i] == '/' && src[i + 1] == '+') { depth++; i += 2; continue; }
                if (src[i] == '+' && src[i + 1] == '/') { depth--; i += 2; continue; }
                if (src[i] == '\n') line++;
                i++;
            }
            continue;
        }
        if (c == '"' || c == '`' || c == '\'') {
            immutable char q = c;
            immutable bool raw = (q == '`');
            i++;
            while (i < src.length && src[i] != q) {
                if (!raw && src[i] == '\\') i++;
                if (i < src.length && src[i] == '\n') line++;
                i++;
            }
            i++;
            continue;
        }

        if (c == '\n') { line++; head ~= ' '; i++; continue; }
        if (c == '(')  { paren++; head ~= c; i++; continue; }
        if (c == ')')  { if (paren > 0) paren--; head ~= c; i++; continue; }

        if (c == '{') {
            Scope k;
            if (headOpensAggregate(head))  k = Scope.Aggregate;
            else if (headInherits(head))   k = cur();
            else                            k = Scope.Block;
            stack ~= k;
            head = "";
            i++;
            continue;
        }
        if (c == '}') {
            if (stack.length) stack = stack[0 .. $ - 1];
            head = "";
            i++;
            continue;
        }
        if (c == ';') { head = ""; i++; continue; }

        // ---- identifiers ----
        if (isAlphaNum(c) || c == '_') {
            size_t j = i;
            while (j < src.length && isIdentChar(src[j])) j++;
            immutable string word = src[i .. j];
            immutable bool boundary = (i == 0 || !isIdentChar(src[i - 1]));

            if (boundary && paren == 0 && declScope()) {
                if (word == "MarkView" && isFieldDeclarator(src, j))
                    out_ ~= Violation(line, "field", lineTextAt(src, i));
                if ((word == "selectedVertexView" || word == "selectedEdgeView"
                     || word == "selectedFaceView")
                    && !precededByMarkView(src, i))
                    out_ ~= Violation(line, "auto-field", lineTextAt(src, i));
            }
            head ~= word;
            i = j;
            continue;
        }

        head ~= c;
        i++;
    }
    return out_.data;
}

/// After the type name `MarkView` at `p`, does a DECLARATOR follow (as
/// opposed to a function declaration, a construction, or `.init`)? Accepts
/// any run of `[]`, `[N]`, `*` before the name; rejects `Name(` (a function).
private bool isFieldDeclarator(string src, size_t p) {
    size_t i = p;
    void ws() { while (i < src.length && isWhite(src[i])) i++; }
    ws();
    // Type suffixes.
    while (i < src.length && (src[i] == '*' || src[i] == '[')) {
        if (src[i] == '*') { i++; ws(); continue; }
        int d = 0;
        while (i < src.length) {
            if (src[i] == '[') d++;
            else if (src[i] == ']') { d--; if (d == 0) { i++; break; } }
            i++;
        }
        ws();
    }
    ws();
    if (i >= src.length) return false;
    if (!(isAlphaNum(src[i]) || src[i] == '_')) return false;   // `.init`, `(`, `;`, `,`
    while (i < src.length && isIdentChar(src[i])) i++;
    ws();
    if (i >= src.length) return false;
    return src[i] == ';' || src[i] == '=' || src[i] == ',';     // `(` => function
}

/// Is the identifier at `p` immediately preceded by the type name `MarkView`?
/// That is the ACCESSOR DECLARATION `MarkView selectedFaceView() const`, not a
/// call — the one shape in `mesh.d` that must not be reported.
private bool precededByMarkView(string src, size_t p) {
    size_t i = p;
    while (i > 0 && isWhite(src[i - 1])) i--;
    enum string t = "MarkView";
    if (i < t.length) return false;
    if (src[i - t.length .. i] != t) return false;
    return i == t.length || !isIdentChar(src[i - t.length - 1]);
}

private string lineTextAt(string src, size_t p) {
    size_t a = p;
    while (a > 0 && src[a - 1] != '\n') a--;
    size_t b = p;
    while (b < src.length && src[b] != '\n') b++;
    return src[a .. b].strip;
}

// ---------------------------------------------------------------------------
// Self-tests: the scanner is not allowed to be inert either.
// ---------------------------------------------------------------------------

private size_t nFound(string src) { return scanForStoredViews(src).length; }

unittest {
    // The four field spellings the contract forbids, INCLUDING the three the
    // task's original grep could not see.
    assert(nFound("struct S { MarkView v; }") == 1, "bare field");
    assert(nFound("struct S { private MarkView[] cache; }") == 1, "array field");
    assert(nFound("struct S { MarkView* p; }") == 1, "pointer field");
    assert(nFound("struct S { MarkView[3] fixed; }") == 1, "static-array field");
    assert(nFound("struct S { static MarkView x = MarkView.init; }") == 1,
           "static field with an initializer");
    assert(nFound("class C { MarkView v; }") == 1, "class field");
    assert(nFound("struct S { version (Foo) { MarkView v; } }") == 1,
           "a field wrapped in version{} is still a field");
    assert(nFound("struct S { private: MarkView v; }") == 1,
           "a field under a protection label is still a field");
    assert(nFound("MarkView g_leak;") == 1, "module-scope global");

    // The `auto`-typed spelling of the same mistake.
    assert(nFound("struct S { auto v = m.selectedFaceView(); }") == 1, "auto field");
    assert(nFound("struct S { auto v = m.selectedEdgeView(); }") == 1);
    assert(nFound("struct S { auto v = m.selectedVertexView(); }") == 1);
}

unittest {
    // Everything that is LEGAL must stay silent, or the guard gets deleted the
    // first time it cries wolf.
    assert(nFound("MarkView selectedFaceView() const { return MarkView(faceMarks, 1); }") == 0,
           "the accessor's own declaration is not a field");
    assert(nFound("struct Mesh { MarkView selectedFaceView() const "
                  ~ "{ return MarkView(faceMarks, 1); } }") == 0,
           "the accessor declared INSIDE the aggregate is not a field either");
    assert(nFound("void f(MarkView m, MarkView n) { }") == 0, "parameters");
    assert(nFound("void draw(int a, MarkView sel, bool[] h) { }") == 0,
           "a parameter followed by a comma is not a field");
    assert(nFound("void f() { MarkView local = m.selectedFaceView(); }") == 0,
           "a local inside a function body is exactly what the type is for");
    assert(nFound("struct S { void f() { MarkView local; auto v = m.selectedEdgeView(); } }") == 0,
           "a local inside a METHOD is a local, not a field");
    assert(nFound("import mesh : Surface, GpuMesh, MarkView;") == 0, "selective import");
    assert(nFound("import mesh : MarkView, Other;") == 0, "selective import, first");
    assert(nFound("auto x = MarkView.init;") == 0, "`.init` is not a declarator");
    assert(nFound("gpu.drawEdges(c, -1, MarkView.init, [], w);") == 0, "a call argument");

    // Literals and comments must not desynchronise the brace tracker, and must
    // not themselves be read as declarations.
    assert(nFound("// struct S { MarkView v; }") == 0, "line comment");
    assert(nFound("/* struct S { MarkView v; } */") == 0, "block comment");
    assert(nFound("/+ struct S { /+ nested +/ MarkView v; } +/") == 0, "nested comment");
    assert(nFound(`enum s = "struct S { MarkView v; }";`) == 0, "string literal");
    assert(nFound("enum s = `struct S { MarkView v; }`;") == 0, "backtick literal");
    assert(nFound("char c = '{'; struct S { MarkView v; }") == 1,
           "a brace inside a char literal must not eat the aggregate");
}

unittest {
    // The scanner reports WHERE, not just how many -- a guard whose message
    // does not name the line costs more to act on than it saves.
    auto v = scanForStoredViews("module a;\n\nstruct S {\n    MarkView v;\n}\n");
    assert(v.length == 1);
    assert(v[0].line == 4, format("expected line 4, got %d", v[0].line));
    assert(v[0].text == "MarkView v;", "got: " ~ v[0].text);
    assert(v[0].kind == "field");
}

// ---------------------------------------------------------------------------
// The gate itself.
// ---------------------------------------------------------------------------

private enum guardRepoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    const dir = buildPath(guardRepoRoot, "source");
    assert(exists(dir) && isDir(dir),
           "the guard cannot find source/ at " ~ dir ~ " — it is measuring "
           ~ "nothing, which is worse than being absent");

    size_t filesScanned;
    string[] found;
    foreach (entry; dirEntries(dir, SpanMode.depth)) {
        if (!entry.isFile || entry.name.length < 2
            || entry.name[$ - 2 .. $] != ".d") continue;
        filesScanned++;
        foreach (v; scanForStoredViews(readText(entry.name)))
            found ~= format("%s:%d  [%s]  %s",
                            relativePath(entry.name, guardRepoRoot),
                            v.line, v.kind, v.text);
    }

    // Non-vacuity: a walk that found no files would report a clean tree.
    assert(filesScanned > 100,
           format("only %d .d files under source/ — the walk is not reaching "
                  ~ "the tree it claims to be guarding", filesScanned));

    assert(found.length == 0,
           "a `MarkView` is being STORED, which the type's lifetime contract "
           ~ "(source/mesh.d) forbids: it is a borrowed slice of the mesh's live "
           ~ "marks array and is invalidated by any change to that array's "
           ~ "length, so it may not outlive the draw call that took it. Read "
           ~ "the marks through `Mesh.is*Selected(i)` or re-take the view at "
           ~ "use.\n  " ~ found.length.format!"%d site(s):\n  " ~ found.join("\n  "));
}
