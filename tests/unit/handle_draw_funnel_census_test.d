module tests.unit.handle_draw_funnel_census_test;

import handles.arbiter;
import handles.shapes;
import tools.transform.scale;

import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.file : dirEntries, readText, SpanMode;
import std.meta : AliasSeq;
import std.path : buildPath, dirName;
import std.regex : matchAll, matchFirst, regex;
import std.string : indexOf, split, splitLines, strip;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
                                   enclosingSymbols, symbolAt;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private alias kGatedHandleModules = AliasSeq!(
    handles.shapes, handles.arbiter, tools.transform.scale);
private immutable string[] kGatedHandlerNames = [
    "Arrow", "BoxHandler", "CenterDiskGizmo", "CircleHandler",
    "ClickPointHandler", "CubicArrow", "EngageProbeHandle",
    "FullCircleHandler", "MoveHandler", "RotateHandler", "ScaleHandler",
    "ScaleHeadHandle", "SemicircleHandler", "ShaftedArrow",
];
private immutable string[] kCensusHandlerNames = [
    "Arrow", "BoxHandler", "CenterDiskGizmo", "CircleHandler",
    "ClickPointHandler", "CubicArrow", "EngageProbeHandle",
    "FullCircleHandler", "MoveHandler", "RotateHandler", "ScaleHandler",
    "ScaleHeadHandle", "SemicircleHandler", "ShaftedArrow",
];

private bool sameSet(const(string)[] a, const(string)[] b) pure {
    return missingFrom(a, b).length == 0 && missingFrom(b, a).length == 0;
}

private string missingFrom(const(string)[] a, const(string)[] b) pure {
    string result;
    foreach (x; a) {
        if (b.canFind(x)) continue;
        result ~= (result.length ? ", " : "") ~ x;
    }
    return result;
}

private string[] gatedHandlerNames() {
    string[] result;
    static foreach (mod; kGatedHandleModules) {
        static foreach (name; __traits(allMembers, mod)) {{
            static if (__traits(compiles, __traits(getMember, mod, name))) {
                alias Member = __traits(getMember, mod, name);
                static if (is(Member : Handler) && !is(Member == Handler))
                    if (!result.canFind(name)) result ~= name;
            }
        }}
    }
    return result;
}

private string[] derivedDrawOwners() {
    string[] result;
    static foreach (mod; kGatedHandleModules) {
        static foreach (name; __traits(allMembers, mod)) {{
            static if (__traits(compiles, __traits(getMember, mod, name))) {
                alias Member = __traits(getMember, mod, name);
                static if (is(Member : Handler) && !is(Member == Handler)) {
                    static foreach (member; __traits(derivedMembers, Member))
                        static if (member == "draw")
                            if (!result.canFind(name)) result ~= name;
                }
            }
        }}
    }
    return result;
}

private enum g1Names = gatedHandlerNames();
private enum g1DrawOwners = derivedDrawOwners();
static assert(!__traits(isVirtualMethod, Handler.draw),
    "Handler.draw must stay final/non-virtual so every ordinary leaf enters "
  ~ "the task-5480 receipt scope");
static assert(sameSet(g1Names, kGatedHandlerNames) && g1DrawOwners.length == 0,
    "the compile-time handle funnel changed:\n"
  ~ "  expected handlers missing: " ~ missingFrom(kGatedHandlerNames, g1Names) ~ "\n"
  ~ "  unrecorded handlers present: " ~ missingFrom(g1Names, kGatedHandlerNames) ~ "\n"
  ~ "  handlers declaring their own draw: " ~ missingFrom(g1DrawOwners, []));

private struct ClassDecl {
    string name;
    string moduleName;
    string[] bases;
}

private string tailName(string name) {
    auto pieces = name.split(".");
    return pieces.length ? pieces[$ - 1] : name;
}

private ClassDecl[] classesIn(string moduleName, string code) {
    auto outp = appender!(ClassDecl[]);
    auto classRe = regex(`\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*`
                       ~ `(?:\:\s*([^\{]+))?\s*\{`);
    auto baseRe = regex(`[A-Za-z_][A-Za-z0-9_.]*`);
    foreach (m; code.matchAll(classRe)) {
        ClassDecl d;
        d.name = m[1];
        d.moduleName = moduleName;
        foreach (base; m[2].split(",")) {
            auto bm = base.matchFirst(baseRe);
            if (!bm.empty) d.bases ~= tailName(bm.hit);
        }
        outp.put(d);
    }
    return outp.data;
}

