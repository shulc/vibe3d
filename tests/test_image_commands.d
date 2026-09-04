// Task 0616 Ph5 — the image-item commands, driven the way a caller actually
// reaches them: over `/api/command`, by path, with no UI.
//
// The in-module unittests in `source/commands/image/commands.d` carry the
// behavioural weight (they can see `storedPath`, the derived metadata and
// object identity directly). What ONLY this file can prove is the half that
// lives outside those modules:
//
//   * the four commands are REGISTERED — an unregistered id is an "unknown
//     command" error, so every assertion here is downstream of that;
//   * the `path` / `index` arguments arrive through the generic param
//     injection under the names the commands declare. A misspelled attr name
//     is silently ignored by that injector (task 0633), so the tests below
//     never assert on the argument's presence — they assert on an outcome
//     that is unreachable unless the argument landed (the item's name is the
//     file stem; the read-back path equals the file written);
//   * the undo CLASSES are what the module claims: load/replace/remove land
//     an entry, `image.reload` lands none — asserted by what a subsequent
//     undo actually reverts, not by reading a flag;
//   * `layer.attr <img> filename <v>` is refused while `image.replace` on the
//     same item succeeds. That PAIR is the point: refusing the generic write
//     path is only correct because a dedicated path exists.
//
// The image files are written by this process into a scratch directory and
// read back by the app process by absolute path.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.file   : write, remove, exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path   : buildPath;
import std.string : indexOf;

void main() {}

alias baseUrl = testBaseUrl;

// ---------------------------------------------------------------------------
// HTTP helpers (mirrors tests/test_nonmesh_items.d)
// ---------------------------------------------------------------------------


JSONValue cmdRaw(string body_) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
}

JSONValue cmd(string body_) {
    auto j = cmdRaw(body_);
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

void clearHistory() { cmd(`{"id":"history.clear"}`); }

void resetCube() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", commandBody("scene.reset")));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    clearHistory();
}

JSONValue postUndo() { return parseJSON(cast(string)post(baseUrl ~ "/api/command", commandBody("history.undo"))); }
JSONValue postRedo() { return parseJSON(cast(string)post(baseUrl ~ "/api/redo", "")); }

void undoOk(string why) {
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo (" ~ why ~ ") failed: " ~ u.toString);
}
void redoOk(string why) {
    auto r = postRedo();
    assert(r["status"].str == "ok", "redo (" ~ why ~ ") failed: " ~ r.toString);
}

JSONValue getLayers()   { return getJson("/api/layers"); }
size_t    layerCount()  { return getLayers()["layers"].array.length; }
JSONValue layerAt(size_t i) { return getLayers()["layers"].array[i]; }

// ---------------------------------------------------------------------------
// Image fixtures on disk — a minimal uncompressed 24-bit BMP (14-byte file
// header + 40-byte BITMAPINFOHEADER + bottom-up BGR rows padded to 4). Written
// here rather than checked in so each case can pick its own dimensions, which
// is what makes "the reload saw the new file" observable at all.
// ---------------------------------------------------------------------------

immutable scratch = "/tmp/vibe3d_httpimg";

string bmpAt(string name, int w, int h) {
    mkdirRecurse(scratch);
    auto path = buildPath(scratch, name);
    ubyte[] b;
    void u16(ushort v) { b ~= cast(ubyte)(v & 0xFF); b ~= cast(ubyte)((v >> 8) & 0xFF); }
    void u32(uint v) {
        b ~= cast(ubyte)(v & 0xFF);         b ~= cast(ubyte)((v >> 8)  & 0xFF);
        b ~= cast(ubyte)((v >> 16) & 0xFF); b ~= cast(ubyte)((v >> 24) & 0xFF);
    }
    immutable size_t rowBytes = cast(size_t)((w * 3 + 3) & ~3);
    immutable size_t pixBytes = rowBytes * h;
    b ~= cast(ubyte)'B'; b ~= cast(ubyte)'M';
    u32(cast(uint)(54 + pixBytes));
    u16(0); u16(0); u32(54); u32(40);
    u32(cast(uint) w); u32(cast(uint) h);
    u16(1); u16(24); u32(0); u32(cast(uint) pixBytes);
    u32(2835); u32(2835); u32(0); u32(0);
    foreach (y; 0 .. h) {
        foreach (x; 0 .. w) {
            b ~= cast(ubyte)(x * 7 + 3); b ~= cast(ubyte)(y * 11 + 5); b ~= cast(ubyte)(x * 3 + y);
        }
        foreach (_; 0 .. rowBytes - cast(size_t)(w * 3)) b ~= cast(ubyte) 0;
    }
    write(path, b);
    return path;
}

string jsonStr(string s) { return JSONValue(s).toString(); }

/// `image.load` by path — the exact route the file dialog feeds once it has
/// produced a path.
JSONValue loadImage(string path) {
    return cmdRaw(`{"id":"image.load","path":` ~ jsonStr(path) ~ `}`);
}

