// Tool-deactivate / tool-switch resets the TOOL-DRIVEN toolpipe
// stages (ACEN / AXIS / WGHT) so the previous preset's state
// doesn't bleed into the next session. USER-DRIVEN globals (SNAP /
// SYMM / WORK) survive across tool changes — those reflect status-
// bar toolbar state the user controls independently.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

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

string[string] stageAttrs(string task) {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str != task) continue;
        string[string] m;
        foreach (k, v; st["attrs"].object)
            m[k] = v.str;
        return m;
    }
    assert(false, task ~ " stage missing");
}

unittest { // tool.set xfrm.elementMove off resets ACEN + WGHT to
           // defaults. Without this the next tool would inherit
           // mode=element / type=element from the previous session.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    // Simulate the post-click state: ACEN pivoted, falloff sphere
    // configured, anchor ring populated.
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0,0,0.5\"");
    cmd("tool.pipe.attr falloff anchorRing \"4,5,6,7\"");

    auto acenOn = stageAttrs("ACEN");
    auto wghtOn = stageAttrs("WGHT");
    assert(acenOn["mode"] == "element",
        "expected ACEN.mode=element while xfrm.elementMove is on; "
        ~ "got " ~ acenOn["mode"]);
    assert(acenOn["userPlaced"] == "true",
        "expected ACEN.userPlaced=true after userPlacedCenter set");
    assert(wghtOn["type"] == "element",
        "expected WGHT.type=element; got " ~ wghtOn["type"]);
    assert(wghtOn["anchorRing"] == "4,5,6,7",
        "expected WGHT.anchorRing=4,5,6,7; got " ~ wghtOn["anchorRing"]);

    cmd("tool.set xfrm.elementMove off");
    auto acenOff = stageAttrs("ACEN");
    auto wghtOff = stageAttrs("WGHT");
    assert(acenOff["mode"] == "none",
        "deactivate must reset ACEN.mode to default (none); got "
        ~ acenOff["mode"]);
    assert(acenOff["userPlaced"] == "false",
        "deactivate must clear ACEN.userPlaced; got "
        ~ acenOff["userPlaced"]);
    assert(wghtOff["type"] == "none",
        "deactivate must reset WGHT.type to none; got "
        ~ wghtOff["type"]);
    assert(wghtOff["anchorRing"] == "",
        "deactivate must clear WGHT.anchorRing; got "
        ~ wghtOff["anchorRing"]);
}

unittest { // Switching from xfrm.elementMove to TransformMove
           // (= xfrm.transform with T=1/R=0/S=0, no pipe attrs)
           // must reset ACEN/WGHT BEFORE the new preset's
           // preActivate runs. TransformMove has no pipe.* block,
           // so the resulting state is the post-reset baseline.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0.1,0.2,0.3\"");
    cmd("tool.pipe.attr falloff anchorRing \"0,1,2\"");

    cmd("tool.set TransformMove on");
    auto acen = stageAttrs("ACEN");
    auto wght = stageAttrs("WGHT");
    assert(acen["mode"] == "none",
        "switch to TransformMove must reset ACEN.mode (no preActivate "
        ~ "pin); got " ~ acen["mode"]);
    assert(acen["userPlaced"] == "false",
        "switch must clear ACEN.userPlaced; got " ~ acen["userPlaced"]);
    assert(wght["type"] == "none",
        "switch must reset WGHT.type (TransformMove doesn't pin "
        ~ "falloff); got " ~ wght["type"]);
    assert(wght["anchorRing"] == "",
        "switch must clear WGHT.anchorRing; got " ~ wght["anchorRing"]);
}

unittest { // Switching to a preset that DOES pin pipe stages
           // (xfrm.elementMove again) lands on the preset's
           // settings — reset fires first, then preActivate
           // applies. End state matches preset, not defaults.
    postJson("/api/reset", "");
    cmd("tool.set TransformMove on");
    cmd("tool.set xfrm.elementMove on");
    auto acen = stageAttrs("ACEN");
    auto wght = stageAttrs("WGHT");
    assert(acen["mode"] == "element",
        "switch to xfrm.elementMove must apply preset's "
        ~ "ACEN.mode=element; got " ~ acen["mode"]);
    assert(wght["type"] == "element",
        "switch must apply WGHT.type=element from preset; got "
        ~ wght["type"]);
}

unittest { // User-driven globals SNAP / SYMM / WORK survive tool
           // switches — they reflect status-bar toolbar state the
           // user controls independently, NOT preset config.
    postJson("/api/reset", "");

    // Turn snap on (= user-driven global). Verify it carries across
    // tool activation + deactivation.
    cmd("snap.toggle");
    auto snapBefore = stageAttrs("SNAP")["enabled"];
    assert(snapBefore == "true",
        "snap.toggle should enable; got " ~ snapBefore);

    cmd("tool.set xfrm.elementMove on");
    cmd("tool.set xfrm.elementMove off");

    auto snapAfter = stageAttrs("SNAP")["enabled"];
    assert(snapAfter == "true",
        "SNAP.enabled must survive tool activate+deactivate cycle; "
        ~ "got " ~ snapAfter);

    // Cleanup: leave snap off so this test doesn't affect siblings.
    cmd("snap.toggle");
}
