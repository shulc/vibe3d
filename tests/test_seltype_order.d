// Selection-types Stage 1 — SelType most-recent ordering + current-type signal.
//
// Drives the live app through /api/command (the `select.typeFrom` mode-switch
// funnel — the same funnel keys 1/2/3 route through) and asserts:
//
//   1. The CURRENT selection type promotes on a switch: /api/selection reports
//      the new `selType`, and /api/changes `currentTypeChanged` ticks on a flip.
//   2. A switch to the type ALREADY current does NOT flip (no currentTypeChanged
//      tick) — the same-type no-op contract (so keys 1/2/3 pressed for the
//      current mode neither tick the bus nor drop the tool).
//   3. editMode stays the picking authority and mirrors the current geometry
//      type in LOCKSTEP: /api/selection `mode` tracks `selType`, and a selection
//      made for a given geometry type reads back identically whether the mode
//      was reached via select.typeFrom or via the /api/select mode token. (#4
//      Stage 1 is behavior-neutral for geometry editing; only the type-current
//      counter + tool-drop-on-flip are new.)
//
// Counters are read as DELTAS across a step (the runner resets app STATE, not
// the bus, between test binaries — snapshot-before / read-after and diff).

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv    : to, text;
import std.string  : strip;
import std.algorithm : map, sort, equal;
import std.array     : join, array;
import std.file      : exists, remove, tempDir;
import std.path      : buildPath;
import std.process   : thisProcessID;
import core.thread : Thread;
import core.time   : dur;

void main() {}

alias baseUrl = testBaseUrl;


void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

// /api/selection fields used here.
struct Sel {
    string mode;       // editMode token (vertices/edges/polygons)
    string selType;    // currentSelType token (vertex/edge/polygon/item)
    int[]  faces;
    int[]  verts;
    int[]  edges;
}
Sel readSel() {
    auto j = getJson("/api/selection");
    Sel s;
    s.mode    = j["mode"].str;
    s.selType = j["selType"].str;
    foreach (v; j["selectedFaces"].array)    s.faces ~= cast(int)v.integer;
    foreach (v; j["selectedVertices"].array) s.verts ~= cast(int)v.integer;
    foreach (v; j["selectedEdges"].array)    s.edges ~= cast(int)v.integer;
    return s;
}

ulong currentTypeChanged() {
    return getJson("/api/changes")["currentTypeChanged"].integer;
}

// Wait until the per-frame flush has advanced currentTypeChanged past `from`
// (a flip was delivered), or time out. Returns the new value.
ulong waitTypeChangedPast(ulong from) {
    foreach (i; 0 .. 60) {                 // up to ~3s
        Thread.sleep(dur!"msecs"(50));
        auto now = currentTypeChanged();
        if (now > from) return now;
    }
    return currentTypeChanged();
}

