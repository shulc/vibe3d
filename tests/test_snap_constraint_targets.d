// Tests for Stages 1–6 of doc/snap_constraint_targets_plan.md:
//
//  Stage 1: new SnapType bits (pivot/intersection/worldAxis/box) + SnapMode
//  Stage 2: WorldAxis LINE constraints
//  Stage 3: Pivot discrete targets from item frames
//  Stage 4: Box corner (discrete) + face plane (constraint) targets
//  Stage 5: scope filtering via typeEligible
//  Stage 6: screen-space edge Intersection

import std.net.curl;
import std.json;
import std.math   : fabs, sqrt;
import std.conv   : to;
import std.string : indexOf;
import std.format : format;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// Helpers (mirror test_toolpipe_snap.d / test_fixture_item_transform.d).
// ---------------------------------------------------------------------------

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

JSONValue cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

// POST /api/snap and return the JSON result.
JSONValue querySnap(double cx, double cy, double cz, int sx, int sy) {
    string body_ = format(
        `{"cursor":[%.6f,%.6f,%.6f],"sx":%d,"sy":%d,"excludeVerts":[]}`,
        cx, cy, cz, sx, sy);
    return postJson("/api/snap", body_);
}

// SNAP stage attrs from /api/toolpipe.
string[string] getSnapAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "SNAP") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    assert(false, "SNAP stage missing");
}

// Standard setup: default cube, snap enabled, huge range.
void snapSetup(string types) {
    postJson("/api/reset", `{"primitive":"cube"}`);
    cmd("tool.pipe.attr snap enabled true");
    cmd(`tool.pipe.attr snap types "` ~ types ~ `"`);
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
}

// Camera pixel at the viewport center (used by many tests).
int[2] viewportCenter() {
    auto cam = getJson("/api/camera");
    int cx = cast(int)(cam["vpX"].integer + cam["width"].integer  / 2);
    int cy = cast(int)(cam["vpY"].integer + cam["height"].integer / 2);
    return [cx, cy];
}

bool approx(double a, double b, double eps = 5e-3) {
    return fabs(a - b) < eps;
}

// =========================================================================
// Stage 1 / snap.mode command — config round-trip and reset.
// =========================================================================

unittest { // new type tokens appear in listAttrs types
    snapSetup("vertex");
    cmd(`tool.pipe.attr snap types "vertex,pivot,intersection,worldAxis,box"`);
    auto a = getSnapAttrs();
    assert(a["types"].indexOf("pivot")        >= 0, "pivot missing from types: "        ~ a["types"]);
    assert(a["types"].indexOf("intersection") >= 0, "intersection missing from types: " ~ a["types"]);
    assert(a["types"].indexOf("worldAxis")    >= 0, "worldAxis missing from types: "    ~ a["types"]);
    assert(a["types"].indexOf("box")          >= 0, "box missing from types: "          ~ a["types"]);
}

unittest { // toggleType round-trips new bits individually
    snapSetup("vertex");
    // pivot is NOT in the default set — toggle on then off.
    cmd("snap.toggleType pivot");
    auto a1 = getSnapAttrs();
    assert(a1["types"].indexOf("pivot") >= 0,
        "after toggle pivot should be on; got " ~ a1["types"]);
    cmd("snap.toggleType pivot");
    auto a2 = getSnapAttrs();
    assert(a2["types"].indexOf("pivot") < 0,
        "second toggle should remove pivot; got " ~ a2["types"]);
}

unittest { // snapMode default is 'global'
    snapSetup("vertex");
    auto a = getSnapAttrs();
    assert("snapMode" in a,
        "snapMode missing from SNAP attrs; got " ~ a.to!string);
    assert(a["snapMode"] == "global",
        "default snapMode expected global; got " ~ a["snapMode"]);
}

unittest { // snap.mode command round-trips all three modes
    snapSetup("vertex");
    foreach (mode; ["component", "item", "global"]) {
        cmd("snap.mode " ~ mode);
        auto a = getSnapAttrs();
        assert(a["snapMode"] == mode,
            "after snap.mode " ~ mode ~ " expected " ~ mode
            ~ "; got " ~ a["snapMode"]);
    }
}

unittest { // reset clears snapMode back to global
    snapSetup("vertex");
    cmd("snap.mode item");
    postJson("/api/reset", `{"primitive":"cube"}`);
    auto a = getSnapAttrs();
    assert(a["snapMode"] == "global",
        "reset must restore snapMode=global; got " ~ a["snapMode"]);
}

// =========================================================================
// Stage 2: WorldAxis constraint snap.
// Camera from front (+Z). Screen center ray passes through origin.
// The world Y-axis (line through origin, direction (0,1,0)) is
// perpendicular to the camera ray — closest point = origin = (0,0,0).
// With types=worldAxis + huge range the constraint snaps to (0,0,0).
// constraintType must equal 512 (WorldAxis = 1<<9).
// =========================================================================

