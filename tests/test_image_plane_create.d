// Task 0612 Stage 7 — creating a reference-image plane, driven the way a user
// reaches it: `imagePlane.add` over `/api/command`, read back through
// `/api/layers` and `layer.attr … ?`.
//
// The plan names T-A1 and T-A2 as this stage's gate and never writes them
// down (§9 has tables for the cache, the placement, the viewport match, the
// repaint, the links, the item transform, the `.v3d` round-trip and
// non-participation — and no table for creation at all). They are defined
// here, against what this stage can actually get wrong.
//
// WHAT ONLY THIS FILE CAN PROVE. Every earlier stage put its plane in the
// document through `POST /api/test/layer`, the test-only injector, which
// builds the item by hand. So nothing until now has exercised the item's
// PRODUCTION shape, and the two ways a production creator can be wrong are
// both invisible to the injector:
//
//   * the payload object. `ImagePlaneData` is a class reference, null until
//     something constructs one, and `layer_params.d`'s bundle answers a null
//     payload with the BASE bundle rather than an error — so a plane created
//     without one presents as an item with no channels at all, not as a
//     failure. Every channel assertion below is therefore also a payload
//     assertion.
//   * the arguments. `injectParamsInto` ignores an unknown JSON key, so a
//     misspelled or undeclared argument runs the command on its DEFAULTS.
//     Nothing below asserts `status: ok`; every assertion is on an outcome
//     that the default run cannot produce — a `right` projection, a link to
//     the MIDDLE clip, a name that is not "Plane 1".
//
// FIXTURE. Three clips, all naming ONE file, and the plane bound to the
// MIDDLE one — the arrangement `tests/test_image_plane_link.d` explains at
// length: one clip cannot tell a real reference from "resolved to the only
// one there was"; three clips on three paths make a path-identity bug resolve
// to nothing, which reads like a broken link; three clips on one path make it
// resolve to the WRONG clip with every count still adding up.

import std.net.curl;
import std.json;
import std.conv : to;
import std.file : write, mkdirRecurse;
import std.path : buildPath;

void main() {}

immutable baseUrl = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string)get(baseUrl ~ path)); }

JSONValue cmdRaw(string body_) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
}

