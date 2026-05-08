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
    // CSV values must be quoted — argstring's bareword grammar
    // doesn't include comma.
    postJson("/api/command",
        `tool.pipe.attr snap types "vertex,edgeCenter,polyCenter,grid"`);
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

// -------------------------------------------------------------------------
// 7.3b: EdgeCenter snap. Cube has 12 edges; each midpoint has exactly
// one zero coord and two ±0.5 coords. Huge range + types=edgeCenter
// must produce one of those.
// -------------------------------------------------------------------------

unittest { // EdgeCenter snap fires on a cube edge midpoint
    resetCube();
    postJson("/api/command", "tool.pipe.attr snap enabled true");
    postJson("/api/command", "tool.pipe.attr snap types edgeCenter");
    postJson("/api/command", "tool.pipe.attr snap innerRange 999999");
    postJson("/api/command", "tool.pipe.attr snap outerRange 999999");
    auto sr = querySnap(0.0, 0.0, 0.0, 320, 240);
    assert(sr["snapped"].type == JSONType.true_,
        "expected EdgeCenter snap, got " ~ sr.toString);
    auto wp = sr["worldPos"].array;
    int zeros = 0, halves = 0;
    foreach (c; wp) {
        double v = c.floating;
        if      (approx(v, 0.0))                          zeros++;
        else if (approx(v, -0.5) || approx(v, 0.5))       halves++;
    }
    assert(zeros == 1 && halves == 2,
        "EdgeCenter must have 1 zero + 2 ±0.5 coords; got " ~ sr.toString);
}

// -------------------------------------------------------------------------
// 7.3b: Edge snap (closest point along an edge). Any point on a cube
// edge has 2 coords = ±0.5 and 1 coord ∈ [-0.5, 0.5]. Closer test
// criteria: 2 coords are within 1e-3 of ±0.5; 1 coord is in [-0.5, 0.5].
// -------------------------------------------------------------------------

unittest { // Edge snap fires on a cube edge
    resetCube();
    postJson("/api/command", "tool.pipe.attr snap enabled true");
    postJson("/api/command", "tool.pipe.attr snap types edge");
    postJson("/api/command", "tool.pipe.attr snap innerRange 999999");
    postJson("/api/command", "tool.pipe.attr snap outerRange 999999");
    auto sr = querySnap(0.0, 0.0, 0.0, 320, 240);
    assert(sr["snapped"].type == JSONType.true_,
        "expected Edge snap, got " ~ sr.toString);
    auto wp = sr["worldPos"].array;
    int onAxis = 0;     // coords pinned to ±0.5
    int inSpan = 0;     // coords in [-0.5, 0.5] but not pinned
    foreach (c; wp) {
        double v = c.floating;
        if      (approx(v, -0.5) || approx(v, 0.5)) onAxis++;
        else if (v >= -0.5 - 1e-3 && v <= 0.5 + 1e-3) inSpan++;
    }
    assert(onAxis >= 2 && (onAxis + inSpan) == 3,
        "Edge result must have ≥2 ±0.5 coords; got " ~ sr.toString);
}

// -------------------------------------------------------------------------
// 7.3b: PolyCenter snap. Cube has 6 face centers; each has one ±0.5
// coord and two zero coords.
// -------------------------------------------------------------------------

unittest { // PolyCenter snap fires on a cube face center
    resetCube();
    postJson("/api/command", "tool.pipe.attr snap enabled true");
    postJson("/api/command", "tool.pipe.attr snap types polyCenter");
    postJson("/api/command", "tool.pipe.attr snap innerRange 999999");
    postJson("/api/command", "tool.pipe.attr snap outerRange 999999");
    auto sr = querySnap(0.0, 0.0, 0.0, 320, 240);
    assert(sr["snapped"].type == JSONType.true_,
        "expected PolyCenter snap, got " ~ sr.toString);
    auto wp = sr["worldPos"].array;
    int zeros = 0, halves = 0;
    foreach (c; wp) {
        double v = c.floating;
        if      (approx(v, 0.0))                          zeros++;
        else if (approx(v, -0.5) || approx(v, 0.5))       halves++;
    }
    assert(zeros == 2 && halves == 1,
        "PolyCenter must have 2 zeros + 1 ±0.5 coord; got " ~ sr.toString);
}

// -------------------------------------------------------------------------
// 7.3b: Polygon snap (closest point on face surface). Any point on a
// cube face has at least one coord = ±0.5 and the others within
// [-0.5, 0.5].
// -------------------------------------------------------------------------

unittest { // Polygon snap fires on a cube face surface
    resetCube();
    postJson("/api/command", "tool.pipe.attr snap enabled true");
    postJson("/api/command", "tool.pipe.attr snap types polygon");
    postJson("/api/command", "tool.pipe.attr snap innerRange 999999");
    postJson("/api/command", "tool.pipe.attr snap outerRange 999999");
    auto sr = querySnap(0.0, 0.0, 0.0, 320, 240);
    assert(sr["snapped"].type == JSONType.true_,
        "expected Polygon snap, got " ~ sr.toString);
    auto wp = sr["worldPos"].array;
    int onAxis = 0;
    int inSpan = 0;
    foreach (c; wp) {
        double v = c.floating;
        if      (approx(v, -0.5) || approx(v, 0.5)) onAxis++;
        else if (v >= -0.5 - 1e-3 && v <= 0.5 + 1e-3) inSpan++;
    }
    assert(onAxis >= 1 && (onAxis + inSpan) == 3,
        "Polygon result must have ≥1 ±0.5 coord; got " ~ sr.toString);
}

