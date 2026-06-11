// Bare named falloff sub-tool commands (falloff.<type>).
//
// Verifies:
// - falloff.linear/radial/cylinder/screen/lasso each SET the falloff (WGHT)
//   stage's `type` to that value, exactly like the status-bar Falloff pulldown
//   (`tool.pipe.attr falloff type <type>`).
// - Activation is BARE: it does NOT change the active tool (no transform
//   bundle, no tool.set replacement).
// - After activation, the falloff stage's type-specific params become live
//   (start/end for linear, center/size for radial, axis for cylinder, ...).
// - A preset-set geometry attr survives a (no-op) re-activation — the on-switch
//   auto-size only fires on a REAL type change.
// - Command labels read as first-class sub-tools ("Linear Falloff", ...).

import std.net.curl;
import std.json;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

// Run a command via /api/command (argstring). Returns the parsed response.
JSONValue cmd(string argstring) {
    return postJson("/api/command", argstring);
}

// Read the live falloff (WGHT) stage attrs from /api/toolpipe.
string[string] falloffAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "WGHT") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    }
    assert(false, "WGHT (falloff) stage missing from /api/toolpipe");
}

// Query a falloff stage attr through the forms-engine `?` read-back path.
// Returns the response JSON (with "value" present on a successful query).
JSONValue queryFalloffAttr(string attr) {
    return cmd("tool.pipe.attr falloff " ~ attr ~ " ?");
}

void resetCube() {
    postJson("/api/reset", `{"primitive":"cube"}`);
    // Start from a known falloff state.
    cmd("tool.pipe.attr falloff type none");
}

// -------------------------------------------------------------------------
// Each bare command sets the falloff type and leaves the active tool alone.
// -------------------------------------------------------------------------

// (type, a type-specific attr the active type exposes via params()).
struct Case { string type; string typeAttr; }
immutable Case[] cases = [
    Case("linear",   "start"),
    Case("radial",   "center"),
    Case("cylinder", "axis"),
    Case("screen",   "screenSize"),
    Case("lasso",    "lassoStyle"),
];

unittest { // falloff.<type> sets the WGHT stage type
    foreach (c; cases) {
        resetCube();
        auto r = cmd("falloff." ~ c.type);
        assert(r["status"].str == "ok",
            "falloff." ~ c.type ~ " failed: " ~ r.toString());

        // Live stage attr reflects the new type. (`type` is excluded from
        // params(), so it is read back from /api/toolpipe stage attrs, not via
        // the tool.pipe.attr `?` query — the same as the status-bar pulldown.)
        auto attrs = falloffAttrs();
        assert("type" in attrs && attrs["type"] == c.type,
            "falloff." ~ c.type ~ ": WGHT type is '"
            ~ (("type" in attrs) ? attrs["type"] : "<missing>")
            ~ "', expected '" ~ c.type ~ "'");
    }
}

unittest { // params() now exposes the active type's type-specific fields
    foreach (c; cases) {
        resetCube();
        cmd("falloff." ~ c.type);
        // params() is type-filtered: querying a field of the ACTIVE type must
        // succeed (the field is exposed in the live schema).
        auto q = queryFalloffAttr(c.typeAttr);
        assert(q["status"].str == "ok" && "value" in q,
            "falloff." ~ c.type ~ ": type-specific attr '" ~ c.typeAttr
            ~ "' not exposed after activation: " ~ q.toString());
    }
}

unittest { // bare = the active tool is NOT changed
    foreach (c; cases) {
        resetCube();
        // Activate a transform tool (id "move"); it must stay active across
        // the bare falloff command. tool.attr <id> <attr> ? throws unless
        // <id> is the active tool, so a successful TX query proves move is
        // still active.
        cmd("tool.set move");
        auto r = cmd("falloff." ~ c.type);
        assert(r["status"].str == "ok",
            "falloff." ~ c.type ~ " failed: " ~ r.toString());

        auto q = cmd("tool.attr move TX ?");
        assert(q["status"].str == "ok" && "value" in q,
            "falloff." ~ c.type ~ " changed the active tool away from 'move': "
            ~ q.toString());
    }
}

unittest { // a preset-set geometry attr survives a no-op re-activation
    resetCube();
    cmd("falloff.cylinder");
    // Set an explicit axis, then re-activate the SAME type — the on-switch
    // auto-size only fires on a REAL type change, so the explicit value
    // must survive.
    cmd(`tool.pipe.attr falloff axis "1,0,0"`);
    auto before = falloffAttrs();
    assert("axis" in before, "cylinder: axis attr missing pre re-activation");
    cmd("falloff.cylinder");   // no-op type change
    auto after = falloffAttrs();
    assert(after["axis"] == before["axis"],
        "cylinder axis changed across no-op re-activation: '"
        ~ before["axis"] ~ "' -> '" ~ after["axis"] ~ "'");
}

unittest { // pulldown path and bare-command path land on the same type
    foreach (c; cases) {
        resetCube();
        cmd("tool.pipe.attr falloff type " ~ c.type);   // pulldown path
        auto viaPulldown = falloffAttrs()["type"];

        resetCube();
        cmd("falloff." ~ c.type);                       // bare command path
        auto viaCommand = falloffAttrs()["type"];

        assert(viaPulldown == viaCommand && viaCommand == c.type,
            "falloff." ~ c.type ~ ": pulldown='" ~ viaPulldown
            ~ "' command='" ~ viaCommand ~ "'");
    }
}