JSONValue cmd(string body_) {
    auto j = cmdRaw(body_);
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

JSONValue postUndo() { return parseJSON(cast(string)post(baseUrl ~ "/api/undo", "")); }
JSONValue postRedo() { return parseJSON(cast(string)post(baseUrl ~ "/api/redo", "")); }

JSONValue layers() { return getJson("/api/layers")["layers"]; }
JSONValue layerAt(size_t i) { return layers().array[i]; }
size_t layerCount() { return layers().array.length; }

/// The index of the layer `/api/layers` marks as the item-selection FOCUS.
/// -1 when none is (a state the document invariants forbid, so a -1 here is
/// itself a finding).
int focusedIndex() {
    foreach (i, l; layers().array)
        if (l["focused"].boolean) return cast(int) i;
    return -1;
}

/// The plane row's `links` entry for `slot`, or `JSONValue(null)`.
JSONValue linkSlot(size_t layerIdx, string slot) {
    foreach (s; layerAt(layerIdx)["links"].array)
        if (s["slot"].str == slot) return s;
    return JSONValue(null);
}

/// Read one channel back through the generic attribute path. This is also the
/// payload probe: with no `ImagePlaneData` constructed, the channel is not
/// declared at all and `layer.attr` reports it as an unknown attribute.
JSONValue attr(size_t layerIdx, string name) {
    auto r = cmdRaw("layer.attr " ~ to!string(layerIdx) ~ " " ~ name ~ " ?");
    assert(r["status"].str == "ok",
        "reading `" ~ name ~ "` off layer " ~ to!string(layerIdx)
        ~ " failed — a plane with no payload has no channels to read: "
        ~ r.toString);
    return r["value"];
}

immutable scratch = "/tmp/vibe3d_planecreate";

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

/// [mesh(0), clipA(1), clipB(2), clipC(3)] — three clips on ONE file.
void buildFixture() {
    resetCube();
    auto file = bmpAt("sheet.bmp", 5, 7);
    foreach (_; 0 .. 3)
        cmd(`{"id":"image.load","path":` ~ jsonStr(file) ~ `}`);
    assert(layerCount() == 4, "mesh + three clips");
}

// ---------------------------------------------------------------------------
// T-A1 — `imagePlane.add` creates a plane a user can then edit.
//
// Wrong implementations this discriminates against, and what each reads:
//
//   * the payload is never constructed  ⇒ `layer.attr 4 projection ?` is an
//     unknown attribute (the bundle falls back to the base one) — the item
//     exists and has nothing on it;
//   * `projection` is not declared / not applied ⇒ reads "front", the default;
//   * `image` is not declared / not applied ⇒ no `image` slot at all;
//   * `image` resolved by picking the first or last clip ⇒ target 1 or 3;
//   * `name` is not declared ⇒ reads "Plane 1", the auto name.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();

    cmd(`{"id":"imagePlane.add","name":"Ref Right","image":2,"projection":"right"}`);

    assert(layerCount() == 5, "the add appended exactly one item");
    auto p = layerAt(4);
    assert(p["type"].str == "imagePlane",
        "the new row is an image plane, read `" ~ p["type"].str ~ "`");
    assert(p["name"].str == "Ref Right",
        "the `name` argument landed, read `" ~ p["name"].str ~ "`");
    assert(p["visible"].boolean, "a created plane is visible");

    // The link. `target` is a LAYER index, and the middle clip is the only
    // value that distinguishes "resolved the argument" from "took the first
    // clip" / "took the last" / "off by one".
    auto slot = linkSlot(4, "image");
    assert(slot.type != JSONType.null_,
        "the `image` argument produced a link slot");
    assert(slot["target"].integer == 2,
        "bound to the MIDDLE clip (layer 2), read "
        ~ to!string(slot["target"].integer));
    assert(slot["state"].str == "live",
        "and the link is live, read `" ~ slot["state"].str ~ "`");

    // The channels — i.e. the payload exists, and the projection argument
    // reached it rather than the channel's own default.
    assert(attr(4, "projection").str == "right",
        "`projection` argument landed on the channel, read `"
        ~ attr(4, "projection").str ~ "`");
    import std.math : fabs;
    immutable px = attr(4, "pixelSize").floating;
    assert(fabs(px - 0.01) < 1e-6,
        "the whole channel bundle is present, pixelSize at its 0.01 default "
        ~ "— read " ~ to!string(px));
    assert(attr(4, "keepAspect").boolean,
        "Keep Aspect defaults ON — the mode selector rev 3 restored");
    // And the four-state source verdict agrees with the link: a plane created
    // WITH an image is immediately usable, not merely bound.
    assert(p["imageSource"].str == "ready",
        "a plane created with a readable clip is `ready`, read `"
        ~ p["imageSource"].str ~ "`");

    // Selection. A plane can never be primary, so `add` must leave the MESH
    // edit target alone while making the plane the item-selection FOCUS —
    // which is exactly what the properties form binds.
    assert(focusedIndex() == 4,
        "the new plane is the focus, read " ~ to!string(focusedIndex()));
    assert(layerAt(0)["primary"].boolean,
        "and the mesh is still the edit target");
    assert(!p["primary"].boolean, "the plane never becomes primary");

    // A second, argument-free add: the defaults, and the auto name counts
    // PLANES, not layers (`layer.add`'s "Layer N" counts the whole list,
    // which on a document of meshes + clips + planes produces jumps).
    cmd(`{"id":"imagePlane.add"}`);
    assert(layerCount() == 6, "the second add appended one more item");
    assert(layerAt(5)["name"].str == "Plane 2",
        "auto-named over the planes that exist, read `"
        ~ layerAt(5)["name"].str ~ "`");
    assert(attr(5, "projection").str == "front",
        "and defaults to a front plane, read `" ~ attr(5, "projection").str ~ "`");
    assert(linkSlot(5, "image").type == JSONType.null_,
        "an argument-free plane is created UNBOUND — a legal, observable "
        ~ "state, not an error");
}

