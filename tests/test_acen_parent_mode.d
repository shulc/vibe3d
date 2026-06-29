// Task 0082: ACEN/AXIS Parent mode + layer.parent command.
//
// Verifies:
// - layer.parent sets/clears the item-parent reference.
// - /api/layers exposes a "parent" index field (-1 = no parent).
// - ACEN Parent mode returns the primary's parent pivot world position.
// - AXIS Parent mode returns the parent's orientation basis.
// - Null-parent fallback → (0,0,0) / identity basis.
// - `actr.parent` combined preset flips both stages.
// - /api/reset clears the parent link (-j8 bleed guard).

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

// Read the "parent" index for a given layer index off /api/layers (-1=none).
int getLayerParent(int idx) {
    foreach (l; getJson("/api/layers")["layers"].array)
        if (l["index"].integer == idx) {
            auto p = l["parent"];
            if (p.type == JSONType.integer)  return cast(int)p.integer;
            if (p.type == JSONType.uinteger) return cast(int)p.uinteger;
            assert(false, "parent field not an int: " ~ p.toString);
        }
    assert(false, "layer " ~ idx.to!string ~ " not in /api/layers");
}

// -------------------------------------------------------------------------
// /api/layers "parent" field.
// -------------------------------------------------------------------------

unittest { // parent=-1 after reset (no parent)
    resetCube();
    assert(getLayerParent(0) == -1, "layer 0 parent should be -1 after reset");
}

unittest { // layer.parent sets and /api/layers reflects it
    resetCube();
    cmd("layer.add name:B");    // layer 1 = B (now primary)
    cmd("layer.parent child:1 parent:0");
    assert(getLayerParent(1) == 0, "layer 1 parent expected 0 after layer.parent");
    assert(getLayerParent(0) == -1, "layer 0 parent must remain -1");
}

unittest { // layer.parent clear (parent:-1) removes the link
    resetCube();
    cmd("layer.add name:B");
    cmd("layer.parent child:1 parent:0");
    cmd("layer.parent child:1 parent:-1");
    assert(getLayerParent(1) == -1, "parent should be -1 after clear");
}

// -------------------------------------------------------------------------
// Guards: self-parent and cycle must be rejected.
// -------------------------------------------------------------------------

unittest { // self-parent rejected
    resetCube();
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/command",
        "layer.parent child:0 parent:0"));
    assert(r["status"].str != "ok", "self-parent must be rejected");
}

unittest { // cycle guard: A→B→A rejected
    resetCube();
    cmd("layer.add name:B");                      // layer 1 = B
    cmd("layer.parent child:0 parent:1");         // A.parent = B
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/command",
        "layer.parent child:1 parent:0"));        // B.parent = A → cycle
    assert(r["status"].str != "ok", "cycle B→A must be rejected when A.parent=B");
    // clean up A.parent so next test starts clean
    cmd("layer.parent child:0 parent:-1");
}

// -------------------------------------------------------------------------
// ACEN Parent mode: null-parent fallback returns (0,0,0).
// -------------------------------------------------------------------------

unittest { // Parent mode with no parent → center = (0,0,0)
    resetCube();
    // layer 0 has no parent; switch to parent mode
    cmd("tool.pipe.attr actionCenter mode parent");
    auto a = getAcenAttrs();
    assert(a["mode"] == "parent", "expected mode=parent, got " ~ a["mode"]);
    assert(abs(floatAttr(a, "cenX")) < 1e-4, "null-parent cenX != 0: " ~ a["cenX"]);
    assert(abs(floatAttr(a, "cenY")) < 1e-4, "null-parent cenY != 0: " ~ a["cenY"]);
    assert(abs(floatAttr(a, "cenZ")) < 1e-4, "null-parent cenZ != 0: " ~ a["cenZ"]);
}

// -------------------------------------------------------------------------
// ACEN Parent mode: center = parent's pivot world position.
// B is primary, B.parent=A, A.pivot=(1.5,0,0), A.pos=default → cenX=1.5.
// -------------------------------------------------------------------------

unittest { // Parent mode: cenX = parent's pivot.x
    resetCube();
    cmd("layer.attr 0 pivot.x 1.5");   // A's pivot.x = 1.5
    cmd("layer.add name:B");            // B becomes primary (layer 1)
    cmd("layer.parent child:1 parent:0");
    cmd("tool.pipe.attr actionCenter mode parent");
    auto a = getAcenAttrs();
    assert(abs(floatAttr(a, "cenX") - 1.5f) < 1e-4,
        "Parent cenX expected 1.5, got " ~ a["cenX"]);
    assert(abs(floatAttr(a, "cenY")) < 1e-4, "cenY: " ~ a["cenY"]);
    assert(abs(floatAttr(a, "cenZ")) < 1e-4, "cenZ: " ~ a["cenZ"]);
}

unittest { // Parent mode: parent pos contributes to world position
    // A.pos.z = 2.0, A.pivot.z = 0.5 → A's pivot world pos.z = 2.5
    // B is primary, B.parent = A → Parent mode cenZ = 2.5
    resetCube();
    cmd("layer.attr 0 pos.z 2.0");
    cmd("layer.attr 0 pivot.z 0.5");
    cmd("layer.add name:B");
    cmd("layer.parent child:1 parent:0");
    cmd("tool.pipe.attr actionCenter mode parent");
    auto a = getAcenAttrs();
    assert(abs(floatAttr(a, "cenZ") - 2.5f) < 1e-4,
        "Parent cenZ expected 2.5 (pos+pivot), got " ~ a["cenZ"]);
}

// -------------------------------------------------------------------------
// AXIS Parent mode: identity parent transform → world basis.
// -------------------------------------------------------------------------

unittest { // AXIS Parent mode: identity parent → world basis
    resetCube();
    cmd("layer.add name:B");
    cmd("layer.parent child:1 parent:0");
    cmd("tool.pipe.attr axis mode parent");
    auto a = getAxisAttrs();
    assert(a["mode"] == "parent", "expected mode=parent, got " ~ a["mode"]);
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
// actr.parent combined preset: both ACEN and AXIS flip to parent.
// -------------------------------------------------------------------------

unittest { // actr.parent preset
    resetCube();
    cmd("actr.parent");
    auto acen = getAcenAttrs();
    auto axis = getAxisAttrs();
    assert(acen["mode"] == "parent", "ACEN mode after actr.parent: " ~ acen["mode"]);
    assert(axis["mode"] == "parent", "AXIS mode after actr.parent: " ~ axis["mode"]);
}

// -------------------------------------------------------------------------
// /api/reset clears the parent link (-j8 bleed guard).
// A parent set in one test must not survive into the next.
// -------------------------------------------------------------------------

unittest { // reset clears parent (-j8 bleed guard)
    resetCube();
    cmd("layer.add name:B");
    cmd("layer.parent child:1 parent:0");
    assert(getLayerParent(1) == 0, "parent should be 0 before reset");
    // reset collapses to 1 layer; the surviving layer has no parent
    parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(getLayerParent(0) == -1, "layer 0 parent must be -1 after reset");
}
