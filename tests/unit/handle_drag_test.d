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

import math : Vec3, Viewport, lookAt, orthographicMatrix, perspectiveMatrix, projectToWindow;
import drag : HandleDrag, DragFrame, DragKind, screenAxisDelta, planeDragDelta, planeJacobian;
import viewgrid : vectorSnap;
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
static assert([__traits(allMembers, HandleDrag)] == ["point", "pressX", "pressY", "press", "client", "travel"]);

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
    // Press + 20 events of +2 px = press + 40 px of travel (0.0909, rounded to
    // the 0.005 view quantum: a line keeps its offset), whatever came between.
    Vec3 c;
    bool skip;
    foreach (k; 1 .. 21) c = g.client(400 + 2 * k, 300, f, vp, skip);
    assert(!skip && abs(c.x - 0.39f) < 1e-5f && c.z == 0.1f,
        "press + 20 x 2 px must be press + q(40 px of travel)");
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
    // Pure: the client reads only the press, so a detour through another pixel
    // leaves the answer at a pixel unchanged — in a perspective view, where a
    // per-event re-press would re-linearise and land elsewhere.
    immutable eye = Vec3(3, 4, 5);
    Viewport vp = Viewport(lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0)),
        perspectiveMatrix(1.0471976f, 800.0f / 600.0f, 0.01f, 100.0f), 800, 600, 0, 0, eye);
    vp.focus = Vec3(0, 0, 0);
    DragFrame f;
    f.kind = DragKind.screenAxis;
    HandleDrag g;
    g.press(Vec3(0.3f, 0, 0.1f), 400, 300);
    bool skip;
    immutable Vec3 first = g.client(440, 300, f, vp, skip);
    foreach (k; 1 .. 21) g.client(400 + 4 * k, 300, f, vp, skip);
    assert(!skip && g.client(440, 300, f, vp, skip) == first, "the client must not accumulate");
}

unittest {
    // Law-neutral in the witnesses' ortho rig: the incremental bodies H2 replaced
    // (a live origin / reference, the previous pixel) sum to the same travel,
    // which the kind's form then rounds (a line its travel, the plane its point).
    auto vp = topView();
    foreach (kind; [DragKind.screenAxis, DragKind.handlePlane]) {
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
                : planeDragDelta(x, y, px, py, 3, live, vp, skip));
            immutable Vec3 want = kind == DragKind.screenAxis
                ? p0 + f.axis * cast(float)(round((live.x - p0.x) / 0.005) * 0.005)
                : vectorSnap(live, 0.005f);
            assert((g.client(x, y, f, vp, skip) - want).length < 1e-6f);
            ++n;
        }
        assert(n == 20);
    }
}

// The reference's oblique perspective rig (K-C3, task 9471): pinhole focal
// 1004.7546 px centred on (576, 487), eye (0.07, 33.96, 19.03) on the focus
// (0.07, 1, 0); its view pixel scale 0.030303 is ours' `viewWorldPerPixel`.
private Viewport obliqueView() {
    import std.math : atan;
    immutable eye = Vec3(0.07f, 33.959961496f, 19.029442725f);
    Viewport vp = Viewport(lookAt(eye, Vec3(0.07f, 1, 0), Vec3(0, 1, 0)),
        perspectiveMatrix(cast(float)(2 * atan(487 / 1004.7545726038318)), 1152.0f / 974.0f,
                          0.1f, 1000.0f), 1152, 974, 0, 0, eye);
    vp.focus = Vec3(0.07f, 1, 0);
    return vp;
}

unittest {
    // The map: T = H + inv(M) (pixel travel), M forward-differenced at H with a
    // step of ten view pixels, on the base plane's (Z, X). The read targets of
    // the four cells (capture K-C3, cells C3a / C3b / C3c / C3e) to
    // 1e-5; the anchored pixel step misses by 9.5e-4..1.2e-2, k -> 0 by 1.3e-2+.
    auto vp = obliqueView();
    static struct Cell { string id; Vec3 h; int dx, dy; Vec3 t; }
    immutable Cell[4] cells = [
        Cell("C3a", Vec3(-8.15f, 0, 2.6f), 240, 24, Vec3(0.946016f, 0, 3.591705f)),
        Cell("C3b", Vec3(4.05f, 0, -0.1f), 0, 240, Vec3(3.504465f, 0, 10.542967f)),
        Cell("C3c", Vec3(-6.25f, 0, 5.4f), 168, -168, Vec3(-0.756621f, 0, -1.033932f)),
        Cell("C3e", Vec3(0.2877f, 0, 1.2183f), 120, -90, Vec3(4.874834f, 0, -2.638698f))];
    size_t n;
    foreach (c; cells) {
        auto j = planeJacobian(c.h, Vec3(0, 0, 1), Vec3(1, 0, 0), vp);
        assert(j.valid && (c.h + j.apply(c.dx, c.dy) - c.t).length <= 1e-5f,
            c.id ~ ": the forward-difference map misses the read target");
        ++n;
    }
    assert(n == 4);

    // C3e through Move's frame (the free kind): the vertex is
    // start + q(T) - q(start) at the view quantum 0.05 (DQ in world channels).
    float sx, sy, sz;
    assert(projectToWindow(cells[3].h, vp, sx, sy, sz) && abs(sx - 582) < 1 && abs(sy - 528) < 1,
        "rig: the C3e start must sit under its press pixel (582, 528)");
    DragFrame f;
    f.kind = DragKind.viewPlane;
    HandleDrag g;
    g.press(cells[3].h, 582, 528);
    bool skip;
    immutable Vec3 v = g.client(702, 438, f, vp, skip);
    assert(!skip && (v - Vec3(4.8377f, 0, -2.6317f)).length <= 1e-4f,
        "move-free-oblique: the vertex must land on start + q(T) - q(start)");
}

