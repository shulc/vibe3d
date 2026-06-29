// Tests for ConstrainStage skeleton (Stages 1-2 of doc/cons_constraint_plan.md).
//
// Verifies:
// - CONS stage is registered at TaskCode.Cons; task label "CONS".
// - Default attrs: enabled=false, geometry=point, offset=0, handle=true,
//   dblSided=false.
// - tool.pipe.attr constrain <name> <value> round-trips through listAttrs.
// - constrain.toggle flips enabled false→true→false.
// - /api/reset restores all attrs to defaults (reset isolation).

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

// Find the CONS stage entry in /api/toolpipe.
string[string] getConsAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "CONS") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    }
    assert(false, "CONS stage missing from /api/toolpipe");
}

void resetScene() {
    postJson("/api/reset", `{"primitive":"cube"}`);
}

// -------------------------------------------------------------------------
// Stage 1: CONS stage is registered.
// -------------------------------------------------------------------------

unittest { // CONS stage present in /api/toolpipe
    resetScene();
    auto j = getJson("/api/toolpipe");
    bool found = false;
    foreach (st; j["stages"].array)
        if (st["task"].str == "CONS") { found = true; break; }
    assert(found, "CONS stage missing from /api/toolpipe");
}

// -------------------------------------------------------------------------
// Stage 1: default attrs.
// -------------------------------------------------------------------------

unittest { // defaults: enabled=false, geometry=point, offset=0, handle=true, dblSided=false
    resetScene();
    auto a = getConsAttrs();
    assert(a["enabled"]  == "false", "default enabled: " ~ a["enabled"]);
    assert(a["geometry"] == "point", "default geometry: " ~ a["geometry"]);
    assert(a["offset"]   == "0",     "default offset: "  ~ a["offset"]);
    assert(a["handle"]   == "true",  "default handle: "  ~ a["handle"]);
    assert(a["dblSided"] == "false", "default dblSided: " ~ a["dblSided"]);
}

// -------------------------------------------------------------------------
// Stage 1: tool.pipe.attr round-trips.
// -------------------------------------------------------------------------

unittest { // setAttr enabled true
    resetScene();
    postJson("/api/command", "tool.pipe.attr constrain enabled true");
    auto a = getConsAttrs();
    assert(a["enabled"] == "true",
        "expected enabled=true, got " ~ a["enabled"]);
}

unittest { // setAttr geometry=off/screen/vector/point round-trips
    resetScene();
    foreach (mode; ["off", "screen", "vector", "point"]) {
        postJson("/api/command",
            "tool.pipe.attr constrain geometry " ~ mode);
        auto a = getConsAttrs();
        assert(a["geometry"] == mode,
            "geometry=" ~ mode ~ " round-trip failed; got " ~ a["geometry"]);
    }
}

unittest { // setAttr offset float round-trips
    resetScene();
    postJson("/api/command", "tool.pipe.attr constrain offset 1.5");
    auto a = getConsAttrs();
    assert(fabs(a["offset"].to!float - 1.5f) < 1e-3f,
        "offset 1.5 round-trip failed; got " ~ a["offset"]);
}

unittest { // setAttr handle false round-trips
    resetScene();
    postJson("/api/command", "tool.pipe.attr constrain handle false");
    auto a = getConsAttrs();
    assert(a["handle"] == "false",
        "handle=false round-trip failed; got " ~ a["handle"]);
}

unittest { // setAttr dblSided true round-trips
    resetScene();
    postJson("/api/command", "tool.pipe.attr constrain dblSided true");
    auto a = getConsAttrs();
    assert(a["dblSided"] == "true",
        "dblSided=true round-trip failed; got " ~ a["dblSided"]);
}

// -------------------------------------------------------------------------
// Stage 2: constrain.toggle flips enabled.
// -------------------------------------------------------------------------

unittest { // constrain.toggle false→true
    resetScene();
    auto a0 = getConsAttrs();
    assert(a0["enabled"] == "false", "expected initial enabled=false");
    postJson("/api/command", "constrain.toggle");
    auto a1 = getConsAttrs();
    assert(a1["enabled"] == "true",
        "after constrain.toggle expected true; got " ~ a1["enabled"]);
}

unittest { // constrain.toggle is a true toggle (true→false)
    resetScene();
    postJson("/api/command", "constrain.toggle");
    postJson("/api/command", "constrain.toggle");
    auto a = getConsAttrs();
    assert(a["enabled"] == "false",
        "two toggles should restore false; got " ~ a["enabled"]);
}

// -------------------------------------------------------------------------
// Stage 1: /api/reset restores defaults (reset isolation).
// -------------------------------------------------------------------------

unittest { // /api/reset restores all attrs to defaults
    resetScene();
    postJson("/api/command", "tool.pipe.attr constrain enabled true");
    postJson("/api/command", "tool.pipe.attr constrain geometry off");
    postJson("/api/command", "tool.pipe.attr constrain offset 3.0");
    postJson("/api/command", "tool.pipe.attr constrain handle false");
    postJson("/api/command", "tool.pipe.attr constrain dblSided true");
    postJson("/api/reset", `{"primitive":"cube"}`);
    auto a = getConsAttrs();
    assert(a["enabled"]  == "false", "post-reset enabled: " ~ a["enabled"]);
    assert(a["geometry"] == "point", "post-reset geometry: " ~ a["geometry"]);
    assert(a["offset"]   == "0",     "post-reset offset: "  ~ a["offset"]);
    assert(a["handle"]   == "true",  "post-reset handle: "  ~ a["handle"]);
    assert(a["dblSided"] == "false", "post-reset dblSided: " ~ a["dblSided"]);
}
