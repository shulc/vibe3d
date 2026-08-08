module io.image_path;

// ---------------------------------------------------------------------------
// Task 0616 Ph5 — the seam between an image item's AUTHORED path and the
// DERIVED metadata the disk answers with.
//
// Two functions, deliberately separated:
//
//   * `resolveStoredPath` — stored form -> the path we actually open. TODAY
//     that is the identity function, and it is a function anyway so that Ph6
//     (which owns the document-relative anchor rules: beside the document,
//     its parent, absolute otherwise) has EXACTLY ONE place to grow them.
//     Every caller in this phase already goes through it, so Ph6 changes one
//     body instead of hunting four call sites.
//
//   * `refreshImageMeta` — re-read the header and refresh the four derived
//     fields on `ImageData`. This is the ONLY writer of those fields, and it
//     is what `image.load` / `image.replace` / `image.reload` each call
//     exactly once. Ph6's `.v3d` reader calls it too, after the parse, which
//     is why it lives in `io/` rather than in the command module: the file
//     format must not have to import a command to find out how big an image
//     is.
//
// Header-only, ALWAYS: this calls `imageInfo`, never `imageDecode`. No pixel
// buffer is ever materialised on this path, so no `DecodedImage.free()` is
// ever owed by it — see the lifetime note in `commands/image/commands.d`.
// ---------------------------------------------------------------------------

import std.file : read;

import document       : ImageData;
import io.image_decode : ImageInfo, imageInfo, MAX_IMAGE_BYTES;
import log            : logWarn;

/// Upper bound on the number of bytes read off disk to answer a header query.
///
/// The file size is a number this process did not write, and `std.file.read`
/// without a bound will happily allocate whatever a hostile (or merely
/// mistaken — a `.v3d` naming a multi-gigabyte video) file claims. Pinned to
/// the decoder's own decoded-byte budget: a compressed file LARGER than the
/// largest buffer we would ever be willing to decode cannot be an image we
/// could use, so one constant governs both ends.
enum size_t MAX_IMAGE_FILE_BYTES = MAX_IMAGE_BYTES;

/// The stored path resolved to a path this process can open.
///
/// Ph5: identity — the stored form IS the path. `image.load` stores whatever
/// absolute path the dialog (or the test) handed it, so there is nothing to
/// anchor against yet.
///
/// Ph6 replaces this body with the anchor chain (as-is when absolute; against
/// the document's directory; against its parent; first hit wins) WITHOUT
/// touching a single caller — that is the entire reason this is a function
/// today rather than an inlined field read.
string resolveStoredPath(string stored) {
    return stored;
}

/// Re-read the header of the file `img` names and refresh its four derived
/// fields. Returns true iff the file was read AND its header parsed.
///
/// Contract on failure, which is the half that matters:
///   * `storedPath` / `colorspace` / `useAlpha` — the AUTHORED fields — are
///     never touched. A file that has gone missing must not be able to erase
///     what the document says about it; that is the "silent forget" failure
///     the task forbids, and it is worse than a missing file because the user
///     cannot tell it happened.
///   * the derived fields are CLEARED, not left stale. `missing == true` next
///     to `width == 3` would be a document that reports both "I could not
///     read this" and "it is three pixels wide", and a consumer has no way to
///     know which half to believe.
///
/// `maxFileBytes` is a parameter purely so the bound above is testable
/// without writing a 256 MiB fixture; every production call site takes the
/// default.
bool refreshImageMeta(ImageData img, size_t maxFileBytes = MAX_IMAGE_FILE_BYTES) {
    if (img is null) return false;

    // Clear FIRST, so every early return below leaves the same well-formed
    // "unresolved" state regardless of which one it took.
    img.width    = 0;
    img.height   = 0;
    img.channels = 0;
    img.missing  = true;

    const path = resolveStoredPath(img.storedPath);
    if (path.length == 0) {
        logWarn("io", "image: refresh skipped — the item names no file");
        return false;
    }

    ubyte[] bytes;
    try {
        // Read at most maxFileBytes + 1: the extra byte is what lets the
        // check below tell "exactly at the bound" from "over it" without
        // trusting a separate `getSize` call that could disagree with what
        // the read actually returns (a file can grow between the two).
        bytes = cast(ubyte[]) read(path, maxFileBytes + 1);
    } catch (Exception e) {
        logWarn("io", "image: cannot read '" ~ path ~ "': " ~ e.msg);
        return false;
    }
    if (bytes.length > maxFileBytes) {
        import std.conv : to;
        logWarn("io", "image: rejected '" ~ path ~ "': larger than the "
            ~ maxFileBytes.to!string ~ "-byte read bound");
        return false;
    }

    ImageInfo info;
    if (!imageInfo(bytes, info)) {
        // imageInfo already logged the reason (bad header, or the dimension
        // bound) — do not double-report it.
        return false;
    }

    img.width    = info.width;
    img.height   = info.height;
    img.channels = info.channels;
    img.missing  = false;
    return true;
}

