// Task 0612 Stage 3 — the plane → clip link, driven the way a caller reaches
// it: `imagePlane.setImage` over `/api/command`, read back through
// `/api/layers`.
//
// This is the tree's FIRST production `setLink` caller, so the link model
// itself becomes observable here for the first time. What only this file can
// prove:
//
//   * the command is REGISTERED, and its two index arguments arrive under the
//     names it declares. `injectParamsInto` ignores an unknown JSON key, so a
//     misspelled argument silently runs the command on its defaults — every
//     assertion below is therefore on an OUTCOME that is unreachable unless
//     the argument landed, never on `status: ok`;
//   * `/api/layers` reports the slot, the target's LAYER index, and the link
//     state — the three things a caller has no other way to see;
//   * deleting the target leaves the plane alone and its link DANGLING (links
//     are never swept), and undo restores it to LIVE by object identity, with
//     nothing on the link side to restore.
//
// FIXTURE, and why it is shaped this way. Three clips, the plane bound to the
// MIDDLE one, and all three naming ONE file. One clip could not tell a real
// lookup from "resolved to the only one there was"; three clips with three
// paths would make a path-identity bug resolve to nothing, which reads like a
// broken link. Three clips on one path makes it resolve to the WRONG clip,
// with every count still adding up — the only arrangement where the bug is
// visible. The target is the MIDDLE one so "off by one" and "took the first"
// and "took the last" are three different observations.

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

JSONValue postUndo() { return parseJSON(cast(string)post(baseUrl ~ "/api/undo", "")); }

JSONValue layers() { return getJson("/api/layers")["layers"]; }
JSONValue layerAt(size_t i) { return layers().array[i]; }

immutable scratch = "/tmp/vibe3d_planelink";

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

/// Build [mesh, clip1, clip2, clip3, plane] and return the plane's index.
///
/// The plane arrives through the test-only injector. That was a necessity
/// when this file was written — Stage 3 deliberately shipped no user-reachable
/// creation route — and is now a CHOICE: `imagePlane.add` (Stage 7) exists,
/// and `tests/test_image_plane_create.d` drives it. Keeping the injector here
/// is deliberate: these assertions are about the LINK model, and a fixture
/// built by the same command whose behaviour a sibling file is pinning would
/// make one bug able to turn both files green together.
size_t buildFixture() {
    resetCube();
    auto file = bmpAt("sheet.bmp", 5, 7);
    foreach (_; 0 .. 3)
        cmd(`{"id":"image.load","path":` ~ jsonStr(file) ~ `}`);
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/test/layer",
        `{"kind":"imagePlane","name":"front sheet"}`));
    assert(r["status"].str == "ok", "plane injection failed: " ~ r.toString);
    auto ls = layers().array;
    assert(ls.length == 5, "mesh + three clips + one plane");
    assert(ls[4]["type"].str == "imagePlane", "the injected row is a plane");
    return 4;
}

/// The plane row's `links` entry for `slot`, or `JSONValue(null)`.
JSONValue linkSlot(size_t layerIdx, string slot) {
    foreach (s; layerAt(layerIdx)["links"].array)
        if (s["slot"].str == slot) return s;
    return JSONValue(null);
}

// ---------------------------------------------------------------------------
// T-L1 — bind the MIDDLE clip; `/api/layers` reports slot/target/state.
// ---------------------------------------------------------------------------
unittest {
    immutable p = buildFixture();

    // Unbound to start: no slot at all. An absent slot and an unset one are
    // the same state by design, and the response has one representation.
    assert(layerAt(p)["links"].array.length == 0, "a fresh plane holds no link");
    assert(layerAt(p)["imageSource"].str == "unbound",
        "and reports itself unbound");

    cmd(`{"id":"imagePlane.setImage","index":4,"image":2}`);

    auto s = linkSlot(p, "image");
    assert(s.type != JSONType.null_,
        "the plane now has an `image` slot — an implementation that wrote a "
        ~ "different slot name has nothing here, and the link API's "
        ~ "absent-slot answer is silent by design");
    assert(s["state"].str == "live", "and it resolves: " ~ s.toString);
    assert(s["target"].integer == 2,
        "at the MIDDLE clip, layer 2 — all three clips name ONE file, so a "
        ~ "path-keyed lookup lands on 1 and an off-by-one on 1 or 3");
    assert(layerAt(p)["imageSource"].str == "ready",
        "and the source verdict is Ready");

    // The OTHER two clips did not acquire a link: a link is on the CONSUMER,
    // one-directional, and the target knows nothing about it.
    foreach (i; [1, 3])
        assert(layerAt(i)["links"].array.length == 0,
            "the clip at " ~ i.to!string ~ " holds no link of its own — the "
            ~ "reference is forward-only");

    // Re-point to a different clip: the slot is REPLACED, not doubled.
    cmd(`{"id":"imagePlane.setImage","index":4,"image":3}`);
    assert(layerAt(p)["links"].array.length == 1, "still exactly one slot");
    assert(linkSlot(p, "image")["target"].integer == 3, "now naming clip 3");

    // Undo the re-point: back to the middle clip, not to unbound. This is the
    // assertion that separates "revert restores the PREVIOUS target" from
    // "revert clears the slot", and only a fixture with two successive binds
    // can see the difference.
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    auto restored = linkSlot(p, "image");
    assert(restored.type != JSONType.null_,
        "undo restores the SLOT — a revert that CLEARS instead of restoring "
        ~ "leaves no slot here at all");
    assert(restored["target"].integer == 2,
        "and restores the PREVIOUS target, not an empty slot");
}

