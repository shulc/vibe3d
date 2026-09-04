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

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import std.file : write, mkdirRecurse;
import std.path : buildPath;

void main() {}

alias baseUrl = testBaseUrl;


JSONValue cmdRaw(string body_) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
}

JSONValue cmd(string body_) {
    auto j = cmdRaw(body_);
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", commandBody("scene.reset")));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

JSONValue postUndo() { return parseJSON(cast(string)post(baseUrl ~ "/api/command", commandBody("history.undo"))); }
JSONValue postRedo() { return parseJSON(cast(string)post(baseUrl ~ "/api/command", commandBody("history.redo"))); }

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

/// The indices of every SELECTED row, in layer order. Task 0668's rows assert
/// on this LIST rather than on "the plane is selected": the pre-0668
/// behaviour also left the plane selected, and only the COUNT tells "cleared
/// every other item" apart from "cleared none" — or, on a document with more
/// than two items, from "cleared one".
int[] selectedIndices() {
    int[] out_;
    foreach (i, l; layers().array)
        if (l["selected"].boolean) out_ ~= cast(int) i;
    return out_;
}

/// The indices of every row `/api/layers` marks `primary`. A LIST, not a
/// bool: "no primary" and "two primaries" are different findings and a
/// bool would fold them together.
int[] primaryIndices() {
    int[] out_;
    foreach (i, l; layers().array)
        if (l["primary"].boolean) out_ ~= cast(int) i;
    return out_;
}

/// `/api/layers`' `active` field — the derived `activeIndex`, reported as -1
/// when there is no primary.
int activeIndex() { return cast(int) getJson("/api/layers")["active"].integer; }

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

    // Selection. A plane can never be primary, so the create makes it the
    // item-selection FOCUS — which is exactly what the properties form binds.
    // TASK 0671 rewrote the second half again, and this time in the direction
    // that costs nothing: creating a plane leaves the mesh LATCHED as the edit
    // target. 0668 cleared it (and 0669's primitive buttons went grey with it);
    // 0670 read the mechanism and the clearing was never what the reference
    // does — a plane's selection flushes the PLANE bucket, not the mesh one.
    assert(focusedIndex() == 4,
        "the new plane is the focus, read " ~ to!string(focusedIndex()));
    assert(layerAt(0)["primary"].boolean,
        "and the mesh is STILL the edit target (task 0671) — creating a "
        ~ "reference image does not take the model out from under the tool");
    assert(!layerAt(0)["selected"].boolean,
        "…while being out of the SELECTION, which is 0668's half and is kept");
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

// ---------------------------------------------------------------------------
// T-A3 (task 0668) — creating a plane selects ONLY the plane.
//
// THE ASSERTION THAT WOULD BE WORTH NOTHING HERE. "the plane is selected"
// passes against the code this row exists to change: before 0668 the add
// already selected the plane, it just kept the mesh selected alongside it.
// So every row below reads the COUNT — the exact list of selected indices —
// which is the only reading that separates "cleared every other item" from
// "cleared none".
//
// AND WHY THE FIXTURE HAS FOUR ITEMS BEFORE THE ADD. On a one-mesh document
// "cleared all others" and "cleared exactly one" produce identical readings.
// `buildFixture` leaves [mesh, clipA, clipB, clipC]; selecting all four and
// then adding the plane makes `[4]` distinguishable from `[0,4]` (cleared
// only the clips), from `[1,2,3,4]` (cleared only the mesh) and from
// `[0,1,2,3,4]` (cleared nothing).
//
// The wrong implementations this discriminates against:
//   * the pre-0668 `exclusiveSelect`, which spared the primary  -> reads
//     `[0,4]` and `primary [0]`;
//   * ~~"clear the others but keep the mesh latched as primary" (the third
//     state the document model forbids: a latched item that draws as
//     background while the toolpipe writes to it)~~ — TASK 0671: that IS the
//     answer. The state it feared is a mesh drawn as BACKGROUND while being
//     edited, and the reference's classifier does not produce it: a mesh with
//     a non-zero selection state is FOREGROUND. So the latched mesh reads
//     `selected [4]`, `primary [0]`, `active 0`, `foreground` true;
//   * a fix written for the image plane specifically rather than for the
//     KIND property -> T-A4 catches it.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();

    // Select everything first, so the add has more than one thing to clear.
    foreach (i; 0 .. 4)
        cmd(`{"id":"layer.select","index":` ~ to!string(i) ~ `,"mode":"add"}`);
    assert(selectedIndices() == [0, 1, 2, 3],
        "fixture: all four items selected before the add, read "
        ~ to!string(selectedIndices()));

    cmd(`{"id":"imagePlane.add"}`);

    assert(selectedIndices() == [4],
        "the created plane is the ONLY selected item. `[0,4]` is the "
        ~ "pre-0668 reading (the mesh primary spared); `[0,1,2,3,4]` is "
        ~ "'cleared nothing'. Read " ~ to!string(selectedIndices()));
    assert(layerAt(4)["type"].str == "imagePlane",
        "…and the one thing selected is the plane, not some survivor at "
        ~ "index 4");
    assert(focusedIndex() == 4, "which also holds the focus");

    // The edit target. TASK 0671: it is the MESH, still, and it got there
    // without being in the selection — the plane's select flushed the PLANE
    // bucket and the mesh sat in the mesh one.
    assert(primaryIndices() == [0],
        "the mesh is still the edit target, read " ~ to!string(primaryIndices()));
    assert(activeIndex() == 0,
        "and `active` names it — read " ~ to!string(activeIndex()));
    assert(layerAt(0)["foreground"].boolean && !layerAt(0)["background"].boolean,
        "…and it is FOREGROUND, not a dimmed read-only background layer that "
        ~ "the toolpipe is nevertheless writing to — the state the bullet list "
        ~ "above used to call forbidden");

    // …so a mesh command LANDS, on the mesh, which is the whole point: creating
    // a reference image does not take the model out from under the tool.
    auto sub = cmdRaw(`{"id":"mesh.subdivide"}`);
    assert(sub["status"].str == "ok",
        "a mesh command runs against the latched target: " ~ sub.toString);

    // Read through an EXPLICIT `?layer=0`, so "it succeeded" and "it wrote to
    // the right layer" are two readings and not one.
    auto m = getJson("/api/model?layer=0");
    assert(m["vertices"].array.length == 26,
        "one Catmull-Clark pass took the cube from 8 vertices to 26 on layer 0 "
        ~ "— read " ~ to!string(m["vertices"].array.length));
}

