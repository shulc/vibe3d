// Task 1520, Phase 1b — the UI tree must not reach the THROWING dispatch.
//
// WHAT THIS GUARDS. `applyOrRefire(cmd, mode, throwMsg)` with a non-null
// `throwMsg` is the script refusal policy: it throws. Inside an ImGui draw the
// throw unwinds through `_Dmain` and kills the editor — that is the whole of
// task 1520, and it was reproduced twice by hand before any code changed.
//
// Phase 1 removed the BOUND references (the panels now dispatch through
// `uiCommandDelegate`, whose refusal is a notice) and Phase 1b narrowed the
// `EditorApp.applyOrRefire` FIELD to the non-throwing shape, moving the
// throwing one to `applyOrRefireThrowing`.
//
// WHY A GATE ON TOP OF THAT. "It cannot be compiled from a panel" would be
// FALSE and the plan says so: `applyOrRefire` is a public field, `RecordMode`
// is module-level in `editor_app.d`, and the panel bodies are `with (app)` —
// so `applyOrRefireThrowing(cmd, RecordMode.Record, "boom")` compiles from
// `ui/panels.d` today. The claim the fix actually supports is "no BOUND
// reference under source/ui carries the script policy", and this file is what
// keeps it true.
//
// HOW TO FIX A FAILURE. Do not add the file to an allowlist. A UI call site
// that needs to run a command dispatches it through `uiCommandDelegate` (a
// refusal becomes a notice) or through `runCommand` (same). If you genuinely
// need the throw, you are writing script/HTTP code, which does not belong
// under `source/ui/`.

import std.file  : dirEntries, SpanMode, readText, write, mkdirRecurse,
                   rmdirRecurse, exists;
import std.path  : buildPath, extension;
import std.algorithm : canFind;
import std.conv   : to;
import std.string : indexOf, strip, startsWith;

void main() {}

struct Hit { string file; size_t line; string text; }

// A CALL, not a mention. The Phase-6 comments in `ui/panels.d` name
// `applyOrRefire` on purpose (they explain why the `scope(exit)` guards are
// still needed), so matching the bare identifier would flag prose. What is
// forbidden is an invocation: the identifier immediately followed by `(`.
private bool isCall(string line, string ident) {
    ptrdiff_t from = 0;
    while (true) {
        auto i = line[from .. $].indexOf(ident);
        if (i < 0) return false;
        const at  = from + i;
        const end = at + ident.length;
        // must not be part of a longer identifier on the left
        bool leftOk = (at == 0) || !isIdentChar(line[at - 1]);
        bool rightCall = (end < line.length) && line[end] == '(';
        if (leftOk && rightCall) return true;
        from = end;
    }
}

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

Hit[] scanFile(string path) {
    Hit[] hits;
    size_t lineNo = 0;
    foreach (line; splitLines(readText(path))) {
        lineNo++;
        auto t = line.strip;
        if (t.startsWith("//") || t.startsWith("///")) continue;
        if (isCall(line, "applyOrRefireThrowing") || isCall(line, "applyOrRefire"))
            hits ~= Hit(path, lineNo, t);
        // The throwing field must not even be NAMED under source/ui — there is
        // no legitimate reason for a draw to know it exists.
        else if (line.canFind("applyOrRefireThrowing"))
            hits ~= Hit(path, lineNo, t);
    }
    return hits;
}

private string[] splitLines(string s) {
    string[] r;
    size_t start = 0;
    foreach (i, ch; s) if (ch == '\n') { r ~= s[start .. i]; start = i + 1; }
    if (start < s.length) r ~= s[start .. $];
    return r;
}

Hit[] scanTree(string root) {
    Hit[] hits;
    foreach (e; dirEntries(root, SpanMode.depth)) {
        if (!e.isFile || e.name.extension != ".d") continue;
        hits ~= scanFile(e.name);
    }
    return hits;
}

// ---------------------------------------------------------------------------
// KNOWN-NON-ZERO SELF-TEST, first and deliberately. A scanner that matches
// nothing finds zero hits and "passes" the tree scan below while measuring
// nothing at all.
// ---------------------------------------------------------------------------
unittest {
    const dir = buildPath("/tmp", "vibe3d_ui_throw_gate_selftest");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope(exit) if (exists(dir)) rmdirRecurse(dir);

    const f = buildPath(dir, "synthetic.d");
    write(f,
        "void a(EditorApp app) {\n"                                    // 1
      ~ "    applyOrRefire(cmd, RecordMode.Record, \"boom\");\n"        // 2 HIT
      ~ "}\n"                                                          // 3
      ~ "void b(EditorApp app) {\n"                                    // 4
      ~ "    applyOrRefireThrowing(cmd, RecordMode.Record, \"x\");\n"   // 5 HIT
      ~ "}\n"                                                          // 6
      ~ "// every call below routes through `applyOrRefire`, so it throws\n" // 7 not
      ~ "void c() { uiCommandDelegate(\"image.load\", \"{}\"); }\n");   // 8 not

    auto hits = scanFile(f);
    assert(hits.length == 2,
        "self-test: the scanner must find exactly the 2 synthetic calls, found "
        ~ hits.length.to!string
        ~ " — a scanner that matches nothing would then 'pass' the tree scan");
    assert(hits[0].line == 2, "self-test: first hit is line 2, got "
        ~ hits[0].line.to!string);
    assert(hits[1].line == 5, "self-test: second hit is line 5, got "
        ~ hits[1].line.to!string);
}

unittest { // THE GATE
    auto hits = scanTree("source/ui");
    if (hits.length) {
        string msg = "source/ui must not dispatch through the THROWING command "
                   ~ "funnel — a refusal raised from inside an ImGui draw "
                   ~ "unwinds through _Dmain and kills the editor (task 1520). "
                   ~ "Offending lines:\n";
        foreach (h; hits)
            msg ~= "  " ~ h.file ~ ":" ~ h.line.to!string ~ "  " ~ h.text ~ "\n";
        assert(false, msg);
    }
}
