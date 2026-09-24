// The hide family on the Viewport tab (wave bugfix S13, item 20).
//
// Law (fixture `delete_makepoly_lasso_hide_keys.json`, section
// `hide_family`): four component actions in menu order Hide Selected /
// Hide Unselected / Hide Invert / Unhide, each ONE undo step that restores
// the selection too. Owner's decisions: the four sit on the Viewport tab
// after Fit / Fit Selected under the reference's labels; the Visibility
// group's "Isolate" is renamed "Hide Unselected"; Hide Invert's undo keeps
// OUR correct restore (the reference restores nothing hidden — its defect).
//
// Two parts, order load-bearing:
//   1. behaviour, driven by the KEYS (real SDL events through
//      /api/play-events) — parity, expected GREEN before and after the fix;
//   2. the buttons, read through the PRODUCTION loader `loadButtons` over
//      config/buttons.yaml — not /api/buttons/availability, which records
//      only DRAWN buttons with no tab name, so "no row" there cannot tell
//      "missing" from "tab not open". RED before the fix at
//      "viewport tab lacks mesh.hide".
// Clicking a button is out of reach of the suite (no HTTP door to the
// panel's dispatch); that is the live check.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import buttonset : loadButtons, Panel, PanelItem, Group, Button, ActionKind;
import std.json;
import std.format : format;
import std.conv : to;
import std.algorithm : sort;
import core.thread : Thread;
import core.time : msecs;

void main() {}

enum string kFixture = import("fixtures/delete_makepoly_lasso_hide_keys.json");

enum SDLK_h      = 104;
enum SDLK_u      = 117;
enum SDLK_z      = 122;
enum KMOD_NONE   = 0;
enum KMOD_LSHIFT = 1;
enum KMOD_LCTRL  = 64;