/// Read an image row's stored path back through the generic attr query. This
/// is the only HTTP-visible read of `storedPath` in this phase (the panel and
/// the `/api/layers` image sub-object are later phases), and it works because
/// `filename` ships as a READABLE-but-readonly param.
string storedPathOf(size_t idx) {
    auto r = cmdRaw("layer.attr " ~ idx.to!string ~ " filename ?");
    assert(r["status"].str == "ok", "filename query failed: " ~ r.toString);
    assert("value" in r, "filename query returned no value: " ~ r.toString);
    return r["value"].str;
}

// ---------------------------------------------------------------------------
// LOAD by path over HTTP: the command is registered, the argument lands, and
// the new row is an image named after the file.
//
// Discriminating: the row's name is the file STEM ("hotel"), which no
// implementation naming rows "Layer N" produces and which is unreachable
// unless the `path` argument actually arrived; "type":"image" separates it
// from a mesh row; and `vertexCount` is JSON null rather than 0.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    immutable before = layerCount();
    auto path = bmpAt("hotel.bmp", 3, 2);

    auto r = loadImage(path);
    assert(r["status"].str == "ok", "image.load must be registered and apply: " ~ r.toString);

    assert(layerCount() == before + 1, "one row appeared");
    auto row = layerAt(before);
    assert(row["type"].str == "image", `the new row reports "type":"image"`);
    assert(row["name"].str == "hotel",
        "named after the file STEM — not \"Layer N\", which is what a load "
        ~ "that never saw the path argument would produce");
    assert(row["vertexCount"].type == JSONType.null_,
        "an image row has no vertex count — null, never 0");
    assert(row["primary"].type == JSONType.false_,
        "and it never becomes the mesh edit target");
    assert(storedPathOf(before) == path, "the item carries the path it was given");
}

// ---------------------------------------------------------------------------
// LOAD of an unreadable path: an error THAT NAMES THE PATH, and no row.
//
// Discriminating on both halves. `layerCount()` after the failure catches an
// implementation that appended a broken row first. The message check is what
// makes the FAILURE assertion mean anything (review round 3, S3): "status !=
// ok" on its own is equally satisfied by a load that never received the `path`
// attribute at all — an unknown attr name is accepted silently (task 0633), so
// the command would run on its default (empty) path and decline for a
// completely unrelated reason. Naming the path back is unreachable unless the
// argument landed AND the command got as far as opening it.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    immutable before = layerCount();

    auto missing = buildPath(scratch, "definitely_not_here.bmp");
    auto r = loadImage(missing);
    assert(r["status"].str != "ok", "an unreadable path is an error");
    assert("message" in r && r["message"].str.indexOf(missing) >= 0,
        "and the error names the path it was handed — an implementation that "
        ~ "never saw the `path` argument declines with a message that cannot "
        ~ "contain it. Observed: " ~ r.toString);
    assert(layerCount() == before,
        "and leaves NO row behind — a failed command that half-committed is "
        ~ "the failure that matters");
}

// ---------------------------------------------------------------------------
// The T12 PAIR: the generic attr path cannot author a path, and the dedicated
// command can.
//
// Discriminating on both halves. For the refusal: the command must error AND
// the stored path must be unchanged — "it failed" alone passes an
// implementation that failed after writing, and "unchanged" alone passes one
// that silently discarded the edit while reporting success. For the dedicated
// path: the same edit through `image.replace` must move the value, so the
// refusal is a routing decision rather than "images have no writable state".
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    immutable idx = layerCount();
    auto oldPath = bmpAt("india.bmp", 3, 2);
    auto newPath = bmpAt("juliet.bmp", 5, 7);
    assert(loadImage(oldPath)["status"].str == "ok");

    auto refused = cmdRaw("layer.attr " ~ idx.to!string ~ " filename " ~ newPath);
    assert(refused["status"].str != "ok",
        "layer.attr must REFUSE to author `filename` (read-only)");
    assert(storedPathOf(idx) == oldPath,
        "and the path is unchanged — a refusal after the write would read the "
        ~ "new path here");

    // Also: a param the image kind does not have is an unknown attribute, and
    // one it does have is writable — so the refusal above is about `filename`,
    // not about image rows having no writable channels at all.
    assert(cmdRaw("layer.attr " ~ idx.to!string ~ " pos.x 5")["status"].str != "ok",
        "an image row has no transform channels");
    cmd("layer.attr " ~ idx.to!string ~ " colorspace linear");

    auto ok = cmdRaw(`{"id":"image.replace","index":` ~ idx.to!string
                     ~ `,"path":` ~ jsonStr(newPath) ~ `}`);
    assert(ok["status"].str == "ok", "image.replace applies: " ~ ok.toString);
    assert(storedPathOf(idx) == newPath, "the dedicated path DOES author it");
    assert(layerCount() == idx + 1, "and adds no row while doing it");

    undoOk("replace");
    assert(storedPathOf(idx) == oldPath, "undo puts the previous file back");
    redoOk("replace");
    assert(storedPathOf(idx) == newPath, "redo re-applies it");
}

