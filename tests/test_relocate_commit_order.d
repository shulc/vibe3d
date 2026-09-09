// A production interactive numeric edit followed by an off-gizmo relocate
// must freeze the pre-relocate action-centre pin before the bank publishes the
// new one.  The click log contains mouse-down only: no synthetic motion and no
// mouse-up can close the fresh relocate edit before Ctrl+Z tests its baseline.

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

struct BankCase {
    string name;
    string tool;
    string channel;
    double value;
}

void settle() { Thread.sleep(120.msecs); }

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

string cancelAndReleaseLog(int x, int y) {
    return format(
        `{"t":0.000,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n" ~
        `{"t":10.000,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n" ~
        `{"t":20.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
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
        playAndWait(cancelAndReleaseLog(clickX, clickY));
        settle();

        // Step 3: only now judge Ctrl+Z.  It cancels the open, motionless
        // relocate while preserving the already-committed numeric geometry.
        Vec3 afterUndo = publishedPivot();
        assert(close(afterUndo, oldPivot),
            bank.name ~ ": Ctrl+Z must restore pre-relocate pivot; old="
            ~ oldPivot.to!string ~ " after=" ~ afterUndo.to!string);
        assert(sameGeometry(vertices(), numericGeometry),
            bank.name ~ ": Ctrl+Z must preserve committed numeric geometry");
        assert(modelDepth() == floor + 1,
            bank.name ~ ": Ctrl+Z must preserve committed numeric history above floor; floor="
            ~ floor.to!string ~ " depth=" ~ modelDepth().to!string);
    }
}