enum string LOG_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1.0,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2.0,"type":"SDL_WINDOWEVENT","sub":3}`;

/// One row of the family: fixture action name → our command, its key and
/// the reference label the owner asked for, in the fixture's menu order.
struct Member { string action; string id; int sym; int mod; string label; }
immutable Member[] kFamily = [
    Member("hide_selected",   "mesh.hide",           SDLK_h, KMOD_NONE,   "Hide Selected"),
    Member("hide_unselected", "mesh.hideUnselected", SDLK_h, KMOD_LSHIFT, "Hide Unselected"),
    Member("hide_invert",     "mesh.hideInvert",     SDLK_h, KMOD_LCTRL,  "Hide Invert"),
    Member("unhide_all",      "mesh.unhideAll",      SDLK_u, KMOD_NONE,   "Unhide"),
];

JSONValue family() { return parseJSON(kFixture)["hide_family"]; }

void ok(JSONValue r, string what) {
    assert(r["status"].str == "ok", what ~ " failed: " ~ r.toString);
}

void waitPlaybackFinish() {
    foreach (_; 0 .. 100) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "playback didn't finish within 5s");
}

void pressKey(int sym, int mod) {
    auto log = LOG_HEADER ~ "\n" ~ format(
        `{"t":50,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
      ~ `{"t":60,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
        sym, mod, sym, mod);
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", "/api/play-events failed: " ~ r.toString);
    waitPlaybackFinish();
}

int[] ints(JSONValue a) {
    int[] r;
    foreach (v; a.array) r ~= cast(int) v.integer;
    r.sort();
    return r;
}

int[][] ints2(JSONValue a) {
    int[][] r;
    foreach (row; a.array) {
        int[] x;
        foreach (v; row.array) x ~= cast(int) v.integer;
        r ~= x;
    }
    return r;
}

int[] hiddenPolys() {
    int[] r;
    foreach (i, b; getJson("/api/model")["faceHidden"].array)
        if (b.type == JSONType.true_) r ~= cast(int) i;
    return r;
}

int[] selectedPolys() { return ints(getJson("/api/selection")["selectedFaces"]); }

size_t undoDepth() { return getJson("/api/history")["undo"].array.length; }

void selectPolys(int[] idx) {
    ok(postJson("/api/command", commandBody("mesh.select",
        `{"mode":"polygons","indices":` ~ idx.to!string ~ `}`)), "mesh.select");
}

/// Load the fixture cube (its own vertex and polygon order — ours differs),
/// polygon mode, apply the cell's `before` (hidden set, then selection) and
/// clear history, so one Ctrl+Z can only undo the key under test.
void rig(JSONValue c) {
    auto rg = parseJSON(kFixture)["rigs"][c["rig"].str];
    auto body = JSONValue.emptyObject;
    body["vertices"] = rg["vertices"];
    body["faces"] = rg["polygons"];
    ok(postJson("/api/command", commandBody("scene.reset")), "scene.reset");
    ok(postJson("/api/command", commandBody("scene.loadMesh", body.toString)), "scene.loadMesh");
    ok(postJson("/api/command", "select.typeFrom polygon"), "select.typeFrom polygon");
    auto before = c["before"];
    auto hide = ints(before["hidden_polygons"]);
    if (hide.length) {
        selectPolys(hide);
        ok(postJson("/api/command", "mesh.hide"), "mesh.hide (rig)");
    }
    selectPolys(ints(before["selected"]["polygons"]));
    ok(postJson("/api/command", `{"id":"history.clear"}`), "history.clear");

    auto m = getJson("/api/model");
    assert(m["faceCount"].integer == 6 && before["polygon_count"].integer == 6,
        "rig: the cube must have 6 polygons, got " ~ m["faceCount"].toString);
    assert(ints2(m["faces"]) == ints2(rg["polygons"]),
        "rig: loaded polygon order is not the fixture's — indices would not mean the same faces");
    assert(hiddenPolys() == hide && selectedPolys() == ints(before["selected"]["polygons"]),
        format("rig: before state not applied (hidden %s, selected %s)",
               hiddenPolys(), selectedPolys()));
    assert(undoDepth() == 0, "rig: history not cleared before the key");
}

/// Hidden and selected polygons against a fixture stage (or an override).
void expectStage(string cellName, string stage, int[] wantHidden, int[] wantSel,
                 string note = "") {
    auto gh = hiddenPolys();
    auto gs = selectedPolys();
    assert(gh == wantHidden && gs == wantSel,
        format("%s %s differs from the reference%s: hidden %s selected %s, want hidden %s selected %s",
               cellName, stage, note, gh, gs, wantHidden, wantSel));
}

// ---------------------------------------------------------------------------
// Part 1 — behaviour through the keys (parity; GREEN on HEAD). A red here is
// a semantics divergence (PLAN-FINDING), not something to silence.
// ---------------------------------------------------------------------------
unittest {
    auto fam = family();
    string[] order;
    foreach (v; fam["menu_order"].array) order ~= v.str;
    string[] ours;
    foreach (mb; kFamily) ours ~= mb.action;
    assert(order == ours, "fixture menu_order changed: " ~ order.to!string);

    immutable cells = ["t-hs", "t-hu", "t-hi", "t-un"];
    assert(fam["cells"].object.length == cells.length,
        "fixture hide_family cell population changed: " ~ fam["cells"].object.keys.to!string);

    size_t stagesCompared = 0;
    foreach (name; cells) {
        auto c = fam["cells"][name];
        Member mb;
        foreach (x; kFamily) if (x.action == c["action"].str) mb = x;
        assert(mb.id.length, name ~ ": unknown fixture action " ~ c["action"].str);
        assert(c["mode"].str == "polygon" && c["rig"].str == "cube", name ~ ": rig/mode changed");

        rig(c);

        pressKey(mb.sym, mb.mod);
        expectStage(name, "after", ints(c["after"]["hidden_polygons"]),
                    ints(c["after"]["selected"]["polygons"]));
        assert(undoDepth() == 1, name ~ ": the key did not record exactly one undo entry");
        ++stagesCompared;

        pressKey(SDLK_z, KMOD_LCTRL);
        if (name == "t-hi") {
            // Owner's decision: Hide Invert's undo is OURS — back to the
            // `before` state. The fixture's `after_undo` (nothing hidden) is
            // the reference's defect and is deliberately not the expectation.
            assert(ints(c["after_undo"]["hidden_polygons"]) == [],
                "t-hi: fixture after_undo no longer records the reference defect");
            expectStage(name, "after_undo", ints(c["before"]["hidden_polygons"]),
                        ints(c["before"]["selected"]["polygons"]),
                        " (OUR correct undo, not the reference defect)");
        } else {
            expectStage(name, "after_undo", ints(c["after_undo"]["hidden_polygons"]),
                        ints(c["after_undo"]["selected"]["polygons"]));
        }
        ++stagesCompared;

        pressKey(SDLK_z, KMOD_LCTRL | KMOD_LSHIFT);
        expectStage(name, "after_redo", ints(c["after_redo"]["hidden_polygons"]),
                    ints(c["after_redo"]["selected"]["polygons"]));
        ++stagesCompared;
    }
    assert(stagesCompared == 12, "stage population floor: " ~ stagesCompared.to!string);
}

// ---------------------------------------------------------------------------
// Part 2 — the buttons, through the production loader. Floors first (green),
// then one assert per id (RED on HEAD at the first), order, labels, ceiling,
// then the Visibility group's label.
// ---------------------------------------------------------------------------
unittest {
    auto panels = loadButtons("config/buttons.yaml");

    const(Panel)* vp;
    size_t vpTabs = 0;
    foreach (ref p; panels) if (p.title == "Viewport") { vp = &p; ++vpTabs; }
    assert(vpTabs == 1, "rig: viewport tab head changed (Viewport tabs: " ~ vpTabs.to!string ~ ")");

    string[] ids;
    string[] labels;
    foreach (ref it; vp.items) {
        assert(!it.isGroup && it.button.action.kind == ActionKind.command,
            "rig: viewport tab holds a non-command row");
        ids ~= it.button.action.id;
        labels ~= it.button.label;
    }
    assert(ids.length >= 2 && ids[0] == "viewport.fit" && ids[1] == "viewport.fit_selected",
        "rig: viewport tab head changed: " ~ ids.to!string);

    bool has(string id) { foreach (x; ids) if (x == id) return true; return false; }
    assert(has("mesh.hide"),           "viewport tab lacks mesh.hide");
    assert(has("mesh.hideUnselected"), "viewport tab lacks mesh.hideUnselected");
    assert(has("mesh.hideInvert"),     "viewport tab lacks mesh.hideInvert");
    assert(has("mesh.unhideAll"),      "viewport tab lacks mesh.unhideAll");

    assert(ids.length >= 6, "viewport tab population: " ~ ids.to!string);
    string[] want;
    foreach (mb; kFamily) want ~= mb.id;
    assert(ids[2 .. 6] == want,
        "viewport tab order differs from the reference menu: " ~ ids[2 .. 6].to!string);
    foreach (i, mb; kFamily)
        assert(labels[2 + i] == mb.label,
            format("viewport tab label %s: %s", mb.id, labels[2 + i]));
    assert(ids.length == 6, "viewport tab has extra rows: " ~ ids.to!string);

    // The Visibility group: exactly one, four buttons, the renamed label.
    const(Group)* vis;
    size_t visGroups = 0;
    foreach (ref p; panels)
        foreach (ref it; p.items)
            if (it.isGroup && it.group.title == "Visibility") { vis = &it.group; ++visGroups; }
    assert(visGroups == 1 && vis.buttons.length == 4,
        "rig: visibility group changed (groups " ~ visGroups.to!string ~ ")");
    string hu;
    size_t huRows = 0;
    foreach (ref b; vis.buttons)
        if (b.action.id == "mesh.hideUnselected") { hu = b.label; ++huRows; }
    assert(huRows == 1, "rig: visibility group lost its mesh.hideUnselected row");
    assert(hu == "Hide Unselected", "visibility group still labels hideUnselected " ~ hu);
}
