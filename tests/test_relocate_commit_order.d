// A production interactive numeric edit followed by an off-gizmo relocate
// press. The click log contains mouse-down only: no synthetic motion and no
// mouse-up can close the fresh relocate before Ctrl+Z is pressed WHILE the
// button is held.
//
// Law (slice M1a of doc/tool_session_model_plan_2026-09-24.md, R4.4; capture
// C-O5-relocate, verdict O5+beta, gap 304): a key pressed while a mouse button
// is held is dropped, so that Ctrl+Z does nothing — the pin stays at the new
// point and the numeric edit stays open. The relocate is not an undo row: the
// Ctrl+Z after the release pops the numeric edit AND the arm together (the tool
// ends), and the pin is NOT restored to the pre-relocate point. Only the
// held-key half and "the numeric edit is popped, no relocate row" are ours
// (M1a). Two halves are NOT yet, pinned below as OUR model so the slice that
// aligns them reddens here: our activation is its own row (H1, later slice),
// so the tool stays; and Move's numeric edit undo restores the pin frozen at
// the relocate press (Rotate and Scale keep it, as the reference; gap 304).

import core.thread : Thread;
import core.time : msecs;
import http_client : getJson, postJson, quiesce;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json : JSONType;
import std.math : fabs, sqrt;

import drag_helpers;

void main() {}

struct BankCase {
    string name;
    string tool;
    string channel;
    double value;
}


void settle() { quiesce(); }

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void interactiveCmd(string line) {
    auto r = postJson("/api/script?interactive=true", line ~ "\n");
    assert(r["status"].str == "ok",
        "interactive command '" ~ line ~ "' failed: " ~ r.toString);
}

long modelDepth() {
    return getJson("/api/undo/status")["modelDepth"].integer;
}

Vec3 readVec3(const ref typeof(getJson("/api/tool/state")) value) {
    auto a = value.array;
    return Vec3(cast(float)a[0].floating,
                cast(float)a[1].floating,
                cast(float)a[2].floating);
}

Vec3 publishedPivot() {
    return readVec3(getJson("/api/toolpipe/eval")["actionCenter"]["center"]);
}

double[3][] vertices() {
    double[3][] result;
    foreach (entry; getJson("/api/model")["vertices"].array) {
        auto a = entry.array;
        result ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return result;
}

bool close(Vec3 a, Vec3 b, float eps = 0.02f) {
    return fabs(a.x - b.x) <= eps && fabs(a.y - b.y) <= eps &&
           fabs(a.z - b.z) <= eps;
}

bool sameGeometry(double[3][] a, double[3][] b, double eps = 1e-4) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length)
        foreach (axis; 0 .. 3)
            if (fabs(a[i][axis] - b[i][axis]) > eps) return false;
    return true;
}

Vec3 bboxCenter(double[3][] verts) {
    assert(verts.length > 0, "bbox needs populated geometry");
    double[3] lo = verts[0], hi = verts[0];
    foreach (v; verts[1 .. $]) {
        foreach (axis; 0 .. 3) {
            if (v[axis] < lo[axis]) lo[axis] = v[axis];
            if (v[axis] > hi[axis]) hi[axis] = v[axis];
        }
    }
    return Vec3(cast(float)((lo[0] + hi[0]) * 0.5),
                cast(float)((lo[1] + hi[1]) * 0.5),
                cast(float)((lo[2] + hi[2]) * 0.5));
}

Vec3 screenRay(float sx, float sy, const ref Viewport vp) {
    float nx = ((sx - vp.x) / vp.width) * 2.0f - 1.0f;
    float ny = 1.0f - ((sy - vp.y) / vp.height) * 2.0f;
    float vx = nx / vp.proj[0];
    float vy = ny / vp.proj[5];
    const ref float[16] v = vp.view;
    Vec3 d = Vec3(v[0] * vx + v[1] * vy - v[2],
                  v[4] * vx + v[5] * vy - v[6],
                  v[8] * vx + v[9] * vy - v[10]);
    float len = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    assert(len > 1e-6f, "screen ray must be non-degenerate");
    return d / len;
}

