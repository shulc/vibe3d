// One gizmo hit test and the small handle duplicates (task 9409).
//
// A bank lists its parts once (`handleParts`, hit priority); the arbiter
// registration and the bank's own press / hover test both read it through the
// one winner rule `firstHitPart`. The deleted copies stay deleted: the per-tool
// axis loops, Mirror's private loop with its own pick literal, the second
// `enum DragBank`, the second Ctrl wait-gate literal and the unused mouse
// virtuals of the `Handler` base. Polarity: every needle below is RED on the
// pre-slice tree (9 code `hitTestAxes` tokens, 2 `enum DragBank`, a `< 25` gate
// in move.d and slice_tool.d) and green after.
module tests.unit.handle_hit_census_test;

import std.algorithm : canFind, sort;
import std.array : array;
import std.file : dirEntries, readText, SpanMode;
import std.regex : matchAll, regex;
import tests.unit.census_symbols : blankNonCode, isIdentChar, countOccurrences;

import handler : Handler, HandlePart, firstHitPart, BoxHandler;
import math : Vec3, Viewport, lookAt, orthographicMatrix;
import drag : ctrlLockPending, kCtrlLockWaitPx;
import tools.transform.move : MoveTool;
import tools.transform.scale : ScaleTool;
import tools.transform.rotate : RotateTool;
import tools.transform.xfrm_transform : XfrmTransformTool;
import tools.transform.xfrm_handles : DragBank;
import tools.edit.edge_extend : EdgeExtendTool;
import tools.alignment.mirror : MirrorTool;

// 1. The fence, compiled: composition pins (allMembers sees private members).
static assert(![__traits(allMembers, MoveTool)].canFind("hitTestAxes"));
static assert(![__traits(allMembers, ScaleTool)].canFind("hitTestAxes"));
static assert(![__traits(allMembers, RotateTool)].canFind("hitTestAxes"));
static assert(![__traits(allMembers, RotateTool)].canFind("registerPrincipalHandles"));
static assert(![__traits(allMembers, MoveTool)].canFind("registerAxisHandles"));
static assert(![__traits(allMembers, ScaleTool)].canFind("registerAxisHandles"));
static assert(![__traits(allMembers, MirrorTool)].canFind("moverHitTest"));
static assert(![__traits(allMembers, XfrmTransformTool)].canFind("DragBank"));
static assert(![__traits(allMembers, EdgeExtendTool)].canFind("DragBank"));
static assert([__traits(allMembers, DragBank)] == ["None", "Move", "Rotate", "Scale"]);
static assert(![__traits(allMembers, Handler)].canFind("onMouseButtonDown"));
static assert(![__traits(allMembers, Handler)].canFind("onMouseButtonUp"));
static assert(![__traits(allMembers, Handler)].canFind("onMouseMotion"));
// Positive control for the negations above: the same trait sees the new list.
static assert([__traits(allMembers, MoveTool)].canFind("handleParts"));
static assert([__traits(allMembers, Handler)].canFind("onKeyDown"));

private size_t countWord(string code, string word) {
    size_t n, i;
    while (true) {
        import std.string : indexOf;
        auto k = code[i .. $].indexOf(word);
        if (k < 0) return n;
        size_t a = i + k, b = a + word.length;
        if ((a == 0 || !isIdentChar(code[a - 1])) && (b >= code.length || !isIdentChar(code[b]))) ++n;
        i = b;
    }
}

unittest {
    string[] files;
    foreach (e; dirEntries("source", "*.d", SpanMode.depth)) files ~= e.name;
    string[string] code;
    foreach (f; files) code[f] = blankNonCode(readText(f));
    // Population floor: the walk saw the anchor modules at all.
    foreach (f; ["source/tools/transform/move.d", "source/drag.d", "source/tools/alignment/mirror.d",
                 "source/tools/slice/slice_tool.d", "source/tools/transform/xfrm_handles.d"])
        assert(f in code, "census walk missed " ~ f);

    // 2. Needle: the per-tool loops. Every spelling of the identifier, incl. `&hitTestAxes`.
    string[] users, legacy;
    size_t enumBanks;
    foreach (f, c; code) {
        if (countWord(c, "firstHitPart")) users ~= f;
        if (countWord(c, "hitTestAxes")) legacy ~= f;
        enumBanks += matchAll(c, regex(`\benum\s+DragBank\b`)).array.length;
    }
    // 3. Structural: the call-site roster of the one rule (polarity: equality).
    users.sort();
    assert(users == ["source/handles/shapes.d", "source/tools/alignment/mirror.d",
                     "source/tools/transform/move.d", "source/tools/transform/rotate.d",
                     "source/tools/transform/scale.d"], "firstHitPart roster drifted");
    assert(legacy.length == 0, "a per-tool hitTestAxes copy is back");
    assert(enumBanks == 1 && countWord(code["source/tools/transform/xfrm_handles.d"], "DragBank") >= 1,
        "enum DragBank must be declared once, in xfrm_handles.d");

    // Mirror: its private loop and its own pick literal are gone.
    auto mirror = code["source/tools/alignment/mirror.d"];
    assert(countWord(mirror, "moverHitTest") == 0 && countOccurrences(mirror, "8.0f") == 0);
    // Its press order is the tool's own DATA (rotate box before the centre box,
    // the reverse of its arbiter registration) until the hit-order capture.
    assert(countOccurrences(mirror, "[HandlePart(rotateBox, 4), HandlePart(mover.centerBox, 3)]") == 1,
        "Mirror press order changed without the hit-order capture");

    // The Ctrl wait gate: one home. `<` not preceded by `<` (so `1 << 25` is
    // not a gate) and 25 as a whole number (so `< 250` is not either).
    foreach (f, c; code) {
        if (f == "source/drag.d") continue;
        assert(matchAll(c, regex(`[^<]<\s*25(?![0-9.])`)).empty, "a literal Ctrl gate in " ~ f);
    }
    assert(countWord(code["source/tools/transform/move.d"], "ctrlLockPending") == 1);
    assert(countWord(code["source/tools/slice/slice_tool.d"], "ctrlLockPending") == 2); // import + call
}

unittest {
    // The wait gate's radius, as a disc (inside = pending), both sides of the rim.
    static assert(kCtrlLockWaitPx == 5);
    assert(ctrlLockPending(0, 0) && ctrlLockPending(4, 2) && ctrlLockPending(-3, -3));
    assert(!ctrlLockPending(5, 0) && !ctrlLockPending(3, 4) && !ctrlLockPending(0, -5));
}

unittest {
    // The winner rule: list order decides an overlap, an invisible part is skipped.
    immutable eye = Vec3(0, 0, 5);
    Viewport vp = Viewport(lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0)),
                           orthographicMatrix(1.0f, 1.0f, 0.01f, 100.0f), 200, 200, 0, 0, eye);
    auto a = new BoxHandler(Vec3(0, 0, 0), Vec3(1, 0, 0));
    auto b = new BoxHandler(Vec3(0, 0, 0), Vec3(0, 1, 0));
    a.size = b.size = 0.1f;
    assert(firstHitPart(100, 100, vp, [HandlePart(a, 7), HandlePart(b, 9)]) == 7);
    assert(firstHitPart(100, 100, vp, [HandlePart(b, 9), HandlePart(a, 7)]) == 9);
    a.setVisible(false);
    assert(firstHitPart(100, 100, vp, [HandlePart(a, 7), HandlePart(b, 9)]) == 9);
    assert(firstHitPart(0, 0, vp, [HandlePart(a, 7), HandlePart(b, 9)]) == -1);
}