// ---------------------------------------------------------------------------
// T-A4 (task 0668) — the rule is the KIND's, not the image plane's.
//
// A fix written as "creating a plane clears the selection" would pass T-A3
// and fail here: an image CLIP is a different kind that also declares
// `canBePrimary == false`, and an exclusive select of one must behave
// identically. The second half is the discriminator in the other direction —
// `mode:add` must NOT clear, or the fix would have been written as "a
// non-mesh selection never has a primary", which would drop the edit target
// on a ctrl-click, where the user is adding to a selection rather than
// replacing it.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();                       // [mesh, clipA, clipB, clipC]

    // SET on a clip — same kind property, same answer.
    cmd(`{"id":"layer.select","index":2,"mode":"set"}`);
    assert(selectedIndices() == [2],
        "an exclusive select of a CLIP clears the mesh too — the rule keys "
        ~ "on `canBePrimary`, not on the image plane. Read "
        ~ to!string(selectedIndices()));
    // TASK 0671: …and leaves the MESH latched, because a clip is a different
    // history bucket. The rule still keys on `canBePrimary` — the clip cannot
    // become the target — and it now also keys on the BUCKET, which is what
    // stops it taking the mesh's away.
    assert(primaryIndices() == [0] && activeIndex() == 0,
        "…and leaves the mesh LATCHED as the edit target, read primary "
        ~ to!string(primaryIndices()) ~ " active " ~ to!string(activeIndex()));

    // ADD is not SET. Start from the mesh, then ctrl-add a clip.
    cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
    assert(selectedIndices() == [0] && primaryIndices() == [0],
        "control: selecting the mesh restores an ordinary document, read "
        ~ to!string(selectedIndices()));
    cmd(`{"id":"layer.select","index":3,"mode":"add"}`);
    assert(selectedIndices() == [0, 3],
        "ctrl-adding a clip GROWS the set, read " ~ to!string(selectedIndices()));
    assert(primaryIndices() == [0],
        "…and the mesh stays the edit target under Add — a fix that cleared "
        ~ "here would break ctrl-click. Read " ~ to!string(primaryIndices()));
    assert(focusedIndex() == 3, "while the focus moves to the added clip");
}