// -------------------------------------------------------------------------
// 7.3b: types is a bitmask — multiple types active simultaneously.
// Vertex + EdgeCenter + PolyCenter set together produces SOME snap;
// targetType is one of those three.
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// 7.3c: Workplane snap. Cursor ray ∩ workplane plane. Default
// workplane = XZ at Y=0 ⇒ snapped Y must be 0. Distance is 0 (the
// candidate projects back to the cursor pixel) so snap always fires
// at default ranges.
// -------------------------------------------------------------------------

unittest { // Workplane snap fires; result lies on Y=0
    resetCube();
    // Pin the workplane to XZ at Y=0 so the test doesn't depend on
    // the auto-mode camera-facing pick.
    postJson("/api/command", "tool.pipe.attr workplane mode worldY");
    postJson("/api/command", "tool.pipe.attr snap enabled true");
    postJson("/api/command", "tool.pipe.attr snap types workplane");
    auto sr = querySnap(0.0, 0.0, 0.0, 320, 240);
    assert(sr["snapped"].type == JSONType.true_,
        "expected Workplane snap, got " ~ sr.toString);
    auto wp = sr["worldPos"].array;
    assert(approx(wp[1].floating, 0.0),
        "Workplane snap Y must be 0; got " ~ sr.toString);
    // SnapType.Workplane = 64.
    assert(cast(int)sr["targetType"].integer == 64,
        "targetType expected 64 (Workplane), got " ~ sr.toString);
    // Restore default for subsequent tests.
    postJson("/api/command", "tool.pipe.attr workplane mode auto");
}

// -------------------------------------------------------------------------
// 7.3c: Grid snap with fixedGrid=true, fixedGridSize=0.5. Result lies
// on the workplane (Y=0) and X / Z components are integer multiples
// of 0.5.
// -------------------------------------------------------------------------

unittest { // Grid snap fixed step = 0.5
    resetCube();
    postJson("/api/command", "tool.pipe.attr workplane mode worldY");
    postJson("/api/command", "tool.pipe.attr snap enabled true");
    postJson("/api/command", "tool.pipe.attr snap types grid");
    postJson("/api/command", "tool.pipe.attr snap fixedGrid true");
    postJson("/api/command", "tool.pipe.attr snap fixedGridSize 0.5");
    postJson("/api/command", "tool.pipe.attr snap innerRange 999999");
    postJson("/api/command", "tool.pipe.attr snap outerRange 999999");
    auto sr = querySnap(0.0, 0.0, 0.0, 320, 240);
    assert(sr["snapped"].type == JSONType.true_,
        "expected Grid snap, got " ~ sr.toString);
    import std.math : round, fabs;
    auto wp = sr["worldPos"].array;
    assert(approx(wp[1].floating, 0.0),
        "Grid snap Y must be 0; got " ~ sr.toString);
    double x = wp[0].floating, z = wp[2].floating;
    assert(fabs(x - round(x / 0.5) * 0.5) < 1e-3,
        "Grid snap X must be multiple of 0.5; got x=" ~ x.to!string);
    assert(fabs(z - round(z / 0.5) * 0.5) < 1e-3,
        "Grid snap Z must be multiple of 0.5; got z=" ~ z.to!string);
    postJson("/api/command", "tool.pipe.attr workplane mode auto");
}

// -------------------------------------------------------------------------
// 7.3c: Grid snap dynamic = step 1.0 (matches visible grid in
// app.d, hard-coded at 1.0).
// -------------------------------------------------------------------------

unittest { // Grid snap dynamic step = 1.0
    resetCube();
    postJson("/api/command", "tool.pipe.attr workplane mode worldY");
    postJson("/api/command", "tool.pipe.attr snap enabled true");
    postJson("/api/command", "tool.pipe.attr snap types grid");
    postJson("/api/command", "tool.pipe.attr snap fixedGrid false");
    postJson("/api/command", "tool.pipe.attr snap innerRange 999999");
    postJson("/api/command", "tool.pipe.attr snap outerRange 999999");
    auto sr = querySnap(0.0, 0.0, 0.0, 320, 240);
    assert(sr["snapped"].type == JSONType.true_,
        "expected Grid snap, got " ~ sr.toString);
    import std.math : round, fabs;
    auto wp = sr["worldPos"].array;
    assert(approx(wp[1].floating, 0.0),
        "Grid snap Y must be 0; got " ~ sr.toString);
    double x = wp[0].floating, z = wp[2].floating;
    assert(fabs(x - round(x)) < 1e-3,
        "Grid snap X must be integer; got x=" ~ x.to!string);
    assert(fabs(z - round(z)) < 1e-3,
        "Grid snap Z must be integer; got z=" ~ z.to!string);
    postJson("/api/command", "tool.pipe.attr workplane mode auto");
}

unittest { // multi-type combo picks closest across types
    resetCube();
    postJson("/api/command", "tool.pipe.attr snap enabled true");
    postJson("/api/command",
        `tool.pipe.attr snap types "vertex,edgeCenter,polyCenter"`);
    postJson("/api/command", "tool.pipe.attr snap innerRange 999999");
    postJson("/api/command", "tool.pipe.attr snap outerRange 999999");
    auto sr = querySnap(0.0, 0.0, 0.0, 320, 240);
    assert(sr["snapped"].type == JSONType.true_,
        "expected snap, got " ~ sr.toString);
    int t = cast(int)sr["targetType"].integer;
    // SnapType bitmask: Vertex=1, EdgeCenter=4, PolyCenter=16.
    assert(t == 1 || t == 4 || t == 16,
        "targetType expected 1 / 4 / 16, got " ~ t.to!string);
}
