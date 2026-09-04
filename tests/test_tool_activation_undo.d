// test_tool_activation_undo.d — lifecycle undo stepping (task 0065).
//
// Two interactive Move gizmo gestures, EACH bracketed by tool.set move /
// tool.set move off, drive the production path:
//   * the gesture's mouse-up records a snapshot-based in-session geometry entry;
//   * each tool arm emits a lifecycle record; drop consolidates the run but
//     owns no additional lifecycle step. The arm record is visible in
//     /api/history and also counted by /api/undo/status.toolLifecycleCount.
//
// Resulting surfaced stack after both gestures (undo count = 4 new entries):
//   [ArmA(lifecycle), geomA(Model), ArmB(lifecycle), geomB(Model)]
//
// Undo sequence (the headline contract this task pins):
//   undo₁ → geomB reverts (v6 back to post-gesture-A position).
//   undo₂ → ArmB lifecycle step, geometry no-op.
//   undo₃ → geomA reverts (v6 back to the cube baseline).
//   undo₄ → ArmA lifecycle step, geometry no-op.
// Redo round-trip walks the same steps in reverse and restores both gestures.
//
// Gizmo gestures drive the MAIN loop via drag_helpers.buildDragLog +
// /api/play-events with the mandatory ~120ms post-playback settle. Verify-and-
// retry is keyed on the geometry MOVE (a missed grab leaves v6 unmoved -> retry).
module test_tool_activation_undo;


import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math : fabs, sqrt, PI, sin, cos;
import std.conv : to;
import std.string : format;

import drag_helpers;

void main() {}

alias baseUrl = testBaseUrl;


void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(120.msecs);
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}
long lifecycleCount() {
    return getJson("/api/undo/status")["toolLifecycleCount"].integer;
}
bool canUndoLifecycle() {
    return getJson("/api/undo/status")["canUndoLifecycle"].boolean;
}

double[3] vert(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}
bool vertNear(double[3] a, double[3] b, double eps = 1e-2) {
    return fabs(a[0]-b[0]) < eps && fabs(a[1]-b[1]) < eps && fabs(a[2]-b[2]) < eps;
}

bool playerIdle() {
    auto s = getJson("/api/play-events/status");
    auto f = "finished" in s;
    return f is null || f.type != JSONType.false_;
}