unittest { // WorldAxis constraint fires; constraintType == 512
    postJson("/api/reset", `{"primitive":"cube"}`);
    postJson("/api/camera",
        `{"azimuth":0.0,"elevation":0.0,"distance":3.0,` ~
        `"focus":{"x":0,"y":0,"z":0}}`);
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types worldAxis");
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
    auto p = viewportCenter();
    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    assert(sr["snapped"].type == JSONType.true_,
        "WorldAxis constraint expected snapped=true; got " ~ sr.toString);
    assert(cast(int)sr["constraintType"].integer == 512,
        "constraintType expected 512 (WorldAxis); got " ~ sr.toString);
    // WorldPos must be near origin (the world axis passes through origin).
    auto wp = sr["worldPos"].array;
    assert(approx(wp[0].floating, 0.0, 0.1)
        && approx(wp[1].floating, 0.0, 0.1)
        && approx(wp[2].floating, 0.0, 0.1),
        "WorldAxis snap world pos expected near origin; got " ~ sr.toString);
    // Discrete tier is empty (no vertex/edge types) so targetType stays 0.
    assert(cast(int)sr["targetType"].integer == 0,
        "WorldAxis-only snap should have targetType=0; got " ~ sr.toString);
}

unittest { // WorldAxis snap returns constraintType in JSON response
    // Verify the /api/snap JSON carries the constraintType key.
    postJson("/api/reset", `{"primitive":"cube"}`);
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types worldAxis");
    auto p = viewportCenter();
    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    assert("constraintType" in sr,
        "/api/snap response missing constraintType field; got " ~ sr.toString);
}

// =========================================================================
// Stage 3: Pivot discrete target.
// Set layer pivot to (0.3, 0, 0); world pivot = pos + pivot = (0.3, 0, 0).
// types=pivot + huge range → snaps to that point; targetType == 128.
// =========================================================================

unittest { // Pivot discrete snap fires on world pivot position
    postJson("/api/reset", `{"primitive":"cube"}`);
    postJson("/api/camera",
        `{"azimuth":0.0,"elevation":0.0,"distance":3.0,` ~
        `"focus":{"x":0,"y":0,"z":0}}`);
    // Author a non-zero pivot on layer 0.
    cmd("layer.attr 0 pivot.x 0.3");
    cmd("layer.attr 0 pivot.y 0.0");
    cmd("layer.attr 0 pivot.z 0.0");
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types pivot");
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
    auto p = viewportCenter();
    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    assert(sr["snapped"].type == JSONType.true_,
        "Pivot snap expected snapped=true; got " ~ sr.toString);
    // targetType = Pivot = 1<<7 = 128.
    assert(cast(int)sr["targetType"].integer == 128,
        "targetType expected 128 (Pivot); got " ~ sr.toString);
    // World pos must equal the authored pivot (pos=(0,0,0) + pivot=(0.3,0,0)).
    auto wp = sr["worldPos"].array;
    assert(approx(wp[0].floating, 0.3),
        "Pivot snap world pos x expected ~0.3; got " ~ sr.toString);
    assert(approx(wp[1].floating, 0.0),
        "Pivot snap world pos y expected 0; got " ~ sr.toString);
    assert(approx(wp[2].floating, 0.0),
        "Pivot snap world pos z expected 0; got " ~ sr.toString);
}

// =========================================================================
// Stage 4: Box corner (discrete) snap.
// Default cube AABB = [-0.5, 0.5]^3; its 8 corners have ±0.5 coords.
// types=box + huge range → snaps to one of the 8 AABB corners;
// targetType == 4096 (Box = 1<<12).
// =========================================================================

unittest { // Box corner discrete snap fires; result at a cube AABB corner
    snapSetup("box");
    auto p = viewportCenter();
    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    assert(sr["snapped"].type == JSONType.true_,
        "Box snap expected snapped=true; got " ~ sr.toString);
    assert(cast(int)sr["targetType"].integer == 4096,
        "targetType expected 4096 (Box); got " ~ sr.toString);
    // Each coordinate of an AABB corner must be ±0.5.
    auto wp = sr["worldPos"].array;
    foreach (i, c; wp)
        assert(approx(c.floating, -0.5) || approx(c.floating, 0.5),
            "Box corner coord[" ~ i.to!string ~ "] expected ±0.5; got "
            ~ sr.toString);
}

// =========================================================================
// Stage 5: Scope filtering — typeEligible gates.
//   Global:    all types (Vertex=Component bucket + Pivot=Item bucket) eligible
//   Component: Pivot excluded (not in component bucket)
//   Item:      Vertex excluded (not in item bucket)
// =========================================================================

unittest { // Global mode: pivot snap fires
    postJson("/api/reset", `{"primitive":"cube"}`);
    cmd("layer.attr 0 pivot.x 0.3");
    cmd("snap.mode global");
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types pivot");
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
    auto p = viewportCenter();
    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    assert(sr["snapped"].type == JSONType.true_,
        "Global mode + types=pivot expected snap; got " ~ sr.toString);
}

