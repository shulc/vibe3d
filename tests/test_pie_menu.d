module test_pie_menu;

import core.thread : Thread;
import core.time : dur;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json : JSONType;
import std.process : environment;
import std.math : fabs, sqrt;
import drag_helpers : Vec3, fetchCamera, viewportFromCamera, projectToWindow,
    fetchHandlePart, vertexPos;

void main() {}

enum CX = 475, CY = 330, AIM = 80;
enum SYM_LCTRL = 1073742048;
enum HEADER = `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}`;

bool cell(string name) {
    auto only = environment.get("VIBE3D_PIE_CELL", "");
    return only.length == 0 || only == name;
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
           line ~ " failed: " ~ r.toString);
}

void play(string[] events) {
    string log = HEADER ~ "\n";
    foreach (e; events) log ~= e ~ "\n";
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", r.toString);
    for (int i; i < 300; ++i) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.TRUE) {
            Thread.sleep(dur!"msecs"(35));
            return;
        }
        Thread.sleep(dur!"msecs"(10));
    }
    assert(false, "playback did not finish");
}

string motion(int x, int y, int t = 5, int state = 0, int mod = 0) {
    return format(`{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":%d}`,
                  t, x, y, state, mod);
}
string dragMotion(int x, int y, int xrel, int yrel, int t, int mod = 0) {
    return format(`{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":%d}`,
                  t, x, y, xrel, yrel, mod);
}
string keyDown(int sym, int scan, int mod, uint ts, int repeat = 0, int t = 10) {
    return format(`{"t":%d,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":%d,"repeat":%d,"ts":%u}`,
                  t, sym, scan, mod, repeat, ts);
}
string keyUp(int sym, int scan, int mod, uint ts, int t = 20,
             int focus = 1) {
    return format(`{"t":%d,"type":"SDL_KEYUP","sym":%d,"scan":%d,"mod":%d,"repeat":0,"ts":%u,"focus":%d}`,
                  t, sym, scan, mod, ts, focus);
}
string button(int btn, bool down, int x, int y, int t = 20, int mod = 0) {
    return format(`{"t":%d,"type":"SDL_MOUSEBUTTON%s","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":%d}`,
                  t, down ? "DOWN" : "UP", btn, x, y, mod);
}
string wheel(int y, int t = 20) {
    return format(`{"t":%d,"type":"SDL_MOUSEWHEEL","x":0,"y":%d}`, t, y);
}

void resetScene() {
    cmd(commandBody("scene.reset", "{}"));
    cmd("prim.cube");
    cmd("viewport.view Perspective");
    cmd("select.typeFrom polygon");
}
void openAndAim(int x, int y) {
    play([motion(CX, CY, 1), keyDown(32, 44, 64, 1000, 0, 2), motion(x, y, 3)]);
    assert(getJson("/api/pie")["open"].boolean, "setup: pie did not open");
}
string preset() { return getJson("/api/camera?viewport=0")["viewPreset"].str; }
size_t historyLen() { return getJson("/api/history")["undo"].array.length; }
string tool() { return getJson("/api/input/context")["tool"].str; }

unittest { // L4: DOWN is inert; left UP executes the stored hover
    if (!cell("L4")) return;
    resetScene(); openAndAim(CX + AIM, CY);
    play([button(1, true, CX + AIM, CY)]);
    assert(getJson("/api/pie")["open"].boolean && preset() == "Perspective");
    play([button(1, false, CX + AIM, CY)]);
    assert(!getJson("/api/pie")["open"].boolean && preset() == "Right");
}

unittest { // L5: right UP executes
    if (!cell("L5")) return;
    resetScene(); openAndAim(CX, CY + AIM);
    play([button(3, true, CX, CY + AIM), button(3, false, CX, CY + AIM, 21)]);
    assert(preset() == "Bottom", "L5 right release did not run Bottom");
}

unittest { // L6: middle UP executes
    if (!cell("L6")) return;
    resetScene(); openAndAim(CX - AIM, CY);
    play([button(2, true, CX - AIM, CY), button(2, false, CX - AIM, CY, 21)]);
    assert(preset() == "Left", "L6 middle release did not run Left");
}

