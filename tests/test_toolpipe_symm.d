// Tests for phase 7.6a: SymmetryStage skeleton + master toggle.
//
// Verifies:
// - SYMM stage is registered at TaskCode.Symm, ordinal 0x31.
// - Default attrs: enabled=false, axis=x, offset=0, useWorkplane=false,
//   topology=false, epsilon=1e-4.
// - tool.pipe.attr symmetry <name> <value> round-trips through listAttrs.
// - Bogus values are rejected (setAttr fails — listAttrs still shows
//   the previous value).

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

string[string] getSymmetryAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "SYMM") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    }
    assert(false, "SYMM stage missing from /api/toolpipe");
}

void resetCube() {
    postJson("/api/reset", `{"primitive":"cube"}`);
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    postJson("/api/command", "tool.pipe.attr symmetry offset 0");
    postJson("/api/command", "tool.pipe.attr symmetry useWorkplane false");
    postJson("/api/command", "tool.pipe.attr symmetry topology false");
    postJson("/api/command", "tool.pipe.attr symmetry epsilon 0.0001");
}

// -------------------------------------------------------------------------
// 7.6a: SYMM stage is registered with correct task / id / ordinal.
// -------------------------------------------------------------------------

unittest { // SYMM stage present
    resetCube();
    auto j = getJson("/api/toolpipe");
    bool found = false;
    foreach (st; j["stages"].array) {
        if (st["task"].str != "SYMM") continue;
        assert(st["id"].str == "symmetry",
            "SYMM stage id should be 'symmetry', got " ~ st["id"].str);
        assert(st["ordinal"].integer == 0x31,
            "SYMM ordinal should be 0x31, got "
            ~ st["ordinal"].integer.to!string);
        assert(st["enabled"].type == JSONType.true_,
            "SymmetryStage should be enabled (registered) by default");
        found = true;
    }
    assert(found, "SYMM stage missing from /api/toolpipe");
}

// -------------------------------------------------------------------------
// 7.6a: defaults.
// -------------------------------------------------------------------------

unittest { // defaults
    resetCube();
    auto a = getSymmetryAttrs();
    assert(a["enabled"]      == "false",  "default enabled: " ~ a["enabled"]);
    assert(a["axis"]         == "x",      "default axis: "    ~ a["axis"]);
    assert(a["offset"]       == "0",      "default offset: "  ~ a["offset"]);
    assert(a["useWorkplane"] == "false",  "default useWorkplane: " ~ a["useWorkplane"]);
    assert(a["topology"]     == "false",  "default topology: " ~ a["topology"]);
    assert(a["epsilon"]      == "0.0001", "default epsilon: " ~ a["epsilon"]);
}

// -------------------------------------------------------------------------
// 7.6a: enabled / useWorkplane / topology bool round-trip.
// -------------------------------------------------------------------------

unittest { // enabled toggle
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    assert(getSymmetryAttrs()["enabled"] == "true");
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    assert(getSymmetryAttrs()["enabled"] == "false");
}

unittest { // useWorkplane toggle
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry useWorkplane true");
    assert(getSymmetryAttrs()["useWorkplane"] == "true");
    postJson("/api/command", "tool.pipe.attr symmetry useWorkplane false");
    assert(getSymmetryAttrs()["useWorkplane"] == "false");
}

unittest { // topology toggle (schema-only in v1; round-trips like any bool)
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry topology true");
    assert(getSymmetryAttrs()["topology"] == "true");
    postJson("/api/command", "tool.pipe.attr symmetry topology false");
    assert(getSymmetryAttrs()["topology"] == "false");
}

// -------------------------------------------------------------------------
// 7.6a: axis setAttr round-trip for each recognised value.
// -------------------------------------------------------------------------

unittest { // axis x / y / z
    resetCube();
    foreach (label; ["x", "y", "z"]) {
        postJson("/api/command", "tool.pipe.attr symmetry axis " ~ label);
        auto a = getSymmetryAttrs();
        assert(a["axis"] == label,
            "axis expected " ~ label ~ ", got " ~ a["axis"]);
    }
}

unittest { // axis uppercase also accepted
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry axis Y");
    auto a = getSymmetryAttrs();
    assert(a["axis"] == "y",
        "uppercase 'Y' should map to lowercase 'y', got " ~ a["axis"]);
}

// -------------------------------------------------------------------------
// 7.6a: scalar attrs round-trip.
// -------------------------------------------------------------------------

unittest { // offset float
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry offset 2.5");
    auto a = getSymmetryAttrs();
    assert(a["offset"] == "2.5", "offset: " ~ a["offset"]);
}

unittest { // epsilon float
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry epsilon 0.001");
    auto a = getSymmetryAttrs();
    assert(a["epsilon"] == "0.001", "epsilon: " ~ a["epsilon"]);
}

// -------------------------------------------------------------------------
// 7.6a: bogus values must not corrupt state.
// -------------------------------------------------------------------------

unittest { // bogus axis rejected
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry axis y");
    cast(void)post(baseUrl ~ "/api/command",
                   "tool.pipe.attr symmetry axis bogus");
    auto a = getSymmetryAttrs();
    assert(a["axis"] == "y",
        "bogus axis must not change state; got " ~ a["axis"]);
}

unittest { // negative epsilon rejected
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry epsilon 0.001");
    cast(void)post(baseUrl ~ "/api/command",
                   "tool.pipe.attr symmetry epsilon -1");
    auto a = getSymmetryAttrs();
    assert(a["epsilon"] == "0.001",
        "negative epsilon must be rejected; got " ~ a["epsilon"]);
}

unittest { // unknown attr rejected
    resetCube();
    auto r = postJson("/api/command", "tool.pipe.attr symmetry nosuchattr 1");
    assert(r["status"].str != "ok",
        "unknown attr should fail, got " ~ r.toString);
}