void establishCubeBaseline() {
    import core.thread : Thread;
    import core.time   : msecs;
    bool cubePristine() {
        auto v = getJson("/api/model")["vertices"].array;
        if (v.length != 8) return false;
        auto c = v[6].array;   // startup cube v6 = (0.5, 0.5, 0.5)
        return fabs(c[0].floating - 0.5) < 1e-3
            && fabs(c[1].floating - 0.5) < 1e-3
            && fabs(c[2].floating - 0.5) < 1e-3;
    }
    foreach (attempt; 0 .. 8) {
        postJson("/api/script", "tool.set move off");
        foreach (_; 0 .. 200) {
            if (playerIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        postJson("/api/reset", "");
        postJson("/api/command", "history.clear");
        if (cubePristine() && undoCount() == 0) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    assert(cubePristine(), "could not establish pristine cube baseline");
}

void selectV6() {
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[6]}`));
    settle();
    auto s = getJson("/api/selection");
    assert(s["mode"].str == "vertices"
        && s["selectedVertices"].array.length == 1
        && s["selectedVertices"].array[0].integer == 6,
        "v6 selection did not take: " ~ s.toString);
}

// Authoritative gizmo pivot: evaluated ActionCenterPacket.center.
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// +X arrow handle grab pixel (0.7 along the arrow) + screen-space +X direction.
void arrowGrab(Vec3 pivot, ref Viewport vp, out int gx, out int gy,
               out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 5.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,        pivot.y, pivot.z), vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// One ON-handle +X Move gesture against the CURRENT pivot, verify-and-retry
// keyed on v6 actually moving away from `before`. Returns v6's post position.
double[3] moveGestureOnHandle(double[3] before, double mag = 60.0) {
    foreach (attempt; 0 .. 8) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        int xa, ya; double ux, uy;
        arrowGrab(evalPivot(), vp, xa, ya, ux, uy);
        int xb = xa + cast(int)(mag * ux);
        int yb = ya + cast(int)(mag * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xb, yb, 10));
        settle();
        if (!vertNear(vert(6), before)) break;
    }
    return vert(6);
}

// --- Test case ---

unittest {
    establishCubeBaseline();
    selectV6();   // records ONE UI-undo entry; it stays BELOW the geometry floor
    long floor = undoCount();   // = 1 (the select entry)
    auto base = vert(6);   // (0.5, 0.5, 0.5)

    // --- Gesture A: drag, then DROP (consolidate run A + emit lifecycle) ---
    postJson("/api/script", "tool.set move");
    settle();
    auto afterA = moveGestureOnHandle(base);
    assert(!vertNear(afterA, base), "gesture A must move v6 off baseline");
    postJson("/api/script", "tool.set move off");
    settle();

    assert(undoCount() == floor + 2,
        "after gesture A + drop: floor+2 surfaced entries; floor=" ~ floor.to!string
        ~ " got " ~ undoCount().to!string);
    assert(lifecycleCount() == 1,
        "after gesture A + drop: 1 lifecycle entry; got " ~ lifecycleCount().to!string);

    // --- Gesture B: drag, then DROP (consolidate run B + emit lifecycle) ---
    postJson("/api/script", "tool.set move");
    settle();
    auto afterB = moveGestureOnHandle(afterA);
    assert(!vertNear(afterB, afterA), "gesture B must move v6 further");
    postJson("/api/script", "tool.set move off");
    settle();

    assert(undoCount() == floor + 4,
        "after gesture B + drop: floor+4 surfaced entries; floor=" ~ floor.to!string
        ~ " got " ~ undoCount().to!string);
    assert(lifecycleCount() == 2,
        "after gesture B + drop: 2 lifecycle entries; got " ~ lifecycleCount().to!string);

    // --- undo₁: revert geomB (v6 -> afterA) ---
    postJson("/api/undo", "");
    settle();
    assert(vertNear(vert(6), afterA),
        "undo₁ should revert geomB to afterA; got " ~ vert(6).to!string
        ~ " want " ~ afterA.to!string);

    // Arm B is now the tail. Strict LIFO makes undo₂ consume that lifecycle
    // record without touching geomA; the former two-press geometry contract
    // must stay false.
    assert(canUndoLifecycle(), "undo₂ must see the arm-B lifecycle tail");
    auto beforeArmBStep = lifecycleCount();
    postJson("/api/undo", "");
    settle();
    assert(vertNear(vert(6), afterA),
        "undo₂ must consume arm B without reverting geomA; got "
        ~ vert(6).to!string ~ " want " ~ afterA.to!string);
    assert(!vertNear(vert(6), base),
        "obsolete two-press contract resurfaced: undo₂ reverted geomA");
    assert(lifecycleCount() == beforeArmBStep - 1,
        "undo₂ must consume exactly one lifecycle entry");

    // undo₃ now reaches geomA and restores the original geometry.
    postJson("/api/undo", "");
    settle();
    assert(vertNear(vert(6), base),
        "undo₃ should revert geomA to baseline; got " ~ vert(6).to!string
        ~ " want " ~ base.to!string);
    assert(canUndoLifecycle(), "undo₄ must see the remaining arm-A lifecycle tail");
    auto beforeStep = lifecycleCount();
    postJson("/api/undo", "");
    settle();
    assert(vertNear(vert(6), base),
        "undo₄ lifecycle step must not change geometry");
    assert(lifecycleCount() == beforeStep - 1,
        "undo₄ must consume exactly one lifecycle entry");

    import std.stdio : writeln;
    writeln("test_tool_activation_undo: PASS");
}
