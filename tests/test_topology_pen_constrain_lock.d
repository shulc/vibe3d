// Topology Pen P0 (doc/topopen_p0_plan.md) — constraint userLocked
// semantics, review fixes SF / SF-1.
//
// SF made `ConstrainStage.userLocked` mirror ActionCenterStage/AxisStage:
// the lock is set ONLY at an explicit-user COMMAND entry point
// (`constrain.toggle` or `tool.pipe.attr constrain enabled <v>`), never
// inside `onParamChanged` (which fires for a tool's own internal setAttr
// calls too, and used to lock unconditionally).
//
// SF-1 made `TopologyPenTool.activate()` respect a pre-existing lock: it
// used to unconditionally clobber `userLocked` back to false after
// composing CONS+Point, silently dropping a user's explicit constraint the
// moment they picked up the pen tool. This file proves BOTH halves:
//
//   1. Baseline (no prior lock): activating mesh.topoPen composes CONS
//      transiently; switching to another tool reverts it (enabled=false) —
//      the pre-existing resetTransientPipeStages() contract, unharmed by
//      the SF refactor.
//   2. The SF-1 regression itself: an explicit user lock (via
//      `tool.pipe.attr constrain enabled true`, then again via
//      `constrain.toggle`) SURVIVES activating mesh.topoPen AND a
//      subsequent switch to another tool.
//
// Run via: ./run_test.d topology_pen_constrain_lock

import std.net.curl;
import std.json;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}

// `tool.pipe.attr constrain enabled ?` — forms-engine query idiom
// (ToolPipeAttrCommand.setQuery); returns the live bool via the
// `{"status":"ok","value":<bool>}` wire shape (http_server.d).
bool constrainEnabled() {
    auto j = postJson("/api/command", "tool.pipe.attr constrain enabled ?");
    assert(j["status"].str == "ok", "query failed: " ~ j.toString);
    auto v = j["value"];
    assert(v.type == JSONType.true_ || v.type == JSONType.false_,
        "expected a bool value; got " ~ j.toString);
    return v.type == JSONType.true_;
}

void resetScene() {
    postJson("/api/reset", "");
}

unittest { // baseline: transient composition still reverts on tool switch
    resetScene();
    assert(!constrainEnabled(), "fresh scene: CONS should start disabled");

    cmd("tool.set mesh.topoPen on");
    assert(constrainEnabled(),
        "activate(): TopologyPenTool's own transient composition should "
        ~ "enable CONS");

    cmd("tool.set move on");   // tool switch -> resetTransientPipeStages()
    assert(!constrainEnabled(),
        "tool switch: an UNLOCKED (tool-composed) CONS must revert to "
        ~ "disabled — resetTransient() contract");
}

unittest { // SF-1: explicit lock via `tool.pipe.attr constrain enabled true`
    resetScene();
    cmd("tool.pipe.attr constrain enabled true");
    assert(constrainEnabled(), "explicit enable should take effect");

    cmd("tool.set mesh.topoPen on");
    assert(constrainEnabled(),
        "activate(): a pre-existing EXPLICIT user lock must NOT be "
        ~ "clobbered by TopologyPenTool composing CONS transiently");

    cmd("tool.set move on");   // tool switch -> resetTransientPipeStages()
    assert(constrainEnabled(),
        "tool switch: an EXPLICIT user lock must survive — this is the "
        ~ "exact SF-1 regression (activate() used to force userLocked=false "
        ~ "unconditionally, so resetTransient() would then wrongly revert "
        ~ "the user's own setting)");
}

unittest { // SF-1: explicit lock via `constrain.toggle`
    resetScene();
    cmd("constrain.toggle");   // false -> true, locked
    assert(constrainEnabled(), "constrain.toggle should enable CONS");

    cmd("tool.set mesh.topoPen on");
    assert(constrainEnabled(),
        "activate(): a constrain.toggle lock must NOT be clobbered either");

    cmd("tool.set move on");
    assert(constrainEnabled(),
        "tool switch: the constrain.toggle lock must survive");
}