// ---------------------------------------------------------------------------
// Test support + tests
// ---------------------------------------------------------------------------

version (unittest) {
    import std.file : write, remove, exists, tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;

    /// A minimal uncompressed 24-bit BMP — 14-byte file header, 40-byte
    /// BITMAPINFOHEADER, bottom-up BGR rows padded to 4 bytes.
    ///
    /// Hand-built rather than reusing `io/image_decode.d`'s PNG builder for
    /// one reason: this module's tests (and the command tests that import
    /// this helper) do not care what the PIXELS are — the decoder's own
    /// unittests already prove channel order and row order against a
    /// pixel-distinct PNG. What these tests need is a FILE whose declared
    /// dimensions are distinguishable, and a BMP header carries those in two
    /// plain little-endian ints with no zlib stream and no CRC in the way.
    ubyte[] buildTestBmp(int w, int h) {
        assert(w > 0 && h > 0, "buildTestBmp: dimensions must be positive");
        immutable size_t rowBytes = cast(size_t)((w * 3 + 3) & ~3);
        immutable size_t pixBytes = rowBytes * h;
        immutable size_t fileSize = 54 + pixBytes;

        ubyte[] b;
        b.reserve(fileSize);

        void u16(ushort v) { b ~= cast(ubyte)(v & 0xFF); b ~= cast(ubyte)((v >> 8) & 0xFF); }
        void u32(uint v) {
            b ~= cast(ubyte)(v & 0xFF);         b ~= cast(ubyte)((v >> 8)  & 0xFF);
            b ~= cast(ubyte)((v >> 16) & 0xFF); b ~= cast(ubyte)((v >> 24) & 0xFF);
        }

        b ~= cast(ubyte)'B'; b ~= cast(ubyte)'M';
        u32(cast(uint) fileSize);
        u16(0); u16(0);
        u32(54);                    // pixel data offset
        u32(40);                    // BITMAPINFOHEADER size
        u32(cast(uint) w);
        u32(cast(uint) h);
        u16(1);                     // planes
        u16(24);                    // bits per pixel
        u32(0);                     // BI_RGB, no compression
        u32(cast(uint) pixBytes);
        u32(2835); u32(2835);       // pixels per metre
        u32(0); u32(0);             // palette counts

        // Deterministic, position-dependent bytes — not a flat fill, so a
        // future pixel-level test riding this helper is not born vacuous.
        foreach (y; 0 .. h) {
            foreach (x; 0 .. w) {
                b ~= cast(ubyte)(x * 7 + 3);   // B
                b ~= cast(ubyte)(y * 11 + 5);  // G
                b ~= cast(ubyte)(x * 3 + y);   // R
            }
            foreach (_; 0 .. rowBytes - cast(size_t)(w * 3)) b ~= cast(ubyte) 0;
        }
        return b;
    }

    /// Write a BMP of the given size to `path` (creating parent dirs).
    void writeTestBmp(string path, int w, int h) {
        import std.path : dirName;
        mkdirRecurse(dirName(path));
        write(path, buildTestBmp(w, h));
    }

    /// A per-test scratch directory under the system temp dir, WIPED first.
    ///
    /// The wipe is not tidiness. Without it the directory survives between
    /// runs, and a file left there by a previous run — including one left by
    /// a DELIBERATE-BREAK run — is visible to the next one. That was observed
    /// while verifying these tests: a break that renamed a file on disk left
    /// the renamed file behind, and the NEXT run went red on an unrelated
    /// assertion in a different test. A test whose result depends on what an
    /// earlier run left on disk is not a test.
    string imageTestDir(string tag) {
        auto d = buildPath(tempDir(), "vibe3d_img_" ~ tag);
        if (exists(d)) rmdirRecurse(d);
        mkdirRecurse(d);
        return d;
    }
}