// ---------------------------------------------------------------------------
// T-A1b — the two refusals, asserted on the OUTCOME (no item appeared), never
// on a status string.
//
// The `projection` refusal is the load-bearing one: an unvalidated token
// would create a plane whose channel holds a value no viewport can ever
// match, and the user's evidence would be "my reference image never appears"
// — indistinguishable from a draw bug.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();

    auto r1 = cmdRaw(`{"id":"imagePlane.add","image":0}`);
    assert(r1["status"].str != "ok",
        "`image` naming the MESH is refused: " ~ r1.toString);
    assert(layerCount() == 4,
        "and nothing was appended, read " ~ to!string(layerCount()) ~ " layers");

    auto r2 = cmdRaw(`{"id":"imagePlane.add","image":99}`);
    assert(r2["status"].str != "ok", "`image` out of range is refused");
    assert(layerCount() == 4, "and nothing was appended");

    auto r3 = cmdRaw(`{"id":"imagePlane.add","projection":"frnt"}`);
    assert(r3["status"].str != "ok",
        "an unknown projection token is refused at the wire edge, not "
        ~ "stored: " ~ r3.toString);
    assert(layerCount() == 4,
        "and no plane with an unmatchable projection exists, read "
        ~ to!string(layerCount()) ~ " layers");
}

// ---------------------------------------------------------------------------
// T-A2 — undo removes the plane and restores the PRIOR focus; redo re-appends
// the SAME object.
//
// Two wrong implementations, two different reads:
//
//   * the revert restores the prior selection SET and the prior PRIMARY but
//     not the prior FOCUS (which is what `LayerDuplicate.revert` does, and
//     what is correct there because on an all-mesh document focus and primary
//     always coincide). Reads: focus 0, the mesh — the undo silently moved
//     the properties panel off the clip the user had selected.
//   * redo mints a FRESH `Layer` instead of re-appending the held one. Then a
//     later command that resolved the plane BY OBJECT — `imagePlane.setImage`
//     does exactly that, and says why — writes onto the orphan, and the
//     visible plane keeps the binding the add gave it. Reads: target 3, the
//     clip the ADD chose, instead of 1, the clip the setImage chose.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();

    // Put the focus on a NON-PRIMARY item first. This is the state the whole
    // assertion turns on and it is only reachable because a clip row is
    // selectable: with the focus on the mesh, focus and primary coincide and
    // restoring either one restores both.
    cmd(`{"id":"layer.select","index":1,"mode":"set"}`);
    assert(focusedIndex() == 1, "clip A is the focus before the add");
    cmd(`{"id":"history.clear"}`);   // the add is now the only undoable entry

    cmd(`{"id":"imagePlane.add","image":3}`);
    assert(layerCount() == 5 && focusedIndex() == 4,
        "the plane is appended and focused");
    assert(!layerAt(1)["selected"].boolean,
        "and the SET-of-one select dropped clip A from the selection");

    // Rebind, so the redo path has a second command that resolved the plane
    // BY OBJECT and can therefore land on an orphan.
    cmd(`{"id":"imagePlane.setImage","index":4,"image":1}`);
    assert(linkSlot(4, "image")["target"].integer == 1, "rebound to clip A");

    postUndo();                       // undo the setImage
    assert(linkSlot(4, "image")["target"].integer == 3,
        "back to the clip the add chose, read "
        ~ to!string(linkSlot(4, "image")["target"].integer));

    postUndo();                       // undo the add
    assert(layerCount() == 4,
        "the plane is gone, read " ~ to!string(layerCount()) ~ " layers");
    assert(focusedIndex() == 1,
        "and the focus is back on clip A, not on the mesh primary — read "
        ~ to!string(focusedIndex()));
    assert(layerAt(1)["selected"].boolean, "clip A is selected again");

    postRedo();                       // redo the add
    assert(layerCount() == 5, "the plane is back");
    assert(focusedIndex() == 4, "and focused again");

    postRedo();                       // redo the setImage
    assert(linkSlot(4, "image")["target"].integer == 1,
        "the redone rebind landed on the plane the document HOLDS — a redo "
        ~ "that minted a fresh item would have written onto an orphan and "
        ~ "left this at 3. Read "
        ~ to!string(linkSlot(4, "image")["target"].integer));
}
