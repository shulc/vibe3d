// Make Polygon from an EDGE selection, and the P key (task 7131, wave bugfix
// S11 item 16). Law (fixture `delete_makepoly_lasso_hide_keys.json`, section
// `make_polygon`): the selected edges are walked as a chain — a closed 4-edge
// hole gives the quad, an open 3-edge chain is closed to the same quad; the
// winding matches the neighbouring polygons, not the selection order and not
// the view; the new polygon becomes selected, a vertex selection is dropped,
// an EDGE selection is kept. One undo restores geometry and selection.
//
// Polygons are compared CYCLICALLY (a rotation is allowed, a reversal is
// not): the reference's start corner is not observable from its selection.
// Two holes on opposite faces of the cube (`cube_minus_face0` / `_face1`)
// need opposite windings relative to the stored edge direction, so a kernel
// that ignored the neighbours could not satisfy both.
//
// Order is load-bearing: floors, then the vertex-selection branch (a green
// control on HEAD), then the edge branch through the COMMAND, and the key P
// last, so a fix that only binds the key cannot pass the command block.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.json;
import std.format : format;
import std.algorithm : sort;
import core.thread : Thread;
import core.time : msecs;

void main() {}

enum string kFixture = import("fixtures/delete_makepoly_lasso_hide_keys.json");

enum SDLK_p = 112;

