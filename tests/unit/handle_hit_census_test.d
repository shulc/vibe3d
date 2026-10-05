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
import drag : ctrlLockPending, kCtrlLockWaitPx, screenAxisFraction;
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

unittest {
    // The unitless axis projection: the pixel drag over the projected segment,
    // and its two refusals (an end that does not project, a sub-pixel segment).
    immutable eye = Vec3(0, 0, 5);
    Viewport vp = Viewport(lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0)),
                           orthographicMatrix(1.0f, 1.0f, 0.01f, 100.0f), 200, 200, 0, 0, eye);
    bool skip;
    // 0.5 world = 50 px to the right: 25 px right of a 50 px segment = 0.5.
    assert(screenAxisFraction(25, 7, Vec3(0, 0, 0), Vec3(0.5f, 0, 0), vp, skip) == 0.5f && !skip);
    assert(screenAxisFraction(25, 7, Vec3(0, 0, 0), Vec3(0.005f, 0, 0), vp, skip) == 0 && skip,
        "a sub-pixel segment must refuse");
    assert(screenAxisFraction(25, 7, Vec3(0, 0, 0), Vec3(0, 0, 0), vp, skip) == 0 && skip);
}

// The transform gizmo's overlap law (capture K-HO): of two parts within the
// pick reach of a press, the one NEAREST ON SCREEN is grabbed, whatever their
// registration order or depth. Each cell finds, in our own gizmo, a press
// <= 0.5 px from part A and 3.5..4.5 px from part B (the fixture's margins),
// registers the parts in the production order, and asks the arbiter.
private bool findPress(Handler a, Handler b, const ref Viewport vp, out int px, out int py) {
    foreach (y; 100 .. 700) foreach (x; 340 .. 940) {
        if (!a.isVisible() || !b.isVisible() || !a.hitTest(x, y, vp) || !b.hitTest(x, y, vp)) continue;
        immutable da = a.aiScreenDistance(x, y, vp), db = b.aiScreenDistance(x, y, vp);
        if (da <= 0.5f && db >= 3.5f && db <= 4.5f) { px = x; py = y; return true; }
    }
    return false;
}

