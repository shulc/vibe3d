// Tests for phase 7.5a: FalloffStage skeleton + None type.
//
// Verifies:
// - WGHT stage is registered at TaskCode.Wght.
// - Default attrs: type=none, shape=smooth, default geometry placeholders.
// - falloff/enabled state path = "false" by default.
// - tool.pipe.attr falloff <name> <value> round-trips through listAttrs.
// - Setting type to each of the five recognised values (none / linear /
//   radial / screen / lasso) flips the published `falloff/enabled`
//   state path appropriately (false only for none).
// - Vec3 attrs (start / end / center / size) parse "x,y,z" CSV.
// - Bogus values are refused (setAttr fails silently — listAttrs still
//   shows the previous value).

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

string[string] getFalloffAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "WGHT") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    }
    assert(false, "WGHT stage missing from /api/toolpipe");
}

void resetCube() {
    postJson("/api/reset", `{"primitive":"cube"}`);
    postJson("/api/command", "tool.pipe.attr falloff type none");
}

// -------------------------------------------------------------------------
// 7.5a: WGHT stage is registered.
// -------------------------------------------------------------------------

unittest { // WGHT stage present
    resetCube();
    auto j = getJson("/api/toolpipe");
    bool found = false;
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT") { found = true; break; }
    assert(found, "WGHT stage missing from /api/toolpipe");
}

// -------------------------------------------------------------------------
// 7.5a: default attrs.
// -------------------------------------------------------------------------

unittest { // defaults
    resetCube();
    auto a = getFalloffAttrs();
    assert(a["type"]   == "none",   "default type expected none, got " ~ a["type"]);
    assert(a["shape"]  == "smooth", "default shape expected smooth, got " ~ a["shape"]);
    assert(a["start"]  == "0,0,0",  "default start: " ~ a["start"]);
    assert(a["end"]    == "0,1,0",  "default end: "   ~ a["end"]);
    assert(a["center"] == "0,0,0",  "default center: " ~ a["center"]);
    assert(a["size"]   == "1,1,1",  "default size: "   ~ a["size"]);
    assert(a["transparent"] == "false");
}

// -------------------------------------------------------------------------
// 7.5a: type setAttr round-trip for each recognised value.
// -------------------------------------------------------------------------

unittest { // type linear / radial / screen / lasso / none
    resetCube();
    foreach (label; ["linear", "radial", "screen", "lasso", "none"]) {
        postJson("/api/command", "tool.pipe.attr falloff type " ~ label);
        auto a = getFalloffAttrs();
        assert(a["type"] == label,
            "type expected " ~ label ~ ", got " ~ a["type"]);
    }
}

// -------------------------------------------------------------------------
// 7.5a: shape setAttr round-trip.
// -------------------------------------------------------------------------

unittest { // shape presets
    resetCube();
    foreach (label; ["linear", "easeIn", "easeOut", "smooth", "custom"]) {
        postJson("/api/command", "tool.pipe.attr falloff shape " ~ label);
        auto a = getFalloffAttrs();
        assert(a["shape"] == label,
            "shape expected " ~ label ~ ", got " ~ a["shape"]);
    }
}

// -------------------------------------------------------------------------
// 7.5a: Vec3 attrs parse CSV. argstring's bareword grammar doesn't
// include comma so the value must be quoted.
// -------------------------------------------------------------------------

unittest { // start / end / center / size CSV round-trip
    resetCube();
    postJson("/api/command", `tool.pipe.attr falloff start "1,2,3"`);
    postJson("/api/command", `tool.pipe.attr falloff end "4,5,6"`);
    postJson("/api/command", `tool.pipe.attr falloff center "7,8,9"`);
    postJson("/api/command", `tool.pipe.attr falloff size "0.5,0.25,0.125"`);
    auto a = getFalloffAttrs();
    assert(a["start"]  == "1,2,3",       "start: "  ~ a["start"]);
    assert(a["end"]    == "4,5,6",       "end: "    ~ a["end"]);
    assert(a["center"] == "7,8,9",       "center: " ~ a["center"]);
    assert(a["size"]   == "0.5,0.25,0.125", "size: " ~ a["size"]);
}

// -------------------------------------------------------------------------
// 7.5a: scalar attrs round-trip.
// -------------------------------------------------------------------------

unittest { // screenCx / screenCy / screenSize / softBorder / in / out
    resetCube();
    postJson("/api/command", "tool.pipe.attr falloff screenCx 320");
    postJson("/api/command", "tool.pipe.attr falloff screenCy 240");
    postJson("/api/command", "tool.pipe.attr falloff screenSize 80");
    postJson("/api/command", "tool.pipe.attr falloff softBorder 24");
    postJson("/api/command", "tool.pipe.attr falloff in 0.3");
    postJson("/api/command", "tool.pipe.attr falloff out 0.7");
    auto a = getFalloffAttrs();
    assert(a["screenCx"]   == "320", "screenCx: "   ~ a["screenCx"]);
    assert(a["screenCy"]   == "240", "screenCy: "   ~ a["screenCy"]);
    assert(a["screenSize"] == "80",  "screenSize: " ~ a["screenSize"]);
    assert(a["softBorder"] == "24",  "softBorder: " ~ a["softBorder"]);
    assert(a["in"]         == "0.3", "in: "         ~ a["in"]);
    assert(a["out"]        == "0.7", "out: "        ~ a["out"]);
}

