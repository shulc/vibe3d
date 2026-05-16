// Tests for FalloffStage.connect — Stage 14.4 connectivity gate on
// the Element falloff. `connect != Off` restricts the spherical
// weight to verts in the same connected component as the picked
// element; the component mask is BFS-built from mesh.edges by
// ElementMoveTool when it picks.
//
// Without a way to construct truly disconnected geometry through the
// current HTTP API (vibe3d's mesh holds one connected component
// after prim.cube), this test focuses on the contract: setAttr /
// listAttrs round-trip for the `connect` value, plus an apply on
// the cube where connect=Vertex behaves identically to connect=Off
// (since all 8 verts are in the same component).

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}
void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

string falloffAttr(string key) {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT")
            return st["attrs"][key].str;
    assert(false, "WGHT stage missing");
}

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

unittest { // connect attr round-trips through setAttr / listAttrs
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    foreach (mode; ["off", "vertex", "edge", "polygon", "material"]) {
        cmd("tool.pipe.attr falloff connect " ~ mode);
        assert(falloffAttr("connect") == mode,
            "connect=" ~ mode ~ " should round-trip; got "
            ~ falloffAttr("connect"));
    }
}

unittest { // unknown connect value is rejected (not silently coerced)
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    auto r = postJson("/api/command",
                      "tool.pipe.attr falloff connect bogus");
    assert(r["status"].str != "ok",
        "unknown connect value should fail; got " ~ r.toString);
}

unittest { // on a connected cube, connect=Vertex behaves like Off:
           // every vert is in the picked component, so the
           // unrestricted sphere math applies. With pickedCenter at
           // the +X+Y+Z corner and dist=0.5, only that corner moves.
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedCenter \"0.5,0.5,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.pipe.attr falloff connect vertex");
    // ElementMoveTool's BFS only runs on actual click — for a
    // headless test we have no LMB-down. With an empty connectMask
    // the gate degrades to "unrestricted" per the elementWeight
    // doc comment. So this also verifies the empty-mask fallback.
    cmd("tool.attr xfrm.elementMove TX 0.3");
    cmd("tool.doApply");
    auto verts = getJson("/api/model")["vertices"].array;
    int moved = 0, unmoved = 0;
    foreach (v; verts) {
        auto a = v.array;
        bool isCorner = approxEq(a[1].floating, 0.5)
                     && approxEq(a[2].floating, 0.5)
                     && approxEq(a[0].floating, 0.8);  // 0.5 + 0.3
        if (isCorner) moved++;
        else {
            // Untouched corner: components on the ±0.5 box.
            foreach (c; 0 .. 3)
                assert(approxEq(fabs(a[c].floating), 0.5, 1e-4),
                    "unmoved vert should stay on ±0.5 box");
            unmoved++;
        }
    }
    assert(moved == 1,
        "exactly one corner should shift to (0.8,0.5,0.5); got "
        ~ moved.to!string);
    assert(unmoved == 7);
}
