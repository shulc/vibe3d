import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

unittest { // SMOKE: /api/command runs select.invert on a fresh cube
    post("http://localhost:8080/api/reset", "");

    // After reset: vertex mode, empty selection.
    auto sel = parseJSON(get("http://localhost:8080/api/selection"));
    assert(sel["mode"].str == "vertices",
        "expected vertices mode after reset, got " ~ sel["mode"].str);
    assert(sel["selectedVertices"].array.length == 0,
        "expected 0 selected verts after reset");

    // Trigger select.invert via /api/command.
    auto resp = post("http://localhost:8080/api/command",
                     `{"id":"select.invert"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok",
        "expected ok, got: " ~ resp);

    // After invert in vertex mode with empty selection: all 8 verts selected.
    sel = parseJSON(get("http://localhost:8080/api/selection"));
    assert(sel["selectedVertices"].array.length == 8,
        "expected 8 selected verts after invert, got "
        ~ sel["selectedVertices"].array.length.to!string);
}

unittest { // ERROR: unknown command id returns status:error
    auto resp = post("http://localhost:8080/api/command",
                     `{"id":"nonexistent.command.foo"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error status for unknown id, got: " ~ resp);
    assert(j["message"].str.length > 0,
        "expected nonempty error message");
}

unittest { // ERROR: missing 'id' field returns status:error
    auto resp = post("http://localhost:8080/api/command", `{}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error status for missing id, got: " ~ resp);
}
