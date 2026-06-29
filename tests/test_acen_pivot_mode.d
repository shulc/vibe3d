// Task 0082: ACEN/AXIS Pivot mode.
//
// Verifies:
// - ACEN Pivot mode returns the primary item's pivot world position.
// - AXIS Pivot mode returns the primary item's orientation basis.
// - `actr.pivot` combined preset flips both stages to pivot.
// - Null-primary fallback → (0,0,0) / identity basis.

import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : abs;
import std.format: format;

void main() {}

immutable baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

string[string] getAcenAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "ACEN") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    assert(false, "ACEN stage not found in /api/toolpipe");
}

string[string] getAxisAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "AXIS") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    assert(false, "AXIS stage not found in /api/toolpipe");
}

float floatAttr(string[string] attrs, string key) {
    return attrs[key].to!float;
}

// -------------------------------------------------------------------------
// Pivot mode: center = primary item's pivot world position.
// With default transform (pos=0, rot=0, scale=1) and pivot=(p,0,0):
//   pivot_world = pos + pivot = (p, 0, 0).
// -------------------------------------------------------------------------

unittest { // Pivot mode: pivot.x=2.0 → cenX=2.0
    resetCube();
    cmd("layer.attr 0 pivot.x 2.0");
    cmd("tool.pipe.attr actionCenter mode pivot");
    auto a = getAcenAttrs();
    assert(a["mode"] == "pivot", "expected mode=pivot, got " ~ a["mode"]);
    assert(abs(floatAttr(a, "cenX") - 2.0f) < 1e-4,
        "Pivot cenX expected 2.0, got " ~ a["cenX"]);
    assert(abs(floatAttr(a, "cenY")) < 1e-4,
        "Pivot cenY expected 0, got " ~ a["cenY"]);
    assert(abs(floatAttr(a, "cenZ")) < 1e-4,
        "Pivot cenZ expected 0, got " ~ a["cenZ"]);
}

unittest { // Pivot mode: pos.x=1.0 + pivot.x=0.5 → cenX=1.5
    resetCube();
    cmd("layer.attr 0 pos.x 1.0");
    cmd("layer.attr 0 pivot.x 0.5");
    cmd("tool.pipe.attr actionCenter mode pivot");
    auto a = getAcenAttrs();
    assert(abs(floatAttr(a, "cenX") - 1.5f) < 1e-4,
        "Pivot cenX expected 1.5 (pos+pivot), got " ~ a["cenX"]);
    assert(abs(floatAttr(a, "cenY")) < 1e-4, "cenY: " ~ a["cenY"]);
    assert(abs(floatAttr(a, "cenZ")) < 1e-4, "cenZ: " ~ a["cenZ"]);
}

unittest { // Pivot mode: pivot changes update the published center
    resetCube();
    cmd("tool.pipe.attr actionCenter mode pivot");
    cmd("layer.attr 0 pivot.z -1.0");
    auto a = getAcenAttrs();
    assert(abs(floatAttr(a, "cenZ") - (-1.0f)) < 1e-4,
        "Pivot cenZ expected -1.0, got " ~ a["cenZ"]);
}

// -------------------------------------------------------------------------
// AXIS Pivot mode: basis = item orientation.
// With default identity transform, basis = world basis.
// -------------------------------------------------------------------------

unittest { // AXIS Pivot mode: identity item → world basis
    resetCube();
    cmd("tool.pipe.attr axis mode pivot");
    auto a = getAxisAttrs();
    assert(a["mode"] == "pivot", "expected mode=pivot, got " ~ a["mode"]);
    assert(abs(floatAttr(a, "rightX") - 1.0f) < 1e-5, "rightX: " ~ a["rightX"]);
    assert(abs(floatAttr(a, "rightY"))         < 1e-5, "rightY: " ~ a["rightY"]);
    assert(abs(floatAttr(a, "rightZ"))         < 1e-5, "rightZ: " ~ a["rightZ"]);
    assert(abs(floatAttr(a, "upX"))            < 1e-5, "upX: "    ~ a["upX"]);
    assert(abs(floatAttr(a, "upY") - 1.0f)    < 1e-5, "upY: "    ~ a["upY"]);
    assert(abs(floatAttr(a, "upZ"))            < 1e-5, "upZ: "    ~ a["upZ"]);
    assert(abs(floatAttr(a, "fwdX"))           < 1e-5, "fwdX: "   ~ a["fwdX"]);
    assert(abs(floatAttr(a, "fwdY"))           < 1e-5, "fwdY: "   ~ a["fwdY"]);
    assert(abs(floatAttr(a, "fwdZ") - 1.0f)   < 1e-5, "fwdZ: "   ~ a["fwdZ"]);
}

// -------------------------------------------------------------------------
// actr.pivot combined preset: both ACEN and AXIS flip to pivot mode.
// -------------------------------------------------------------------------

unittest { // actr.pivot preset
    resetCube();
    cmd("actr.pivot");
    auto acen = getAcenAttrs();
    auto axis = getAxisAttrs();
    assert(acen["mode"] == "pivot", "ACEN mode after actr.pivot: " ~ acen["mode"]);
    assert(axis["mode"] == "pivot", "AXIS mode after actr.pivot: " ~ axis["mode"]);
}

// -------------------------------------------------------------------------
// Symmetry + Pivot mode: base-side override must NOT clobber the item pivot.
//
// Repro: symmetry enabled (X axis), all 8 cube verts selected (spans ±x),
// mode = pivot. Old code called baseSideCentroid() and overwrote pkt.center
// with the base-side vertex centroid (~0.5, 0, 0) instead of the item pivot.
// With the fix, Pivot (like Origin/Manual/Element/Local) is excluded from the
// override, so cenX stays at the item pivot (2.0).
// -------------------------------------------------------------------------

unittest { // symmetry ON + both-sides selection does NOT clobber Pivot center
    resetCube();
    cmd("layer.attr 0 pivot.x 2.0");          // item pivot world pos = (2, 0, 0)
    cmd("tool.pipe.attr symmetry enabled true");
    cmd("tool.pipe.attr symmetry axis x");
    // select all 8 cube vertices — spans both sides of the x=0 plane
    post(baseUrl ~ "/api/select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    cmd("tool.pipe.attr actionCenter mode pivot");
    auto a = getAcenAttrs();
    assert(a["mode"] == "pivot", "expected mode=pivot, got " ~ a["mode"]);
    // cenX must be the item pivot (2.0), NOT the base-side centroid (~0.5)
    assert(abs(floatAttr(a, "cenX") - 2.0f) < 1e-4,
        "Pivot+symmetry cenX expected 2.0 (item pivot), got " ~ a["cenX"]);
    assert(abs(floatAttr(a, "cenY")) < 1e-4, "cenY: " ~ a["cenY"]);
    assert(abs(floatAttr(a, "cenZ")) < 1e-4, "cenZ: " ~ a["cenZ"]);
}

// actr.pivot → switch back to auto via actr.auto, verify modes reset.
unittest { // actr.pivot then actr.auto restores auto on both stages
    resetCube();
    cmd("actr.pivot");
    cmd("actr.auto");
    auto acen = getAcenAttrs();
    auto axis = getAxisAttrs();
    assert(acen["mode"] == "auto", "ACEN after actr.auto: " ~ acen["mode"]);
    assert(axis["mode"] == "auto", "AXIS after actr.auto: " ~ axis["mode"]);
}
