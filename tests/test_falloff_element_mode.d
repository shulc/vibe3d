// Tests for Stage 14.8 — FalloffStage's `mode` attr (4-mode
// `element-mode` enum: auto / vertex / edge / polygon). Controls
// XfrmTransformTool's pick-type restriction (when falloff.element is active).
// Retired tokens autoCent / edgeCent / polyCent are accepted as aliases
// but echo back the bare token, so they are NOT tested in the round-trip loop.

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
void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

string falloffAttr(string key) {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT")
            return st["attrs"][key].str;
    assert(false, "WGHT stage missing");
}

unittest { // every surviving mode value round-trips through setAttr / listAttrs
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    foreach (mode; ["auto", "vertex", "edge", "polygon"]) {
        cmd("tool.pipe.attr falloff mode " ~ mode);
        assert(falloffAttr("mode") == mode,
            "mode=" ~ mode ~ " should round-trip; got "
            ~ falloffAttr("mode"));
    }
}

unittest { // retired alias tokens are accepted but echo back the bare token
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    // autoCent → auto
    cmd("tool.pipe.attr falloff mode autoCent");
    assert(falloffAttr("mode") == "auto",
        "autoCent alias should resolve to 'auto'; got " ~ falloffAttr("mode"));
    // edgeCent → edge
    cmd("tool.pipe.attr falloff mode edgeCent");
    assert(falloffAttr("mode") == "edge",
        "edgeCent alias should resolve to 'edge'; got " ~ falloffAttr("mode"));
    // polyCent → polygon
    cmd("tool.pipe.attr falloff mode polyCent");
    assert(falloffAttr("mode") == "polygon",
        "polyCent alias should resolve to 'polygon'; got " ~ falloffAttr("mode"));
}

unittest { // unknown mode rejected (not silently coerced)
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    auto r = postJson("/api/command",
                      "tool.pipe.attr falloff mode bogus");
    assert(r["status"].str != "ok",
        "unknown mode should fail; got " ~ r.toString);
}

unittest { // default after xfrm.elementMove preset = auto
           // (`mode integer 0` baseline)
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    assert(falloffAttr("mode") == "auto",
        "xfrm.elementMove default mode should be 'auto', got "
        ~ falloffAttr("mode"));
}
