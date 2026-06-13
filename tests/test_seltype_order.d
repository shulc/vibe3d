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

import std.net.curl;
import std.json;
import std.conv    : to, text;
import std.string  : strip;
import std.algorithm : map, sort, equal;
import std.array     : join, array;
import core.thread : Thread;
import core.time   : dur;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
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
    auto j = postJson("/api/select",
        `{"mode":"` ~ mode ~ `","indices":[` ~ idxs ~ `]}`);
    assert(j["status"].str == "ok", "select failed: " ~ j.toString);
}

// 1 + 3: a switch promotes the current type; /api/selection reflects it; mode
// and selType stay in lockstep across the three geometry types.
unittest {
    post(baseUrl ~ "/api/reset", "");

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

// 1: each FLIP ticks currentTypeChanged exactly once.
unittest {
    post(baseUrl ~ "/api/reset", "");
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
    post(baseUrl ~ "/api/reset", "");
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

// 3 (picking authority cross-check): editMode drives picking identically — a
// face selection placed in polygon mode reads back the SAME indices whether the
// mode was reached via select.typeFrom or via the /api/select polygons token.
// The selType layer above editMode does not perturb the geometry payload.
unittest {
    post(baseUrl ~ "/api/reset", "");

    // Reach polygon mode via select.typeFrom, then select faces.
    cmd("select.typeFrom polygon");
    selectVia("polygons", [0, 2, 4]);
    auto viaTypeFrom = readSel().faces.dup;
    sort(viaTypeFrom);

    // Reset, reach polygon mode via the /api/select mode token, select the same.
    post(baseUrl ~ "/api/reset", "");
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