private struct Scan {
    ClassDecl[] classes;
    string[] handleDrawOwners;
    string[] manualReceiptOwners;
    size_t legacyOverrides;
    size_t drawImplOverrides;
    size_t directDrawImplCalls;
}

private size_t occurrences(string haystack, string needle) {
    size_t count;
    for (size_t at; (at = haystack.indexOf(needle, at)) != size_t.max;
         at += needle.length)
        ++count;
    return count;
}

private Scan scanTree() {
    Scan result;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const src = blankUnittestBodies(blankNonCode(readText(de.name)));
        auto mm = src.matchFirst(regex(`(?m)^\s*module\s+([A-Za-z0-9_.]+)\s*;`));
        const moduleName = mm.empty ? "<missing-module>" : mm[1];
        result.classes ~= classesIn(moduleName, src);

        const bool inHandles = de.name.canFind(buildPath("source", "handles"));
        if (inHandles) {
            result.legacyOverrides += occurrences(src, "override void draw(");
            result.drawImplOverrides +=
                occurrences(src, "protected override void drawImpl(");
        }
        result.directDrawImplCalls += occurrences(src, ".drawImpl(");

        const auto syms = enclosingSymbols(src);
        foreach (li, line; src.splitLines()) {
            if (line.canFind("g_fc.handleDraw("))
                result.handleDrawOwners ~= symbolAt(syms, li);
            if (moduleName != "perf_probe"
                && line.canFind("g_fc.noteHandleSubmission("))
                result.manualReceiptOwners ~= symbolAt(syms, li);
        }
    }
    return result;
}

private struct Closure {
    string[] names;
    string[] modules;
}

private Closure handlerClosure(const ClassDecl[] classes) {
    string[] reached = ["Handler"];
    Closure result;
    bool changed;
    do {
        changed = false;
        foreach (d; classes) {
            if (reached.canFind(d.name)) continue;
            bool derived;
            foreach (base; d.bases)
                if (reached.canFind(base)) { derived = true; break; }
            if (!derived) continue;
            reached ~= d.name;
            result.names ~= d.name;
            if (!result.modules.canFind(d.moduleName))
                result.modules ~= d.moduleName;
            changed = true;
        }
    } while (changed);
    return result;
}

unittest {
    auto scan = scanTree();
    auto closure = handlerClosure(scan.classes);
    static immutable string[] expectedModules = [
        "handles.arbiter", "handles.shapes", "tools.transform.scale",
    ];

    assert(scan.legacyOverrides == 0,
           "G2 r1: source/handles regained "
           ~ scan.legacyOverrides.to!string ~ " `override void draw` declaration(s)");
    assert(sameSet(closure.names, kCensusHandlerNames)
           && sameSet(closure.modules, expectedModules),
           "G2 r2 closure: names missing ["
           ~ missingFrom(kCensusHandlerNames, closure.names)
           ~ "], names unrecorded ["
           ~ missingFrom(closure.names, kCensusHandlerNames)
           ~ "], modules missing ["
           ~ missingFrom(expectedModules, closure.modules)
           ~ "], modules unrecorded ["
           ~ missingFrom(closure.modules, expectedModules) ~ "]");
    assert(scan.handleDrawOwners ==
           ["Handler.draw", "CubicArrow.drawHeadOnly"],
           "G2 r3 handleDraw owners changed: expected Handler.draw and "
           ~ "CubicArrow.drawHeadOnly exactly once each, got ["
           ~ missingFrom(scan.handleDrawOwners, []) ~ "]");
    assert(scan.manualReceiptOwners == ["CenterDiskGizmo.drawImpl"],
           "G2 r4 manual receipt owners changed: got ["
           ~ missingFrom(scan.manualReceiptOwners, []) ~ "]");
    assert(scan.drawImplOverrides == 11,
           "G2 r5 expected 11 protected drawImpl overrides, got "
           ~ scan.drawImplOverrides.to!string);
    assert(scan.directDrawImplCalls == 0,
           "G2 r5 found a direct member drawImpl call outside Handler.draw");
}