unittest {
    // One form per frame kind, top view at q 0.005, off-lattice starts (K-G2,
    // K-G3, K-H2; every pair of forms 2.3e-3+ apart at these cells).
    auto vp = topView();
    Vec3 drag(DragKind kind, Vec3 p, int dx, int dy, Vec3 axis = Vec3(1, 0, 0)) {
        DragFrame f;
        f.kind = kind;
        f.axis = axis;
        f.normal = Vec3(0, 1, 0);
        HandleDrag g;
        g.press(p, 400, 300);
        bool skip;
        immutable Vec3 c = g.client(400 + dx, 300 + dy, f, vp, skip);
        assert(!skip);
        return c;
    }
    // No travel, no motion: the free form subtracts the two roundings first,
    // so a press on an off-lattice point returns it bit-for-bit (a one-ulp
    // drift is an edit, and commits a run of its own).
    size_t still;
    foreach (p; [Vec3(0.3023f, 0, 0.2017f), Vec3(-1.2f, 0, 1.2f), Vec3(0.2789f, 0, -0.5003f)]) {
        assert(drag(DragKind.viewPlane, p, 0, 0) == p, "free: zero travel must return the point");
        ++still;
    }
    assert(still == 3);
    immutable Vec3 free = drag(DragKind.viewPlane, Vec3(0.3023f, 0, 0.2017f), 84, 5);
    assert(abs(free.x - 0.4973f) <= 1e-4f && abs(free.z - 0.2167f) <= 1e-4f,
        "free (Move): p + q(p + T) - q(p), (0.4973, 0.2167)");
    assert(abs(drag(DragKind.handlePlane, Vec3(0.0523f, 0, 0), 40, 0).x - 0.145f) <= 1e-4f,
        "planar (primitive centre mover): q(p + T), 0.145");
    assert(abs(drag(DragKind.screenAxis, Vec3(0.3523f, 0, 0), 40, 0).x - 0.4423f) <= 1e-4f,
        "line (size handle): p + q(t), 0.4423");
    assert(abs(drag(DragKind.screenAxis, Vec3(0.0523f, 0, 0), 40, 0, Vec3(0.6f, 0, 0)).x
               - 0.1423f) <= 1e-4f,
        "line (centre mover arrow, gain 0.6): p + q(t) in world, 0.1423");
    assert(abs(drag(DragKind.planeHit, Vec3(0.3523f, 0, 0), 40, 0).x - 0.4423f) <= 1e-4f,
        "line (height handle): p + q(t), 0.4423");
    assert(abs(drag(DragKind.axisArm, Vec3(0.3023f, 0, 0), 95, 0).x - 0.5173f) <= 1e-4f
        && abs(drag(DragKind.axisArm, Vec3(0.3023f, 0, 0), 83, 0).x - 0.4923f) <= 1e-4f,
        "line (Move axis arm): p + q(t), 0.5173 / 0.4923");
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
    // hand-over, the axis leg's own press (nothing moved before it). The base
    // drag's corner is a handle too (task 9473): box, radial, torus presses.
    // The topology pen's grab (task 9510) re-presses a local value per
    // evaluation at the ARM-TIME anchor and the press pixel's origin, which is
    // the gesture's press restated: nothing it returns is written back.
    assert(sites == ["ArrayTool.onMouseButtonDown",
                     "BoxTool.onMouseButtonDown", "BoxTool.onMouseButtonDown",
                     "BoxTool.onMouseButtonDown", "BoxTool.onMouseButtonDown",
                     "CloneTool.onMouseButtonDown",
                     "HandledCreateTool.tryGrabHandles", "MirrorTool.onMouseButtonDown",
                     "MoveTool.armAxisLeg",
                     "PrimitiveCreateTool.tryGrabMover", "RadialSweepTool.onMouseButtonDown",
                     "SizedRadialCreateTool.onMouseButtonDown",
                     "TopologyPenTool.grabOffset", "TorusTool.onMouseButtonDown"],
        "a HandleDrag press outside the named press sites");
}

private string[] remove(string[] a, string key) {
    foreach (i, s; a) if (s == key) return a[0 .. i] ~ a[i + 1 .. $];
    assert(false, "narrowed receiver not among the press sites: " ~ key);
}
