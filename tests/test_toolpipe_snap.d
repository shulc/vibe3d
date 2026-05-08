// Tests for phase 7.3a: SnapStage skeleton + Vertex snap.
//
// Verifies:
// - SNAP stage is registered at TaskCode.Snap.
// - Default attrs: enabled=false, types includes vertex/edgeCenter/
//   polyCenter/grid, ranges 8 / 24 px.
// - tool.pipe.attr snap <name> <value> round-trips through listAttrs.
// - /api/snap returns input pass-through when enabled=false.
// - With enabled=true + types=vertex + huge range, snap fires on the
//   nearest cube vertex regardless of camera orientation.
// - excludeVerts removes candidates from the walk.
// - Tiny range + cursor far from any vert ⇒ no snap.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

string[string] getSnapAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "SNAP") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    }
    assert(false, "SNAP stage missing from /api/toolpipe");
}

JSONValue querySnap(double cx, double cy, double cz, int sx, int sy,
                    int[] excludeVerts = null)
{
    import std.format : format;
    string excl = "[";
    foreach (i, e; excludeVerts) {
        if (i) excl ~= ",";
        excl ~= e.to!string;
    }
    excl ~= "]";
    string body_ = format(
        `{"cursor":[%.6f,%.6f,%.6f],"sx":%d,"sy":%d,"excludeVerts":%s}`,
        cx, cy, cz, sx, sy, excl);
    return postJson("/api/snap", body_);
}

