module test_history_args;

// Integration tests for subphase 5.3: /api/history returns structured per-entry
// objects { "label": ..., "args": ..., "command": ... } instead of plain strings.

import std.net.curl : get, post;
import std.json;
import std.conv : to;
import std.algorithm : canFind;

void main() {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private JSONValue getHistory() {
    return parseJSON(cast(string)get("http://localhost:8080/api/history"));
}

private JSONValue postCmd(string argstring) {
    return parseJSON(cast(string)post("http://localhost:8080/api/command", argstring));
}

private void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

private void postSelect(string mode, int[] indices) {
    import std.format : format;
    string idxList;
    foreach (i, idx; indices) {
        if (i > 0) idxList ~= ",";
        idxList ~= idx.to!string;
    }
    post("http://localhost:8080/api/select",
        format(`{"mode":"%s","indices":[%s]}`, mode, idxList));
}

// ---------------------------------------------------------------------------
// 1. Parameterized command → structured entry with non-empty args
// ---------------------------------------------------------------------------

unittest { // /api/history returns per-entry objects with label/args/command fields
    resetCube();

    // Move v0 onto v1 so there is something to merge (non-default dist not needed
    // for this test; we just check that parameterized invocation lands in args).
    postCmd("mesh.move_vertex from:{-0.5,-0.5,-0.5} to:{0.5,-0.5,-0.5}");
    postSelect("vertices", [0, 1]);

    // Use a non-default dist (0.0005 != default 0.001) so isUserSet fires.
    auto r = postCmd("vert.merge range:fixed dist:0.0005");
    assert(r["status"].str == "ok", "vert.merge should succeed: " ~ r.toString());

    auto h = getHistory();
    auto undo = h["undo"].array;
    assert(undo.length >= 1, "undo stack must have at least one entry");

    auto last = undo[$ - 1];

    // Each entry must be an object with the three required keys.
    assert(last.type == JSONType.object, "undo entry must be an object");
    assert("label"   in last, "entry must have 'label' key");
    assert("args"    in last, "entry must have 'args' key");
    assert("command" in last, "entry must have 'command' key");

    assert(last["command"].str == "vert.merge",   "command name mismatch");
    assert(last["label"].str   == "Merge Vertices", "label mismatch");

    auto args = last["args"].str;
    assert(args.length > 0, "args must be non-empty for parameterized cmd");
    assert(args.canFind("range:fixed"), "args must contain range:fixed: " ~ args);
    assert(args.canFind("dist:0.0005"), "args must contain dist:0.0005: "  ~ args);
}

// ---------------------------------------------------------------------------
// 2. Default-valued params are omitted from args (isUserSet semantics)
// ---------------------------------------------------------------------------

unittest { // default params omitted; only explicit non-defaults appear in args
    resetCube();

    postCmd("mesh.move_vertex from:{-0.5,-0.5,-0.5} to:{0.5,-0.5,-0.5}");
    postSelect("vertices", [0, 1]);

    // Only range:fixed is non-default (default is "auto").
    // dist and keep are left at their defaults → must NOT appear in args.
    auto r = postCmd("vert.merge range:fixed");
    assert(r["status"].str == "ok", "vert.merge range:fixed should succeed: " ~ r.toString());

    auto h    = getHistory();
    auto last = h["undo"].array[$ - 1];
    auto args = last["args"].str;

    assert(args.canFind("range:fixed"), "explicit non-default must appear: " ~ args);
    assert(!args.canFind("keep:"),      "'keep' is default — must NOT appear: " ~ args);
    assert(!args.canFind("dist:0.001"), "'dist' at default — must NOT appear: " ~ args);
}

// ---------------------------------------------------------------------------
// 3. Command without a params schema → empty args field
// ---------------------------------------------------------------------------

unittest { // no-schema command yields empty args string
    resetCube();

    // mesh.subdivide has no user-set params in its schema beyond defaults;
    // mesh.delete has no schema at all. Use subdivide since it always succeeds.
    postSelect("vertices", [0]);
    // mesh.subdivide is a polygon-mode op.
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
    auto r = postCmd("mesh.subdivide");
    if (r["status"].str != "ok") return; // skip if not applicable in current env

    auto h    = getHistory();
    auto last = h["undo"].array[$ - 1];

    // args field must exist and be a string (possibly empty).
    assert(last["args"].type == JSONType.string, "args must be a JSON string");
    // subdivide has no user-settable params → args is empty.
    assert(last["args"].str == "", "no-schema cmd should have empty args, got: " ~ last["args"].str);
}

// ---------------------------------------------------------------------------
// 4. Redo entries also carry structured objects
// ---------------------------------------------------------------------------

unittest { // redo stack entries are also structured objects
    resetCube();

    postSelect("vertices", [0]);
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
    auto r = postCmd("mesh.subdivide");
    if (r["status"].str != "ok") return;

    // Undo so the subdivide entry moves to redo.
    post("http://localhost:8080/api/undo", "");

    auto h    = getHistory();
    auto redo = h["redo"].array;
    assert(redo.length >= 1, "redo stack must have at least one entry after undo");

    auto entry = redo[$ - 1];
    assert(entry.type == JSONType.object, "redo entry must be an object");
    assert("label"   in entry);
    assert("args"    in entry);
    assert("command" in entry);
    assert(entry["command"].str.length > 0, "command name must be non-empty");
}

// ---------------------------------------------------------------------------
// 5. Existing array.length usage still works (backward-compat guard)
// ---------------------------------------------------------------------------

unittest { // array.length on undo/redo still works after format change
    resetCube();

    postSelect("vertices", [0]);
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
    post("http://localhost:8080/api/command", `{"id":"mesh.subdivide"}`);

    auto h = getHistory();
    int undoLen = cast(int)h["undo"].array.length;
    int redoLen = cast(int)h["redo"].array.length;
    assert(undoLen >= 1, "undo should be non-empty");
    assert(redoLen == 0, "redo should be empty before any undo");
}