unittest { // L7: release in the dead zone closes without side effects
    if (!cell("L7")) return;
    resetScene(); immutable before = historyLen(); openAndAim(CX, CY);
    play([button(1, true, CX, CY), button(1, false, CX, CY, 21)]);
    assert(preset() == "Perspective" && historyLen() == before
           && !getJson("/api/pie")["open"].boolean);
}

unittest { // L8: UP coordinates do not re-aim
    if (!cell("L8")) return;
    resetScene(); openAndAim(CX + AIM, CY);
    play([button(1, true, CX + AIM, CY), button(1, false, CX, CY - AIM, 21)]);
    assert(preset() == "Right", "L8 release coordinates re-aimed the pie");
}

unittest { // L9: wheel is swallowed while open
    if (!cell("L9")) return;
    resetScene();
    play([motion(CX, CY), wheel(3), wheel(3, 30)]);
    assert(getJson("/api/camera?viewport=0")["distance"].floating != 3.0,
           "L9 control wheel did not zoom");
    resetScene(); openAndAim(CX, CY);
    play([wheel(3), wheel(3, 30)]);
    assert(getJson("/api/camera?viewport=0")["distance"].floating == 3.0
           && getJson("/api/pie")["open"].boolean, "L9 wheel leaked through pie");
    play([button(1, false, CX, CY)]);
}

unittest { // L10: a bound key down is swallowed; its later up closes
    if (!cell("L10")) return;
    resetScene(); openAndAim(CX, CY);
    play([keyDown(119, 26, 0, 1200)]); // W -> move
    assert(getJson("/api/pie")["open"].boolean && tool() != "move",
        "L10 bound W keydown escaped the modal pie");
    play([keyUp(119, 26, 0, 1300)]);
    assert(!getJson("/api/pie")["open"].boolean && tool() != "move",
        "L10 W release did not close inertly");
}

unittest { // L11: held chord release runs from event time in one <=20ms play
    if (!cell("L11")) return;
    resetScene();
    play([motion(CX, CY, 1), keyDown(32, 44, 64, 1000, 0, 2),
          motion(CX, CY - AIM, 3), keyUp(32, 44, 64, 1300, 20)]);
    assert(preset() == "Top" && !getJson("/api/pie")["open"].boolean);
}

unittest { // L12: releasing Ctrl first runs; tail Space repeats are inert
    if (!cell("L12")) return;
    resetScene(); cmd("tool.set TransformMove on"); openAndAim(CX - AIM, CY);
    immutable before = historyLen();
    play([keyUp(SYM_LCTRL, 224, 64, 1300)]);
    assert(preset() == "Left");
    play([keyDown(32, 44, 0, 1500, 1), keyDown(32, 44, 0, 1540, 1, 20)]);
    assert(!getJson("/api/pie")["open"].boolean && preset() == "Left"
           && historyLen() == before && tool() == "TransformMove");
}

unittest { // L13: a foreign special-key release commits the hover
    if (!cell("L13")) return;
    resetScene(); openAndAim(CX + AIM, CY);
    play([keyDown(9, 43, 0, 1150), keyUp(9, 43, 0, 1300, 20)]); // Tab
    assert(preset() == "Right" && !getJson("/api/pie")["open"].boolean);
}

unittest { // L13b: a printable letter release also commits the hover
    if (!cell("L13b")) return;
    resetScene(); openAndAim(CX + AIM, CY);
    play([keyDown(97, 4, 0, 1150), keyUp(97, 4, 0, 1300, 20)]);
    assert(preset() == "Right" && !getJson("/api/pie")["open"].boolean,
        "L13b letter release did not run the hovered pie");
}

unittest { // L14: Escape down is modal; Escape up commits
    if (!cell("L14")) return;
    resetScene(); cmd("tool.set TransformMove on"); openAndAim(CX, CY + AIM);
    play([keyDown(27, 41, 0, 1200)]);
    assert(getJson("/api/pie")["open"].boolean && tool() == "TransformMove");
    play([keyUp(27, 41, 0, 1300)]);
    assert(preset() == "Bottom" && tool() == "TransformMove");
}

