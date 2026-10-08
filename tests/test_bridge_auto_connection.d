// Captured structural/Curve behavior 2026-10-08, task 20261600.
// The HTTP command and session doors pin selection, undo and refusal together.
import http_client : getJson, postJson, postRawAllowingErrorStatus,
    testBaseUrl, keepAliveGet, frameFence;
import http_command_helpers : commandBody;
import std.json;
import std.conv : to;
import std.algorithm : sort, canFind, reverse;
import std.process : environment;

void main() {}

private bool cell(string name) {
    return environment.get("VIBE3D_CELL", name) == name;
}
private JSONValue fixture(string name) {
    auto f = parseJSON(import("fixtures/bridge_auto_connection/frozen.json"));
    assert(f["cases"].array.length == 14, "frozen case population 14");
    foreach (c; f["cases"].array) if (c["case"].str == name) return c;
    assert(false, "missing frozen case " ~ name);
}
private void ok(JSONValue r) {
    assert(r["status"].str == "ok", "bridge command failed: " ~ r.toString);
}
private void cmd(string line) { ok(postJson("/api/command", line)); }
private string planes() {
    return cast(string) keepAliveGet(testBaseUrl ~ "/api/mesh/planes");
}
private size_t depth() { return getJson("/api/history")["undo"].array.length; }
private ulong key(JSONValue e) {
    auto a = cast(uint)e[0].integer, b = cast(uint)e[1].integer;
    return (cast(ulong)(a < b ? a : b) << 32) | (a < b ? b : a);
}
private ulong[] selected(JSONValue model) {
    ulong[] result;
    foreach (i; getJson("/api/selection")["selectedEdges"].array)
        result ~= key(model["edges"][i.integer]);
    return result;
}
private ulong[] load(JSONValue c) {
    ok(postJson("/api/command", commandBody("scene.reset", `{"empty":true}`)));
    auto inp = c["input"], scene = JSONValue.emptyObject;
    scene["vertices"] = inp["vertices"]; scene["faces"] = inp["faces"];
    ok(postJson("/api/command", commandBody("scene.loadMesh", scene.toString)));
    auto model = getJson("/api/model");
    JSONValue[] indices;
    foreach (e; inp["selection_packet_order"]["edges"].array) {
        bool found;
        foreach (i, actual; model["edges"].array) if (key(e) == key(actual)) {
            indices ~= JSONValue(i); found = true; break;
        }
        assert(found, "input selected edge exists");
    }
    assert(indices.length == 8, "input edge population 8");
    auto sel = JSONValue.emptyObject;
    sel["mode"] = JSONValue("edges"); sel["indices"] = JSONValue(indices);
    ok(postJson("/api/command", commandBody("mesh.select", sel.toString)));
    cmd("history.clear");
    assert(depth() == 0, "history cleared with headroom");
    return selected(model);
}
private JSONValue params(JSONValue c) {
    auto a = c["attributes_observed"], p = JSONValue.emptyObject;
    foreach (name; ["segments", "twist", "mode", "tension", "orient", "uvs", "steps"])
        p[name] = a[name];
    foreach (name; ["remove", "flip", "connect", "autoStep", "continuous"])
        p[name] = JSONValue(a[name].integer != 0);
    assert(p.object.length == 12, "full bridge parameter population 12");
    return p;
}
private JSONValue apply(JSONValue p) {
    return parseJSON(postRawAllowingErrorStatus("/api/command",
        commandBody("mesh.bridgeTool", p.toString)));
}
private double number(JSONValue n) {
    return n.type == JSONType.float_ ? n.floating : cast(double)n.integer;
}
private uint bits(float f) {
    import core.stdc.string : memcpy;
    uint b; memcpy(&b, &f, 4); return b;
}
private bool cyclic(JSONValue a, JSONValue b) {
    if (a.array.length != b.array.length) return false;
    foreach (k; 0 .. a.array.length) {
        bool equal = true;
        foreach (i; 0 .. a.array.length)
            if (a[i].integer != b[(i+k)%b.array.length].integer) equal = false;
        if (equal) return true;
    }
    return false;
}
private size_t golden(JSONValue c, JSONValue model) {
    auto inp = c["input"], outp = c["output"];
    auto id = c["case"].str;
    foreach (name; ["vertexCount", "edgeCount", "faceCount"])
        assert(model[name].integer == outp[name].integer, id ~ " " ~ name);
    // Model formatting is display precision; planes preserve float32 bits.
    auto positions = parseJSON(planes())["vertices"];
    size_t newPositions;
    foreach (i; inp["vertices"].array.length .. outp["vertices"].array.length) {
        ++newPositions;
        foreach (j; 0 .. 3)
            assert(bits(cast(float)number(positions[i][j])) ==
                bits(cast(float)number(outp["vertices"][i][j])), id ~ " position bits " ~ i.to!string);
    }
    foreach (i, f; outp["faces"].array)
        assert(cyclic(model["faces"][i], f), id ~ " cyclic winding face " ~ i.to!string);
    foreach (i, f; inp["faces"].array)
        assert(model["faces"][i] == f, id ~ " original face immutable");
    ulong[] actualEdges, expectedEdges;
    foreach (e; model["edges"].array) actualEdges ~= key(e);
    foreach (e; outp["edges"].array) expectedEdges ~= key(e);
    sort(actualEdges); sort(expectedEdges);
    assert(actualEdges == expectedEdges, id ~ " exact edge set");
    long[] rowVertices, reused, expectedReuse;
    foreach (e; inp["selection_packet_order"]["edges"].array)
        foreach (v; e.array) rowVertices ~= v.integer;
    foreach (i; inp["faces"].array.length .. model["faces"].array.length)
        foreach (v; model["faces"][i].array)
            if (v.integer < inp["vertices"].array.length &&
                !canFind(rowVertices, v.integer) && !canFind(reused, v.integer))
                reused ~= v.integer;
    foreach (v; c["reused_original_vertices_derived"].array) expectedReuse ~= v.integer;
    sort(reused); sort(expectedReuse);
    assert(reused == expectedReuse, id ~ " reused original IDs");
    return newPositions;
}