unittest {
    import std.math : sqrt;
    import mesh : Mesh, makeCube;
    import mesh_gpu : GpuMesh;
    import editmode : EditMode;
    import view : View;
    import math : Orientation, cross, dot, projectToWindowFull;
    import handler : ToolHandles, HitRule;
    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto mv = new MoveTool(() => &mesh, &gpu, &mode);
    auto sc = new ScaleTool(() => &mesh, &gpu, &mode);
    auto rt = new RotateTool(() => &mesh, &gpu, &mode);
    Viewport camera(Vec3 back) {
        auto v = new View(0, 0, 1280, 800);
        Vec3 b = back * (1.0f / sqrt(dot(back, back)));
        Vec3 r = cross(Vec3(0, 1, 0), b); r = r * (1.0f / sqrt(dot(r, r)));
        v.setOrientation(Orientation.fromBasis(r, cross(b, r), b));
        v.distance = 3.0f;
        Viewport vp = v.viewport();
        mv.setWrapperGizmoPose(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));
        sc.setWrapperGizmoPose(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));
        rt.setWrapperGizmoPose(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));
        mv.handler.syncGeometry(vp); sc.handler.syncGeometry(vp); rt.handler.syncGeometry(vp);
        return vp;
    }
    // One press: `near` must win under the production rule; `firstWins` is
    // the part the old first-registered rule answered (the flip control).
    int cells;
    void press(string name, Viewport vp, Handler near, int nearPart, Handler far,
               void delegate(ToolHandles) register, int firstWins) {
        int x, y;
        assert(findPress(near, far, vp, x, y), "rig: no qualifying press for " ~ name);
        auto th = new ToolHandles;
        th.begin(); register(th);
        th.rule = HitRule.nearestOnScreen;
        assert(th.test(x, y, vp) == nearPart, name ~ ": the press nearer on screen must win");
        th.rule = HitRule.firstRegistered;
        assert(th.test(x, y, vp) == firstWins, name ~ ": rig, first-registered control");
        ++cells;
    }
    immutable Vec3 xFront = Vec3(1, 0.063f, -1), zFront = Vec3(-1, 0.063f, 1);
    void moveBank(ToolHandles th) { mv.registerHandles(th, 0); }
    void scaleBank(ToolHandles th) { sc.registerHandles(th, 20); }
    void rotBank(ToolHandles th) { rt.registerHandles(th, 10); }
    void unified(ToolHandles th) { mv.registerHandles(th, 0); rt.registerHandles(th, 10); }
    auto vp = camera(xFront);
    press("M_Xf_onZ", vp, mv.handler.arrowZ, 2, mv.handler.arrowX, &moveBank, 0);
    press("M_Xf_onX", vp, mv.handler.arrowX, 0, mv.handler.arrowZ, &moveBank, 0);
    press("S_Xf_onZ", vp, sc.handler.arrowZ, 22, sc.handler.arrowX, &scaleBank, 20);
    press("S_Xf_onX", vp, sc.handler.arrowX, 20, sc.handler.arrowZ, &scaleBank, 20);
    vp = camera(zFront);
    press("M_Zf_onZ", vp, mv.handler.arrowZ, 2, mv.handler.arrowX, &moveBank, 0);
    press("M_Zf_onX", vp, mv.handler.arrowX, 0, mv.handler.arrowZ, &moveBank, 0);
    press("S_Zf_onZ", vp, sc.handler.arrowZ, 22, sc.handler.arrowX, &scaleBank, 20);
    press("S_Zf_onX", vp, sc.handler.arrowX, 20, sc.handler.arrowZ, &scaleBank, 20);
    vp = camera(Vec3(0.3f, 0.25f, 1));
    press("R_Zp_onY", vp, rt.handler.arcY, 11, rt.handler.arcX, &rotBank, 10);
    press("R_Zp_onX", vp, rt.handler.arcX, 10, rt.handler.arcY, &rotBank, 10);
    vp = camera(Vec3(-0.5f, 0.15f, 0.866f));
    press("T_XS_onRing", vp, rt.handler.arcX, 10, mv.handler.arrowX, &unified, 0);
    press("T_XS_onShaft", vp, mv.handler.arrowX, 0, rt.handler.arcX, &unified, 0);
    assert(cells == 12);

    // An AREA part (box, disc, head) keeps its registration precedence: the
    // law was measured on strokes only. The move centre box and a rotate ring
    // under one press: whichever is registered first wins, as before.
    int bx, by;
    Handler ring;
    bool found;
    foreach (back; [Vec3(0.3f, 0.25f, 1), xFront, zFront, Vec3(1, 0.25f, 0.3f)]) {
        if (found) break;
        vp = camera(back);
        float cx, cy, cz;
        assert(projectToWindowFull(Vec3(0, 0, 0), vp, cx, cy, cz));
        foreach (Handler arc; [cast(Handler)rt.handler.arcX, rt.handler.arcY, rt.handler.arcZ])
            foreach (dy; -8 .. 9) foreach (dx; -8 .. 9) {
                int x = cast(int)cx + dx, y = cast(int)cy + dy;
                if (!found && arc.isVisible() && mv.handler.centerBox.hitTest(x, y, vp)
                    && arc.hitTest(x, y, vp)) { bx = x; by = y; ring = arc; found = true; }
            }
    }
    assert(found, "rig: no press on both the centre box and a rotate ring");
    foreach (boxFirst; [true, false]) {
        auto th = new ToolHandles;
        th.begin();
        th.rule = HitRule.nearestOnScreen;
        if (boxFirst) { th.add(mv.handler.centerBox, 3); th.add(ring, 10); }
        else          { th.add(ring, 10); th.add(mv.handler.centerBox, 3); }
        assert(th.test(bx, by, vp) == (boxFirst ? 3 : 10), "an area part keeps its registration precedence");
    }
}