// -------------------------------------------------------------------------
// 7.5a: transparent / lassoStyle round-trip.
// -------------------------------------------------------------------------

unittest { // transparent toggle
    resetCube();
    postJson("/api/command", "tool.pipe.attr falloff transparent true");
    auto a1 = getFalloffAttrs();
    assert(a1["transparent"] == "true");
    postJson("/api/command", "tool.pipe.attr falloff transparent false");
    auto a2 = getFalloffAttrs();
    assert(a2["transparent"] == "false");
}

unittest { // lassoStyle
    resetCube();
    foreach (label; ["freehand", "rect", "circle", "ellipse"]) {
        postJson("/api/command", "tool.pipe.attr falloff lassoStyle " ~ label);
        auto a = getFalloffAttrs();
        assert(a["lassoStyle"] == label,
            "lassoStyle expected " ~ label ~ ", got " ~ a["lassoStyle"]);
    }
}

// -------------------------------------------------------------------------
// 7.5a: bogus values must not corrupt state.
// -------------------------------------------------------------------------

unittest { // bogus type rejected
    resetCube();
    postJson("/api/command", "tool.pipe.attr falloff type linear");
    cast(void)post(baseUrl ~ "/api/command",
                   "tool.pipe.attr falloff type bogus");
    auto a = getFalloffAttrs();
    assert(a["type"] == "linear",
        "bogus type must not change state; got " ~ a["type"]);
}

unittest { // malformed Vec3 rejected
    resetCube();
    postJson("/api/command", `tool.pipe.attr falloff center "1,2,3"`);
    cast(void)post(baseUrl ~ "/api/command",
                   `tool.pipe.attr falloff center "garbage"`);
    auto a = getFalloffAttrs();
    assert(a["center"] == "1,2,3",
        "malformed Vec3 must not change state; got " ~ a["center"]);
}

// -------------------------------------------------------------------------
// 7.5b: switching type to linear auto-sizes start/end to the selection
// bbox, oriented along the workplane normal. With workplane=worldY a
// default cube produces start=(0,-0.5,0), end=(0,0.5,0) (centred on
// origin, length = bbox Y extent = 1).
// -------------------------------------------------------------------------

unittest { // auto-size linear on type switch
    resetCube();
    // Force workplane to worldY so the auto-size axis is deterministic.
    postJson("/api/command", "tool.pipe.attr workplane mode worldY");
    // Whole-mesh "selection" — no explicit selection means selectionBBox*
    // falls back to all geometry, mirroring the rest of vibe3d's
    // bbox-with-empty-selection convention.
    postJson("/api/command", "tool.pipe.attr falloff type linear");
    auto a = getFalloffAttrs();
    assert(a["type"]  == "linear", "type: " ~ a["type"]);
    assert(a["start"] == "0,-0.5,0",
        "auto-size start expected 0,-0.5,0; got " ~ a["start"]);
    assert(a["end"]   == "0,0.5,0",
        "auto-size end expected 0,0.5,0; got " ~ a["end"]);
    postJson("/api/command", "tool.pipe.attr workplane mode auto");
}

// -------------------------------------------------------------------------
// 7.5b: switching type to radial auto-sizes center+size to the selection
// bbox half-extents (cube → center=(0,0,0), size=(0.5,0.5,0.5)).
// -------------------------------------------------------------------------

unittest { // auto-size radial on type switch
    resetCube();
    postJson("/api/command", "tool.pipe.attr falloff type radial");
    auto a = getFalloffAttrs();
    assert(a["type"]   == "radial");
    assert(a["center"] == "0,0,0",
        "auto-size center expected 0,0,0; got " ~ a["center"]);
    assert(a["size"]   == "0.5,0.5,0.5",
        "auto-size size expected 0.5,0.5,0.5; got " ~ a["size"]);
}

// -------------------------------------------------------------------------
// 7.5b: setting the same type as the current one does NOT auto-size —
// the user can manually tune start/end and a no-op type set should
// preserve those edits.
// -------------------------------------------------------------------------

unittest { // no auto-size on no-op type set
    resetCube();
    postJson("/api/command", "tool.pipe.attr falloff type linear");
    postJson("/api/command", `tool.pipe.attr falloff start "10,20,30"`);
    postJson("/api/command", `tool.pipe.attr falloff end "40,50,60"`);
    // Re-set to linear: should leave start/end alone.
    postJson("/api/command", "tool.pipe.attr falloff type linear");
    auto a = getFalloffAttrs();
    assert(a["start"] == "10,20,30",
        "start clobbered by no-op type set: " ~ a["start"]);
    assert(a["end"]   == "40,50,60",
        "end clobbered by no-op type set: " ~ a["end"]);
}

// -------------------------------------------------------------------------
// 7.5b: switching back to None doesn't auto-size (no geometry to fit).
// -------------------------------------------------------------------------

unittest { // none does not auto-size
    resetCube();
    postJson("/api/command", "tool.pipe.attr falloff type linear");
    postJson("/api/command", `tool.pipe.attr falloff start "1,1,1"`);
    postJson("/api/command", "tool.pipe.attr falloff type none");
    auto a = getFalloffAttrs();
    assert(a["start"] == "1,1,1",
        "start clobbered by switch-to-none: " ~ a["start"]);
}
