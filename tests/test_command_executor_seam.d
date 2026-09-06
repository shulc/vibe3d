// Command-funnel witness (task 4570, step 2). This file pins the published
// exception set, the reachable layer.attr continuation, and pre-apply drop on
// refusal. It does not identify which mesh a successful command edits while a
// tool owns an uncommitted preview; that remaining cell needs a geometry diff.
//
// The blocks are ordered for the mutation drill. Exception rows come before
// the Model row, so a policy mutated to always-false reaches the Model failure
// only after proving the exception stayed green. The refusal status mutation
// A1 lives at http_providers.refused; A0's throw-to-return change inside
// applyOrRefire is inert on this non-throwing HTTP path.

import http_client : getJson, postJson, postRaw;
import http_command_helpers : commandBody;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.json : JSONValue;
import std.string : startsWith;

void main() {}

enum string kArmedTool = "xfrm";

JSONValue command(string line) {
    return postJson("/api/command", line);
}

void resetCube(string context) {
    auto response = postJson("/api/command", commandBody("scene.reset"));
    assert(response["status"].str == "ok",
        context ~ ": scene.reset failed: " ~ response.toString);
}

string armedTool() {
    auto state = getJson("/api/tool/state");
    return ("tool" in state) ? state["tool"].str : "";
}

void armMove(string context) {
    auto response = postJson("/api/script", "tool.set move");
    assert(response["status"].str == "ok",
        context ~ ": tool.set move failed: " ~ response.toString);
    const tool = armedTool();
    assert(tool == kArmedTool,
        context ~ ": non-vacuity floor failed: tool.set move must arm xfrm, got '"
        ~ tool ~ "'");
}

long modelDepth() {
    return getJson("/api/undo/status")["modelDepth"].integer;
}

bool containsPrefix(const string[] ids, string prefix) {
    foreach (id; ids) {
        if (id.startsWith(prefix)) return true;
    }
    return false;
}

void cleanTeardown(string context) {
    postRaw("/api/command", "tool.set move off");
    resetCube(context);
}

// The reachable exception continues the armed session. This block must stay
// green when the policy is mutated to always-false and must be the first red
// block when it is mutated to always-true.
unittest {
    resetCube("layer.attr exception");
    armMove("layer.attr exception");
    auto layerResponse = command("layer.attr 0 pos.x 1.0");
    const toolAfter = armedTool();
    cleanTeardown("layer.attr teardown");
    assert(layerResponse["status"].str == "ok",
        "layer.attr exception: command did not execute: "
        ~ layerResponse.toString);
    assert(toolAfter == kArmedTool,
        "layer.attr exception: layer.attr dropped the armed xfrm session");
}

// A successful Model command drops the armed tool and contributes exactly one
// Model history entry. The depth delta proves that an empty tool state did not
// come from a command that never ran.
unittest {
    resetCube("Model command");
    armMove("Model command");
    const before = modelDepth();
    auto response = command("layer.rename name:Renamed");
    const toolAfter = armedTool();
    const after = modelDepth();
    cleanTeardown("Model command teardown");
    assert(response["status"].str == "ok",
        "Model command: layer.rename did not execute: " ~ response.toString);
    assert(toolAfter.length == 0,
        "Model command: layer.rename left the armed xfrm session active");
    assert(after == before + 1,
        "Model command: layer.rename must add exactly one Model history entry; depth "
        ~ before.to!string ~ " -> " ~ after.to!string);
}

// A refused command reports the refusal, records no Model history entry, and
// drops the armed tool. Keep depth before status: the A1 adapter mutation is
// observed green there before status reddens, proving the two halves apart.
unittest {
    resetCube("refusal contract");
    armMove("refusal contract");
    const before = modelDepth();
    auto response = command("mesh.bevel");
    const after = modelDepth();
    const toolAfter = armedTool();
    cleanTeardown("refusal teardown");
    assert(after == before,
        "refusal contract: mesh.bevel refusal changed Model history depth "
        ~ before.to!string ~ " -> " ~ after.to!string);
    assert(response["status"].str == "error",
        "refusal contract: mesh.bevel refusal must return status:error, got "
        ~ response.toString);
    assert(toolAfter.length == 0,
        "refusal contract: mesh.bevel refusal left the armed xfrm session active");
}

// The registry publishes the complete cold-command policy. This pins all four
// exclusions, including prefixes whose concrete commands cannot reach the
// prefix checks because their flags already fail the Model gate.
unittest {
    auto registry = getJson("/api/registry");
    string[] drops;
    foreach (id; registry["commandsDroppingToolBeforeApply"].array)
        drops ~= id.str;

    assert(registry["commands"].array.length == 261,
        "drop-policy registry lost its command population: "
        ~ registry["commands"].array.length.to!string);
    assert(!containsPrefix(drops, "tool."),
        "drop-policy registry contains an excluded tool.* command");
    assert(!containsPrefix(drops, "scene."),
        "drop-policy registry contains an excluded scene.* command");
    assert(!containsPrefix(drops, "file."),
        "drop-policy registry contains an excluded file.* command");
    assert(!drops.canFind("layer.attr"),
        "drop-policy registry contains the layer.attr exception");
    assert(drops.length == 148,
        "drop-policy registry population changed: " ~ drops.length.to!string);
    assert(drops.canFind("layer.rename"),
        "drop-policy registry lost the layer.rename positive control");
    assert(drops.canFind("mesh.bevel"),
        "drop-policy registry lost the mesh.bevel positive control");
}

unittest {
    cleanTeardown("final teardown");
}
