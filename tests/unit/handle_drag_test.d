// One handle drag: press + travel (task 9412, M-HANDLE).
//
// `HandleDrag.client` is the handle at the press plus the pointer travel since
// the press; it holds no snap, so a snapped answer never feeds the next event
// and a released snap rejoins the pointer (captured K-B9, one law for Move and
// the Box). The deleted copies stay deleted: Move's separate snap client, the
// Box's unsnapped parameter copy, the primitive mover body and both mover hit
// wrappers. Polarity: the needles are RED on the pre-slice tree (4 `snapClient`,
// 13 `dragRaw_`, 4 `handleMoverDrag`, 3 + 2 `moverHitTest` code tokens).
module tests.unit.handle_drag_test;

import std.algorithm : canFind, sort;
import std.array : array;
import std.file : dirEntries, readText, SpanMode;
import std.math : abs, round;
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, containsWord,
    isIdentChar, symbolTokenHits;

import math : Vec3, Viewport, lookAt, orthographicMatrix;
import drag : HandleDrag, DragFrame, DragKind, screenAxisDelta, primitiveCenterDragDelta;
import tools.transform.move : MoveTool;
import tools.create.box : BoxTool;
import tools.create.primitive_create_tool : PrimitiveCreateTool;

// 1. The fence, compiled (allMembers sees private members).
static assert(![__traits(allMembers, MoveTool)].canFind("snapClient"));
static assert(![__traits(allMembers, MoveTool)].canFind("planeAnchor"));
static assert(![__traits(allMembers, MoveTool)].canFind("axisAnchor"));
static assert(![__traits(allMembers, BoxTool)].canFind("dragRaw_"));
static assert(![__traits(allMembers, BoxTool)].canFind("moverHitTest"));
static assert(![__traits(allMembers, BoxTool)].canFind("applyEdgeDelta"));
static assert(![__traits(allMembers, PrimitiveCreateTool)].canFind("handleMoverDrag"));
static assert(![__traits(allMembers, PrimitiveCreateTool)].canFind("moverHitTest"));
// Positive control: the same trait sees each tool's one handle drag.
static assert([__traits(allMembers, MoveTool)].canFind("grab"));
static assert([__traits(allMembers, BoxTool)].canFind("grab"));
static assert([__traits(allMembers, PrimitiveCreateTool)].canFind("grab"));
static assert([__traits(allMembers, HandleDrag)] == ["point", "pressX", "pressY", "press", "client"]);

// Top orthographic view at 440 px/m, the witnesses' rig: +x is +440 px right.
private Viewport topView() {
    immutable eye = Vec3(0, 5, 0.0001f);
    Viewport vp = Viewport(lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0)),
        orthographicMatrix(300.0f / 440.0f, 800.0f / 600.0f, 0.01f, 100.0f),
        800, 600, 0, 0, eye);
    vp.focus = Vec3(0, 0, 0);
    return vp;
}

private float gridX(Vec3 v) { return cast(float)(round(v.x / 0.1) * 0.1); }

unittest {
    auto vp = topView();
    DragFrame f;
    f.kind = DragKind.screenAxis;
    f.axis = Vec3(1, 0, 0);
    HandleDrag g;
    g.press(Vec3(0.3f, 0, 0.1f), 400, 300);
    // Press + 20 events of +2 px = press + 40 px of travel, whatever came between.
    Vec3 c;
    bool skip;
    foreach (k; 1 .. 21) c = g.client(400 + 2 * k, 300, f, vp, skip);
    assert(!skip && abs(c.x - (0.3f + 40.0f / 440.0f)) < 1e-5f && c.z == 0.1f,
        "press + 20 x 2 px must be press + 40 px of travel");
    // The snapped answer (grid 0.1) is the client rounded; it never moves the press.
    assert(abs(gridX(c) - 0.4f) < 1e-6f);
    // Fed back (the previous snapped answer as the next press), 2 px never leaves
    // the node: the K-B9 FED-BACK candidate 0.3 — must DIFFER from press + travel.
    Vec3 fed = Vec3(0.3f, 0, 0.1f);
    foreach (k; 1 .. 21) {
        HandleDrag h;
        h.press(fed, 400 + 2 * (k - 1), 300);
        fed.x = gridX(h.client(400 + 2 * k, 300, f, vp, skip));
    }
    assert(abs(fed.x - 0.3f) < 1e-6f && abs(gridX(c) - fed.x) > 0.05f,
        "a fed-back press must stay on 0.3; press + travel reaches 0.4");
    // Release: after snapped events, an unsnapped one is the client itself.
    assert(g.client(440, 300, f, vp, skip) == c, "a released snap rejoins the pointer");
}