Vec3 screenPlaneHit(int x, int y, Vec3 planePoint, const ref Viewport vp) {
    Vec3 dir = screenRay(cast(float)x, cast(float)y, vp);
    Vec3 normal = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    float denom = dot(normal, dir);
    assert(fabs(denom) > 1e-6f, "screen-plane ray must intersect");
    float t = dot(normal, planePoint - vp.eye) / denom;
    return vp.eye + dir * t;
}

string pressOnlyLog(CameraState cam, int x, int y) {
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, x, y);
}

string ctrlZLog() {
    return `{"t":0.000,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n" ~
           `{"t":10.000,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n";
}

string releaseLog(int x, int y) {
    return format(
        `{"t":0.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y);
}

void establishFloor() {
    foreach (tool; ["move", "rotate", "scale"])
        postJson("/api/script", "tool.set " ~ tool ~ " off");
    settle();
    postJson("/api/command", commandBody("scene.reset"));
    cmd("history.clear");
    cmd("mesh.move_vertex from:{-0.5,-0.5,-0.5} to:{-0.25,-0.5,-0.5}");
    assert(modelDepth() == 1,
        "history floor must contain exactly one model edit; got "
        ~ modelDepth().to!string);
}

unittest {
    immutable BankCase[] banks = [
        BankCase("move",   "move",   "TX", 0.35),
        BankCase("rotate", "rotate", "RZ", 30.0),
        BankCase("scale",  "scale",  "SX", 1.5),
    ];

    foreach (bank; banks) {
        establishFloor();
        immutable long floor = modelDepth();
        assert(floor > 0, bank.name ~ ": history floor must be nonzero");
        auto floorGeometry = vertices();

        cmd("tool.set " ~ bank.tool);
        cmd("actr.screen");
        cmd(`tool.pipe.attr actionCenter userPlacedCenter "0,0,0"`);
        settle();

        interactiveCmd(format("tool.attr %s %s %.9g",
                              bank.tool, bank.channel, bank.value));
        settle();
        auto numericGeometry = vertices();
        auto before = getJson("/api/tool/state");
        Vec3 oldPivot = publishedPivot();

        // Step 1: a production interactive numeric write really opened the
        // wrapper edit, changed geometry, and precedes a distinct target.
        assert(before["editOpen"].type == JSONType.true_,
            bank.name ~ ": interactive numeric edit must be open before relocate");
        assert(!sameGeometry(numericGeometry, floorGeometry),
            bank.name ~ ": interactive numeric edit must change geometry");
        assert(modelDepth() == floor,
            bank.name ~ ": open numeric edit must not record history; floor="
            ~ floor.to!string ~ " depth=" ~ modelDepth().to!string);

        auto cam = fetchCamera();
        auto vp = viewportFromCamera(cam);
        int clickX = cam.vpX + cast(int)(cam.width * 0.78);
        int clickY = cam.vpY + cast(int)(cam.height * 0.28);
        float oldX, oldY;
        assert(projectToWindow(oldPivot, vp, oldX, oldY),
            bank.name ~ ": old pivot must project into the viewport");
        float pixelDistance = sqrt((clickX - oldX) * (clickX - oldX) +
                                   (clickY - oldY) * (clickY - oldY));
        assert(pixelDistance > 180.0f,
            bank.name ~ ": relocate press must be well clear of every gizmo handle");
        Vec3 targetPivot = screenPlaneHit(clickX, clickY,
                                          bboxCenter(numericGeometry), vp);
        assert(!close(oldPivot, targetPivot, 0.1f),
            bank.name ~ ": oldPivot must differ from targetPivot");

        playAndWait(pressOnlyLog(cam, clickX, clickY));
        settle();

        // Step 2: prove the click was accepted before asking undo anything.
        auto afterPressEval = getJson("/api/toolpipe/eval");
        auto afterPressState = getJson("/api/tool/state");
        Vec3 published = readVec3(afterPressEval["actionCenter"]["center"]);
        Vec3 handler = readVec3(afterPressState["handlerPivot"]);
        assert(afterPressEval["actionCenter"]["isUserPlaced"].type == JSONType.true_,
            bank.name ~ ": off-gizmo press must publish a user-placed pin");
        assert(!close(published, oldPivot, 0.1f) && close(published, targetPivot),
            bank.name ~ ": published pin must move from oldPivot to targetPivot; old="
            ~ oldPivot.to!string ~ " target=" ~ targetPivot.to!string
            ~ " published=" ~ published.to!string);
        assert(!close(handler, oldPivot, 0.1f) && close(handler, targetPivot),
            bank.name ~ ": handler pivot must move from oldPivot to targetPivot; old="
            ~ oldPivot.to!string ~ " target=" ~ targetPivot.to!string
            ~ " handler=" ~ handler.to!string);
        assert(afterPressState["editOpen"].type == JSONType.true_,
            bank.name ~ ": relocate press without motion must leave its edit open");
        assert(afterPressState["activeBank"].str == bank.name,
            bank.name ~ ": relocate press reached wrong bank: "
            ~ afterPressState["activeBank"].str);
        immutable string armedTool = afterPressState["tool"].str;
        immutable long pressDepth = modelDepth();

        // Step 3: Ctrl+Z while the button is held is DROPPED. Asserted first,
        // so the half that must stay green stands above the one that moves.
        playAndWait(ctrlZLog());
        settle();
        auto heldEval = getJson("/api/toolpipe/eval");
        auto heldState = getJson("/api/tool/state");
        assert(close(readVec3(heldEval["actionCenter"]["center"]), targetPivot)
               && heldState["editOpen"].type == JSONType.true_
               && heldState["tool"].str == armedTool
               && sameGeometry(vertices(), numericGeometry)
               && modelDepth() == pressDepth,
            bank.name ~ ": Ctrl+Z while the button was held was not dropped; pin="
            ~ readVec3(heldEval["actionCenter"]["center"]).to!string
            ~ " target=" ~ targetPivot.to!string ~ " editOpen="
            ~ heldState["editOpen"].toString ~ " tool=" ~ heldState["tool"].toString
            ~ " depth=" ~ modelDepth().to!string ~ " at the press=" ~ pressDepth.to!string);

        // Step 4: release, then Ctrl+Z pops the numeric edit and the arm
        // together; the relocated pin is not an undo row, so it stays.
        playAndWait(releaseLog(clickX, clickY));
        settle();
        playAndWait(ctrlZLog());
        settle();
        auto afterState = getJson("/api/tool/state");
        immutable string toolAfter = ("tool" in afterState.object) ? afterState["tool"].str : "";
        assert(sameGeometry(vertices(), floorGeometry),
            bank.name ~ ": Ctrl+Z after the release did not pop the numeric edit");
        // The reference pops the ARM with that Ctrl+Z too (its activation row
        // joins the first group, H1). Ours keeps the activation as its own row
        // until the H1 slice lands, so the tool stays and that row is on top.
        // Pinned as OUR model so the H1 slice's flip is a visible red here.
        auto undoRows = getJson("/api/history")["undo"].array;
        assert(toolAfter == armedTool && undoRows.length > 0
               && undoRows[$ - 1]["command"].str == "tool.activate",
            bank.name ~ ": our model (activation is its own row until H1) changed; tool="
            ~ toolAfter ~ " top=" ~ (undoRows.length ? undoRows[$ - 1]["command"].str : "<none>"));
        assert(modelDepth() == floor,
            bank.name ~ ": the relocate or the numeric edit left a model row; floor="
            ~ floor.to!string ~ " depth=" ~ modelDepth().to!string);
        // The reference does NOT restore the pin here (the relocate is no undo
        // row). Rotate and Scale agree; Move does not yet: its numeric edit's
        // row carries the pin frozen at the relocate press and restores it
        // (gap 304, open residual). Pinned per bank as MEASURED so the slice
        // that aligns Move reddens here.
        Vec3 afterUndo = publishedPivot();
        immutable bool restored = close(afterUndo, oldPivot);
        immutable bool kept = close(afterUndo, targetPivot);
        assert(bank.name == "move" ? restored : kept,
            bank.name ~ ": the pin after Ctrl+Z changed from the measured model (move: restored, "
            ~ "a divergence; rotate/scale: kept, the reference); old=" ~ oldPivot.to!string
            ~ " target=" ~ targetPivot.to!string ~ " after=" ~ afterUndo.to!string);
    }

    foreach (tool; ["move", "rotate", "scale"])
        postJson("/api/script", "tool.set " ~ tool ~ " off");
    cmd("tool.pipe.attr actionCenter mode auto");
}