void selectVia(string mode, int[] indices) {
    string idxs = indices.length ? indices.map!(i => text(i)).join(",") : "";
    auto j = postJson("/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":[` ~ idxs ~ `]}`));
    assert(j["status"].str == "ok", "select failed: " ~ j.toString);
}

string[] parsedOrder(JSONValue selection) {
    string[] result;
    foreach (entry; selection["selTypeOrder"].array) result ~= entry.str;
    return result;
}

int[] parsedIds(JSONValue selection, string field) {
    int[] result;
    foreach (entry; selection[field].array)
        result ~= cast(int)entry.integer;
    return result;
}

// 1 + 3: a switch promotes the current type; /api/selection reflects it; mode
// and selType stay in lockstep across the three geometry types.
unittest {
    post(baseUrl ~ "/api/command", commandBody("scene.reset"));

    cmd("select.typeFrom polygon");
    auto s = readSel();
    assert(s.selType == "polygon", "selType promotes to polygon; got " ~ s.selType);
    assert(s.mode    == "polygons", "editMode mirrors in lockstep; got " ~ s.mode);

    cmd("select.typeFrom edge");
    s = readSel();
    assert(s.selType == "edge"  && s.mode == "edges",
        "edge: selType+mode lockstep; got " ~ s.selType ~ "/" ~ s.mode);

    cmd("select.typeFrom vertex");
    s = readSel();
    assert(s.selType == "vertex" && s.mode == "vertices",
        "vertex: selType+mode lockstep; got " ~ s.selType ~ "/" ~ s.mode);
}

// Task 5690 — the protocol adapter must invoke the selection read-model's
// accessor for every request. The two populated layers carry different marks,
// so a Document or Mesh* captured when wiring cannot agree accidentally.
unittest {
    post(baseUrl ~ "/api/command", commandBody("scene.reset"));
    selectVia("vertices", [1, 4]);              // A's distinct marks
    cmd("layer.add name:B");
    cmd("prim.cube");                           // B is populated too
    selectVia("edges", [0, 5]);                 // B's distinct marks

    auto layers = getJson("/api/layers")["layers"].array;
    assert(layers.length == 2,
        "selection live-accessor fixture population floor: expected two layers");
    assert(getJson("/api/model?layer=0")["vertices"].array.length == 8
        && getJson("/api/model?layer=1")["vertices"].array.length == 8,
        "selection live-accessor fixture population floor: both layers are populated cubes");

    immutable path = buildPath(tempDir(),
        text("vibe3d_5690_selection_projection_", thisProcessID, ".v3d"));
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);
    cmd(`{"id":"file.save","path":` ~ JSONValue(path).toString ~ `}`);
    assert(exists(path), "selection live-accessor fixture save must produce a file");

    // Primary switch: A's two vertex marks must replace B's two edge marks on
    // the very next parsed response. Equal counts alone would be inert here.
    cmd("layer.select index:0");
    auto afterPrimary = getJson("/api/selection");
    assert(afterPrimary["items"].array.length == 2,
        "post-primary item comparison population floor: expected two rows");
    assert(parsedIds(afterPrimary, "selectedVertices") == [1, 4],
        "next selection request after primary switch did not read A's marks");
    assert(parsedIds(afterPrimary, "selectedVertices").length == 2,
        "post-primary selected-id comparison population floor: expected two ids");
    assert(parsedIds(afterPrimary, "selectedEdges").length == 0,
        "next selection request after primary switch retained B's edge marks");
    assert(afterPrimary["items"][0]["selected"].type == JSONType.true_
        && afterPrimary["items"][1]["selected"].type == JSONType.false_,
        "next selection request after primary switch did not read the item set");
    assert(parsedOrder(afterPrimary) == ["item", "edge", "vertex", "polygon"],
        "next selection request after primary switch did not read parsed live order");
    assert(afterPrimary["selTypeOrder"].array.length == 4,
        "post-primary order comparison population floor: expected four types");
    assert(afterPrimary["mode"].str == "edges",
        "item front must preserve the derived geometry mode invariant");

    cmd("select.typeFrom polygon");
    auto afterFront = getJson("/api/selection");
    assert(parsedOrder(afterFront) == ["polygon", "item", "edge", "vertex"],
        "next selection request after front switch did not read parsed live order");
    assert(afterFront["selTypeOrder"].array.length == 4,
        "post-front order comparison population floor: expected four types");
    assert(afterFront["selType"].str == "polygon"
        && afterFront["mode"].str == "polygons",
        "selection front and derived geometry mode must remain in lockstep");

    cmd("layer.select index:1 mode:add");
    auto afterItemAdd = getJson("/api/selection");
    assert(afterItemAdd["items"].array.length == 2,
        "post-item-add comparison population floor: expected two rows");
    size_t selectedItemCount = 0;
    foreach (item; afterItemAdd["items"].array)
        if (item["selected"].type == JSONType.true_) ++selectedItemCount;
    assert(selectedItemCount == 2,
        "next selection request after item add must report both selected rows");
    assert(parsedOrder(afterItemAdd) == ["item", "polygon", "edge", "vertex"],
        "item add must promote item at the front of the parsed live order");
    assert(afterItemAdd["selTypeOrder"].array.length == 4,
        "post-item-add order comparison population floor: expected four types");

    // Native load replaces the whole Document. Selection marks are not file
    // payload, so the saved two-layer document comes back with no geometry ids
    // and with B's saved item selection. A cached A mesh or copied Document
    // answers differently on the first response after load.
    cmd(`{"id":"file.load","path":` ~ JSONValue(path).toString ~ `}`);
    auto afterLoad = getJson("/api/selection");
    assert(afterLoad["items"].array.length == 2,
        "next selection request after load must see the replacement two-layer document");
    assert(afterLoad["items"][0]["selected"].type == JSONType.false_
        && afterLoad["items"][1]["selected"].type == JSONType.true_,
        "next selection request after load must see B's saved item selection");
    assert(parsedIds(afterLoad, "selectedVertices").length == 0
        && parsedIds(afterLoad, "selectedEdges").length == 0
        && parsedIds(afterLoad, "selectedFaces").length == 0,
        "next selection request after load must not retain either old layer's marks");
    assert(parsedOrder(afterLoad) == ["item", "polygon", "edge", "vertex"],
        "document load must not replace the live selection-type order");
    assert(afterLoad["selTypeOrder"].array.length == 4,
        "post-load order comparison population floor: expected four types");
}

// 1: each FLIP ticks currentTypeChanged exactly once.
unittest {
    post(baseUrl ~ "/api/command", commandBody("scene.reset"));
    cmd("select.typeFrom vertex");             // settle to a known current type
    auto base = waitTypeChangedPast(0);        // ensure the reset/seed flushed

    auto before = currentTypeChanged();
    cmd("select.typeFrom polygon");            // vertex → polygon: a flip
    auto after = waitTypeChangedPast(before);
    assert(after == before + 1,
        "one flip ticks currentTypeChanged once; got +"
        ~ to!string(after - before));
}

// 2: a switch to the already-current type does NOT flip (no tick).
unittest {
    post(baseUrl ~ "/api/command", commandBody("scene.reset"));
    cmd("select.typeFrom polygon");
    waitTypeChangedPast(0);
    auto before = currentTypeChanged();

    cmd("select.typeFrom polygon");            // already current → no flip
    cmd("select.typeFrom polygon");
    Thread.sleep(dur!"msecs"(300));            // nothing accumulates
    auto after = currentTypeChanged();
    assert(after == before,
        "a redundant same-type switch must NOT tick currentTypeChanged; got +"
        ~ to!string(after - before));
}

// 4 (reset reroute + reverse-sync deletion): a scene.reset via /api/reset
// leaves selType and mode in lockstep as vertices. This covers the Phase-2
// SceneReset reroute (setPromoteHook) and confirms the deleted reverse-sync at
// the /api/reset handler did not leave the order stale. The prior type before
// reset (polygon here) must NOT survive into the post-reset ordering front.
unittest {
    post(baseUrl ~ "/api/command", commandBody("scene.reset"));

    // Switch to polygon mode, then reset — reset must front vertices.
    cmd("select.typeFrom polygon");
    auto sBefore = readSel();
    assert(sBefore.selType == "polygon" && sBefore.mode == "polygons",
        "pre-reset: polygon mode expected; got " ~ sBefore.selType ~ "/" ~ sBefore.mode);

    post(baseUrl ~ "/api/command", commandBody("scene.reset"));
    auto sAfter = readSel();
    assert(sAfter.mode == "vertices",
        "post-reset: mode must be vertices; got " ~ sAfter.mode);
    assert(sAfter.selType == "vertex",
        "post-reset: selType must be vertex; got " ~ sAfter.selType);
}

// 3 (picking authority cross-check): editMode drives picking identically — a
// face selection placed in polygon mode reads back the SAME indices whether the
// mode was reached via select.typeFrom or via the /api/select polygons token.
// The selType layer above editMode does not perturb the geometry payload.
unittest {
    post(baseUrl ~ "/api/command", commandBody("scene.reset"));

    // Reach polygon mode via select.typeFrom, then select faces.
    cmd("select.typeFrom polygon");
    selectVia("polygons", [0, 2, 4]);
    auto viaTypeFrom = readSel().faces.dup;
    sort(viaTypeFrom);

    // Reset, reach polygon mode via the /api/select mode token, select the same.
    post(baseUrl ~ "/api/command", commandBody("scene.reset"));
    selectVia("polygons", [0, 2, 4]);
    auto viaSelectToken = readSel().faces.dup;
    sort(viaSelectToken);

    assert(equal(viaTypeFrom, viaSelectToken),
        "the same face pick reads back identically regardless of how polygon "
        ~ "mode was reached: " ~ to!string(viaTypeFrom)
        ~ " vs " ~ to!string(viaSelectToken));
    assert(viaTypeFrom == [0, 2, 4],
        "the geometry selection payload is exactly the picked faces; got "
        ~ to!string(viaTypeFrom));
}
