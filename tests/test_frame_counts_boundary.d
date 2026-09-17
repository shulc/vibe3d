// Live owner-boundary witness for /api/frames/counts (task 6357).
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.algorithm : sort;
import std.array : array;
import std.json : JSONValue;

void main() {}

private string[] keys(JSONValue value) {
    auto result = value.object.byKey.array;
    result.sort;
    return result;
}

private void assertSchema(JSONValue counts) {
    assert(keys(counts) == ["frames", "handlePass", "last", "lastScene", "totals"]);
    enum recordKeys = ["allocBytes", "cellsConsidered", "cellsRendered",
        "drawCalls", "drawVerts", "handlePasses", "hoverPicks", "pass",
        "pipeEvals", "seq", "stageEvals", "statRebuilds", "uploadCalls",
        "uploadVerts"];
    enum passKeys = ["bgEdges", "bgFaces", "edges", "faceOverlay", "faces",
        "grid", "handles", "idPick", "imagePlane", "subpatch", "symmetry",
        "verts"];
    enum countKeys = ["calls", "verts"];
    enum handleKeys = ["generation", "ids", "receiptsDropped", "submitted", "writes"];
    foreach (name; ["lastScene", "last", "totals"]) {
        assert(keys(counts[name]) == recordKeys);
        assert(keys(counts[name]["pass"]) == passKeys);
        foreach (pass; passKeys)
            assert(keys(counts[name]["pass"][pass]) == countKeys);
    }
    assert(keys(counts["handlePass"]) == handleKeys);
}

private JSONValue resetAndRead() {
    auto reset = postJson("/api/frames/counts/reset", `{}`);
    assert(reset["status"].str == "ok");
    return getJson("/api/frames/counts");
}

unittest { // L1: every reset publishes whole post-reset frames
    auto scene = postJson("/api/command", commandBody("scene.reset", "{}"));
    assert("status" !in scene || scene["status"].str != "error");
    foreach (_; 0 .. 20) {
        auto counts = resetAndRead();
        assertSchema(counts);
        const frames = counts["frames"].integer;
        assert(frames >= 1 && frames < 100);
        assert(counts["totals"]["seq"].integer == frames);
        assert(counts["last"]["seq"].integer == frames);
        assert(counts["totals"]["cellsRendered"].integer >= 1);
        const perScene = counts["lastScene"]["pass"]["faces"]["verts"].integer;
        assert(perScene > 0);
        assert(counts["totals"]["pass"]["faces"]["verts"].integer
            == counts["totals"]["cellsRendered"].integer * perScene);
    }
}

unittest { // L2: each detached response is internally coherent while frames advance
    auto first = resetAndRead();
    long firstFrame = first["frames"].integer;
    long lastFrame = firstFrame;
    foreach (_; 0 .. 300) {
        auto counts = getJson("/api/frames/counts");
        const frames = counts["frames"].integer;
        assert(frames == counts["totals"]["seq"].integer);
        assert(frames == counts["last"]["seq"].integer);
        assert(counts["lastScene"]["seq"].integer <= frames);
        const perScene = counts["lastScene"]["pass"]["faces"]["verts"].integer;
        assert(counts["totals"]["pass"]["faces"]["verts"].integer
            == counts["totals"]["cellsRendered"].integer * perScene);
        lastFrame = frames;
    }
    assert(lastFrame - firstFrame >= 20,
        "6357 live coherence loop did not span 20 frame publications");
}
