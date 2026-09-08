// Capture-backed regression for task 4691: a Move-caused replay keeps held
// Scale state while history remains command-owned and undo/redo asymmetric.

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

bool sameVec(double[3] a, double[3] b, double eps = 1e-5) {
    return fabs(a[0] - b[0]) < eps && fabs(a[1] - b[1]) < eps &&
           fabs(a[2] - b[2]) < eps;
}

bool sameGeometry(double[3][] a, double[3][] b, double eps = 1e-5) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length)
        if (!sameVec(a[i], b[i], eps)) return false;
    return true;
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
    auto original = vertices();

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
    auto postMove = vertices();
    auto postMoveT = published("translate");
    auto postMoveR = published("rotate");
    auto postMoveS = published("scale");
    assert(undoCount() == floor + 1 && inSessionCount() == 1,
        "population floor: preceding Move must leave one in-session row; floor="
        ~ floor.to!string ~ " undo=" ~ undoCount().to!string
        ~ " tagged=" ~ inSessionCount().to!string);

    // Seed held Scale while the Move run is live.  Read it back before TX: the
    // population floor is independent of the history label under judgment.
    cmd("tool.attr Transform SX 2");
    auto scaleReplay = getJson("/api/tool/state")["valueReplay"];
    auto foldsBeforeTX = scaleReplay["folds"].integer;
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
    auto txReplay = getJson("/api/tool/state")["valueReplay"];
    assert(txReplay["cause"].str == "move" &&
           txReplay["source"].str == "interactive" &&
           txReplay["channels"].array.length == 1 &&
           txReplay["channels"].array[0].str == "TX" &&
           txReplay["folds"].integer == foldsBeforeTX + 1,
        "TX edit must retain its operation cause and add one final fold; got "
        ~ txReplay.toString);
    auto mixedGeometry = vertices();
    auto mixedT = published("translate");
    auto mixedR = published("rotate");
    auto mixedS = published("scale");

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
    assert(undo[$ - 1]["label"].str == "Transform 8 verts",
        "task 4691 command label: expected 'Transform 8 verts', got "
        ~ undo[$ - 1]["label"].str);

    auto finalGeometry = vertices();
    auto finalT = published("translate");
    auto finalR = published("rotate");
    auto finalS = published("scale");
    immutable double[3] identityT = [0.0, 0.0, 0.0];
    immutable double[3] identityR = [0.0, 0.0, 0.0];
    immutable double[3] identityS = [1.0, 1.0, 1.0];
    assert(sameGeometry(finalGeometry, mixedGeometry) &&
           sameVec(finalT, identityT) && sameVec(finalR, identityR) &&
           sameVec(finalS, identityS),
        "Move relocate must preserve geometry and close the live region to identity TRS");

    // Preserve the existing non-symmetric history contract. Undo collapses
    // the live parameter region and never visits its held-Scale state; redo
    // replays the two accepted rows separately and does visit the Move state.
    cmd("history.undo"); settle();
    auto undo1Geometry = vertices();
    auto undo1T = published("translate");
    auto undo1R = published("rotate");
    auto undo1S = published("scale");
    assert(sameGeometry(undo1Geometry, postMove) &&
           sameVec(undo1T, identityT) && sameVec(undo1R, identityR) &&
           sameVec(undo1S, identityS),
        "first undo must remove the whole live SX/TX region without restoring held Scale");
    cmd("history.undo"); settle();
    auto undo2Geometry = vertices();
    auto undo2T = published("translate");
    auto undo2R = published("rotate");
    auto undo2S = published("scale");
    assert(sameGeometry(undo2Geometry, original) &&
           sameVec(undo2T, identityT) && sameVec(undo2R, identityR) &&
           sameVec(undo2S, identityS),
        "second undo must restore the geometry floor and keep identity TRS");
    cmd("history.redo"); settle();
    auto redo1Geometry = vertices();
    auto redo1T = published("translate");
    auto redo1R = published("rotate");
    auto redo1S = published("scale");
    assert(sameGeometry(redo1Geometry, postMove) &&
           sameVec(redo1T, postMoveT) && sameVec(redo1R, postMoveR) &&
           sameVec(redo1S, postMoveS),
        "first redo must replay the preceding Move row and its TRS");
    cmd("history.redo"); settle();
    auto redo2Geometry = vertices();
    auto redo2T = published("translate");
    auto redo2R = published("rotate");
    auto redo2S = published("scale");
    assert(sameGeometry(redo2Geometry, mixedGeometry) &&
           sameVec(redo2T, mixedT) && sameVec(redo2R, mixedR) &&
           sameVec(redo2S, mixedS),
        "second redo must restore final mixed geometry and TRS");

    cmd("tool.set Transform off");
}
