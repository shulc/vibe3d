// Tests for phase 7.0+7.1: Tool Pipe skeleton + Workplane stage.
//
// 7.0 — verifies the pipeline data structures are exposed via
// /api/toolpipe and that the JSON envelope is well-formed.
// 7.1 — verifies the WorkplaneStage is registered by default with
// mode=auto, that tool.pipe.attr can mutate the mode through the
// HTTP path, and that an unknown attr / value is rejected.

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

// -------------------------------------------------------------------------
// 7.0: /api/toolpipe responds with a JSON envelope containing a "stages"
//    array.
// -------------------------------------------------------------------------

unittest { // envelope shape
    auto j = getJson("/api/toolpipe");
    assert("stages" in j.object,
        "/api/toolpipe must expose a 'stages' field, got: " ~ j.toString);
    assert(j["stages"].type == JSONType.array,
        "'stages' must be an array, got " ~ j["stages"].type.to!string);
}

// -------------------------------------------------------------------------
// 7.0: Endpoint is idempotent — repeated GETs return identical payloads.
// -------------------------------------------------------------------------

unittest { // idempotent
    // Reset workplane to default mode so sequential tests don't leak
    // state from earlier ones into the idempotence check.
    postJson("/api/command", "tool.pipe.attr workplane mode auto");
    auto a = getJson("/api/toolpipe");
    auto b = getJson("/api/toolpipe");
    assert(a.toString == b.toString,
        "/api/toolpipe should be idempotent, got differing payloads");
}

// -------------------------------------------------------------------------
// 7.1: WorkplaneStage is registered by default with mode=auto.
// -------------------------------------------------------------------------

unittest { // default WorkplaneStage
    postJson("/api/command", "tool.pipe.attr workplane mode auto");
    auto j = getJson("/api/toolpipe");
    bool found = false;
    foreach (s; j["stages"].array) {
        if (s["task"].str != "WORK") continue;
        assert(s["id"].str == "workplane",
            "WORK stage id should be 'workplane', got " ~ s["id"].str);
        assert(s["ordinal"].integer == 0x30,
            "WORK ordinal should be 0x30 (LXs_ORD_WORK), got "
            ~ s["ordinal"].integer.to!string);
        assert(s["enabled"].type == JSONType.true_,
            "WorkplaneStage should be enabled by default");
        assert(s["attrs"]["mode"].str == "auto",
            "default mode should be 'auto', got " ~ s["attrs"]["mode"].str);
        found = true;
    }
    assert(found, "WorkplaneStage not found in /api/toolpipe");
}

// -------------------------------------------------------------------------
// 7.1: tool.pipe.attr workplane mode worldY persists in subsequent reads.
// -------------------------------------------------------------------------

unittest { // mutable mode
    auto resp = postJson("/api/command", "tool.pipe.attr workplane mode worldY");
    assert(resp["status"].str == "ok",
        "tool.pipe.attr workplane mode worldY failed: " ~ resp.toString);

    auto j = getJson("/api/toolpipe");
    foreach (s; j["stages"].array) {
        if (s["id"].str == "workplane") {
            assert(s["attrs"]["mode"].str == "worldY",
                "after set, mode should be 'worldY', got "
                ~ s["attrs"]["mode"].str);
            break;
        }
    }

    // Cycle through every defined mode to confirm setAttr accepts them.
    foreach (mode; ["worldX", "worldY", "worldZ", "auto"]) {
        auto r = postJson("/api/command", "tool.pipe.attr workplane mode " ~ mode);
        assert(r["status"].str == "ok",
            "tool.pipe.attr mode=" ~ mode ~ " failed: " ~ r.toString);
    }
    // Reset for downstream tests.
    postJson("/api/command", "tool.pipe.attr workplane mode auto");
}

// -------------------------------------------------------------------------
// 7.1: Unknown stage / unknown attr / invalid value all surface as
// errors instead of silently doing nothing.
// -------------------------------------------------------------------------

unittest { // input validation
    auto r1 = postJson("/api/command", "tool.pipe.attr nosuchstage mode auto");
    assert(r1["status"].str != "ok",
        "tool.pipe.attr on unknown stage should fail, got " ~ r1.toString);

    auto r2 = postJson("/api/command", "tool.pipe.attr workplane nosuchattr 1");
    assert(r2["status"].str != "ok",
        "tool.pipe.attr with unknown attr should fail, got " ~ r2.toString);

    auto r3 = postJson("/api/command", "tool.pipe.attr workplane mode garbage");
    assert(r3["status"].str != "ok",
        "tool.pipe.attr with invalid value should fail, got " ~ r3.toString);

    // Reset for downstream tests.
    postJson("/api/command", "workplane.reset");
}

// =========================================================================
// Phase 7.1+: workplane.* commands (MODO-aligned)
// =========================================================================

double readAttrFloat(JSONValue stage, string key) {
    auto v = stage["attrs"][key];
    if (v.type == JSONType.float_)   return v.floating;
    if (v.type == JSONType.integer)  return cast(double)v.integer;
    if (v.type == JSONType.string)   return v.str.to!double;
    return double.nan;
}

JSONValue workplaneStage() {
    auto j = getJson("/api/toolpipe");
    foreach (s; j["stages"].array) {
        if (s["id"].str == "workplane") return s;
    }
    assert(false, "workplane stage missing");
}

