// Task 0616 Ph7 — the two image-item claims that only an END-TO-END run can
// make, driven through `/api/command` against the live document.
//
// WHAT IS DELIBERATELY NOT HERE, because it is already covered and a second
// copy would only make it unclear which one is authoritative:
//
//   * "load an image by path" — `tests/test_image_commands.d` already drives
//     `image.load` over HTTP and reads the path back, including the failure
//     case that names the path (the task-0633 trap);
//   * "two references to one clip" — `document.d`'s link suite (many→one via
//     `referrersOf`, `is`-identity, a decoy clip sharing the target's path)
//     and `commands/image/commands.d`'s `imageRemoveWarning` pair;
//   * "deleting a clip under a live reference" — `document.d` (middle delete,
//     both links Dangling, no neighbour swap) and `commands/image/commands.d`
//     (through `ImageRemove`, undo restores the same object at the same slot).
//
// What NONE of those can reach:
//
//   1. THE WHOLE CHAIN. `image.load` → `file.save` → the folder moves →
//      `file.load`. The in-module tests call `writeV3d`/`readV3d` directly with
//      a hand-set `storedPath`; they cannot see whether the COMMANDS hand the
//      codec the path they were asked to use. Two implementations this
//      separates, neither reachable in-module: one that skips the anchor and
//      stores the absolute path, and one that anchors on the REMEMBERED
//      document path (`io.doc_state` is right there, and `file.save` consults
//      it three lines below the write) instead of the file at hand.
//
//   2. A LINK THAT CAME FROM A FILE SOMEBODY ELSE WROTE. Today a `.v3d` with a
//      `links` array is the ONLY user-reachable way a link enters the document
//      — the first command that creates one arrives with the reference-image
//      item, a later task. Every existing link test round-trips through OUR
//      writer, so a reader and a writer that agreed on the WRONG meaning of
//      `target` would round-trip perfectly and prove nothing. A hand-authored
//      file pins the wire meaning: `target: 2` is `layers[2]`, and the proof
//      is that removing `layers[2]` is what breaks the link.
//
// Both cases write their files from this process and hand the app absolute
// paths, exactly as the file dialog would.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.file   : write, copy, exists, mkdirRecurse, rmdirRecurse, readText,
                    tempDir;
import std.path   : buildPath, buildNormalizedPath, dirName;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// HTTP helpers (mirrors tests/test_image_commands.d)
// ---------------------------------------------------------------------------

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

JSONValue getLayers() { return parseJSON(cast(string)get(baseUrl ~ "/api/layers")); }
JSONValue layerAt(size_t i) { return getLayers()["layers"].array[i]; }
size_t    layerCount() { return getLayers()["layers"].array.length; }

string jsonStr(string s) { return JSONValue(s).toString(); }

/// The image item's path, read back through the generic attr query. This is
/// the only HTTP-visible read of `storedPath` in this slice — `/api/layers`
/// grows its image sub-object (`width` / `height` / `missing`) in a later
/// stage, so the RESOLVED ABSOLUTE PATH is the whole observable here, and the
/// fixtures below are built so that it alone separates right from wrong.
string storedPathOf(size_t idx) {
    auto r = cmdRaw("layer.attr " ~ idx.to!string ~ " filename ?");
    assert(r["status"].str == "ok", "filename query failed: " ~ r.toString);
    assert("value" in r, "filename query returned no value: " ~ r.toString);
    return r["value"].str;
}

