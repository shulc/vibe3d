// HTTP tests for FalloffType.VertexMap.
//
// Three tests:
//   1. weight×delta: vert0 weight=1.0 moves TY; vert1 weight=0.0 stays.
//   2. Non-existent map → full influence (all verts move equally).
//   3. Smoke lifecycle: create/rename/set/remove + falloff attr round-trip.

import std.net.curl;
import std.json;
import std.conv      : to;
import std.math      : fabs;
import std.format    : format;
import std.algorithm : map;
import std.array     : join;
import std.range     : iota;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}
// Send an argstring command (e.g. "tool.set move on").
void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}
// Send a JSON-body command with explicit params JSON.
void cmdJ(string id, string paramsJson) {
    auto j = postJson("/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`);
    assert(j["status"].str == "ok",
        "cmdJ `" ~ id ~ "` failed: " ~ j.toString);
}

double[3][] dumpVerts() {
    double[3][] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return out_;
}

void selectAllVerts(int n) {
    string indices = iota(n).map!(i => i.to!string).join(",");
    auto j = parseJSON(cast(string)
        post(baseUrl ~ "/api/select",
             `{"mode":"vertices","indices":[` ~ indices ~ `]}`));
    assert(j["status"].str == "ok", "select-all-verts failed: " ~ j.toString);
}

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

// --------------------------------------------------------------------------

unittest { // weight×delta: vert0 weight=1.0 moves TY; vert1 weight=0.0 stays
    // Fresh cube has 8 verts at Y in {0,1}. Create weight map "wm", set
    // vert 0 weight=1.0 (all others default 0.0). Apply type=vertexMap +
    // TY=0.5 → vert0 shifts +0.5, vert1 stays.
    postJson("/api/reset", "");
    selectAllVerts(8);

    cmdJ("mesh.weightmap.create", `{"name":"wm"}`);
    cmdJ("mesh.weightmap.set",    `{"name":"wm","vert":0,"weight":1.0}`);

    auto before = dumpVerts();
    assert(before.length == 8, "expected cube with 8 vertices");
    double y0before = before[0][1];
    double y1before = before[1][1];

    cmd("tool.set move on");
    cmd("tool.pipe.attr falloff type vertexMap");
    cmd("tool.pipe.attr falloff map wm");

    cmd("tool.attr move TY 0.5");
    cmd("tool.doApply");

    auto after = dumpVerts();
    double dy0 = after[0][1] - y0before;
    double dy1 = after[1][1] - y1before;

    assert(approxEq(dy0, 0.5, 1e-4),
        format("vert0 (w=1.0) should move +0.5 in Y, got %g", dy0));
    assert(approxEq(dy1, 0.0, 1e-4),
        format("vert1 (w=0.0) should not move in Y, got %g", dy1));
}

unittest { // non-existent map → full influence (all 8 verts move equally)
    postJson("/api/reset", "");
    selectAllVerts(8);

    auto before = dumpVerts();
    assert(before.length == 8);

    cmd("tool.set move on");
    cmd("tool.pipe.attr falloff type vertexMap");
    cmd("tool.pipe.attr falloff map nonexistent");

    cmd("tool.attr move TY 1.0");
    cmd("tool.doApply");

    auto after = dumpVerts();
    foreach (i, bv; before) {
        double dy = after[i][1] - bv[1];
        assert(approxEq(dy, 1.0, 1e-4),
            format("vert %d: empty map should give full influence, got dy=%g",
                   i, dy));
    }
}

unittest { // smoke: lifecycle create/rename/set/remove + falloff attr round-trip
    postJson("/api/reset", "");

    cmdJ("mesh.weightmap.create", `{"name":"tmp"}`);
    cmdJ("mesh.weightmap.rename", `{"from":"tmp","to":"final"}`);
    cmdJ("mesh.weightmap.set",    `{"name":"final","vert":0,"weight":0.75}`);

    cmd("tool.set move on");
    cmd("tool.pipe.attr falloff type vertexMap");
    cmd("tool.pipe.attr falloff map final");

    auto j = getJson("/api/toolpipe");
    bool foundWght = false;
    foreach (st; j["stages"].array) {
        if (st["task"].str == "WGHT") {
            foundWght = true;
            string tp = st["attrs"]["type"].str;
            string mn = st["attrs"]["map"].str;
            assert(tp == "vertexMap",
                "WGHT type should be vertexMap, got " ~ tp);
            assert(mn == "final",
                "WGHT map should be 'final', got " ~ mn);
            break;
        }
    }
    assert(foundWght, "WGHT stage not found in /api/toolpipe response");

    cmdJ("mesh.weightmap.remove", `{"name":"final"}`);
}