unittest {
    // Law-neutral in the witnesses' ortho rig: the incremental bodies H2 replaced
    // (a live origin / reference, the previous pixel) sum to the same client.
    auto vp = topView();
    foreach (kind; [DragKind.screenAxis, DragKind.principalPlane]) {
        DragFrame f;
        f.kind = kind;
        HandleDrag g;
        immutable Vec3 p0 = Vec3(0.3f, 0, 0.1f);
        g.press(p0, 400, 300);
        Vec3 live = p0;
        bool skip;
        size_t n;
        foreach (k; 1 .. 21) {
            const int x = 400 + 2 * k, y = 300 + k, px = x - 2, py = y - 1;
            live = live + (kind == DragKind.screenAxis
                ? screenAxisDelta(x, y, px, py, live, f.axis, vp, skip)
                : primitiveCenterDragDelta(x, y, px, py, live, vp));
            assert((g.client(x, y, f, vp, skip) - live).length < 1e-6f);
            ++n;
        }
        assert(n == 20);
    }
}

unittest {
    string[string] code;
    foreach (e; dirEntries("source", "*.d", SpanMode.depth))
        code[e.name] = blankUnittestBodies(blankNonCode(readText(e.name)));
    foreach (f; ["source/drag.d", "source/tools/transform/move.d", "source/tools/create/box.d",
                 "source/tools/create/primitive_create_tool.d", "source/tools/create/create_common.d"])
        assert(f in code, "census walk missed " ~ f);

    // 2. Needles: every spelling of each deleted copy's identifier.
    foreach (f, c; code)
        foreach (w; ["snapClient", "dragRaw_", "handleMoverDrag", "moverHitTest"])
            assert(!containsWord(c, w), w ~ " is back in " ~ f);

    // 3. Every `.press` (incl. `&x.press`) by enclosing symbol. Narrowed by
    //    receiver to the two other press APIs, which have a ceiling of 3.
    // The token ends at `press` (`.pressX` is a field, not a call).
    string[] keys(string c, string f, string needle) {
        string[] k;
        foreach (h; symbolTokenHits(c, f, needle))
            if (h.text.length == needle.length || !isIdentChar(h.text[needle.length]))
                k ~= h.key;
        return k;
    }
    string[] sites;
    size_t others;
    foreach (f, c; code) sites ~= keys(c, f, ".press");
    foreach (f, c; code)
        foreach (r; ["held_.press", "valueDrag_.press"])
            foreach (k; keys(c, f, r)) { ++others; sites = sites.remove(k); }
    assert(others == 3, "the other press APIs moved; re-read the narrowing");
    sort(sites);
    // Every handle press is a button-down path; `armAxisLeg` is also the Ctrl
    // hand-over, the axis leg's own press (nothing moved before it).
    assert(sites == ["BoxTool.onMouseButtonDown", "BoxTool.onMouseButtonDown",
                     "BoxTool.onMouseButtonDown", "HandledCreateTool.tryGrabHandles",
                     "MoveTool.armAxisLeg", "PrimitiveCreateTool.tryGrabMover"],
        "a HandleDrag press outside the named press sites");
}

private string[] remove(string[] a, string key) {
    foreach (i, s; a) if (s == key) return a[0 .. i] ~ a[i + 1 .. $];
    assert(false, "narrowed receiver not among the press sites: " ~ key);
}