// ---------------------------------------------------------------------------
// The command refuses a wrong-kind argument instead of acting on the wrong
// row. Both indices are into ONE array, which is exactly where a swap hides.
// ---------------------------------------------------------------------------
unittest {
    immutable p = buildFixture();

    // The two arguments swapped: plane index 2 (a clip), image index 4 (the
    // plane). Both are in range, so only a capability check can catch it.
    auto swapped = cmdRaw(`{"id":"imagePlane.setImage","index":2,"image":4}`);
    assert(swapped["status"].str != "ok",
        "a clip is not a plane — this must refuse, not bind something");
    assert(layerAt(p)["links"].array.length == 0, "and nothing was written");
    assert(layerAt(2)["links"].array.length == 0, "on either row");

    // Out of range, both ends.
    assert(cmdRaw(`{"id":"imagePlane.setImage","index":99,"image":2}`)["status"].str != "ok",
        "a plane index past the end is refused, never clamped to the last row");
    assert(cmdRaw(`{"id":"imagePlane.setImage","index":4,"image":99}`)["status"].str != "ok",
        "and so is an image index past the end");
    assert(layerAt(p)["links"].array.length == 0, "still nothing written");

    // A mesh is not a clip either.
    assert(cmdRaw(`{"id":"imagePlane.setImage","index":4,"image":0}`)["status"].str != "ok",
        "the mesh at layer 0 is not a loaded image item");
    assert(layerAt(p)["links"].array.length == 0, "still nothing written");
}

// ---------------------------------------------------------------------------
// T-L2 / T-L3 — deleting the clip DANGLES the link (it is never swept), the
// plane survives, and undo makes it Live again by object identity.
// ---------------------------------------------------------------------------
unittest {
    immutable p = buildFixture();
    cmd(`{"id":"imagePlane.setImage","index":4,"image":2}`);
    assert(linkSlot(p, "image")["state"].str == "live", "bound to start");

    cmd(`{"id":"image.remove","index":2}`);

    auto ls = layers().array;
    assert(ls.length == 4, "the clip is gone; the plane is not");
    // The plane moved down one index with the splice — read it by type, not
    // by the number it used to have, or this test would be asserting against
    // whatever landed at index 4.
    size_t p2 = size_t.max;
    foreach (i, l; ls) if (l["type"].str == "imagePlane") p2 = i;
    assert(p2 != size_t.max, "the plane survives its clip's deletion");

    auto s = linkSlot(p2, "image");
    assert(s.type != JSONType.null_,
        "the slot is STILL THERE — links are never swept, which is what makes "
        ~ "undo exact for free");
    assert(s["state"].str == "dangling",
        "and it reports dangling: the target is named and is not a member");
    assert(s["target"].integer == -1,
        "with no index, because a non-member has none");
    assert(layerAt(p2)["imageSource"].str == "dangling",
        "the source verdict says the ITEM is gone — not `missing`, which "
        ~ "would send the user to the filesystem for a problem undo fixes");

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo of the removal failed: " ~ u.toString);
    assert(layers().array.length == 5, "the clip is back");

    size_t p3 = size_t.max;
    foreach (i, l; layers().array) if (l["type"].str == "imagePlane") p3 = i;
    auto s2 = linkSlot(p3, "image");
    assert(s2["state"].str == "live",
        "the link is LIVE again with nothing on the link side restored — undo "
        ~ "reinserted the SAME object, so identity did the work. An undo that "
        ~ "minted a fresh Layer leaves this dangling forever, beside a "
        ~ "visually identical row");
    assert(s2["target"].integer == 2, "at its original index");
    assert(layerAt(p3)["imageSource"].str == "ready", "and usable again");
}
