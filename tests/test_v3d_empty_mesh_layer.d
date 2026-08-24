// Task 1890 — an EMPTY MESH ITEM survives a `.v3d` round trip.
//
// ---------------------------------------------------------------------------
// The report, and what it actually was
// ---------------------------------------------------------------------------
// Reported as "a scene with no geometry, only two image planes, fails to
// load". The image planes turned out to be incidental. The whole reproduction
// is `layer.add` (the Add Item ▸ Mesh button) then save then load: the writer
// emitted the empty layer happily and the reader answered "no vertices" and
// refused THE WHOLE FILE, because the reject is raised per layer and fails the
// document.
//
// It was task 1210's own leftover. That task removed the same reader's
// "no polygons" requirement for the same reason — the editor can reach a
// points-only mesh, so refusing to read one back is refusing a document we
// wrote — and left the vertex clause standing on the sentence "a mesh with
// neither vertices nor polygons is still nothing at all". An empty mesh item
// is not nothing: it is a first-class row that both this Items list and the
// reference give its own appearance (a greyed name) precisely because
// created-but-empty is an ordinary state to be in.
//
// ---------------------------------------------------------------------------
// The assertion that would be worth nothing here
// ---------------------------------------------------------------------------
// "the file loads" is green for a reader that DROPS the empty layer on the way
// in — which is the likeliest wrong fix, since it makes the error go away and
// every subsequent read looks consistent. So E1 counts the layers and asserts
// the empty one is STILL THERE, still a mesh, and still empty.
//
// And a check that only proves "empty now loads" is green for a fix that
// deleted the vertex validation WHOLESALE — the guard against a malformed
// file, not just the judgement about an empty one. E3/E4/E5 are the rows that
// separate those two: they feed a missing key, a non-array and a bad triple
// and require each to still be REFUSED. Without them this file would pass on a
// reader with no vertex handling at all.
//
// ---------------------------------------------------------------------------
// VERIFIED BY MUTATION — run one at a time (druntime stops a module at its
// first failed assert).
// ---------------------------------------------------------------------------
//   * the `verts.length == 0` reject restored (i.e. the state before this fix)
//       -> E1 "a document with an empty mesh item must load".
//   * the reader DROPS an empty mesh layer instead of keeping it
//       -> E1 "the empty item must survive the round trip — 2 items, want 3".
//   * the `"vertices" is missing or not an array` guard also removed
//       -> E3 "a mesh with no \"vertices\" key at all must still be REFUSED".
//   * the per-vertex `[x,y,z]` triple guard removed
//       -> E5 "a malformed vertex triple must still be REFUSED".

import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import std.file   : write, mkdirRecurse, tempDir, exists;
import std.path   : buildPath;

void main() {}

enum string BASE = "http://localhost:8080";

private JSONValue getJson(string p) { return parseJSON(cast(string) get(BASE ~ p)); }

private JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

/// Fire a load that must be REFUSED, and hand back the message.
private string loadRefused(string path, string what) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command",
                                         `file.load path:"` ~ path ~ `"`));
    assert(j["status"].str == "error",
        format("%s: loading %s reported %s. Accepting a malformed file is not "
               ~ "the same relaxation as accepting an empty one, and this fix "
               ~ "must not have bought the first with the second.",
               what, path, j["status"].str));
    return j["message"].str;
}

private string scratchDir() {
    auto d = buildPath(tempDir(), "vibe3d_v3d_empty_layer");
    mkdirRecurse(d);
    return d;
}

private string writeScene(string name, string body_) {
    auto p = buildPath(scratchDir(), name);
    write(p, body_);
    return p;
}

private struct Row { string type; long verts; string name; }

private Row[] rows() {
    Row[] rs;
    foreach (l; getJson("/api/layers")["layers"].array) {
        long v = l["vertexCount"].type == JSONType.integer
               ? l["vertexCount"].integer : -1;
        rs ~= Row(l["type"].str, v, l["name"].str);
    }
    return rs;
}

private string show(Row[] rs) {
    string s;
    foreach (i, r; rs) {
        if (i) s ~= ", ";
        s ~= format("%s(%s, v=%d)", r.type, r.name, r.verts);
    }
    return "[" ~ s ~ "]";
}

// ===========================================================================

