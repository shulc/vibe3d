// Module unittests for `image_cache`, moved verbatim out of source/image_cache.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.image_cache_test;

import io.image_decode : DecodedImage, ImageInfo, imageDecode, imageInfo,
                          MAX_IMAGE_BYTES;
import log : logWarn;
import bindbc.opengl;
import gl_thread_guard : glThreadGuard;
import io.image_path : writeTestBmp, imageTestDir;
import std.path : buildPath;
import image_cache;

// T-C1 — two clips on ONE path collapse to ONE entry and ONE decode.
//
// The fixture is THREE paths, two of which name the same file, and the
// operated-on entry is the MIDDLE one — a single-path fixture cannot tell a
// real path lookup from "resolved to the only one there was".
//
// Deliberate break (performed, then restored): keying entries by the
// live-set INDEX instead of by the path string — i.e. appending an entry per
// element of `liveSet` without the `find()` guard in pass 3 — reads
// residentEntries == 3 and decodeCount == 3.
unittest {
    auto dir = imageTestDir("cache_dedup");
    auto a   = buildPath(dir, "a.bmp");   // 3x2
    auto b   = buildPath(dir, "b.bmp");   // 5x7
    writeTestBmp(a, 3, 2);
    writeTestBmp(b, 5, 7);

    ImagePixelCache c;
    // a, b, a — the duplicate is NOT adjacent to its twin, so a
    // "skip if equal to the previous element" dedup does not pass either.
    c.reconcile([a, b, a]);

    assert(c.residentEntries() == 2,
        "two distinct files behind three live references are two entries");
    assert(c.decodeCount() == 2, "the repeated path is decoded once, not twice");
    assert(c.lookup(a) != 0 && c.lookup(b) != 0, "both files are resident");
    assert(c.lookup(a) != c.lookup(b), "and they are DIFFERENT textures");
    assert(c.lookup(buildPath(dir, "nope.bmp")) == 0,
        "a path that was never live looks up as absent");
    c.shutdown();
}

// T-C2 — a path that leaves the live set is freed, and the one that stays is
// NOT. Asserted through `residentBytes` with two DIFFERENT-SIZED images, so
// "the right count with the wrong survivor" is visible; an entries-only
// assertion cannot see that bug.
//
// Deliberate break (performed, then restored): making pass 2 free every
// entry unconditionally reads residentEntries == 0 / residentBytes == 0 after
// the second reconcile (and decodeCount 3, since A is then reloaded).
unittest {
    auto dir = imageTestDir("cache_leave");
    auto a   = buildPath(dir, "a.bmp");   // 3x2 -> 24 bytes
    auto b   = buildPath(dir, "b.bmp");   // 5x7 -> 140 bytes
    writeTestBmp(a, 3, 2);
    writeTestBmp(b, 5, 7);

    ImagePixelCache c;
    c.reconcile([a, b]);
    assert(c.residentEntries() == 2, "both live");
    assert(c.residentBytes() == 3 * 2 * 4 + 5 * 7 * 4, "both accounted");

    c.reconcile([a]);
    assert(c.residentEntries() == 1, "B left the live set and was freed");
    assert(c.residentBytes() == 3 * 2 * 4,
        "the SURVIVOR is A — the sizes differ, so the wrong survivor reads 140");
    assert(c.lookup(a) != 0, "A is still resident");
    assert(c.lookup(b) == 0, "B is not");
    assert(c.decodeCount() == 2, "A was not re-decoded on the way through");
    c.shutdown();
    assert(c.residentEntries() == 0 && c.residentBytes() == 0,
        "shutdown releases everything");
}

// T-C2b — reconciling the SAME set twice does not re-decode. The cheap
// version of the orbit regression, and it is what makes `reconcile` callable
// unconditionally once per frame.
//
// Deliberate break (performed, then restored): dropping the `find(p) !is
// null` guard from pass 3 reads decodeCount == 2 after the second call.
unittest {
    auto dir = imageTestDir("cache_idem");
    auto a   = buildPath(dir, "a.bmp");
    writeTestBmp(a, 3, 2);

    ImagePixelCache c;
    c.reconcile([a]);
    immutable uint tex1 = c.lookup(a);
    assert(c.decodeCount() == 1 && c.residentEntries() == 1, "loaded once");

    foreach (_; 0 .. 8) c.reconcile([a]);
    assert(c.decodeCount() == 1, "eight more reconciles of an unchanged set: still one decode");
    assert(c.residentEntries() == 1, "and still one entry");
    assert(c.lookup(a) == tex1, "the texture NAME is stable, not re-created");
    c.shutdown();
}

