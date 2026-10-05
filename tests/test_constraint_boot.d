// The remembered background constraint (task 9401): off at a scene reset,
// put into the pipe by a user tool drop, forgotten by the Escape clear and
// the toggle-off, remembered again by the toggle-on. Every step is a row of
// the captured fixture `fixtures/constraint_boot.json`; keys go through the
// production SDL route, settings through `tool.pipe.attr`.
module test_constraint_boot;

import drag_helpers : playAndWait;
import http_client : getJson, postJson, quiesce, frameFence;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json;
import std.string : indexOf;

void main() {}

private JSONValue fixtureRow(string list, string id) {
    static JSONValue cached;
    if (cached.type == JSONType.null_)
        cached = parseJSON(import("fixtures/constraint_boot.json"));
    auto rows = list == "drop_doors" ? cached[list]["cases"] : cached[list];
    foreach (c; rows.array)
        if (c["id"].str == id) return c;
    assert(0, "fixture row missing: " ~ list ~ " " ~ id);
}
private JSONValue fixtureCase(string id) { return fixtureRow("cases", id); }

private void cmd(string text) {
    const body_ = text[0] == '{' || text.indexOf(' ') >= 0 ? text : commandBody(text);
    auto answer = postJson("/api/command", body_);
    assert(answer["status"].str == "ok",
        format("command `%s` failed: %s", text, answer.toString));
    quiesce();
}

