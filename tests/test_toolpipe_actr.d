// Tests for phase 7.2f: actr.<mode> combined-preset commands.
// Verifies that running each preset flips both the ACEN and AXIS stages
// atomically to the matching MODO mode pair.

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

string stageMode(string taskCode) {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == taskCode)
            return st["attrs"]["mode"].str;
    }
    assert(false, "stage " ~ taskCode ~ " not found");
}

void resetCube() {
    postJson("/api/reset", `{"primitive":"cube"}`);
    postJson("/api/command", "tool.pipe.attr actionCenter mode auto");
    postJson("/api/command", "tool.pipe.attr axis mode auto");
}

// -------------------------------------------------------------------------
// Each preset switches BOTH ACEN and AXIS to the corresponding mode pair.
// Mappings per phase7_2_plan.md §"Canonical user commands".
// -------------------------------------------------------------------------

unittest { // actr.element
    resetCube();
    postJson("/api/command", "actr.element");
    assert(stageMode("ACEN") == "element",
        "actr.element: ACEN expected element, got " ~ stageMode("ACEN"));
    assert(stageMode("AXIS") == "element",
        "actr.element: AXIS expected element, got " ~ stageMode("AXIS"));
}

unittest { // actr.origin
    resetCube();
    postJson("/api/command", "actr.origin");
    assert(stageMode("ACEN") == "origin",
        "actr.origin: ACEN got " ~ stageMode("ACEN"));
    assert(stageMode("AXIS") == "world",
        "actr.origin: AXIS got " ~ stageMode("AXIS"));
}

unittest { // actr.local
    resetCube();
    postJson("/api/command", "actr.local");
    assert(stageMode("ACEN") == "local", "got " ~ stageMode("ACEN"));
    assert(stageMode("AXIS") == "local", "got " ~ stageMode("AXIS"));
}

unittest { // actr.auto resets both
    resetCube();
    // Switch away first.
    postJson("/api/command", "actr.element");
    postJson("/api/command", "actr.auto");
    assert(stageMode("ACEN") == "auto", "got " ~ stageMode("ACEN"));
    assert(stageMode("AXIS") == "auto", "got " ~ stageMode("AXIS"));
}

unittest { // actr.select
    resetCube();
    postJson("/api/command", "actr.select");
    assert(stageMode("ACEN") == "select", "got " ~ stageMode("ACEN"));
    assert(stageMode("AXIS") == "select", "got " ~ stageMode("AXIS"));
}

unittest { // actr.selectauto
    resetCube();
    postJson("/api/command", "actr.selectauto");
    assert(stageMode("ACEN") == "selectauto", "got " ~ stageMode("ACEN"));
    assert(stageMode("AXIS") == "selectauto", "got " ~ stageMode("AXIS"));
}

unittest { // actr.screen
    resetCube();
    postJson("/api/command", "actr.screen");
    assert(stageMode("ACEN") == "screen", "got " ~ stageMode("ACEN"));
    assert(stageMode("AXIS") == "screen", "got " ~ stageMode("AXIS"));
}

unittest { // actr.border (axis falls back to select per the mapping)
    resetCube();
    postJson("/api/command", "actr.border");
    assert(stageMode("ACEN") == "border", "got " ~ stageMode("ACEN"));
    assert(stageMode("AXIS") == "select", "got " ~ stageMode("AXIS"));
}

unittest { // actr.none — MODO's "(none)" Action Center popup entry,
           // implemented in MODO as `tool.clearTask "axis" "center"`.
           // Both stages report mode "none"; ACEN publishes origin (no
           // pivot), AXIS publishes world XYZ (no orientation override).
    resetCube();
    // Switch away from the mappings the previous tests left set.
    postJson("/api/command", "actr.element");
    postJson("/api/command", "actr.none");
    assert(stageMode("ACEN") == "none",
        "actr.none: ACEN expected none, got " ~ stageMode("ACEN"));
    assert(stageMode("AXIS") == "none",
        "actr.none: AXIS expected none, got " ~ stageMode("AXIS"));
    // Switching back to a real preset still works (no sticky state).
    postJson("/api/command", "actr.auto");
    assert(stageMode("ACEN") == "auto", "got " ~ stageMode("ACEN"));
    assert(stageMode("AXIS") == "auto", "got " ~ stageMode("AXIS"));
}