// -------------------------------------------------------------------------
// workplane.reset returns the stage to auto / origin / zero rotation.
// -------------------------------------------------------------------------

unittest { // workplane.reset
    // Dirty the state first.
    postJson("/api/command", "tool.pipe.attr workplane rotZ 90");
    postJson("/api/command", "tool.pipe.attr workplane cenY 5");

    auto r = postJson("/api/command", "workplane.reset");
    assert(r["status"].str == "ok", "workplane.reset failed: " ~ r.toString);

    auto wp = workplaneStage();
    assert(wp["attrs"]["auto"].str == "true",
        "after reset, auto should be true, got " ~ wp["attrs"]["auto"].str);
    foreach (k; ["cenX", "cenY", "cenZ", "rotX", "rotY", "rotZ"]) {
        double v = readAttrFloat(wp, k);
        assert(v == 0,
            "after reset, " ~ k ~ " should be 0, got " ~ v.to!string);
    }
}

// -------------------------------------------------------------------------
// workplane.edit applies absolute values to the named keys; unspecified
// keys remain untouched.
// -------------------------------------------------------------------------

unittest { // workplane.edit absolute set
    postJson("/api/command", "workplane.reset");

    auto r = postJson("/api/command",
        "workplane.edit cenX:1 cenY:2 cenZ:3 rotX:10 rotY:20 rotZ:30");
    assert(r["status"].str == "ok", "workplane.edit failed: " ~ r.toString);

    auto wp = workplaneStage();
    assert(wp["attrs"]["auto"].str == "false",
        "after edit, auto should flip to false");
    assert(readAttrFloat(wp, "cenX") == 1);
    assert(readAttrFloat(wp, "cenY") == 2);
    assert(readAttrFloat(wp, "cenZ") == 3);
    assert(readAttrFloat(wp, "rotX") == 10);
    assert(readAttrFloat(wp, "rotY") == 20);
    assert(readAttrFloat(wp, "rotZ") == 30);

    // Partial edit — only rotZ; the rest should stay.
    postJson("/api/command", "workplane.edit rotZ:45");
    wp = workplaneStage();
    assert(readAttrFloat(wp, "rotZ") == 45);
    assert(readAttrFloat(wp, "cenX") == 1, "partial edit should leave cenX alone");
    assert(readAttrFloat(wp, "rotX") == 10, "partial edit should leave rotX alone");

    postJson("/api/command", "workplane.reset");
}

// -------------------------------------------------------------------------
// workplane.rotate axis:Z angle:N adds N to rotation.z.
// -------------------------------------------------------------------------

unittest { // workplane.rotate cumulative
    postJson("/api/command", "workplane.reset");

    auto r = postJson("/api/command", "workplane.rotate axis:Z angle:30");
    assert(r["status"].str == "ok", "workplane.rotate failed: " ~ r.toString);
    assert(readAttrFloat(workplaneStage(), "rotZ") == 30);

    postJson("/api/command", "workplane.rotate axis:Z angle:60");
    assert(readAttrFloat(workplaneStage(), "rotZ") == 90,
        "two rotations should accumulate");

    postJson("/api/command", "workplane.rotate axis:X angle:45");
    assert(readAttrFloat(workplaneStage(), "rotX") == 45);

    auto bad = postJson("/api/command", "workplane.rotate axis:Q angle:10");
    assert(bad["status"].str != "ok",
        "invalid axis should fail, got " ~ bad.toString);

    postJson("/api/command", "workplane.reset");
}

// -------------------------------------------------------------------------
// workplane.offset axis:X dist:N adds N to center.x.
// -------------------------------------------------------------------------

unittest { // workplane.offset cumulative
    postJson("/api/command", "workplane.reset");

    postJson("/api/command", "workplane.offset axis:X dist:0.5");
    assert(readAttrFloat(workplaneStage(), "cenX") == 0.5);

    postJson("/api/command", "workplane.offset axis:X dist:0.5");
    assert(readAttrFloat(workplaneStage(), "cenX") == 1.0,
        "two offsets should accumulate");

    postJson("/api/command", "workplane.offset axis:Y dist:-2");
    assert(readAttrFloat(workplaneStage(), "cenY") == -2);

    postJson("/api/command", "workplane.reset");
}

// -------------------------------------------------------------------------
// workplane.alignToSelection — polygon mode aligns plane to selected
// face's normal + centroid. Reset first, build a default cube via
// /api/reset, select one face, run the command, verify the workplane's
// auto flag flipped off (a successful alignment pins the plane).
// -------------------------------------------------------------------------

unittest { // workplane.alignToSelection polygon mode
    postJson("/api/command", "workplane.reset");

    // Default reset gives an 8-vert cube. Switch to polygon mode and
    // select face 1 (the +Z face by cube factory convention).
    auto rr = postJson("/api/reset", "");
    assert(rr["status"].str == "ok", rr.toString);
    postJson("/api/command", "select.typeFrom polygon");
    postJson("/api/command", "select.element polygon set 1");

    auto r = postJson("/api/command", "workplane.alignToSelection");
    assert(r["status"].str == "ok",
        "workplane.alignToSelection failed: " ~ r.toString);

    auto wp = workplaneStage();
    assert(wp["attrs"]["auto"].str == "false",
        "alignToSelection should pin the workplane (auto=false)");

    postJson("/api/command", "workplane.reset");
    postJson("/api/reset", "");
}