unittest { // L15/L15b: tap stays open; a later special-key UP runs
    if (!cell("L15")) return;
    resetScene();
    play([motion(CX, CY, 1), keyDown(32, 44, 64, 1000, 0, 2),
          motion(CX + AIM, CY, 3), keyUp(32, 44, 64, 1012, 400)]);
    assert(getJson("/api/pie")["open"].boolean
           && getJson("/api/pie")["boxes"].array.length == 7);
    play([keyDown(1073741886, 62, 0, 1200),
          keyUp(1073741886, 62, 0, 1300, 20)]); // F5
    assert(preset() == "Right" && !getJson("/api/pie")["open"].boolean);
}

unittest { // L16: held release in the dead zone runs nothing
    if (!cell("L16")) return;
    resetScene(); immutable before = historyLen(); openAndAim(CX, CY);
    play([keyUp(32, 44, 64, 1300)]);
    assert(preset() == "Perspective" && historyLen() == before
           && !getJson("/api/pie")["open"].boolean);
}

unittest { // L17/L25: repeat and fresh keydown are swallowed while open
    if (!cell("L17")) return;
    resetScene(); openAndAim(CX + AIM, CY);
    auto before = getJson("/api/pie");
    play([keyDown(32, 44, 64, 1100, 1), keyDown(32, 44, 64, 1140, 1, 20),
          keyDown(32, 44, 64, 1180, 0, 30)]);
    auto after = getJson("/api/pie");
    assert(after["open"].boolean && after["cx"].integer == before["cx"].integer
           && after["cy"].integer == before["cy"].integer
           && after["hover"].integer == before["hover"].integer);
    play([button(1, false, CX + AIM, CY)]);
}

unittest { // L18/L18c: mouse close latches repeats and tail releases
    if (!cell("L18")) return;
    resetScene(); openAndAim(CX, CY - AIM);
    play([button(1, true, CX, CY - AIM), button(1, false, CX, CY - AIM, 21)]);
    assert(preset() == "Top" && !getJson("/api/pie")["open"].boolean);
    immutable before = historyLen();
    play([keyDown(32, 44, 64, 1500, 1), keyDown(32, 44, 64, 1540, 1, 20),
          keyDown(32, 44, 64, 1580, 1, 30)]);
    assert(!getJson("/api/pie")["open"].boolean);
    play([keyUp(32, 44, 64, 1700), keyUp(SYM_LCTRL, 224, 0, 1720, 20)]);
    assert(preset() == "Top" && historyLen() == before);
}

unittest { // L18b: foreign special-key close latches chord repeats
    if (!cell("L18b")) return;
    resetScene(); openAndAim(CX + AIM, CY);
    play([keyDown(9, 43, 0, 1150), keyUp(9, 43, 0, 1300, 20)]);
    assert(preset() == "Right");
    play([keyDown(32, 44, 64, 1500, 1), keyDown(32, 44, 64, 1540, 1, 20)]);
    assert(!getJson("/api/pie")["open"].boolean && preset() == "Right");
}

unittest { // L18d: mouse-close latch swallows an unrelated W autorepeat
    if (!cell("L18d")) return;
    resetScene(); cmd("tool.set move off");
    assert(tool() != "move", "L18d setup left move active");
    openAndAim(CX, CY);
    play([button(1, true, CX, CY), button(1, false, CX, CY, 21)]);
    assert(!getJson("/api/pie")["open"].boolean && tool() != "move",
        "L18d mouse release did not close inertly");
    play([keyDown(119, 26, 0, 1500, 1)]);
    assert(tool() != "move", "L18d post-close W autorepeat activated move");
    play([keyDown(119, 26, 0, 1540, 0)]);
    assert(tool() == "move", "L18d fresh W control did not activate move");
    cmd("tool.set move off");
}

unittest { // L19: the modal press/release cannot reach picking
    if (!cell("L19")) return;
    resetScene();
    play([motion(CX, 300), button(1, true, CX, 300), button(1, false, CX, 300, 21)]);
    assert(getJson("/api/selection")["selectedFaces"].array.length == 1,
           "L19 control click missed the cube");
    cmd("select.drop");
    openAndAim(CX, 300);
    play([button(1, true, CX, 300), button(1, false, CX, 300, 21)]);
    assert(getJson("/api/selection")["selectedFaces"].array.length == 0,
           "L19 pie press leaked to picking");
}