// T-C3 — `residentBytes` is GPU bytes (w*h*4), not the file's size on disk,
// and it returns to zero when the path leaves.
//
// The 3x2 BMP is 78 bytes on disk (54-byte header + two 12-byte padded rows)
// and 24 bytes as RGBA, so the two candidate implementations read different
// numbers. Deliberate break (performed, then restored): accounting
// `bytes.length` (the file buffer) instead of `w*h*4` reads 78. (The plan's
// T-C3 row predicts 54 — that is the BMP HEADER's size, not the file's; the
// discrimination the row is after is unaffected.)
unittest {
    auto dir = imageTestDir("cache_bytes");
    auto a   = buildPath(dir, "a.bmp");
    writeTestBmp(a, 3, 2);

    ImagePixelCache c;
    c.reconcile([a]);
    assert(c.residentBytes() == 24,
        "3*2 RGBA = 24 GPU bytes — the FILE is 78 bytes, which is the wrong answer");

    c.reconcile([]);
    assert(c.residentBytes() == 0, "an empty live set frees everything");
    assert(c.residentEntries() == 0, "and reports no entries");
    c.shutdown();
}

// T-C6 — the residency budget never drops a path that IS resident.
//
// Budget set below the total of a two-file live set. The admitted path is the
// one that fitted; the refused one stays absent; and — the load-bearing half
// — repeated reconciles do NOT thrash: the resident entry is never evicted to
// make room, so the decode count stays put.
//
// Deliberate break (performed, then restored): replacing the admission check
// with "evict the oldest entry until the newcomer fits" reads
// residentBytes == 140 (B displaces A) and a decodeCount that climbs by one
// per reconcile — a decode-per-frame loop wearing a correct-looking
// residency count of 1.
unittest {
    auto dir = imageTestDir("cache_budget");
    auto a   = buildPath(dir, "a.bmp");   // 3x2 -> 24 bytes
    auto b   = buildPath(dir, "b.bmp");   // 5x7 -> 140 bytes
    writeTestBmp(a, 3, 2);
    writeTestBmp(b, 5, 7);

    ImagePixelCache c;
    c.budgetBytes = 100;                  // fits A, cannot also fit B

    foreach (_; 0 .. 5) c.reconcile([a, b]);
    assert(c.residentEntries() == 1, "the budget capped residency at one entry");
    assert(c.residentBytes() == 24,
        "the RESIDENT one is A — an evicting implementation reads 140 here");
    assert(c.lookup(a) != 0 && c.lookup(b) == 0, "A resident, B refused");
    assert(c.decodeCount() == 1,
        "five reconciles under budget pressure caused ONE decode, not five");

    // Headroom released by a departure is usable in the SAME reconcile: A
    // leaves and B arrives at once, which only works because departures are
    // processed before arrivals. The budget is set so that B fits ONLY after
    // A's 24 bytes have been reclaimed (140 <= 150 < 24 + 140) — with the two
    // passes swapped this reads entries 0 / bytes 0, and no ordering-agnostic
    // budget could tell the difference.
    c.budgetBytes = 150;
    c.reconcile([b]);
    assert(c.residentEntries() == 1 && c.residentBytes() == 140,
        "A left and B took its place in one call");
    c.shutdown();
}

// A path that cannot be read is attempted ONCE while it stays live, and is
// retried once it has left and come back. Nothing is resident for it either
// way — a failure memo is not a texture.
//
// Deliberate break (performed, then restored): counting memo entries in
// `residentEntries` reads 1 instead of 0 for a file that does not exist.
unittest {
    auto dir  = imageTestDir("cache_broken");
    auto good = buildPath(dir, "a.bmp");
    auto bad  = buildPath(dir, "not_an_image.bmp");
    writeTestBmp(good, 3, 2);
    import std.file : write;
    write(bad, "this is not an image");

    ImagePixelCache c;
    foreach (_; 0 .. 4) c.reconcile([good, bad]);
    assert(c.residentEntries() == 1, "only the readable file is resident");
    assert(c.residentBytes() == 24, "and only its bytes are accounted");
    assert(c.lookup(bad) == 0, "the broken path has no texture");
    assert(c.decodeCount() == 1, "the broken file was attempted, then remembered");

    // Leaving the live set drops the memo, so a re-point retries.
    c.reconcile([good]);
    c.reconcile([good, bad]);
    assert(c.decodeCount() == 1, "still no successful decode for the broken file");
    assert(c.residentEntries() == 1, "and it is still not resident");
    c.shutdown();
}
