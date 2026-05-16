// Tests for Stage 14.8 — FalloffStage's `mode` attr (7-mode enum
// mirroring MODO's `element-mode`: auto / autoCent / vertex / edge /
// edgeCent / polygon / polyCent). Controls ElementMoveTool's
// pick-type restriction.

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

unittest { // every mode value round-trips through setAttr / listAttrs
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    foreach (mode; ["auto", "autoCent", "vertex", "edge",
                    "edgeCent", "polygon", "polyCent"]) {
        cmd("tool.pipe.attr falloff mode " ~ mode);
        assert(falloffAttr("mode") == mode,
            "mode=" ~ mode ~ " should round-trip; got "
            ~ falloffAttr("mode"));
    }
}

unittest { // unknown mode rejected (not silently coerced)
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    auto r = postJson("/api/command",
                      "tool.pipe.attr falloff mode bogus");
    assert(r["status"].str != "ok",
        "unknown mode should fail; got " ~ r.toString);
}

unittest { // default after xfrm.elementMove preset = auto (matches
           // MODO's `mode integer 0` baseline in resrc/presets.cfg)
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    assert(falloffAttr("mode") == "auto",
        "xfrm.elementMove default mode should be 'auto', got "
        ~ falloffAttr("mode"));
}