private void key(string name) {
    int sym, scan;
    final switch (name) {
        case "escape": sym = 27;  scan = 41; break;
        case "q":      sym = 113; scan = 20; break;   // tool.release (the drop key)
        case "w":      sym = 119; scan = 26; break;   // move
        case "e":      sym = 101; scan = 8;  break;   // rotate
        case "2":      sym = 50;  scan = 31; break;   // edges (selection type)
    }
    playAndWait(
        `{"t":0.000,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n" ~
        format(`{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":0,"repeat":0}`, sym, scan) ~ "\n" ~
        format(`{"t":100.000,"type":"SDL_KEYUP","sym":%d,"scan":%d,"mod":0,"repeat":0}`, sym, scan) ~ "\n");
    quiesce();
}

private JSONValue cons() {
    foreach (st; getJson("/api/toolpipe")["stages"].array)
        if (st["id"].str == "constrain") {
            const a = st["attrs"];
            JSONValue[string] o;
            o["enabled"] = a["enabled"].str == "true";
            o["geometry"] = a["geometry"].str;
            o["offset"] = a["offset"].str.to!double;
            o["handle"] = a["handle"].str == "true";
            o["double_sided"] = a["dblSided"].str == "true";
            return JSONValue(o);
        }
    assert(0, "constrain stage missing from /api/toolpipe");
}

private string tool() { return getJson("/api/input/context")["tool"].toString; }
private bool armed() { return tool() != "null" && tool() != `""`; }

/// One `drop_doors` door (task 9448) from the remembered-but-absent state,
/// with the move tool armed. Where the row drops the tool, ours must too.
private void crossDoor(string id, void delegate() gesture) {
    auto c = fixtureRow("drop_doors", id);
    assert(armed(), id ~ ": the rig armed no tool before the door");
    expect(id ~ " before", parseJSON(`{"enabled":false}`));
    gesture();
    assert(c["tool_armed_after"].boolean || !armed(), id ~ ": the door left " ~ tool() ~ " armed");
    expect(id, c["after"]);
}

private long selCount(string type) {
    const s = getJson("/api/selection");
    const k = type == "vertex" ? "selectedVertices" : "selectedFaces";
    return cast(long) s[k].array.length;
}

/// Every key the fixture row names must read as captured.
private void expect(string where, JSONValue want) {
    const got = cons();
    size_t n;
    foreach (k, v; want.object) {
        if ((k in got.object) is null) continue;   // gesture labels, selection counts
        ++n;
        assert(got[k] == v,
            format("%s: constraint %s want %s got %s (state %s)", where, k, v, got[k], got));
    }
    assert(n >= 1, where ~ ": fixture row compared no constraint field");
}

private void expectSel(string where, string type, JSONValue want) {
    const n = selCount(type);
    assert(n == want["selection_count"].integer,
        format("%s: %s selection want %s got %s", where, type,
            want["selection_count"].integer, n));
}

/// A fresh scene in polygon mode; `postFirstDrop` arms the move tool and drops
/// it with two key taps, as the capture's `post_first_drop` cells did.
private void boot(bool postFirstDrop) {
    cmd("scene.reset");
    cmd("history.clear");
    cmd("select.typeFrom polygon");
    expect("boot", parseJSON(`{"enabled":false,"geometry":"off"}`));
    if (!postFirstDrop) return;
    key("w");
    key("q");
    expect("first drop", fixtureCase("first-drop-move")["steps"][3]);
}

private void select(JSONValue sel) {
    const type = sel["type"].str;
    if (type == "vertex") {
        cmd("select.typeFrom vertex");
        cmd("select.element vertex set 0 1 2");
    } else cmd("select.element polygon set 0");
    assert(selCount(type) == sel["count"].integer, "rig selection: " ~ sel.toString);
}

private void setAttrs(JSONValue c) {
    if (("set" in c.object) is null) return;
    foreach (k, v; c["set"].object)
        cmd(format("tool.pipe.attr constrain %s %s", k, v.type == JSONType.string
            ? v.str : v.toString));
}

unittest {
    size_t ran;

    { // boot-escape: nothing held, Escape drops the selection
        auto c = fixtureCase("boot-escape");
        boot(false);
        select(c["selection"]);
        expect("boot-escape before", c["before"]);
        key("escape");
        expect("boot-escape", c["after"]);
        expectSel("boot-escape", "polygon", c["after"]);
        ++ran;
    }
    { // first-drop-move: arming adds nothing; the drop adds it; it stays
        auto s = fixtureCase("first-drop-move")["steps"];
        boot(false);
        expect("first-drop-move boot", s[0]);
        frameFence(null, 30);
        expect("first-drop-move wait", s[1]);
        key("w");
        expect("first-drop-move arm move", s[2]);
        key("q");
        expect("first-drop-move drop", s[3]);
        cmd("tool.set pen on");
        expect("first-drop-move arm pen", s[4]);
        key("q");
        expect("first-drop-move drop pen", s[5]);
        ++ran;
    }
    { // first-drop-primitive
        auto s = fixtureCase("first-drop-primitive")["steps"];
        boot(false);
        cmd("tool.set prim.sphere on");
        expect("first-drop-primitive arm", s[0]);
        key("q");
        expect("first-drop-primitive drop", s[1]);
        ++ran;
    }
    { // first-drop-pen
        auto s = fixtureCase("first-drop-pen")["steps"];
        boot(false);
        cmd("tool.set pen on");
        expect("first-drop-pen arm pen", s[0]);
        key("q");
        expect("first-drop-pen drop", s[1]);
        key("w");
        expect("first-drop-pen arm move", s[2]);
        ++ran;
    }
    { // first-drop-by-escape: the Escape that drops a tool is a drop
        auto s = fixtureCase("first-drop-by-escape")["steps"];
        boot(false);
        key("w");
        expect("first-drop-by-escape arm", s[0]);
        key("escape");
        assert(tool() == "null" || tool() == `""`, "Escape left a tool armed: " ~ tool());
        expect("first-drop-by-escape", s[1]);
        ++ran;
    }
    foreach (id; ["default-escape-polygon", "default-escape-vertex"]) {
        // an enabled constraint is a held task: Escape clears it, keeps the selection
        auto c = fixtureCase(id);
        boot(true);
        select(c["selection"]);
        expect(id ~ " before", c["before"]);
        key("escape");
        expect(id, c["after"]);
        expectSel(id, c["selection"]["type"].str, c["after"]);
        ++ran;
    }
    foreach (id; ["default-escape-twice", "point-escape-twice", "handle-off-escape-twice"]) {
        // whatever its settings; the second Escape drops the selection
        auto c = fixtureCase(id);
        boot(true);
        select(c["selection"]);
        setAttrs(c);
        foreach (i, want; c["after_each"].array) {
            key("escape");
            expect(format("%s escape %s", id, i + 1), want);
            expectSel(format("%s escape %s", id, i + 1), "polygon", want);
        }
        ++ran;
    }
    { // cleared-not-readded: once cleared, a later drop does not re-add it
        auto c = fixtureCase("cleared-not-readded");
        boot(true);
        select(c["selection"]);
        const steps = ["escape", "w", "q"];
        foreach (i, want; c["after_each"].array) {
            key(steps[i]);
            expect("cleared-not-readded " ~ steps[i], want);
        }
        ++ran;
    }
    { // cleared-point-not-readded
        auto c = fixtureCase("cleared-point-not-readded");
        boot(true);
        select(c["selection"]);
        setAttrs(c);
        foreach (k; ["escape", "w", "q"]) key(k);
        expect("cleared-point-not-readded", c["after"]);
        ++ran;
    }
    { // tool-switch-keeps-point: a user setting survives arm, drop, arm
        auto c = fixtureCase("tool-switch-keeps-point");
        boot(true);
        setAttrs(c);
        auto s = c["steps"];
        key("w");
        expect("tool-switch-keeps-point arm move", s[0]);
        key("q");
        expect("tool-switch-keeps-point drop", s[1]);
        cmd("tool.set pen on");
        expect("tool-switch-keeps-point arm pen", s[2]);
        ++ran;
    }
    { // same-tool-key (CD1): the tool's own key drops it and re-inserts
        boot(false);
        key("w");
        crossDoor("same-tool-key", () { key("w"); });
        ++ran;
    }
    { // seltype-key-flip (CD2): a selection-type key that flips the front type
        boot(false);
        cmd("select.typeFrom vertex");
        key("w");
        crossDoor("seltype-key-flip", () { key("2"); });
        ++ran;
    }
    { // primary-move-item-list (CD4): a primary move inserts nothing. Ours
      // drops the tool there (the reference keeps it armed, a separate gap)
        boot(false);
        cmd("layer.duplicate");
        key("w");
        crossDoor("primary-move-item-list", () {
            cmd(commandBody("layer.select", `{"index":0,"mode":"set"}`));
            assert(getJson("/api/layers")["active"].integer == 0, "the primary did not move");
        });
        ++ran;
    }
    { // scene-open-with-tool-armed (E8): opening a saved scene drops the tool,
      // which re-inserts the remembered constraint
        import std.file : tempDir;
        auto c = fixtureCase("scene-open-with-tool-armed");
        const path = tempDir ~ "/vibe3d_9402_open_seed.v3d";
        boot(false);
        cmd(commandBody("file.save", format(`{"path":%s}`, JSONValue(path))));
        key("w");
        assert(armed(), "scene-open: the rig armed no tool");
        expect("scene-open before", c["before"]);
        cmd(commandBody("file.load", format(`{"path":%s}`, JSONValue(path))));
        assert(armed() == c["after_tool_armed"].boolean, "scene-open: tool armed " ~ tool());
        expect("scene-open-with-tool-armed", c["after"]);
        ++ran;
    }
    { // attr-enabled-forgets-remembers: the panel's Enabled row is the
      // toggle's twin (toggle-off-ends rows)
        auto c = fixtureCase("toggle-off-ends");
        boot(true);
        cmd("tool.pipe.attr constrain enabled false");
        key("w");
        expect("attr-enabled off arm", c["after_toggle_off"]);
        key("q");
        expect("attr-enabled off drop", c["after"]);
        cmd("tool.pipe.attr constrain enabled true");
        key("w");
        key("q");
        expect("attr-enabled on drop", c["after_retoggle"]["after_move_drop"]);
        ++ran;
    }
    { // cleared-unlocks: the Escape clear also drops the settings lock, so a
      // tool's own composition (the topology pen's point mode) applies again
        boot(true);
        cmd("tool.pipe.attr constrain geometry point");   // locks while enabled
        key("escape");
        expect("cleared-unlocks clear", parseJSON(`{"enabled":false,"geometry":"point"}`));
        cmd("tool.set mesh.topoPen on");
        expect("cleared-unlocks topology pen", parseJSON(`{"enabled":true,"geometry":"point"}`));
        key("q");
        expect("cleared-unlocks drop", fixtureCase("cleared-not-readded")["after_each"][2]);
        ++ran;
    }
    { // forgotten-pen-attr-drop (review blocker): a user attr write on the
      // topology pen's own point constraint locks it while the constraint is
      // forgotten; the drop must not disable a locked stage, so the pen
      // re-arms with its constraint (base behaviour: enabled at re-arm)
        boot(false);
        cmd("constrain.toggle");
        cmd("constrain.toggle");   // on, then off: forgotten
        cmd("tool.set mesh.topoPen on");
        expect("forgotten-pen-attr-drop arm", parseJSON(`{"enabled":true,"geometry":"point"}`));
        cmd("tool.pipe.attr constrain offset 0.1");
        key("q");
        cmd("tool.set mesh.topoPen on");
        expect("forgotten-pen-attr-drop re-arm", parseJSON(`{"enabled":true,"geometry":"point"}`));
        ++ran;
    }
    { // load-no-tool-no-seed: a scene load with no tool armed drops nothing
      // and inserts nothing (captured scene-open-no-tool)
        auto c = fixtureCase("scene-open-no-tool");
        boot(false);
        auto r = postJson("/api/command", commandBody("scene.loadMesh",
            `{"vertices":[[0,0,0],[1,0,0],[0,0,1]],"faces":[[0,1,2]]}`));
        assert(r["status"].str == "ok", "scene.loadMesh: " ~ r.toString);
        quiesce();
        expect("load-no-tool-no-seed", c["after"]);
        key("w");
        key("q");
        expect("load-no-tool-no-seed drop", c["after_extra_move_arm_drop"]);
        ++ran;
    }
    { // switch-not-a-drop: arming over an armed tool inserts nothing
        auto c = fixtureCase("switch-no-seed");
        boot(false);
        key("w");
        key("e");
        expect("switch-not-a-drop after switch", c["after"]);
        cmd("tool.set pen on");
        expect("switch-not-a-drop arm pen", c["after_pen"]["constraint"]);
        key("q");
        expect("switch-not-a-drop drop", c["after_drop"]["constraint"]);
        ++ran;
    }
    { // api-reset-after-armed: the scene reset wipes a drop's seeding; the
      // constraint is remembered again, so the next drop adds it
        boot(false);
        key("w");
        cmd("scene.reset");
        expect("api-reset-after-armed reset", parseJSON(`{"enabled":false,"geometry":"off","handle":true}`));
        key("w");
        key("q");
        expect("api-reset-after-armed drop", fixtureCase("first-drop-move")["steps"][3]);
        ++ran;
    }
    { // toggle-off-forgets
        auto c = fixtureCase("toggle-off-ends");
        boot(true);
        expect("toggle-off-forgets before", c["before"]);
        cmd("constrain.toggle");
        expect("toggle-off-forgets toggle", c["after_toggle_off"]);
        key("w");
        key("q");
        expect("toggle-off-forgets drop", c["after"]);
        ++ran;
    }
    { // toggle-on-remembers
        auto c = fixtureCase("toggle-off-ends")["after_retoggle"];
        boot(true);
        cmd("constrain.toggle");
        cmd("constrain.toggle");
        expect("toggle-on-remembers toggle", c["constraint"]);
        key("w");
        key("q");
        expect("toggle-on-remembers drop", c["after_move_drop"]);
        ++ran;
    }
    { // toggle-at-boot: the toggle-on's settings are the defaults
        auto c = fixtureCase("toggle-on-at-boot");
        boot(false);
        cmd("constrain.toggle");
        expect("toggle-at-boot", c["after"]);
        key("w");
        key("q");
        expect("toggle-at-boot drop", c["after_drop"]["constraint"]);
        ++ran;
    }
    { // toggle-keeps-values: toggle-off keeps the settings
        auto c = fixtureCase("toggle-on-keeps-session-value");
        boot(false);
        cmd("constrain.toggle");
        cmd("tool.pipe.attr constrain geometry point");
        expect("toggle-keeps-values set", c["after_set"]);
        cmd("constrain.toggle");
        expect("toggle-keeps-values off", c["after_toggle_off"]);
        cmd("constrain.toggle");
        expect("toggle-keeps-values on", c["after"]);
        ++ran;
    }

    assert(ran == 27, format("constraint boot cells: ran %s, expected 27", ran));
}