unittest { // L22: focus loss closes without running the hovered item
    if (!cell("L22")) return;
    resetScene(); openAndAim(CX, CY - AIM);
    play([keyUp(32, 44, 64, 1300, 20, 0),
          keyUp(SYM_LCTRL, 224, 0, 1300, 20, 0),
          `{"t":20,"type":"SDL_WINDOWEVENT","sub":13}`]);
    assert(!getJson("/api/pie")["open"].boolean && preset() == "Perspective",
        "L22 focus-reset keyups ran the hovered pie before focus loss");
}

unittest { // L22b: the same focused releases are genuine and run the item
    if (!cell("L22b")) return;
    resetScene(); openAndAim(CX, CY - AIM);
    play([keyUp(32, 44, 64, 1300, 20, 1),
          keyUp(SYM_LCTRL, 224, 0, 1300, 20, 1),
          `{"t":20,"type":"SDL_WINDOWEVENT","sub":13}`]);
    assert(!getJson("/api/pie")["open"].boolean && preset() == "Top",
        "L22b focused release did not run the hovered pie");
}

unittest { // Ctrl-sync: the consumed Ctrl-first release still reaches ImGui
    if (!cell("Ctrl-sync")) return;
    resetScene(); openAndAim(CX - AIM, CY);
    assert(getJson("/api/pie")["imguiCtrl"].boolean,
        "Ctrl-sync setup did not raise ImGui Ctrl");
    play([keyUp(SYM_LCTRL, 224, 0, 1300, 20, 1)]);
    auto after = getJson("/api/pie");
    assert(!after["open"].boolean && preset() == "Left",
        "Ctrl-sync control release did not close and run");
    assert(!after["imguiCtrl"].boolean,
        "Ctrl-sync closing release left ImGui Ctrl held");
}

unittest { // ImGui-reset: replay focus loss and automation reset release Ctrl
    if (!cell("ImGui-reset")) return;
    resetScene();
    play([keyDown(SYM_LCTRL, 224, 64, 1000)]);
    assert(getJson("/api/pie")["imguiCtrl"].boolean,
        "ImGui-reset setup did not raise Ctrl before focus loss");
    play([`{"t":20,"type":"SDL_WINDOWEVENT","sub":13}`]);
    assert(!getJson("/api/pie")["imguiCtrl"].boolean,
        "ImGui-reset replayed focus loss left Ctrl held");

    play([`{"t":20,"type":"SDL_WINDOWEVENT","sub":12}`,
          keyDown(SYM_LCTRL, 224, 64, 2000, 0, 21)]);
    assert(getJson("/api/pie")["imguiCtrl"].boolean,
        "ImGui-reset setup did not re-raise Ctrl before reset");
    cmd(commandBody("scene.reset", "{}"));
    Thread.sleep(dur!"msecs"(35));
    assert(!getJson("/api/pie")["imguiCtrl"].boolean,
        "ImGui-reset scene reset left replayed Ctrl held");
}

unittest { // RV2P1: a fresh press after release sees the already-closed pie
    if (!cell("RV2P1")) return;
    resetScene(); cmd("tool.set move off");
    assert(tool() != "move", "RV2P1 setup left move active");
    openAndAim(CX, CY - AIM);
    play([keyUp(32, 44, 64, 1300, 20),
          keyDown(119, 26, 0, 1310, 0, 20)]);
    assert(preset() == "Top" && !getJson("/api/pie")["open"].boolean,
        "RV2P1 control: key-up did not close and run");
    assert(tool() == "move",
        "RV2P1 same-batch fresh W press was swallowed by the closing pie");
    cmd("tool.set move off");
}

unittest { // RV2P2: later motion/release cannot change the release-time hover
    if (!cell("RV2P2")) return;
    resetScene(); openAndAim(CX, CY - AIM);
    play([keyUp(32, 44, 64, 1300, 20), motion(CX + AIM, CY, 20),
          button(1, false, CX + AIM, CY, 20)]);
    assert(!getJson("/api/pie")["open"].boolean,
        "RV2P2 control: pie did not close");
    assert(preset() == "Top",
        "RV2P2 same-batch mouse release ran re-aimed slot " ~ preset());
}

