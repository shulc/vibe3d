module test_headless_edit_lifecycle;

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.json : JSONValue;
import std.algorithm : sort;
import std.array : array;
import std.stdio : writeln;
import std.string : startsWith;

void main() {}

private JSONValue command(string id, string args = null) {
    return postJson("/api/command", commandBody(id, args));
}
private void accepted(string id, string args = null) {
    auto result = command(id, args);
    assert(result["status"].str == "ok", id ~ ": " ~ result.toString());
}
private JSONValue geometry() {
    auto model = getJson("/api/model");
    JSONValue value;
    value["vertices"] = model["vertices"];
    value["faces"] = model["faces"];
    return value;
}
private void fresh() {
    accepted("scene.reset");
    accepted("history.clear");
}

unittest { // Every registration-derived headless alias: real factory/product.
    // The create registrar pairs thirteen commands and mesh registration adds
    // the three Convolve aliases; this roster is independently pinned by the
    // CPU registration census. Each invocation uses a fresh admitted cube.
    enum aliases = ["prim.cube", "prim.sphere", "prim.ellipsoid", "prim.cylinder",
        "prim.tube", "prim.cone", "prim.capsule", "prim.torus", "prim.arc",
        "mesh.mirrorTool", "mesh.radialSweepTool", "mesh.tack", "mesh.bridgeTool",
        "xfrm.smooth", "xfrm.jitter", "xfrm.quantize"];
    auto registry = getJson("/api/registry");
    foreach (id; aliases) {
        bool registered;
        foreach (entry; registry["commands"].array) registered |= entry.str == id;
        assert(registered, "headless alias missing from real registry: " ~ id);
        fresh();
        if (id == "mesh.bridgeTool")
            accepted("mesh.select", `{"mode":"polygons","indices":[0,1]}`);
        if (id == "mesh.tack")
            accepted("mesh.select", `{"mode":"polygons","indices":[4]}`);
        if (id == "mesh.radialSweepTool")
            accepted("mesh.select", `{"mode":"edges","indices":[0]}`);
        accepted("history.clear");
        auto before = geometry();
        auto result = command(id, id == "mesh.tack"
            ? `{"targetFace":1,"targetPoint":[0,1,0]}` : null);
        const refuses = id.startsWith("xfrm.");
        assert((result["status"].str == "error") == refuses,
            "registered alias admission changed: " ~ id ~ result.toString());
        if (result["status"].str != "ok") {
            // Explicit refusal population; no success, inverse or replay is
            // credited to a refused product. A meaningful positive rig below
            // must replace a refusal before this family is counted accepted.
            writeln("L1-CONSUMER refusal ", id, " ", result.toString());
            assert(geometry() == before, "refused alias changed geometry: " ~ id);
            assert(getJson("/api/history")["undo"].array.length == 0,
                "refused alias recorded history: " ~ id);
            continue;
        }
        auto after = geometry();
        accepted("history.undo");
        assert(geometry() == before, "actual alias Undo must restore input: " ~ id);
        accepted("history.redo");
        assert(geometry() == after, "closed alias Redo must restore output: " ~ id);
        accepted("history.undo");
        assert(geometry() == before, "second alias Undo overwrote inverse: " ~ id);
        writeln("L1-CONSUMER accepted ", id, " changed=", after != before);
    }
}
