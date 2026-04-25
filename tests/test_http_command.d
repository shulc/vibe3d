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

unittest { // /api/select: vertex mode, two indices
    post("http://localhost:8080/api/reset", "");

    auto resp = post("http://localhost:8080/api/select",
                     `{"mode":"vertices","indices":[2,5]}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "expected ok, got: " ~ resp);

    auto sel = parseJSON(get("http://localhost:8080/api/selection"));
    assert(sel["mode"].str == "vertices");
    auto verts = sel["selectedVertices"].array;
    assert(verts.length == 2,
        "expected 2 verts, got " ~ verts.length.to!string);
    assert(verts[0].integer == 2);
    assert(verts[1].integer == 5);
}

unittest { // /api/select switches edit mode
    post("http://localhost:8080/api/reset", "");

    post("http://localhost:8080/api/select", `{"mode":"edges","indices":[3]}`);
    auto sel = parseJSON(get("http://localhost:8080/api/selection"));
    assert(sel["mode"].str == "edges",
        "expected edges mode, got " ~ sel["mode"].str);
    assert(sel["selectedEdges"].array.length == 1);
    assert(sel["selectedEdges"].array[0].integer == 3);

    post("http://localhost:8080/api/select", `{"mode":"polygons","indices":[0,4]}`);
    sel = parseJSON(get("http://localhost:8080/api/selection"));
    assert(sel["mode"].str == "polygons");
    assert(sel["selectedFaces"].array.length == 2);
    // Per-mode selections persist across mode switches (matches editor UX);
    // /api/select only replaces the selection in the targeted mode.
}

unittest { // /api/select replaces previous selection in same mode
    post("http://localhost:8080/api/reset", "");
    post("http://localhost:8080/api/select", `{"mode":"vertices","indices":[0,1,2]}`);
    post("http://localhost:8080/api/select", `{"mode":"vertices","indices":[7]}`);
    auto sel = parseJSON(get("http://localhost:8080/api/selection"));
    auto verts = sel["selectedVertices"].array;
    assert(verts.length == 1, "expected 1 vert after replacement, got "
        ~ verts.length.to!string);
    assert(verts[0].integer == 7);
}

unittest { // /api/select: out-of-range index returns error
    post("http://localhost:8080/api/reset", "");
    auto resp = post("http://localhost:8080/api/select",
                     `{"mode":"vertices","indices":[999]}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for OOR index, got: " ~ resp);
}

unittest { // /api/select: empty indices clears current selection
    post("http://localhost:8080/api/reset", "");
    post("http://localhost:8080/api/select", `{"mode":"vertices","indices":[0,1]}`);
    post("http://localhost:8080/api/select", `{"mode":"vertices","indices":[]}`);
    auto sel = parseJSON(get("http://localhost:8080/api/selection"));
    assert(sel["selectedVertices"].array.length == 0,
        "expected empty selection after empty indices");
}
