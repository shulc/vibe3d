// Behaviour guards for Tool Properties panel-visibility filters:
//   - Constrain (disabled): panel hides dependent rows; HTTP surface stays full.
//   - Action Center (mode==none): panel hides the section; HTTP surface stays full.
//
// The ONE intentional side-effect: query-mode reads of hidden attrs return
// "unknown" — matching the falloff precedent (pipe.d:86-88). Locked here.
//
// Module-level params() snapshots (disabled→1 param / None→0 params) live in
// source/toolpipe/stages/constrain.d and source/toolpipe/stages/actcenter.d
// and run via `dub test --config=modeling`. This file covers the HTTP surface.

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

void resetScene() {
    postJson("/api/reset", `{"primitive":"cube"}`);
}

// Retrieve all listAttrs for a stage by its 4-char task code (e.g. "CONS", "ACEN").
string[string] getStageAttrs(string taskCode) {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == taskCode) {
            string[string] out_;
            foreach (k, v; st["attrs"].object)
                out_[k] = v.str;
            return out_;
        }
    }
    assert(false, taskCode ~ " stage missing from /api/toolpipe");
}

// ============================================================== Constrain
// listAttrs must return all 5 attrs even when disabled (panel-only filter).

unittest { // listAttrs: all 5 Constrain attrs present while disabled
    resetScene();
    auto a = getStageAttrs("CONS");
    assert(a["enabled"]  == "false", "default: enabled must be false");
    assert("geometry" in a, "listAttrs missing 'geometry' while disabled");
    assert("offset"   in a, "listAttrs missing 'offset' while disabled");
    assert("handle"   in a, "listAttrs missing 'handle' while disabled");
    assert("dblSided" in a, "listAttrs missing 'dblSided' while disabled");
}

unittest { // setAttr geometry round-trips while Constrain disabled
    resetScene();
    auto a0 = getStageAttrs("CONS");
    assert(a0["enabled"] == "false", "pre-condition: constrain must be disabled");
    postJson("/api/command", "tool.pipe.attr constrain geometry screen");
    auto a1 = getStageAttrs("CONS");
    assert(a1["geometry"] == "screen",
        "geometry setAttr while disabled failed; got " ~ a1["geometry"]);
}

unittest { // setAttr offset float round-trips while Constrain disabled
    resetScene();
    postJson("/api/command", "tool.pipe.attr constrain offset 2.5");
    auto a = getStageAttrs("CONS");
    assert(fabs(a["offset"].to!float - 2.5f) < 1e-3f,
        "offset round-trip failed; got " ~ a["offset"]);
}

// Query-mode read of a HIDDEN attr (while disabled) → error ("unknown attr").
// This is the ONE intentional narrowing; it matches falloff at type==None.
// HTTP error shape: {"status":"error","message":"..."}
unittest { // query-mode read of hidden 'geometry' while disabled → unknown
    resetScene();
    // confirm still disabled
    auto a0 = getStageAttrs("CONS");
    assert(a0["enabled"] == "false", "pre-condition: disabled");
    // `?` as third positional = query (read-back) mode; pipe.d:89-99
    auto r = postJson("/api/command", "tool.pipe.attr constrain geometry ?");
    bool gotError = (r.type == JSONType.object)
                 && ("status" in r.object)
                 && r["status"].str == "error";
    assert(gotError,
        "expected error for query-read of hidden attr while disabled; got " ~ r.toString());
}

// Once enabled, the same query-mode read succeeds.
unittest { // query-mode read of 'geometry' while enabled → success
    resetScene();
    postJson("/api/command", "constrain.toggle");   // enable
    auto a = getStageAttrs("CONS");
    assert(a["enabled"] == "true", "pre-condition: constrain must be enabled");
    auto r = postJson("/api/command", "tool.pipe.attr constrain geometry ?");
    bool hasError = (r.type == JSONType.object)
                 && ("status" in r.object)
                 && r["status"].str == "error";
    assert(!hasError,
        "expected success for query-read when enabled; got " ~ r.toString());
}

// ============================================================== Action Center
// listAttrs must return ACEN attrs even at mode==none (panel-only filter).

unittest { // listAttrs: 'mode' attr present at ACEN mode==none
    resetScene();
    auto a = getStageAttrs("ACEN");
    assert("mode" in a, "ACEN listAttrs missing 'mode' at none");
    assert(a["mode"] == "none",
        "default ACEN mode should be 'none'; got " ~ a["mode"]);
}

// Query-mode read of 'mode' while at none → error (section hidden).
unittest { // query-mode read of ACEN 'mode' at none → unknown
    resetScene();
    auto a0 = getStageAttrs("ACEN");
    assert(a0["mode"] == "none", "pre-condition: ACEN at none");
    auto r = postJson("/api/command", "tool.pipe.attr actionCenter mode ?");
    bool gotError = (r.type == JSONType.object)
                 && ("status" in r.object)
                 && r["status"].str == "error";
    assert(gotError,
        "expected error for query-read of ACEN mode at none; got " ~ r.toString());
}

// After switching to a non-None mode, query-mode read succeeds.
unittest { // query-mode read of ACEN 'mode' after actr.auto → success
    resetScene();
    postJson("/api/command", "actr.auto");
    auto a = getStageAttrs("ACEN");
    assert(a["mode"] == "auto", "pre-condition: ACEN mode should be auto after actr.auto");
    auto r = postJson("/api/command", "tool.pipe.attr actionCenter mode ?");
    bool hasError = (r.type == JSONType.object)
                 && ("status" in r.object)
                 && r["status"].str == "error";
    assert(!hasError,
        "expected success for query-read of ACEN mode after actr.auto; got " ~ r.toString());
}

unittest { // ACEN listAttrs remain full after actr.local (all cenX/Y/Z present)
    resetScene();
    postJson("/api/command", "actr.local");
    auto a = getStageAttrs("ACEN");
    assert("mode"       in a, "ACEN listAttrs missing 'mode'");
    assert("cenX"       in a, "ACEN listAttrs missing 'cenX'");
    assert("cenY"       in a, "ACEN listAttrs missing 'cenY'");
    assert("cenZ"       in a, "ACEN listAttrs missing 'cenZ'");
    assert("userPlaced" in a, "ACEN listAttrs missing 'userPlaced'");
}