// A minimal uncompressed 24-bit BMP. Deliberately a local copy rather than a
// shared `tests/*_helpers.d`: run_test.d compiles EVERY helper into EVERY
// test, so a helper module is a project-wide name, and this is twenty lines.
string bmpAt(string path, int w, int h) {
    mkdirRecurse(dirName(path));
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

/// A wiped scratch directory. Wiped, not merely created: a file left behind by
/// an earlier run — including a DELIBERATE-BREAK run — is otherwise visible to
/// the next one, and a test whose result depends on that is not a test. (The
/// same lesson `io/image_path.d` and `io/native.d` both record.)
string scratch(string tag) {
    auto d = buildPath(tempDir(), "vibe3d_imgdocmove_" ~ tag);
    if (exists(d)) rmdirRecurse(d);
    mkdirRecurse(d);
    return d;
}

// ===========================================================================
// 1 — THE DOCUMENT MOVES TO ANOTHER FOLDER, through the commands.
//
// `image.load A/img.bmp` → `file.save A/scene.v3d` → the document is copied
// into `B/` → `file.load B/scene.v3d`. The item must now point at B's image.
//
// THE MOVE IS A REAL FILE COPY, not a rewritten string, and `A/` IS LEFT
// STANDING. That is the point: an implementation that stored the ABSOLUTE path
// resolves after the move to `A/img.bmp`, a file that genuinely still exists
// and opens — so every "it resolved to something" / "it is not missing"
// assertion passes it. The two copies also differ in content (3x2 vs 9x4) so
// the mistake is a real one and not a naming quibble; the dimensions are not
// HTTP-visible in this slice, so the assertion is on the resolved DIRECTORY,
// which separates the two answers exactly.
//
// The second half re-saves from `B/` and reads the stored string again. That is
// a different number from the first assertion, not a restatement of it: it
// catches a resolve that landed correctly in B while the STORE side anchored
// somewhere else, which would rewrite the path on every save until the document
// no longer knew what it pointed at.
// ===========================================================================
unittest {
    auto root = scratch("moved");
    auto dirA = buildPath(root, "A");
    auto dirB = buildPath(root, "B");
    auto docA = buildPath(dirA, "scene.v3d");
    auto docB = buildPath(dirB, "scene.v3d");
    auto imgA = bmpAt(buildPath(dirA, "img.bmp"), 3, 2);
    auto imgB = bmpAt(buildPath(dirB, "img.bmp"), 9, 4);

    resetCube();
    immutable idx = layerCount();
    assert(loadOk(imgA), "the fixture image loads");
    assert(storedPathOf(idx) == imgA,
        "precondition: in MEMORY the item holds the absolute path it was "
        ~ "given — the relative form exists only on disk");

    cmd(`{"id":"file.save","params":{"path":` ~ jsonStr(docA) ~ `}}`);

    // Precondition, not a claim of its own (`io/native.d`'s N1 owns the file
    // shape): unless the save wrote the RELATIVE form there is nothing for the
    // move below to demonstrate. What makes it worth re-reading HERE is that
    // this document's path was authored by `image.load` and anchored by
    // `file.save`'s own argument — the in-module fixture hand-sets both.
    {
        auto raw = parseJSON(readText(docA));
        auto row = raw["layers"].array[idx];
        assert(row["image"]["filename"].str == "img.bmp",
            "the save anchored the stored path on the path IT WAS GIVEN. Got '"
            ~ row["image"]["filename"].str ~ "'");
    }

    // --- the move: a real copy, with A left intact --------------------------
    copy(docA, docB);
    assert(exists(imgA) && exists(imgB),
        "fixture: BOTH images exist, so the wrong answer is a readable file "
        ~ "and not a missing one");

    cmd(`{"id":"file.load","params":{"path":` ~ jsonStr(docB) ~ `}}`);

    // Vacuity guards: we are about to read an image item's path, so there had
    // better be an image item to read it from.
    assert(layerCount() == idx + 1, "the moved document carries its item");
    assert(layerAt(idx)["type"].str == "image" && layerAt(idx)["name"].str == "img",
        "…and it is still the image row");

    // THE ASSERTION.
    assert(storedPathOf(idx) == imgB,
        "the moved document finds the image BESIDE ITSELF. An absolute stored "
        ~ "path reads " ~ imgA ~ " here — which exists and opens. Got "
        ~ storedPathOf(idx));
    assert(dirName(storedPathOf(idx)) == buildNormalizedPath(dirB),
        "…stated as the directory too, so a path that merely ends in the right "
        ~ "basename cannot pass");

    // --- and the STORE side re-anchors on B ---------------------------------
    auto docB2 = buildPath(dirB, "scene2.v3d");
    cmd(`{"id":"file.save","params":{"path":` ~ jsonStr(docB2) ~ `}}`);
    {
        auto raw = parseJSON(readText(docB2));
        assert(raw["layers"].array[idx]["image"]["filename"].str == "img.bmp",
            "a save from the new location stores the SAME relative string — an "
            ~ "item that had resolved back into A re-stores as '../A/img.bmp' "
            ~ "and the document decays a directory per save. Got '"
            ~ raw["layers"].array[idx]["image"]["filename"].str ~ "'");
    }
}

bool loadOk(string path) {
    auto r = cmdRaw(`{"id":"image.load","path":` ~ jsonStr(path) ~ `}`);
    return r["status"].str == "ok";
}

// ===========================================================================
// 2 — A HAND-AUTHORED `.v3d` BRINGS LIVE LINKS IN, AND A CLIP REMOVED FROM
//     UNDER TWO OF THEM TAKES BOTH DOWN — THROUGH `/api/undo`, NOT `revert()`.
//
// The fixture (six items, indices as written):
//
//   0 mesh  "Base"       primary
//   1 image "clipA"      -> shared.bmp     <- shares the target's FILE
//   2 image "clipB"      -> shared.bmp     <- THE TARGET, a middle clip
//   3 image "clipC"      -> other.bmp
//   4 empty "consumerX"  links: backdropImage -> 2
//   5 empty "consumerY"  links: maskImage -> 3, backdropImage -> 2
//
// Every part of that shape is load-bearing:
//
//   * THREE clips and the links aim at the MIDDLE one. An off-by-one in the
//     post-parse resolve lands on clipA or clipC — both real items, so "the
//     link resolved" passes.
//   * clipA carries the SAME FILE as clipB. A path-keyed resolve picks clipA,
//     which is the failure mode that looks like success: with one file per clip
//     it would resolve to nothing and be obvious.
//   * TWO consumers on clipB. A sweep that stops at the first referrer is
//     invisible with one.
//   * consumerY holds a SECOND slot, onto a different clip. It is the control
//     that survives the removal — without it, "the links are gone" is equally
//     what an implementation that dropped links wholesale produces. Its index
//     also MOVES (3 → 2) when clipB is spliced out, so a writer echoing a
//     cached index writes 3, which after the splice names consumerX.
//   * consumerY's two slots are written in the file in NON-canonical order
//     (maskImage before backdropImage). The re-save must emit them sorted, so
//     the order is re-derived from the slot list rather than echoed.
//
// The removal is what makes the READ side honest. A reader and a writer that
// agreed on a wrong meaning of `target` round-trip perfectly; but if the reader
// had resolved `2` to clipA, then removing clipB leaves both links LIVE and the
// re-saved file still carries them.
// ===========================================================================
unittest {
    auto root = scratch("links");
    auto doc  = buildPath(root, "scene.v3d");
    bmpAt(buildPath(root, "shared.bmp"), 3, 2);
    bmpAt(buildPath(root, "other.bmp"),  5, 7);

    write(doc,
        `{"formatVersion":8,"primaryLayer":0,"focusedItem":0,"layers":[`
        ~ `{"type":"mesh","selected":true,"channels":{"name":"Base","visible":true},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}},`
        ~ `{"type":"image","selected":false,"channels":{"name":"clipA","visible":true},`
        ~ `"image":{"filename":"shared.bmp"}},`
        ~ `{"type":"image","selected":false,"channels":{"name":"clipB","visible":true},`
        ~ `"image":{"filename":"shared.bmp"}},`
        ~ `{"type":"image","selected":false,"channels":{"name":"clipC","visible":true},`
        ~ `"image":{"filename":"other.bmp"}},`
        ~ `{"type":"empty","selected":false,"channels":{"name":"consumerX","visible":true},`
        ~ `"links":[{"slot":"backdropImage","target":2}]},`
        ~ `{"type":"empty","selected":false,"channels":{"name":"consumerY","visible":true},`
        ~ `"links":[{"slot":"maskImage","target":3},{"slot":"backdropImage","target":2}]}`
        ~ `]}`);

    resetCube();
    cmd(`{"id":"file.load","params":{"path":` ~ jsonStr(doc) ~ `}}`);
    cmd(`{"id":"history.clear"}`);   // so the undo below is the removal's

    assert(layerCount() == 6, "fixture: six items came in");
    assert(layerAt(2)["type"].str == "image" && layerAt(2)["name"].str == "clipB",
        "fixture: clipB is the MIDDLE clip, at index 2");
    assert(layerAt(1)["name"].str == "clipA" && layerAt(3)["name"].str == "clipC",
        "fixture: a clip on either side of it");
    assert(storedPathOf(1) == storedPathOf(2),
        "fixture: clipA and clipB resolve to ONE file — that is what makes a "
        ~ "path-keyed resolve pick the wrong clip instead of no clip");

    auto out0 = buildPath(root, "out0.v3d");
    cmd(`{"id":"file.save","params":{"path":` ~ jsonStr(out0) ~ `}}`);
    {
        // The links exist AT ALL. Without this, everything below is equally
        // satisfied by a reader that ignored the `links` key outright.
        auto ls = parseJSON(readText(out0))["layers"].array;
        assertSlots(ls[4], [["backdropImage", "2"]],
            "consumerX kept the slot the file gave it");
        assertSlots(ls[5], [["backdropImage", "2"], ["maskImage", "3"]],
            "consumerY kept both — and they come out NAME-SORTED, though the "
            ~ "file listed maskImage first");
    }

    // --- the clip goes, out from under both links ---------------------------
    cmd(`{"id":"image.remove","index":2}`);
    assert(layerCount() == 5, "clipB left the document");
    assert(layerAt(2)["name"].str == "clipC",
        "…and clipC SLID DOWN into its slot — the exact index a stale target "
        ~ "would now name");

    auto out1 = buildPath(root, "out1.v3d");
    cmd(`{"id":"file.save","params":{"path":` ~ jsonStr(out1) ~ `}}`);
    {
        auto ls = parseJSON(readText(out1))["layers"].array;
        assert("links" !in ls[3],
            "consumerX's only slot named the removed clip, so it writes NO "
            ~ "links block. A reader that had resolved `2` to clipA leaves this "
            ~ "link live and writes one. Got " ~ ls[3].toString);
        assertSlots(ls[4], [["maskImage", "2"]],
            "consumerY keeps ONLY its surviving slot, re-indexed to clipC's NEW "
            ~ "position (2). Two entries here means the dead link survived; "
            ~ "target 3 means a cached index — and 3 is now consumerX");
    }

    // --- undo, through the real history stack -------------------------------
    auto u = parseJSON(cast(string)post(baseUrl ~ "/api/undo", ""));
    assert(u["status"].str == "ok", "undo of the removal failed: " ~ u.toString);
    assert(layerCount() == 6 && layerAt(2)["name"].str == "clipB",
        "the clip is back at its slot");

    auto out2 = buildPath(root, "out2.v3d");
    cmd(`{"id":"file.save","params":{"path":` ~ jsonStr(out2) ~ `}}`);
    {
        auto ls = parseJSON(readText(out2))["layers"].array;
        assertSlots(ls[4], [["backdropImage", "2"]],
            "BOTH links are live again because the undo put back THE SAME "
            ~ "object — an undo that minted a fresh item leaves them dangling "
            ~ "and this block absent, with a row that looks identical in the "
            ~ "panel");
        assertSlots(ls[5], [["backdropImage", "2"], ["maskImage", "3"]],
            "…including the consumer that held two");
    }
}

/// Assert a written item's `links` array equals `want` — [[slot, target], ...]
/// IN ORDER. Order is part of the claim (the slot list is name-sorted), so a
/// set comparison would not do.
void assertSlots(JSONValue row, string[][] want, string why) {
    assert("links" in row, why ~ " — but the item has no links block: " ~ row.toString);
    auto got = row["links"].array;
    assert(got.length == want.length,
        why ~ " — expected " ~ want.length.to!string ~ " slot(s), got "
        ~ row["links"].toString);
    foreach (i, ref w; want) {
        assert(got[i]["slot"].str == w[0] && got[i]["target"].integer.to!string == w[1],
            why ~ " — slot " ~ i.to!string ~ " expected {" ~ w[0] ~ "," ~ w[1]
            ~ "}, got " ~ got[i].toString);
    }
}