// ---------------------------------------------------------------------------
// T-A5 (tasks 0668 / 0671) — the undo returns the previous SELECTION exactly,
// and the edit target with it.
//
// ~~The apply now removes the edit target, so the revert has to put it back.~~
// TASK 0671: the apply does not remove it — a plane's select flushes the PLANE
// bucket — so the target is unchanged across the apply and what the revert owes
// is the SET, the FOCUS, and the deselect history. The wrong implementations
// and their readings:
//   * the revert restores the selected SET but not the order (the raw
//     `l.selected = wasSel` loop alone) -> `primary [0]` after the undo,
//     because the head of the restored queue is whichever mesh comes first in
//     `layers` rather than whichever was selected first;
//   * the revert restores a target by rehoming rather than from the snapshot
//     -> lands on layer 0 even when the pre-add target was a different mesh,
//     which the DUPLICATED mesh below makes visible.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();                       // [mesh, clipA, clipB, clipC]

    // A SECOND mesh, so "restored the snapshot" differs from "rehomed to the
    // first canBePrimary layer". `layer.duplicate` (not `layer.add`) because
    // an added layer has no vertices.
    cmd(`{"id":"layer.duplicate","index":0}`);
    assert(layerCount() == 5, "mesh, three clips, and the duplicate");
    immutable int dup = 4;
    cmd(`{"id":"layer.select","index":` ~ to!string(dup) ~ `,"mode":"set"}`);
    cmd(`{"id":"layer.select","index":1,"mode":"add"}`);
    assert(selectedIndices() == [1, dup] && primaryIndices() == [dup],
        "fixture: a two-item selection whose primary is NOT layer 0, read "
        ~ to!string(selectedIndices()) ~ " primary "
        ~ to!string(primaryIndices()));
    cmd(`{"id":"history.clear"}`);

    cmd(`{"id":"imagePlane.add"}`);
    assert(selectedIndices() == [5],
        "the add cleared both, read " ~ to!string(selectedIndices()));
    assert(primaryIndices() == [dup],
        "…and left the edit target where it was (task 0671) — a plane's "
        ~ "select cannot reach the mesh bucket. Read "
        ~ to!string(primaryIndices()));

    postUndo();

    assert(layerCount() == 5, "the plane is gone");
    assert(selectedIndices() == [1, dup],
        "the undo restored the WHOLE prior set, not a set-of-one. Read "
        ~ to!string(selectedIndices()));
    assert(primaryIndices() == [dup],
        "…and the prior PRIMARY specifically — `[0]` would be a rehome to the "
        ~ "first mesh, `[]` would be an undo that left the document with no "
        ~ "edit target. Read " ~ to!string(primaryIndices()));
    assert(activeIndex() == dup,
        "which `active` agrees with, read " ~ to!string(activeIndex()));
    assert(focusedIndex() == 1,
        "and the prior FOCUS is back on clip A, read "
        ~ to!string(focusedIndex()));

    // The edit target really works again, not merely reported.
    auto sub = cmdRaw(`{"id":"mesh.subdivide"}`);
    assert(sub["status"].str == "ok",
        "a mesh command runs again after the undo: " ~ sub.toString);
}

// ---------------------------------------------------------------------------
// T-A6 (tasks 0668 / 0671) — the add does NOT move the edit target, so the
// foreground mesh must stay staged.
//
// ~~The add moves the edit target, so it must fire the active-layer switch
// hook… `36` after the add means the cube is still staged as the FOREGROUND
// mesh while the document says there is no edit target.~~
//
// TASK 0671 INVERTED THIS ROW, and it is the same inversion as everywhere
// else: creating a plane flushes the PLANE history bucket and leaves the mesh
// in the mesh one, so the mesh is still the edit target and still the
// foreground mesh. `36` is now the correct reading and `0` is the defect — a
// document whose panel, gizmo and tool all still address the cube, with the
// empty stand-in staged in the GPU buffers so nothing draws bright.
//
// The hook obligation itself is unchanged and is not retired: `imagePlane.add`
// still calls `fireSwitchIfChanged`, which fires iff the target OBJECT moved.
// On this path it now never does, so the call is inert here — which is why
// this row asserts what must NOT happen rather than what must.
//
// The wrong implementations and their readings:
//   * the apply drops the edit target (0668's behaviour, reintroduced)  ->
//     `0` after the add;
//   * the undo re-stages something else  ->  anything but `36` after it.
// ---------------------------------------------------------------------------
unittest {
    long faceVerts() { return getJson("/api/gpu/face-vbo")["faceVertCount"].integer; }

    resetCube();
    assert(faceVerts() == 36,
        "fixture: the cube's 6 quads are staged as 36 face-verts, read "
        ~ to!string(faceVerts()));

    cmd(`{"id":"imagePlane.add"}`);
    assert(faceVerts() == 36,
        "the cube is STILL the edit target after the add, so it stays staged "
        ~ "as the foreground mesh. 0 means the empty stand-in was uploaded — "
        ~ "the target was dropped. Read " ~ to!string(faceVerts()));
    assert(layerAt(0)["primary"].boolean,
        "…and the document agrees, so the reading above is not the buffers "
        ~ "being stale");

    postUndo();
    assert(faceVerts() == 36,
        "and the undo leaves it staged — nothing about the edit target moved "
        ~ "in either direction. Read " ~ to!string(faceVerts()));
}