enum string LOG_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1.0,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2.0,"type":"SDL_WINDOWEVENT","sub":3}`;

JSONValue fixture() { return parseJSON(kFixture); }
JSONValue cell(string name) { return fixture()["make_polygon"]["cells"][name]; }

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
    return r;
}

int[][] ints2(JSONValue a) {
    int[][] r;
    foreach (row; a.array) r ~= ints(row);
    return r;
}

/// Edge index of the unordered vertex pair (a,b) in the live model, or -1.
int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int ea = cast(int) e.array[0].integer, eb = cast(int) e.array[1].integer;
        if ((ea == a && eb == b) || (ea == b && eb == a)) return cast(int) i;
    }
    return -1;
}

/// The live edge selection as sorted unordered vertex pairs "a-b" (a<b).
string[] selectedEdgePairs() {
    auto m = getJson("/api/model");
    auto sel = getJson("/api/selection");
    string[] r;
    foreach (ei; ints(sel["selectedEdges"])) {
        auto e = m["edges"].array[ei].array;
        int a = cast(int) e[0].integer, b = cast(int) e[1].integer;
        if (a > b) { auto t = a; a = b; b = t; }
        r ~= format("%d-%d", a, b);
    }
    r.sort();
    return r;
}

string[] pairs(JSONValue a) {
    string[] r;
    foreach (p; ints2(a)) {
        int x = p[0], y = p[1];
        if (x > y) { auto t = x; x = y; y = t; }
        r ~= format("%d-%d", x, y);
    }
    r.sort();
    return r;
}

/// Cyclic equality: same length, `got` is a rotation of `want` (no reversal).
bool cyclicEqual(int[] got, int[] want) {
    if (got.length != want.length || got.length == 0) return false;
    foreach (s; 0 .. want.length) {
        bool all = true;
        foreach (i; 0 .. want.length)
            if (got[i] != want[(i + s) % want.length]) { all = false; break; }
        if (all) return true;
    }
    return false;
}

/// Load the cell's rig, enter its selection mode, select in the given order,
/// clear history.
void rig(JSONValue c) {
    auto rg = fixture()["rigs"][c["rig"].str];
    auto body = JSONValue.emptyObject;
    body["vertices"] = rg["vertices"];
    body["faces"] = rg["polygons"];
    ok(postJson("/api/command", commandBody("scene.reset")), "scene.reset");
    ok(postJson("/api/command", commandBody("scene.loadMesh", body.toString)), "scene.loadMesh");
    immutable bool edges = c["mode"].str == "edge";
    ok(postJson("/api/command", edges ? "select.typeFrom edge" : "select.typeFrom vertex"),
        "select.typeFrom");
    string idx = "[";
    if (edges) {
        auto m = getJson("/api/model");
        foreach (i, p; ints2(c["selection_order_given"])) {
            immutable ei = edgeIndex(m, p[0], p[1]);
            assert(ei >= 0, format("rig: edge %s not in the loaded mesh", p));
            idx ~= (i ? "," : "") ~ format("%d", ei);
        }
    } else {
        foreach (i, v; ints(c["selection_order_given"]))
            idx ~= (i ? "," : "") ~ format("%d", v);
    }
    idx ~= "]";
    ok(postJson("/api/command", commandBody("mesh.select",
        `{"mode":"` ~ (edges ? "edges" : "vertices") ~ `","indices":` ~ idx ~ `}`)), "mesh.select");
    ok(postJson("/api/command", `{"id":"history.clear"}`), "history.clear");

    // Floor: the rig is the fixture's `before` (5 polygons, the hole open) and
    // the selection has the cell's size — else every later cell is vacuous.
    auto m = getJson("/api/model");
    assert(m["faceCount"].integer == 5 && c["before"]["polygon_count"].integer == 5,
        "rig: polygon count is not 5 (" ~ c["rig"].str ~ ")");
    auto sel = getJson("/api/selection");
    immutable size_t want = edges ? c["before"]["selected"]["edges"].array.length
                                  : c["before"]["selected"]["vertices"].array.length;
    immutable size_t got = edges ? sel["selectedEdges"].array.length
                                 : sel["selectedVertices"].array.length;
    assert(got == want && want == c["selection_order_given"].array.length,
        format("rig: edge selection size %d, fixture %d", got, want));
    if (edges)
        assert(selectedEdgePairs() == pairs(c["before"]["selected"]["edges"]),
            "rig: selected edges differ from the fixture");
}

/// The polygon the command appended (the last face), after a count check.
int[] newPolygon(JSONValue c, string failMsg) {
    auto m = getJson("/api/model");
    assert(m["faceCount"].integer == c["after"]["polygon_count"].integer, failMsg);
    auto f = ints2(m["faces"]);
    assert(f.length == 6, "population floor: face list is not 6 long");
    // The five pre-existing polygons are untouched, by identity.
    assert(f[0 .. 5] == ints2(c["before"]["polygons"]),
        "make polygon changed an existing polygon (" ~ c["rig"].str ~ ")");
    return f[5];
}

void expectUndo(JSONValue c, string name) {
    ok(postJson("/api/command", commandBody("history.undo")), "history.undo " ~ name);
    auto m = getJson("/api/model");
    auto u = c["after_undo"];
    assert(m["faceCount"].integer == u["polygon_count"].integer
        && ints2(m["faces"]) == ints2(u["polygons"]),
        "make polygon undo did not restore the polygons (" ~ name ~ ")");
    auto sel = getJson("/api/selection");
    assert(ints(sel["selectedFaces"]).length == 0,
        "make polygon undo left a polygon selected (" ~ name ~ ")");
    if (c["mode"].str == "edge")
        assert(selectedEdgePairs() == pairs(u["selected"]["edges"]),
            "make polygon undo did not restore the edge selection (" ~ name ~ ")");
    else {
        auto sv = ints(sel["selectedVertices"]);
        auto wv = ints(u["selected"]["vertices"]);
        sv.sort(); wv.sort();
        assert(sv.length == 4 && sv == wv,
            "make polygon undo did not restore the vertex selection (" ~ name ~ ")");
    }
}

// 1-2. Vertex branch (green on HEAD: `makePolygonFromVerts` orients the new
// face against its neighbours). A red here is a PLAN-FINDING, not a witness.
unittest {
    size_t cells;
    foreach (name; ["p-v4-key", "p-v4-rev", "p-v4-back"]) {
        auto c = cell(name);
        rig(c);
        ok(postJson("/api/command", `{"id":"mesh.makePolygon"}`), "mesh.makePolygon " ~ name);
        auto np = newPolygon(c, "vertex make polygon did nothing (" ~ name ~ ")");
        assert(cyclicEqual(np, ints(c["new_polygon"])),
            format("vertex make polygon winding disagrees with neighbours (%s): got %s, want %s",
                   name, np, ints(c["new_polygon"])));
        auto sel = getJson("/api/selection");
        assert(ints(sel["selectedFaces"]) == [5] && sel["selectedVertices"].array.length == 0,
            "vertex make polygon: selection after is not the new polygon alone (" ~ name ~ ")");
        expectUndo(c, name);
        ++cells;
    }
    assert(cells == 3);
}

// 3. Edge branch through the COMMAND. RED on HEAD 9f434948: the command reads
// only the vertex selection, and an edge selection selects no vertices.
unittest {
    size_t cells;
    foreach (name; ["p-e4-key", "p-e3-key", "p-e3-rev", "p-e4-back"]) {
        auto c = cell(name);
        rig(c);
        auto r = postJson("/api/command", `{"id":"mesh.makePolygon"}`);
        auto np = newPolygon(c, format("make polygon from edges did nothing (%s): answered %s",
                                       name, r.toString));
        assert(cyclicEqual(np, ints(c["new_polygon"])),
            format("edge make polygon winding disagrees with neighbours (%s): got %s, want %s",
                   name, np, ints(c["new_polygon"])));
        auto sel = getJson("/api/selection");
        assert(ints(sel["selectedFaces"]) == ints(c["after"]["selected"]["polygons"]),
            "edge make polygon did not select the new polygon (" ~ name ~ ")");
        assert(sel["selectedVertices"].array.length == 0,
            "edge make polygon left vertices selected (" ~ name ~ ")");
        assert(selectedEdgePairs() == pairs(c["after"]["selected"]["edges"]),
            "make polygon dropped the edge selection (" ~ name ~ ")");
        expectUndo(c, name);
        ++cells;
    }
    assert(cells == 4);
}

// 4. The key: P in edge mode is Make Polygon. RED on HEAD 9f434948 (shown by
// isolation — block 3 stops the module first): P is bound to nothing.
unittest {
    auto c = cell("p-e4-key");
    rig(c);
    pressKey(SDLK_p, 0);
    auto m = getJson("/api/model");
    assert(m["faceCount"].integer == 6, "key P did not make a polygon");
    auto np = ints2(m["faces"])[5];
    assert(cyclicEqual(np, ints(c["new_polygon"])),
        format("key P: edge make polygon winding disagrees with neighbours: got %s", np));
    assert(selectedEdgePairs() == pairs(c["after"]["selected"]["edges"]),
        "key P: make polygon dropped the edge selection");
}
