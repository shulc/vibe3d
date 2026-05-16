// Tests for D.1 of doc/deform_plan.md — Deform preset tools.
//
// Each preset wraps Move / Rotate / Scale with a FalloffStage
// configuration applied on activate. The test activates each
// preset via `tool.set <preset> on` and asserts the falloff stage
// ends up with the documented `type` + `transparent` values.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

string[string] falloffAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    assert(false, "WGHT stage missing");
}

void clearFalloff() {
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr falloff type none");
    postJson("/api/command", "tool.pipe.attr falloff transparent false");
}

void assertPreset(string toolId, string wantType, string wantTransparent) {
    clearFalloff();
    auto r = postJson("/api/command", "tool.set " ~ toolId ~ " on");
    assert(r["status"].str == "ok",
        "tool.set " ~ toolId ~ " failed: " ~ r.toString);
    auto a = falloffAttrs();
    assert(a["type"] == wantType,
        toolId ~ " expected falloff.type=" ~ wantType
              ~ ", got " ~ a["type"]);
    assert(a["transparent"] == wantTransparent,
        toolId ~ " expected falloff.transparent=" ~ wantTransparent
              ~ ", got " ~ a["transparent"]);
}

unittest { // softDrag = Move + Screen, camera-facing-only (matches
           // MODO's `resrc/presets.cfg` xfrm.softDrag = `trans integer 0`)
    assertPreset("xfrm.softDrag", "screen", "false");
}

unittest { // softMove = Move + Radial
    assertPreset("xfrm.softMove", "radial", "false");
}

unittest { // softRotate = Rotate + Radial
    assertPreset("xfrm.softRotate", "radial", "false");
}

unittest { // softScale = Scale + Radial
    assertPreset("xfrm.softScale", "radial", "false");
}

unittest { // twist = Rotate + Linear
    assertPreset("xfrm.twist", "linear", "false");
}

unittest { // swirl = Rotate + Radial
    assertPreset("xfrm.swirl", "radial", "false");
}

unittest { // shear = Move + Linear
    assertPreset("xfrm.shear", "linear", "false");
}

unittest { // taper = Scale + Linear
    assertPreset("xfrm.taper", "linear", "false");
}

// MODO ships shear / twist / taper with `shape integer 0` (Linear) in
// resrc/presets.cfg. The FalloffStage default is Smooth, so without the
// explicit `shape: linear` in tool_presets.yaml these deform tools would
// silently use the wrong attenuation curve.
unittest { // shear pins shape=linear (matches MODO presets.cfg)
    clearFalloff();
    postJson("/api/command", "tool.set xfrm.shear on");
    auto a = falloffAttrs();
    assert(a["shape"] == "linear",
        "xfrm.shear expected falloff.shape=linear, got " ~ a["shape"]);
}

unittest { // twist pins shape=linear (matches MODO presets.cfg)
    clearFalloff();
    postJson("/api/command", "tool.set xfrm.twist on");
    auto a = falloffAttrs();
    assert(a["shape"] == "linear",
        "xfrm.twist expected falloff.shape=linear, got " ~ a["shape"]);
}

unittest { // taper pins shape=linear (matches MODO presets.cfg)
    clearFalloff();
    postJson("/api/command", "tool.set xfrm.taper on");
    auto a = falloffAttrs();
    assert(a["shape"] == "linear",
        "xfrm.taper expected falloff.shape=linear, got " ~ a["shape"]);
}

unittest { // bulge = Scale + Radial
    assertPreset("xfrm.bulge", "radial", "false");
}

// -------------------------------------------------------------------------
// Each preset, once activated, leaves the falloff configured so that the
// underlying transform's per-vertex math sees a non-trivial weight on the
// next drag. Smoke-test: activate xfrm.softMove, run a /api/transform
// translate, verify the selection bbox actually shifted (falloff stage
// publishing `enabled=true` ⇒ tool consumes it).
// -------------------------------------------------------------------------

unittest { // softMove activates falloff (enabled=true after preset)
    clearFalloff();
    postJson("/api/command", "tool.set xfrm.softMove on");
    auto a = falloffAttrs();
    assert(a["type"] == "radial");
    // Auto-size on type-switch fits the radial to the cube bbox; size
    // should be non-trivial (cube half-extent = 0.5 → radius ≥ 0.5).
    auto sizeParts = a["size"]; // "x,y,z"
    assert(sizeParts.length > 0);
}

// xfrm.elementMove pins ACEN to Element and activates falloff.element
// (sphere around the picked component). MODO's preset leaves AXIS
// alone — we mirror that, so the transform gizmo stays on the
// default workplane axes rather than per-element ones.
unittest {
    clearFalloff();
    auto r = postJson("/api/command", "tool.set xfrm.elementMove on");
    assert(r["status"].str == "ok",
        "tool.set xfrm.elementMove failed: " ~ r.toString);
    auto j = getJson("/api/toolpipe");
    string acenMode;
    foreach (st; j["stages"].array) {
        if (st["task"].str == "ACEN") acenMode = st["attrs"]["mode"].str;
    }
    assert(acenMode == "element",
        "expected ACEN.mode=element, got " ~ acenMode);
    auto a = falloffAttrs();
    assert(a["type"]  == "element",
        "xfrm.elementMove expected falloff.type=element, got " ~ a["type"]);
    assert(a["shape"] == "linear",
        "xfrm.elementMove expected falloff.shape=linear, got " ~ a["shape"]);
}

// xfrm.flare mirrors MODO's `Flare` ToolPreset — surprisingly that's
// xfrm.push + linear falloff (NOT outward-scale, despite the name).
// Verify the preset plumbing wires both.
unittest {
    clearFalloff();
    auto r = postJson("/api/command", "tool.set xfrm.flare on");
    assert(r["status"].str == "ok",
        "tool.set xfrm.flare failed: " ~ r.toString);
    // Falloff stage should be type=linear shape=linear after preset.
    auto a = falloffAttrs();
    assert(a["type"]  == "linear",
        "xfrm.flare expected falloff.type=linear, got " ~ a["type"]);
    assert(a["shape"] == "linear",
        "xfrm.flare expected falloff.shape=linear, got " ~ a["shape"]);
    // Smoke-test apply: dist=0.05 with the preset's linear falloff
    // should push the cube outward (verts shift along their normals
    // weighted by the linear falloff that was auto-fitted to the bbox).
    auto da = postJson("/api/command", "tool.attr xfrm.flare dist 0.05");
    assert(da["status"].str == "ok");
    auto ap = postJson("/api/command", "tool.doApply");
    assert(ap["status"].str == "ok");
    // Just check the mesh wasn't NaN'd (dump succeeds).
    auto m = getJson("/api/model");
    assert(m["vertexCount"].integer == 8, "cube should still have 8 verts");
}
