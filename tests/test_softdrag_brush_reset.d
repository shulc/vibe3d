// test_softdrag_brush_reset.d — per-tool parity: a brush-reset tool bakes each
// stroke, so a post-stroke falloff (radius) change does NOT re-deform it.
//
// The soft-drag tool (`xfrm.softDrag`, `flags: [brushReset]`) is a BRUSH-STYLE
// tool: each LMB stroke is one atomic action and the tool's transform zeroes
// between strokes. A live command-stream capture of the reference confirmed it:
// after a soft-drag move stroke, the next radius gesture drives ONLY the falloff
// attrs (never the transform), so the committed stroke does not move again — the
// radius only arms the NEXT stroke.
//
// vibe3d's in-session falloff re-grade re-applies a committed gizmo gesture with
// the new weights on ANY post-gesture falloff change. That is the intended
// behaviour for the PLAIN (non-brush) move / rotate / scale tools, but WRONG for
// the brush-reset soft-drag tool. `armRegradeStamp()` disarms the re-grade stamp
// at the stroke commit when `ToolFlag.BrushReset` is set, so a soft-drag radius
// tweak is inert.
//
// Two contrasting cases pin the per-tool boundary — SAME falloff type (screen),
// SAME sequence, the ONLY difference is the brushReset flag:
//   (a) xfrm.softDrag (brushReset)  : a screenSize tweak after a stroke leaves
//       geometry BYTE-IDENTICAL (no re-grade).
//   (b) move + falloff.screen (no brushReset): the same screenSize tweak DOES
//       re-grade (geometry changes) — the unchanged behaviour for non-brush.
//
// Test discipline mirrors the other transform tests: drainHistory() BEFORE
// /api/reset (reset is itself undoable); a ~150ms settle after every play-events
// / config command; the move stroke drives the MAIN loop via play-events.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;
import std.string : format;

import drag_helpers;

void main() {}

enum string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}

long undoCount() { return getJson("/api/history")["undo"].array.length; }

void drainHistory() {
    foreach (_; 0 .. 100) {
        if (undoCount() == 0) return;
        postJson("/api/undo", "");
    }
}

Vec3[] verts() {
    auto a = getJson("/api/model")["vertices"].array;
    Vec3[] o;
    o.length = a.length;
    foreach (i, e; a)
        o[i] = Vec3(cast(float)e[0].floating,
                    cast(float)e[1].floating,
                    cast(float)e[2].floating);
    return o;
}

// Max per-vertex euclidean distance between two equal-length vertex arrays.
double maxDelta(Vec3[] a, Vec3[] b) {
    assert(a.length == b.length, "vertex count changed mid-test");
    double m = 0;
    foreach (i; 0 .. a.length) {
        Vec3 d = a[i] - b[i];
        double dist = sqrt(cast(double)(d.x*d.x + d.y*d.y + d.z*d.z));
        if (dist > m) m = dist;
    }
    return m;
}

// Reset to a dense cube (subdivided twice → ~98 verts) so the screen-falloff
// weighting has a clear signal. Selection left empty ⇒ the whole mesh is the
// moving set (universal "empty selection = all" rule).
void establishDenseCube() {
    drainHistory();
    postJson("/api/reset", "");
    drainHistory();
    postJson("/api/script", "mesh.subdivide");
    settle();
    postJson("/api/script", "mesh.subdivide");
    settle();
    auto v = verts();
    assert(v.length > 50,
        "expected a dense cube after two subdivides; got " ~ v.length.to!string);
}

// One screen-plane soft-drag stroke: click an off-gizmo pixel and drag down.
// The screen-falloff disc centres on the click; the moving set (whole mesh)
// translates, each vert weighted by its screen distance to the click.
void softDragStroke() {
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    // Gizmo sits at the selection centroid (origin). Click well clear of it so
    // the drag is a screen-plane haul, not a handle grab.
    float gx, gy;
    projectToWindow(Vec3(0, 0, 0), vp, gx, gy);
    int x0 = cast(int)gx + 130;   // off every gizmo handle (~90px)
    int y0 = cast(int)gy + 130;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x0, y0 - 35, 12));
    settle();
}

// ---------------------------------------------------------------------------
// (a) xfrm.softDrag (brushReset): a post-stroke radius change is INERT.
// ---------------------------------------------------------------------------
unittest {
    establishDenseCube();
    postJson("/api/script", "tool.set xfrm.softDrag on");
    postJson("/api/command", "tool.pipe.attr falloff screenSize 500"); // covers all
    settle();

    auto before = verts();
    softDragStroke();
    auto afterStroke = verts();
    assert(maxDelta(before, afterStroke) > 1e-3,
        "the soft-drag stroke should move geometry; max delta=" ~
        maxDelta(before, afterStroke).to!string);

    // Change the falloff RADIUS after the committed stroke. For a brush-reset
    // tool this must NOT re-deform the baked stroke.
    postJson("/api/command", "tool.pipe.attr falloff screenSize 50");
    settle();
    auto afterRadius = verts();
    assert(maxDelta(afterStroke, afterRadius) < 1e-5,
        "BRUSH-RESET: a radius change after a soft-drag stroke must leave the " ~
        "committed geometry byte-identical; max delta=" ~
        maxDelta(afterStroke, afterRadius).to!string);

    postJson("/api/script", "tool.set xfrm.softDrag off");
    settle();
}

// ---------------------------------------------------------------------------
// (b) move + falloff.screen (NO brushReset): the SAME post-stroke radius change
//     DOES re-grade. Locks in the unchanged behaviour for non-brush tools, so
//     the fix is proven scoped to the brushReset flag alone.
// ---------------------------------------------------------------------------
unittest {
    establishDenseCube();
    postJson("/api/script", "tool.set move on");
    postJson("/api/script", "falloff.screen");
    postJson("/api/command", "tool.pipe.attr falloff screenSize 500");
    settle();

    auto before = verts();
    softDragStroke();
    auto afterStroke = verts();
    assert(maxDelta(before, afterStroke) > 1e-3,
        "the move stroke should move geometry; max delta=" ~
        maxDelta(before, afterStroke).to!string);

    postJson("/api/command", "tool.pipe.attr falloff screenSize 50");
    settle();
    auto afterRadius = verts();
    assert(maxDelta(afterStroke, afterRadius) > 1e-3,
        "NON-BRUSH: a radius change after a move stroke SHOULD re-grade the " ~
        "committed gesture (in-session re-grade unchanged for non-brush tools); " ~
        "max delta=" ~ maxDelta(afterStroke, afterRadius).to!string);

    postJson("/api/script", "tool.set move off");
    settle();
}
