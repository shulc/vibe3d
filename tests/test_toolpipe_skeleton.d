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
    postJson("/api/command", "tool.pipe.attr workplane mode auto");
}
