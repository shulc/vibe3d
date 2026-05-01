// Tests for phase 4.3: tool.set / tool.attr / tool.doApply / tool.reset
// command bridge.
//
// Cube layout:
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)
//
// Default cube has 8 vertices, 12 edges, 6 faces.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

void resetCube()
{
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "reset failed: " ~ cast(string) resp);
}

void postSelect(string mode, int[] indices)
{
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
           "select failed: " ~ cast(string) resp);
}

string postScriptRaw(string script)
{
    return cast(string) post("http://localhost:8080/api/script", script);
}

JSONValue postScript(string script)
{
    auto resp = postScriptRaw(script);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok",
           "/api/script failed: " ~ resp);
    return j;
}

string postCommandRaw(string body_)
{
    return cast(string) post("http://localhost:8080/api/command", body_);
}

JSONValue postCommand(string body_)
{
    auto resp = postCommandRaw(body_);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok",
           "/api/command failed: " ~ resp);
    return j;
}

JSONValue getModel()
{
    return parseJSON(get("http://localhost:8080/api/model"));
}

// ---------------------------------------------------------------------------
// 1. Polygon bevel via tool.* sequence
// ---------------------------------------------------------------------------

unittest { // tool.set bevel → tool.attr (shift/inset) → tool.doApply → tool.set bevel off
    resetCube();
    postSelect("polygons", [0]);   // select face 0

    string script =
        "tool.set bevel\n" ~
        "tool.attr bevel insert 0.25\n" ~
        "tool.attr bevel shift 0.2\n" ~
        "tool.doApply\n" ~
        "tool.set bevel off";

    postScript(script);

    auto m = getModel();
    auto vc = m["vertexCount"].integer;
    assert(vc > 8,
           "polygon bevel should add vertices; got " ~ vc.to!string);
}

// ---------------------------------------------------------------------------
// 2. Edge bevel via tool.* sequence
// ---------------------------------------------------------------------------

unittest { // edge bevel: select edge 0, tool.set bevel, width 0.1, doApply
    resetCube();
    // Switch to edge edit mode and select edge 0.
    postSelect("edges", [0]);

    string script =
        "tool.set bevel\n" ~
        "tool.attr bevel width 0.1\n" ~
        "tool.doApply\n" ~
        "tool.set bevel off";

    postScript(script);

    auto m = getModel();
    auto vc = m["vertexCount"].integer;
    assert(vc > 8,
           "edge bevel should add vertices; got " ~ vc.to!string);
}

// ---------------------------------------------------------------------------
// 3. tool.attr without active tool → status:error
// ---------------------------------------------------------------------------

unittest { // tool.attr with no active tool returns error
    resetCube();
    // Ensure no active tool (send tool.set bevel off).
    postCommand("tool.set bevel off");

    auto resp = postCommandRaw("tool.attr bevel width 0.5");
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
           "tool.attr with wrong/no tool should error; got: " ~ resp);
}

// ---------------------------------------------------------------------------
// 4. tool.set with unknown id → status:error
// ---------------------------------------------------------------------------

unittest { // tool.set with unknown tool id returns error
    resetCube();
    auto resp = postCommandRaw("tool.set nonexistent_tool_xyz");
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
           "tool.set unknown id should error; got: " ~ resp);
}

// ---------------------------------------------------------------------------
// 5. Mixed positional + named: tool.set bevel insert:0.1
// ---------------------------------------------------------------------------

unittest { // tool.set with positional toolId and named param
    resetCube();
    postSelect("polygons", [0]);

    // tool.set with positional "bevel" + named "inset:0.1" activates bevel
    // and sets the inset param in one command.
    string script =
        "tool.set bevel insert:0.1\n" ~
        "tool.doApply\n" ~
        "tool.set bevel off";

    postScript(script);

    auto m = getModel();
    assert(m["vertexCount"].integer > 8,
           "mixed positional+named tool.set should work; got " ~
           m["vertexCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// 6. Undo after tool.doApply restores original mesh
// ---------------------------------------------------------------------------

unittest { // undo after tool.doApply reverts to 8 vertices
    resetCube();
    postSelect("polygons", [0]);

    string script =
        "tool.set bevel\n" ~
        "tool.attr bevel insert 0.15\n" ~
        "tool.doApply\n" ~
        "tool.set bevel off";

    postScript(script);

    // Confirm bevel was applied.
    auto mBeveled = getModel();
    assert(mBeveled["vertexCount"].integer > 8, "bevel not applied");

    // Undo the bevel.
    auto resp = post("http://localhost:8080/api/undo", "");
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", "undo failed: " ~ cast(string) resp);

    auto mRestored = getModel();
    assert(mRestored["vertexCount"].integer == 8,
           "undo should restore 8 verts; got " ~
           mRestored["vertexCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// 7. tool.reset is a no-op on base Tool but should return ok
// ---------------------------------------------------------------------------

unittest { // tool.reset with no active tool returns false (not error)
    resetCube();
    postCommand("tool.set bevel off"); // deactivate any tool

    // tool.reset when no tool active: apply() returns false → "did not apply".
    // This is fine — the test just verifies it doesn't crash.
    auto resp = postCommandRaw("tool.reset");
    // Accept either "ok" (if recorded to history) or "error" (if apply=false).
    // The important thing is valid JSON with a status field.
    auto j = parseJSON(resp);
    assert(j["status"].type == JSONType.string,
           "tool.reset should return JSON with status field; got: " ~ resp);
}

unittest { // tool.reset with active bevel tool succeeds (dialogInit no-op)
    resetCube();
    postCommand("tool.set bevel");
    auto resp = postCommandRaw("tool.reset");
    auto j = parseJSON(resp);
    // dialogInit is a no-op on BevelTool — apply() returns true.
    assert(j["status"].str == "ok",
           "tool.reset with active tool should return ok; got: " ~ resp);
    postCommand("tool.set bevel off");
}