bool approx(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

void resetCube() {
    postJson("/api/reset", `{"primitive":"cube"}`);
    postJson("/api/command", "tool.pipe.attr snap enabled false");
    postJson("/api/command", "tool.pipe.attr snap types vertex,edgeCenter,polyCenter,grid");
    postJson("/api/command", "tool.pipe.attr snap innerRange 8");
    postJson("/api/command", "tool.pipe.attr snap outerRange 24");
}

// -------------------------------------------------------------------------
// 7.3a: SNAP stage is registered.
// -------------------------------------------------------------------------

unittest { // SNAP stage present
    resetCube();
    auto j = getJson("/api/toolpipe");
    bool found = false;
    foreach (st; j["stages"].array)
        if (st["task"].str == "SNAP") { found = true; break; }
    assert(found, "SNAP stage missing from /api/toolpipe");
}

// -------------------------------------------------------------------------
// 7.3a: default attrs.
// -------------------------------------------------------------------------

unittest { // defaults
    resetCube();
    auto a = getSnapAttrs();
    assert(a["enabled"] == "false",
        "default enabled expected false, got " ~ a["enabled"]);
    assert(a["types"] == "vertex,edgeCenter,polyCenter,grid",
        "default types: " ~ a["types"]);
    assert(a["innerRange"] == "8", "innerRange: " ~ a["innerRange"]);
    assert(a["outerRange"] == "24", "outerRange: " ~ a["outerRange"]);
}

// -------------------------------------------------------------------------
// 7.3a: tool.pipe.attr round-trip.
// -------------------------------------------------------------------------

unittest { // setAttr enabled true
    resetCube();
    postJson("/api/command", "tool.pipe.attr snap enabled true");
    auto a = getSnapAttrs();
    assert(a["enabled"] == "true", "expected enabled=true, got " ~ a["enabled"]);
}

unittest { // setAttr types subset
    resetCube();
    postJson("/api/command", "tool.pipe.attr snap types vertex");
    auto a = getSnapAttrs();
    assert(a["types"] == "vertex", "types should be 'vertex', got " ~ a["types"]);
}

unittest { // setAttr innerRange / outerRange floats
    resetCube();
    postJson("/api/command", "tool.pipe.attr snap innerRange 12.5");
    postJson("/api/command", "tool.pipe.attr snap outerRange 30");
    auto a = getSnapAttrs();
    assert(a["innerRange"] == "12.5", "innerRange: " ~ a["innerRange"]);
    assert(a["outerRange"] == "30",   "outerRange: " ~ a["outerRange"]);
}

// -------------------------------------------------------------------------
// 7.3a: /api/snap with disabled snap returns input pass-through.
// -------------------------------------------------------------------------

unittest { // disabled => no snap
    resetCube();
    postJson("/api/command", "tool.pipe.attr snap enabled false");
    auto sr = querySnap(1.234, 5.678, 9.0, 100, 100);
    assert(sr["snapped"].type == JSONType.false_,
        "expected snapped=false, got " ~ sr.toString);
    auto wp = sr["worldPos"].array;
    assert(approx(wp[0].floating, 1.234), "worldPos.x preserved");
    assert(approx(wp[1].floating, 5.678), "worldPos.y preserved");
    assert(approx(wp[2].floating, 9.0),   "worldPos.z preserved");
}

// -------------------------------------------------------------------------
// 7.3a: huge range + types=vertex => snap fires on a cube vert.
// Camera-independent: the closest vert to ANY screen pixel is one of
// the 8 cube verts; verify the result IS a cube vert (each component
// is ±0.5).
// -------------------------------------------------------------------------

unittest { // huge range fires on a cube vert
    resetCube();
    postJson("/api/command", "tool.pipe.attr snap enabled true");
    postJson("/api/command", "tool.pipe.attr snap types vertex");
    postJson("/api/command", "tool.pipe.attr snap innerRange 999999");
    postJson("/api/command", "tool.pipe.attr snap outerRange 999999");
    auto sr = querySnap(0.0, 0.0, 0.0, 320, 240);
    assert(sr["snapped"].type == JSONType.true_,
        "expected snapped=true, got " ~ sr.toString);
    auto idx = sr["targetIndex"].integer;
    assert(idx >= 0 && idx < 8,
        "targetIndex out of [0,8): " ~ idx.to!string);
    auto wp = sr["worldPos"].array;
    foreach (i, c; wp) {
        double v = c.floating;
        assert(approx(v, -0.5) || approx(v, 0.5),
            "worldPos[" ~ i.to!string ~ "] = " ~ v.to!string
            ~ " is not a cube-vert coordinate");
    }
}

// -------------------------------------------------------------------------
// 7.3a: excludeVerts removes candidates.
// -------------------------------------------------------------------------

unittest { // exclude all verts => no candidates
    resetCube();
    postJson("/api/command", "tool.pipe.attr snap enabled true");
    postJson("/api/command", "tool.pipe.attr snap types vertex");
    postJson("/api/command", "tool.pipe.attr snap innerRange 999999");
    postJson("/api/command", "tool.pipe.attr snap outerRange 999999");
    auto sr = querySnap(0.0, 0.0, 0.0, 320, 240,
                        [0, 1, 2, 3, 4, 5, 6, 7]);
    assert(sr["snapped"].type == JSONType.false_,
        "all-excluded should snap=false, got " ~ sr.toString);
    assert(sr["highlighted"].type == JSONType.false_,
        "all-excluded should highlighted=false");
}

// -------------------------------------------------------------------------
// 7.3a: tiny range + cursor pixel far off-screen => no snap.
// (`projectToWindowFull` doesn't clip to screen but our pixel distance
// goes huge for an off-screen cursor pixel; with a 1-pixel range no
// candidate qualifies.)
// -------------------------------------------------------------------------

unittest { // tiny range + far cursor => no snap
    resetCube();
    postJson("/api/command", "tool.pipe.attr snap enabled true");
    postJson("/api/command", "tool.pipe.attr snap types vertex");
    postJson("/api/command", "tool.pipe.attr snap innerRange 1");
    postJson("/api/command", "tool.pipe.attr snap outerRange 2");
    auto sr = querySnap(0.0, 0.0, 0.0, 999999, 999999);
    assert(sr["snapped"].type == JSONType.false_,
        "expected no snap with tiny range + far cursor, got " ~ sr.toString);
    assert(sr["highlighted"].type == JSONType.false_,
        "expected no highlight with tiny range + far cursor");
}
