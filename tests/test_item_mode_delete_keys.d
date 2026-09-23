// Item-mode delete keys (task 7132). Law (fixture
// `delete_makepoly_lasso_hide_keys.json`, section `item_mode_delete_keys`): in
// ITEM mode Backspace and Delete both delete the SELECTED mesh item whole —
// the unselected one stays — as one undo step that undo restores and redo
// repeats; Shift+Backspace does nothing.
//
// The rig carries a LINGERING polygon selection on the selected item, so the
// wrong law is visible: the wildcard `mesh.delete` / `mesh.remove` rows would
// delete that polygon (cube 8/6 -> 8/5 or 4/... ) instead of the item, and a
// Shift+Backspace that fell through to `mesh.remove` would change the cube and
// record a history entry. Keys go through `/api/play-events`, so the keymap,
// the resolver and the dispatcher are all the production ones.
//
// Not asserted: which item is selected AFTER the delete. The reference leaves
// the survivor unselected; ours makes it the edit target (the document keeps a
// primary while a mesh layer exists). That is a separate item-selection law.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.json;
import std.format : format;
import core.thread : Thread;
import core.time : msecs;

void main() {}

enum string kFixture = import("fixtures/delete_makepoly_lasso_hide_keys.json");

enum SDLK_BACKSPACE = 8;
enum SDLK_DELETE    = 127;
enum KMOD_LSHIFT    = 1;

enum string LOG_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1.0,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2.0,"type":"SDL_WINDOWEVENT","sub":3}`;

JSONValue law() { return parseJSON(kFixture)["item_mode_delete_keys"]["cells"]; }

void ok(JSONValue r, string what) {
    assert(r["status"].str == "ok", what ~ " failed: " ~ r.toString);
}

void cmd(string json, string what) { ok(postJson("/api/command", json), what); }

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

/// The document as the fixture spells it: [selected, vertices, polygons] per
/// mesh item, in order.
string items() {
    string r;
    foreach (l; getJson("/api/layers")["layers"].array)
        r ~= format("[%s %d/%d]", l["selected"].type == JSONType.true_ ? "sel" : "-",
                    l["vertexCount"].integer, l["faceCount"].integer);
    return r;
}

string itemsOf(JSONValue state, bool withSelection) {
    string r;
    foreach (it; state["mesh_items"].array)
        r ~= format("[%s %d/%d]",
            withSelection ? (it["selected"].type == JSONType.true_ ? "sel" : "-") : "?",
            it["vertex_count"].integer, it["polygon_count"].integer);
    return r;
}

/// Same, without the selection column.
string counts() {
    string r;
    foreach (l; getJson("/api/layers")["layers"].array)
        r ~= format("[? %d/%d]", l["vertexCount"].integer, l["faceCount"].integer);
    return r;
}

size_t undoDepth() { return getJson("/api/history")["undo"].array.length; }

/// Cube (layer 0) SELECTED, quad (layer 1) not, one polygon of the cube left
/// selected from polygon mode, item mode current, history cleared.
void rig(JSONValue c) {
    cmd(commandBody("scene.reset"), "scene.reset");
    cmd(`{"id":"layer.add"}`, "layer.add");
    cmd(`{"id":"scene.loadMesh","vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],"faces":[[0,1,2,3]]}`,
        "scene.loadMesh quad");
    cmd(`{"id":"layer.select","index":0,"mode":"set"}`, "layer.select 0");
    cmd(commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`), "mesh.select polygon 0");
    cmd("select.typeFrom item", "select.typeFrom item");
    cmd(`{"id":"history.clear"}`, "history.clear");
    assert(undoDepth() == 0, "rig: history not empty");

    auto s = getJson("/api/selection");
    assert(s["selType"].str == "item", "rig: not in item mode: " ~ s["selType"].str);
    assert(c["before"]["mode"].str == "item", "fixture: before.mode");
    assert(items() == itemsOf(c["before"], true),
        format("rig: document %s, fixture %s", items(), itemsOf(c["before"], true)));
}

// 1-2. Backspace and Delete delete the selected item; undo restores both
// items with the selection; redo deletes it again. Red before the fix:
// "d-item-bs: after the key, document [sel 8/5][- 4/1], fixture [? 4/1]".
unittest {
    size_t cells;
    foreach (name; ["d-item-bs", "d-item-del"]) {
        auto c = law()[name];
        rig(c);
        pressKey(name == "d-item-bs" ? SDLK_BACKSPACE : SDLK_DELETE, 0);
        assert(counts() == itemsOf(c["after"], false),
            format("%s: after the key, document %s, fixture %s",
                   name, items(), itemsOf(c["after"], false)));
        assert(getJson("/api/selection")["selType"].str == "item",
            name ~ ": the key left item mode");
        assert(undoDepth() == 1,
            format("%s: the key recorded %d undo entries, not 1", name, undoDepth()));

        cmd(commandBody("history.undo"), "history.undo");
        assert(items() == itemsOf(c["after_undo"], true),
            format("%s: after undo, document %s, fixture %s",
                   name, items(), itemsOf(c["after_undo"], true)));
        cmd(commandBody("history.redo"), "history.redo");
        assert(counts() == itemsOf(c["after_redo"], false),
            format("%s: after redo, document %s, fixture %s",
                   name, items(), itemsOf(c["after_redo"], false)));
        ++cells;
    }
    assert(cells == 2);
}

// 3. Shift+Backspace does nothing in item mode: both items unchanged (the
// lingering polygon too) and no history entry. Red before the fix: the
// wildcard `mesh.remove` row removed the cube's selected polygon.
unittest {
    auto c = law()["d-item-sbs"];
    rig(c);
    immutable before = items();
    // The published readback names the winning row as the no-op kind.
    auto ctx = getJson("/api/input/context?key=shift+backspace");
    assert(ctx["mode"].str == "item" && ctx["matched"].type == JSONType.true_
        && ctx["binding"]["kind"].str == "unbound" && ctx["binding"]["mode"].str == "item",
        "d-item-sbs: input-context readback does not name the unbound row: " ~ ctx.toString);
    auto polysBefore = getJson("/api/selection")["selectedFaces"].toString;
    pressKey(SDLK_BACKSPACE, KMOD_LSHIFT);
    assert(items() == before && items() == itemsOf(c["after"], true),
        format("d-item-sbs: shift+backspace changed the document: %s -> %s", before, items()));
    assert(undoDepth() == 0,
        format("d-item-sbs: shift+backspace recorded %d undo entries", undoDepth()));
    assert(getJson("/api/selection")["selectedFaces"].toString == polysBefore,
        "d-item-sbs: shift+backspace changed the retained polygon selection");
}