unittest {  // E1 — the round trip the editor itself produces
    auto r = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    // `/api/reset` gives one cube; `layer.add` is the Add Item ▸ Mesh button
    // and makes exactly the empty item this task is about. Nothing else is
    // needed to reproduce — no image planes, no backdrop.
    cmd("layer.add");
    auto before = rows();
    assert(before.length == 2 && before[0].verts == 8 && before[1].verts == 0,
        "rig premise: a cube and an EMPTY mesh item — got " ~ show(before));

    auto path = buildPath(scratchDir(), "empty_layer.v3d");
    cmd(`file.save path:"` ~ path ~ `"`);
    cmd(`file.load path:"` ~ path ~ `"`);

    auto after = rows();
    assert(after.length == 2,
        "the empty item must SURVIVE the round trip, not be dropped on the way "
        ~ "in — a reader that quietly drops it makes the error go away and "
        ~ "loses a layer. Got " ~ show(after));
    assert(after[0].type == "mesh" && after[0].verts == 8,
        "the cube keeps its geometry — got " ~ show(after));
    assert(after[1].type == "mesh" && after[1].verts == 0,
        "and the empty item comes back EMPTY and still a mesh, not repaired "
        ~ "into something with vertices — got " ~ show(after));
}

unittest {  // E2 — a document whose ONLY mesh is empty, beside non-mesh items
    // The reported shape: a backdrop-only scene. Distinct from E1 because here
    // there is no non-empty mesh anywhere in the file, so a reader that
    // required "at least one layer with vertices" (a plausible narrower
    // version of the same wrong rule) passes E1 and fails this.
    auto scene = `{
        "formatVersion": 8,
        "primaryLayer": 0,
        "focusedItem": 0,
        "layers": [
            { "type": "mesh", "selected": true,
              "channels": { "name": "Empty", "visible": true },
              "mesh": { "vertices": [], "faces": [], "surfaces": [],
                        "faceMaterial": [], "faceSubpatch": [] } }
        ]
    }`;
    auto path = writeScene("only_empty.v3d", scene);
    cmd(`file.load path:"` ~ path ~ `"`);
    auto after = rows();
    assert(after.length == 1 && after[0].type == "mesh" && after[0].verts == 0,
        "a document whose only item is an empty mesh must load — got "
        ~ show(after));
}

unittest {  // E3 — a MISSING "vertices" key is still refused
    auto scene = `{
        "formatVersion": 8, "primaryLayer": 0,
        "layers": [
            { "type": "mesh", "selected": true,
              "channels": { "name": "Broken", "visible": true },
              "mesh": { "faces": [] } }
        ]
    }`;
    auto path = writeScene("no_vertices_key.v3d", scene);
    auto msg = loadRefused(path, "a mesh with no \"vertices\" key at all");
    assert(msg.length > 0, "and the refusal must carry a reason");
}

unittest {  // E4 — a NON-ARRAY "vertices" is still refused
    auto scene = `{
        "formatVersion": 8, "primaryLayer": 0,
        "layers": [
            { "type": "mesh", "selected": true,
              "channels": { "name": "Broken", "visible": true },
              "mesh": { "vertices": 7, "faces": [] } }
        ]
    }`;
    auto path = writeScene("vertices_not_array.v3d", scene);
    loadRefused(path, "a \"vertices\" that is not an array");
}

unittest {  // E5 — a malformed vertex triple is still refused
    auto scene = `{
        "formatVersion": 8, "primaryLayer": 0,
        "layers": [
            { "type": "mesh", "selected": true,
              "channels": { "name": "Broken", "visible": true },
              "mesh": { "vertices": [[0,0,0],[1,2]], "faces": [] } }
        ]
    }`;
    auto path = writeScene("bad_triple.v3d", scene);
    loadRefused(path, "a malformed vertex triple");
}

unittest {  // E6 — a refused load leaves the OPEN document intact
    // The reader's own stated guarantee (`readV3d`'s catch: "document is
    // mutated only at the swap above, after every reject"). Asserted here
    // because this task moved a reject, and a relaxation that half-applied a
    // file before failing would be a far worse bug than the one being fixed.
    auto r = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
    assert(r["status"].str == "ok", "/api/reset failed");
    cmd("layer.add");
    auto before = rows();

    loadRefused(buildPath(scratchDir(), "bad_triple.v3d"),
        "the malformed file from E5, loaded over a live document");

    auto after = rows();
    assert(after.length == before.length,
        format("a refused load must leave the open document untouched — %s "
               ~ "became %s", show(before), show(after)));
    foreach (i, b; before)
        assert(after[i].type == b.type && after[i].verts == b.verts,
            format("…item %d changed: %s -> %s", i, show(before), show(after)));
}