// ---------------------------------------------------------------------------
// UNDO CLASSES, asserted by what an undo actually reverts.
//
// `image.reload` claims to record no undo entry. The discriminating check is
// to run a load, then a reload, then ONE undo: the item must be gone. An
// implementation that recorded an entry for the reload consumes the undo on
// it, and the item is still there — which no flag-reading assertion would
// notice.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    immutable idx = layerCount();
    auto path = bmpAt("kilo.bmp", 4, 6);
    assert(loadImage(path)["status"].str == "ok");
    assert(layerCount() == idx + 1);

    cmd(`{"id":"image.reload","index":` ~ idx.to!string ~ `}`);
    assert(layerCount() == idx + 1, "a reload changes no row count");
    assert(storedPathOf(idx) == path, "and no path");

    undoOk("the load, not the reload");
    assert(layerCount() == idx,
        "ONE undo removed the loaded item — so the reload recorded no entry. "
        ~ "An implementation that made reload undoable leaves the item here");

    redoOk("load");
    assert(layerCount() == idx + 1, "and redo brings it back");
    assert(layerAt(idx)["name"].str == "kilo", "the same row");
}

// ---------------------------------------------------------------------------
// REMOVE: the kind guard, the removal, and the undo.
//
// Discriminating: `image.remove` aimed at the MESH row must error and change
// nothing, WHILE `layer.delete` at the same index goes through — a panel row
// index is an index into a list that contains no meshes at all. The
// `layer.add` at the top is what makes that pair sayable (review round 3,
// blocker 1): with a single mesh in the document the delete is refused anyway
// (never the last item that can be the edit target), so `image.remove index:0`
// would fail with the kind guard and fail without it, and the assertion would
// read the same either way. The mesh row is renamed first so "the mesh is
// still there" is a read of THAT row rather than of whatever now sits at 0.
//
// Then removal of the image row drops exactly it, and undo restores the row
// WITH its kind and name (a restore that forgot the payload would read a row
// whose `filename` query fails).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd(`{"id":"layer.rename","index":0,"name":"MeshOne"}`);
    cmd(`{"id":"layer.add"}`);                  // a SECOND mesh
    assert(layerCount() == 2, "fixture: two mesh rows");
    assert(layerAt(0)["name"].str == "MeshOne", "fixture: row 0 is the named one");

    immutable idx = layerCount();
    auto path = bmpAt("lima.bmp", 3, 2);
    assert(loadImage(path)["status"].str == "ok");
    immutable after = layerCount();

    auto onMesh = cmdRaw(`{"id":"image.remove","index":0}`);
    assert(onMesh["status"].str != "ok", "the mesh row is not an image item");
    assert(layerCount() == after, "and nothing was removed");
    assert(layerAt(0)["type"].str == "mesh" && layerAt(0)["name"].str == "MeshOne",
        "the SAME mesh row is still at index 0 — a count-only check passes an "
        ~ "implementation that removed it and let another row shift up");

    // THE CONTROL, at the same index and against the same document: the
    // generic delete DOES take row 0. So the refusal above is the kind guard,
    // not the document declining to lose its last edit target.
    cmd(`{"id":"layer.delete","index":0}`);
    assert(layerCount() == after - 1 && layerAt(0)["name"].str != "MeshOne",
        "control: `layer.delete index:0` succeeds where `image.remove index:0` "
        ~ "was refused, and it is MeshOne that goes");
    undoOk("control delete");
    assert(layerCount() == after && layerAt(0)["name"].str == "MeshOne",
        "control: undone, so the rest of this case runs on the same document");

    cmd(`{"id":"image.remove","index":` ~ idx.to!string ~ `}`);
    assert(layerCount() == after - 1, "the image row is gone");

    undoOk("remove");
    assert(layerCount() == after, "undo restores it");
    assert(layerAt(idx)["type"].str == "image" && layerAt(idx)["name"].str == "lima",
        "with its kind and name");
    assert(storedPathOf(idx) == path,
        "and its payload — a restore that dropped the ImageData would fail "
        ~ "this query outright");
}

// ---------------------------------------------------------------------------
// RENAME is `layer.rename`, and it renames the ROW only.
//
// Discriminating: the file at the stored path still exists afterwards and the
// stored path is unchanged, while the row's name moved. An implementation
// that renamed the file on disk fails the `exists` check; one that wrote the
// name into `storedPath` fails the query.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    immutable idx = layerCount();
    auto path = bmpAt("mike.bmp", 3, 2);
    assert(loadImage(path)["status"].str == "ok");

    cmd(`{"id":"layer.rename","index":` ~ idx.to!string ~ `,"name":"Plate"}`);
    assert(layerAt(idx)["name"].str == "Plate", "the row name changed");
    assert(storedPathOf(idx) == path, "the stored path did not");
    assert(exists(path), "and the file is still on disk under its own name");
    assert(!exists(buildPath(scratch, "Plate.bmp")),
        "nothing appeared under the new name");

    undoOk("rename");
    assert(layerAt(idx)["name"].str == "mike", "rename is undoable (Model class)");
}