unittest { // RV3P4: scene reset clears a close latch created by an open pie
    if (!cell("RV3P4")) return;
    resetScene(); openAndAim(CX, CY);
    cmd(commandBody("scene.reset", "{}"));
    cmd("tool.set move off");
    assert(!getJson("/api/pie")["open"].boolean && tool() != "move",
        "RV3P4 reset did not close the setup pie");
    play([keyDown(119, 26, 0, 6000, 1)]);
    assert(tool() == "move",
        "RV3P4 reset leaked the prior pie's post-close latch");
    cmd("tool.set move off");
}

unittest { // L20: the modal drag cannot orbit the camera
    if (!cell("L20")) return;
    resetScene();
    immutable before = getJson("/api/camera?viewport=0")["azimuth"].floating;
    play([motion(CX, CY, 1), button(1, true, CX, CY, 2, 256),
          dragMotion(CX + 20, CY, 20, 0, 3, 256),
          button(1, false, CX + 20, CY, 4, 256)]);
    immutable changed = getJson("/api/camera?viewport=0")["azimuth"].floating;
    assert(fabs(changed - before) > 1e-4, "L20 control orbit did not move camera");
    resetScene(); openAndAim(CX, CY);
    immutable guarded = getJson("/api/camera?viewport=0")["azimuth"].floating;
    play([button(1, true, CX, CY, 2, 256),
          dragMotion(CX + 15, CY, 15, 0, 3, 256),
          button(1, false, CX + 15, CY, 4, 256)]);
    immutable after = getJson("/api/camera?viewport=0")["azimuth"].floating;
    assert(fabs(after - guarded) < 1e-6 && !getJson("/api/pie")["open"].boolean,
           "L20 pie drag leaked to camera orbit");
}

unittest { // L21: the modal drag cannot reach an armed move handle
    if (!cell("L21")) return;
    void setupMove() {
        resetScene();
        cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[6]}`));
        auto r = postJson("/api/script", "tool.set move");
        assert(r["status"].str == "ok", r.toString);
        Thread.sleep(dur!"msecs"(150));
    }
    setupMove();
    double hx, hy; bool found;
    fetchHandlePart(0, hx, hy, found);
    assert(found, "L21 move-handle control has no part 0");
    auto cam = fetchCamera();
    auto vp = viewportFromCamera(cam);
    float sx0, sy0, sx1, sy1;
    assert(projectToWindow(Vec3(0.5f, 0.5f, 0.5f), vp, sx0, sy0));
    assert(projectToWindow(Vec3(1.5f, 0.5f, 0.5f), vp, sx1, sy1));
    immutable double len = sqrt((sx1 - sx0) * (sx1 - sx0) + (sy1 - sy0) * (sy1 - sy0));
    immutable int dx = cast(int)(15.0 * (sx1 - sx0) / len);
    immutable int dy = cast(int)(15.0 * (sy1 - sy0) / len);
    immutable int x0 = cast(int)hx, y0 = cast(int)hy;
    auto pre = vertexPos(6);
    play([motion(x0, y0, 1), button(1, true, x0, y0, 2),
          dragMotion(x0 + dx, y0 + dy, dx, dy, 3),
          button(1, false, x0 + dx, y0 + dy, 4)]);
    auto moved = vertexPos(6);
    assert(fabs(moved[0] - pre[0]) > 1e-4, "L21 control move drag had no effect");

    setupMove();
    fetchHandlePart(0, hx, hy, found);
    assert(found);
    auto held = vertexPos(6);
    immutable int px = cast(int)hx, py = cast(int)hy;
    play([motion(px, py, 1), keyDown(32, 44, 64, 1000, 0, 2)]);
    assert(getJson("/api/pie")["open"].boolean, "L21 pie did not open over handle");
    play([button(1, true, px, py, 2), dragMotion(px + dx, py + dy, dx, dy, 3),
          button(1, false, px + dx, py + dy, 4)]);
    auto after = vertexPos(6);
    foreach (i; 0 .. 3)
        assert(fabs(after[i] - held[i]) < 1e-6, "L21 pie drag moved selected vertex");
}