// A successful refresh fills all four derived fields.
//
// Discriminating: w != h (3x2), so a transposed read reads 2x3; and
// `channels` is 3 for a 24-bit BMP, which a hard-coded "always RGBA 4" reads
// as 4.
unittest {
    auto dir  = imageTestDir("refresh_ok");
    auto file = buildPath(dir, "a.bmp");
    writeTestBmp(file, 3, 2);
    scope (exit) { if (exists(file)) remove(file); }

    auto img = new ImageData();
    img.storedPath = file;
    assert(img.missing, "a fresh payload starts unresolved");

    assert(refreshImageMeta(img), "a readable BMP refreshes");
    assert(img.width  == 3, "width comes from the header, not from height");
    assert(img.height == 2, "height comes from the header, not from width");
    assert(img.channels == 3, "a 24-bit BMP has three source channels");
    assert(!img.missing, "a successful refresh clears `missing`");
    assert(img.storedPath == file, "refresh never rewrites the authored path");
}

// A refresh that fails CLEARS the derived fields and leaves the authored ones
// alone.
//
// Discriminating in two directions at once: after the file disappears the
// width must read 0 (a refresh that returns early WITHOUT clearing reads the
// stale 3), and `storedPath` must still name the vanished file (an
// implementation that "cleans up" a dead path reads "").
unittest {
    auto dir  = imageTestDir("refresh_gone");
    auto file = buildPath(dir, "b.bmp");
    writeTestBmp(file, 5, 7);

    auto img = new ImageData();
    img.storedPath = file;
    img.colorspace = "linear";
    assert(refreshImageMeta(img) && img.width == 5 && img.height == 7,
        "fixture: the first refresh resolved");

    remove(file);
    assert(!refreshImageMeta(img), "a vanished file fails the refresh");
    assert(img.missing, "and reports itself missing");
    assert(img.width == 0 && img.height == 0 && img.channels == 0,
        "the derived fields are cleared, never left stale beside `missing`");
    assert(img.storedPath == file,
        "the authored path SURVIVES a missing file — this is the whole reason "
        ~ "a path beats a blob");
    assert(img.colorspace == "linear", "authored channels are untouched too");
}

// A file that is not an image at all fails cleanly (no throw, no partial
// state).
unittest {
    auto dir  = imageTestDir("refresh_junk");
    auto file = buildPath(dir, "c.bmp");
    write(file, "this is not an image");
    scope (exit) { if (exists(file)) remove(file); }

    auto img = new ImageData();
    img.storedPath = file;
    assert(!refreshImageMeta(img), "a non-image file is rejected");
    assert(img.missing && img.width == 0, "and leaves nothing half-filled");
}

// An empty stored path is a failure, not a crash.
unittest {
    auto img = new ImageData();
    assert(!refreshImageMeta(img), "no path -> no resolution");
    assert(img.missing && img.width == 0);
}

// The read bound is real: a file over it is refused, and specifically it is
// the BOUND that refuses it rather than the truncation happening to break the
// parse.
//
// That distinction is the whole test, and getting it wrong was caught by the
// break check: with a 16-byte bound the read returns 17 bytes, the BMP header
// (54 bytes) is incomplete, and `imageInfo` fails — so the assertion held
// with the bound check DELETED. It was passing for the wrong reason.
//
// The discriminating bound is one that lets the HEADER through and cuts the
// file: 60 bytes against a 102-byte 4x4 BMP whose header is 54. `imageInfo`
// on that prefix succeeds and reports 4x4 — so an implementation missing the
// length check answers `true` with real dimensions for a file it only read a
// fraction of, and this test reads that.
unittest {
    auto dir  = imageTestDir("refresh_bound");
    auto file = buildPath(dir, "d.bmp");
    writeTestBmp(file, 4, 4);
    scope (exit) { if (exists(file)) remove(file); }

    auto img = new ImageData();
    img.storedPath = file;
    assert(refreshImageMeta(img), "control: the file is a valid image");
    assert(img.width == 4 && !img.missing);

    // Control for the control: the truncated prefix really IS parseable, so
    // the refusal below cannot be the parse failing.
    {
        ImageInfo probe;
        auto prefix = cast(ubyte[]) read(file, 61);
        assert(prefix.length == 61, "fixture: the file is longer than the bound");
        assert(imageInfo(prefix, probe) && probe.width == 4 && probe.height == 4,
            "fixture: a 61-byte prefix of this BMP still parses as 4x4 — which "
            ~ "is exactly why the LENGTH check has to exist");
    }

    assert(!refreshImageMeta(img, 60),
        "a file larger than the read bound is refused — by the bound, not by "
        ~ "the parse");
    assert(img.missing && img.width == 0 && img.height == 0,
        "and the refusal leaves the unresolved state, not the previous answer");
}
