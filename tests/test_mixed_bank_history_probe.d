// Diagnostic cell for task 4690.  This file is intentionally a probe while
// the external history law is unresolved; the task card records whether it is
// retained after the capture decision.

import core.thread : Thread;
import core.time : msecs;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json : JSONType;
import std.math : fabs, sqrt;

import drag_helpers;

void main() {}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void interactiveCmd(string line) {
    auto r = postJson("/api/script?interactive=true", line);
    assert(r["status"].str == "ok",
        "interactive command '" ~ line ~ "' failed: " ~ r.toString);
}

void settle() {
    Thread.sleep(120.msecs);
}

double[3] published(string field) {
    auto a = getJson("/api/toolpipe/eval")["transform"][field].array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

double[3][] vertices() {
    double[3][] result;
    foreach (entry; getJson("/api/model")["vertices"].array) {
        auto a = entry.array;
        result ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return result;
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

long inSessionCount() {
    long count;
    foreach (entry; getJson("/api/history")["undo"].array) {
        auto tagged = "inSession" in entry.object;
        if (tagged !is null && tagged.type == JSONType.true_) ++count;
    }
    return count;
}

Vec3 evalPivot() {
    auto a = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float) a[0].floating,
                cast(float) a[1].floating,
                cast(float) a[2].floating);
}

void arrowGeometry(Vec3 pivot, ref Viewport vp,
                   out int grabX, out int grabY,
                   out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float x1, y1, x2, y2;
    projectToWindow(Vec3(pivot.x + size / 5.0f, pivot.y, pivot.z),
                    vp, x1, y1);
    projectToWindow(Vec3(pivot.x + size, pivot.y, pivot.z),
                    vp, x2, y2);
    grabX = cast(int)(x1 + 0.7f * (x2 - x1));
    grabY = cast(int)(y1 + 0.7f * (y2 - y1));
    double dx = x2 - x1, dy = y2 - y1;
    double length = sqrt(dx * dx + dy * dy);
    ux = dx / length;
    uy = dy / length;
}

unittest {
    postJson("/api/command", "tool.set Transform off");
    postJson("/api/command", commandBody("scene.reset"));
    postJson("/api/command", "history.clear");
    cmd("tool.set Transform");
    long floor = undoCount();

    // Establish the preceding Move run that the boundary decision can either
    // preserve as one row or split from the mixed edit.
    auto cam = fetchCamera();
    auto vp = viewportFromCamera(cam);
    int x0, y0;
    double ux, uy;
    arrowGeometry(evalPivot(), vp, x0, y0, ux, uy);
    int x1 = x0 + cast(int)(60.0 * ux);
    int y1 = y0 + cast(int)(60.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 10));
    settle();
    assert(undoCount() == floor + 1 && inSessionCount() == 1,
        "population floor: preceding Move must leave one in-session row; floor="
        ~ floor.to!string ~ " undo=" ~ undoCount().to!string
        ~ " tagged=" ~ inSessionCount().to!string);

    // Seed held Scale while the Move run is live.  Read it back before TX: the
    // population floor is independent of the history label under judgment.
    cmd("tool.attr Transform SX 2");
    auto heldScale = published("scale");
    assert(fabs(heldScale[0] - 2.0) < 1e-6
        && fabs(heldScale[1] - 1.0) < 1e-6
        && fabs(heldScale[2] - 1.0) < 1e-6,
        "population floor: held Scale must be nonidentity (2,1,1), got "
        ~ heldScale.to!string);

    auto heldTranslate = published("translate");
    auto populated = vertices();
    assert(populated.length == 8,
        "population floor: mixed replay must evaluate a populated cube; verts="
        ~ populated.length.to!string);
    cmd("tool.beginSession Transform");
    interactiveCmd(format("tool.attr Transform TX %.9g",
                          heldTranslate[0] + 1.0));
    settle();
    auto afterTranslate = published("translate");
    assert(fabs(afterTranslate[0] - heldTranslate[0] - 1.0) < 1e-6,
        "TX operation must change the published cause channel by +1; before="
        ~ heldTranslate.to!string ~ " after=" ~ afterTranslate.to!string);

    // Close through a Move relocate.  The perpendicular offset is well away
    // from every handle; it asks commitEditAtBankBoundary(Move) to judge the
    // mixed edit's provenance.
    int xoff = cast(int)(x1 + 220.0 * uy);
    int yoff = cast(int)(y1 - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             xoff, yoff, xoff, yoff, 1));
    settle();
    auto undo = getJson("/api/history")["undo"].array;
    string[] labels;
    foreach (entry; undo) labels ~= entry["label"].str;
    assert(undo.length == floor + 2,
        "task 4690 current-routing boundary: expected two rows above floor, got "
        ~ (undo.length - floor).to!string ~ " labels=" ~ labels.to!string);
    assert(undo[$ - 1]["label"].str == "Scale 8 verts",
        "task 4690 current-routing label: expected 'Scale 8 verts', got "
        ~ undo[$ - 1]["label"].str);

    cmd("tool.set Transform off");
}