unittest {
    if (cell("golden")) {
        size_t scored, newPositions;
        foreach (name; ["S01", "S02", "S25", "S26"]) {
            auto c = fixture(name); auto beforeSelection = load(c);
            auto before = planes(); auto u0 = depth();
            ok(apply(params(c)));
            // This must precede restore: a stale planes channel cannot pass undo.
            assert(planes() != before, name ~ " planes changed before undo");
            auto model = getJson("/api/model"); newPositions += golden(c, model);
            assert(selected(model) == beforeSelection, name ~ " result input edge selection order");
            assert(depth() == u0+1, name ~ " exactly one history row");
            cmd("history.undo");
            assert(planes() == before, name ~ " undo byte planes restore");
            assert(selected(getJson("/api/model")) == beforeSelection, name ~ " undo selection restore");
            ++scored;
        }
        assert(scored == 4, "HTTP golden population 4");
        assert(newPositions == 15, "new position bit population 15");
    }
}
unittest {
    if (cell("flip")) {
        auto c = fixture("S02"); load(c); auto p = params(c); ok(apply(p));
        auto a = getJson("/api/model");
        auto positions = parseJSON(planes())["vertices"];
        load(c); p["flip"] = JSONValue(true); ok(apply(p));
        auto b = getJson("/api/model");
        auto flippedPositions = parseJSON(planes())["vertices"];
        assert(a["vertices"] == b["vertices"] && a["faceCount"] == b["faceCount"] &&
            a["edgeCount"] == b["edgeCount"], "flip counts and positions equal");
        assert(positions == flippedPositions, "flip lossless positions equal");
        size_t quads;
        foreach (i; c["input"]["faceCount"].integer .. a["faceCount"].integer) {
            auto ring = a["faces"][i].array.dup;
            assert(ring.length == 4, "flip new quad population");
            reverse(ring[1 .. $]);
            assert(b["faces"][i] == JSONValue(ring), "flip exact quad reversal");
            ++quads;
        }
        assert(quads == 20, "flip quad population 20");
    }
}
unittest {
    if (cell("refusal")) {
        foreach (name; ["S01", "S02", "S25", "S26"]) {
            auto c = fixture(name); load(c); auto p = params(c); ok(apply(p));
            assert(depth() == 1, name ~ " twist zero positive control applies");
            load(c); auto before = planes(); auto u0 = depth(); p["twist"] = JSONValue(1);
            auto r = apply(p);
            assert(r["status"].str == "error", name ~ " open twist HTTP refusal");
            assert(depth() == u0 && planes() == before, name ~ " refusal planes and history inert");
            assert(r["message"].str == "command 'mesh.bridgeTool' did not apply: Twist on open rows is not supported.",
                name ~ " named twist refusal reason: " ~ r.toString);
        }
        auto c = fixture("S01"); load(c); cmd("tool.set mesh.bridgeTool on");
        auto before = planes(); auto u0 = depth();
        auto r = parseJSON(postRawAllowingErrorStatus("/api/command", "tool.attr mesh.bridgeTool unknown 1"));
        cmd("tool.set mesh.bridgeTool off");
        assert(r["status"].str == "error", "unknown bridge attribute refused");
        assert(depth() == u0 && planes() == before, "unknown attr no history or planes");
    }
}
unittest {
    if (cell("remove")) {
        auto c = fixture("S02"); load(c); auto p = params(c); ok(apply(p));
        auto a = planes(); load(c); p["remove"] = JSONValue(false); ok(apply(p));
        assert(planes() == a, "open remove inert complete planes");
    }
}
unittest {
    if (cell("recall")) {
        auto c = fixture("S01"); load(c);
        auto before = planes(); auto u0 = depth();
        cmd("tool.set mesh.bridgeTool on");
        cmd("tool.attr mesh.bridgeTool twist 1");
        auto state = getJson("/api/tool/state");
        cmd("tool.set mesh.bridgeTool off");
        assert(number(state["twist"]) == 1 && state["engaged"].boolean,
            "recall refused drop positive attr engagement");
        assert(planes() == before && depth() == u0, "recall refused open drop inert planes and history");
        cmd("tool.set mesh.bridgeTool on");
        state = getJson("/api/tool/state");
        cmd("tool.set mesh.bridgeTool off");
        assert(number(state["twist"]) == 1, "bridge last-used twist recalled");
    }
}