unittest { // Component mode: pivot snap does NOT fire (pivot is item-only)
    postJson("/api/reset", `{"primitive":"cube"}`);
    cmd("layer.attr 0 pivot.x 0.3");
    cmd("snap.mode component");
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types pivot");
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
    auto p = viewportCenter();
    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    // typeEligible(Pivot, Component) = false → no candidates → no snap.
    assert(sr["snapped"].type == JSONType.false_,
        "Component mode + types=pivot expected NO snap; got " ~ sr.toString);
}

unittest { // Item mode: vertex snap does NOT fire (vertex is component-only)
    postJson("/api/reset", `{"primitive":"cube"}`);
    cmd("snap.mode item");
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types vertex");
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
    auto p = viewportCenter();
    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    // typeEligible(Vertex, Item) = false → no candidates → no snap.
    assert(sr["snapped"].type == JSONType.false_,
        "Item mode + types=vertex expected NO snap; got " ~ sr.toString);
}

unittest { // Item mode: pivot snap fires
    postJson("/api/reset", `{"primitive":"cube"}`);
    cmd("layer.attr 0 pivot.x 0.3");
    cmd("snap.mode item");
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types pivot");
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
    auto p = viewportCenter();
    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    assert(sr["snapped"].type == JSONType.true_,
        "Item mode + types=pivot expected snap; got " ~ sr.toString);
}

unittest { // Global mode: vertex snap still fires
    snapSetup("vertex");
    cmd("snap.mode global");
    auto p = viewportCenter();
    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    assert(sr["snapped"].type == JSONType.true_,
        "Global mode + types=vertex expected snap; got " ~ sr.toString);
    assert(cast(int)sr["targetType"].integer == 1,
        "targetType expected 1 (Vertex); got " ~ sr.toString);
}

// =========================================================================
// Stage 6: Intersection snap.
// Load a mesh with two X-crossing diagonal edges:
//   V0=(-1,-1,0) V1=(1,1,0) V2=(-1,1,0) V3=(1,-1,0)
//   Faces: [0,1,2] [0,3,1] [2,0,3]
//   Edge 0-1 (↗) crosses edge 3-2 (↘) at origin in screen space.
// Camera facing +Z, cursor at screen center → Intersection snap at origin.
// targetType == 256 (Intersection = 1<<8).
// =========================================================================

unittest { // Intersection snap fires on crossing edge pair
    // Load an X-crossing mesh.
    postJson("/api/load-mesh",
        `{"vertices":[[-1,-1,0],[1,1,0],[-1,1,0],[1,-1,0]],` ~
        `"faces":[[0,1,2],[0,3,1],[2,0,3]]}`);
    postJson("/api/camera",
        `{"azimuth":0.0,"elevation":0.0,"distance":5.0,` ~
        `"focus":{"x":0,"y":0,"z":0}}`);
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types intersection");
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
    auto p = viewportCenter();
    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    assert(sr["snapped"].type == JSONType.true_,
        "Intersection snap expected snapped=true; got " ~ sr.toString);
    assert(cast(int)sr["targetType"].integer == 256,
        "targetType expected 256 (Intersection); got " ~ sr.toString);
    // World pos must be near origin (the crossing point of the two diagonals).
    auto wp = sr["worldPos"].array;
    assert(approx(wp[0].floating, 0.0, 0.1)
        && approx(wp[1].floating, 0.0, 0.1)
        && approx(wp[2].floating, 0.0, 0.1),
        "Intersection snap world pos expected near origin; got " ~ sr.toString);
}

// =========================================================================
// Regression guard: existing 7 targets (vertex/edge/edgeCenter/
// polygon/polyCenter/grid/workplane) still snap correctly.
// Quick smoke check — full coverage is in test_toolpipe_snap.d.
// =========================================================================

unittest { // existing vertex snap unaffected after new-type changes
    snapSetup("vertex");
    cmd("snap.mode global");
    auto p = viewportCenter();
    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    assert(sr["snapped"].type == JSONType.true_,
        "Regression: vertex snap broken; got " ~ sr.toString);
    assert(cast(int)sr["targetType"].integer == 1,
        "Regression: targetType expected 1 (Vertex); got " ~ sr.toString);
}

unittest { // disabled snap still returns input pass-through with new types
    postJson("/api/reset", `{"primitive":"cube"}`);
    cmd("tool.pipe.attr snap enabled false");
    cmd(`tool.pipe.attr snap types "vertex,pivot,box,worldAxis,intersection"`);
    auto sr = querySnap(1.1, 2.2, 3.3, 100, 100);
    assert(sr["snapped"].type == JSONType.false_,
        "disabled + new types should still have snapped=false; got " ~ sr.toString);
    auto wp = sr["worldPos"].array;
    assert(fabs(wp[0].floating - 1.1) < 1e-3, "worldPos.x preserved");
    assert(fabs(wp[1].floating - 2.2) < 1e-3, "worldPos.y preserved");
    assert(fabs(wp[2].floating - 3.3) < 1e-3, "worldPos.z preserved");
}
