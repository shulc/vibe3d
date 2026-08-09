module io.image_path;

// ---------------------------------------------------------------------------
// Task 0616 Ph5/Ph6 — the seam between an image item's AUTHORED path and the
// DERIVED metadata the disk answers with, plus (Ph6) the document-relative
// anchor rules that decide what the `.v3d` file actually carries.
//
// Three functions, deliberately separated:
//
//   * `resolveStoredPath` — the STORED form (what a `.v3d` carries) -> the
//     absolute path this process opens. Ph6 gave it the anchor chain; the
//     one-argument overload every Ph5 caller uses is unchanged in meaning
//     (an in-memory path is already absolute, see the storage rule below).
//
//   * `storePathFor` — the inverse: an absolute path -> the form written into
//     a document at `docPath`. `storePathForItem` (task 0635) is the same
//     answer memoised on the item, for the draw path that asks once per row
//     per frame; it is a cache in front of `storePathFor`, never a second rule.
//
//   * `refreshImageMeta` — re-read the header and refresh the four derived
//     fields on `ImageData`. This is the ONLY writer of those fields, and it
//     is what `image.load` / `image.replace` / `image.reload` each call
//     exactly once. Ph6's `.v3d` reader calls it too, after the parse, which
//     is why it lives in `io/` rather than in the command module: the file
//     format must not have to import a command to find out how big an image
//     is.
//
// THE STORAGE RULE (Ph6), and why it is where it is
// -------------------------------------------------
// `ImageData.storedPath` is ABSOLUTE in memory. Relativity exists only at the
// file boundary: `writeV3d` relativises on the way out, `readV3d` resolves on
// the way in, and both already receive the document's own path as an
// argument, so the anchor is a PARAMETER and never global state.
//
// The alternative — keeping the relative form in memory and rebasing every
// image's `storedPath` inside File > Save As — was rejected: it makes a SAVE
// mutate authored document content as a side effect (undo? dirty flag? a
// failed write that already rewrote the paths?), and it makes the meaning of
// `storedPath` depend on a global "current document" that a headless
// `writeV3d(doc, path)` does not have. With the conversion at the boundary,
// Save As to another folder is correct by construction and costs nothing.
//
// The anchor chain, in order (evidence: doc/tasks/0616-evidence/
// clip_panel_shape.md): the document's own directory, then its parent, then
// absolute. The reference has a third anchor, a project root; vibe3d has no
// project concept, so that anchor is declared missing rather than invented.
//
// DOES THE STORAGE RULE MATCH THE DISPLAY RULE? Yes — deliberately, and by
// SHARING `storePathFor` rather than by two rules that agree today. A user
// who reads `../assets/logo.png` in the panel and then greps the `.v3d` must
// find that same string; if the two ever disagreed, every bug report about a
// path would be ambiguous about which of the two was wrong. The panel (Ph4)
// therefore calls `storePathFor(img.storedPath, currentDocPath())` for its
// row text and shows `img.storedPath` itself in the tooltip — which is the
// reference's rule too (relative in the row, absolute in the tooltip).
//
// Header-only, ALWAYS: this calls `imageInfo`, never `imageDecode`. No pixel
// buffer is ever materialised on this path, so no `DecodedImage.free()` is
// ever owed by it — see the lifetime note in `commands/image/commands.d`.
// ---------------------------------------------------------------------------

import std.file : read, exists, getSize;
import std.path : isAbsolute, absolutePath, buildNormalizedPath, dirName,
                  relativePath, isDirSeparator;

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

/// How many bytes of a file a header query actually READS.
///
/// `MAX_IMAGE_FILE_BYTES` above is a REJECTION threshold, not a read size, and
/// conflating the two is what this constant fixes: the first cut of this
/// function read `maxFileBytes + 1` bytes — up to 256 MiB — merely to answer
/// "how big is this image", which broke `imageInfo`'s own promise that no
/// allocation proportional to the image size happens on this path. The `.v3d`
/// reader calls this ONCE PER IMAGE ITEM at load, so a document with a dozen
/// large photographs turned a File > Open into gigabytes of transient reads
/// for data nothing was going to look at.
///
/// 256 KiB rather than the ~64 bytes a bare header needs: a JPEG's SOF marker
/// sits AFTER its application segments, and each of those may be just under
/// 64 KiB (EXIF, XMP, an embedded ICC profile), so a few-hundred-KiB window is
/// what keeps a real-world photograph inside the fast path. A header that
/// still does not fit falls back to a single full-file read (below) — bounded
/// by `maxFileBytes` exactly as before — so the window is a performance
/// decision and can never make a decodable file unreadable.
enum size_t IMAGE_HEADER_WINDOW = 256 * 1024;

/// Separator normalisation for the ON-DISK form. A `.v3d` written on Windows
/// must open on Linux, so the stored form always uses `/`; the resolve side
/// accepts either, because `buildNormalizedPath` does.
private string toPortableSeparators(string p) {
    version (Windows) {
        import std.array : replace;
        return p.replace("\\", "/");
    } else {
        return p;
    }
}

/// True iff `abs` lies inside `dir` (at any depth), and if so `rel` is the
/// path from `dir` to `abs`.
///
/// Implemented on top of `relativePath` and then VALIDATED, rather than by a
/// string prefix compare: a prefix compare says `/a/bc` is under `/a/b`, and
/// on Windows `relativePath` across two drives cannot produce a relative form
/// at all — both cases show up here as "not under", which is the answer that
/// makes the caller fall through to storing an absolute path.
private bool relativeUnder(string abs, string dir, ref string rel) {
    if (dir.length == 0) return false;
    string r;
    try {
        r = relativePath(abs, dir);
    } catch (Exception) {
        return false;
    }
    if (r.length == 0 || isAbsolute(r)) return false;
    if (r == "." || r == "..") return false;
    if (r.length >= 3 && r[0 .. 2] == ".." && isDirSeparator(r[2])) return false;
    rel = r;
    return true;
}

/// Absolutise + normalise, so every comparison below happens between two
/// paths of the same shape.
private string normAbs(string p) {
    if (p.length == 0) return p;
    return buildNormalizedPath(isAbsolute(p) ? p : absolutePath(p));
}

/// The form an image path is STORED in, for a document that lives at
/// `docPath`. The inverse of `resolveStoredPath`.
///
/// Anchors, in order: the document's own directory (`logo.png`,
/// `assets/logo.png`), then its parent (`../logo.png`), then absolute. An
/// UNTITLED document (`docPath` empty) has no anchor at all, so everything
/// stores absolute and re-anchors on its first save — which is exactly what
/// makes Save As correct with no document mutation.
///
/// `absolute` that is not in fact absolute is absolutised against the process
/// CWD first. That case is reachable (`image.load path:relative/x.png` from a
/// script), and silently anchoring a CWD-relative path at the DOCUMENT would
/// be the one wrong answer here: it would name a different file.
string storePathFor(string absolute, string docPath) {
    if (absolute.length == 0) return absolute;
    const abs = normAbs(absolute);
    if (docPath.length == 0) return toPortableSeparators(abs);

    const dir = dirName(normAbs(docPath));
    string rel;
    if (relativeUnder(abs, dir, rel))
        return toPortableSeparators(rel);

    const parent = dirName(dir);
    if (parent != dir && relativeUnder(abs, parent, rel))
        return "../" ~ toPortableSeparators(rel);

    return toPortableSeparators(abs);
}

/// `storePathFor` for an image ITEM, memoised on the item (task 0635).
///
/// Same value as `storePathFor(img.storedPath, docPath)` — this is a cache in
/// front of that function and nothing else; if the two could ever disagree the
/// cache would be a second rule, which is the thing the whole storage/display
/// story exists to avoid.
///
/// WHY IT EXISTS: the clip list calls this once per row per frame while its
/// panel is open, and `storePathFor` allocates (four transient strings, none
/// of which survive the row). Measured over 600 frames on 1 mesh + 20 clips,
/// it was 81% of the row build's 5120 bytes/frame.
///
/// WHY IT IS SAFE: `storePathFor` reads no file — it is `buildNormalizedPath`
/// + `relativePath` over two strings — so its answer is a total function of
/// the pair `(storedPath, docPath)`, which is exactly the pair kept beside the
/// cached value. `resolveStoredPath` below is the opposite case and must never
/// get the same treatment: it calls `exists()`, so its answer changes when a
/// file appears or disappears with nothing in the document changing at all.
///
/// The cache is KEYED rather than cleared by whoever writes `storedPath`; the
/// argument for that, and the three mutation sites a hook would have missed,
/// are on `RowTextMemo` in `document.d`.
///
/// (One input is implicit and shared with the uncached function: a
/// `storedPath` that is not absolute is absolutised against the process CWD.
/// `storedPath` is absolute in memory by the storage rule at the top of this
/// module, and the CWD does not move between two frames of one panel, so the
/// key is complete for every reachable state.)
///
/// IT WRITES, and the guard says which thread may. See `imageRowsInto`.
string storePathForItem(ImageData img, string docPath) {
    if (img is null) return "";
    if (img.rowText.storeValid
        && img.rowText.storeSource == img.storedPath
        && img.rowText.storeAnchor == docPath)
        return img.rowText.storeText;

    import gl_thread_guard : glThreadGuard;
    glThreadGuard("imageRowText");

    const text = storePathFor(img.storedPath, docPath);
    img.rowText.storeText   = text;
    img.rowText.storeSource = img.storedPath;
    img.rowText.storeAnchor = docPath;
    img.rowText.storeValid  = true;
    return text;
}

/// The stored path resolved to a path this process can open, anchored at the
/// document that carried it.
///
/// An ABSOLUTE stored form answers itself (normalised). A RELATIVE one is
/// tried against the document's directory and then its parent, FIRST EXISTING
/// HIT WINS — and when neither exists the document's own directory is still
/// the answer. That last clause is the §Q4 rule in one line: a file that is
/// not there must still yield a definite path, so the item can keep saying
/// what it points at (and re-save the same bytes) instead of degrading to
/// "nothing". `missing` is what reports the failure; an empty path would
/// destroy the statement the document made.
///
/// The one-argument overload is what every Ph5 caller uses and keeps its Ph5
/// meaning: an in-memory `storedPath` is already absolute (see the storage
/// rule at the top of this module), so with no anchor there is nothing to
/// resolve.
string resolveStoredPath(string stored, string docPath = null) {
    if (stored.length == 0) return stored;
    if (isAbsolute(stored)) return buildNormalizedPath(stored);
    if (docPath.length == 0) return stored;      // no anchor: CWD-relative, as Ph5

    const dir = dirName(normAbs(docPath));
    const here = buildNormalizedPath(dir, stored);
    if (exists(here)) return here;

    const parent = dirName(dir);
    if (parent != dir) {
        const above = buildNormalizedPath(parent, stored);
        if (exists(above)) return above;
    }
    return here;   // best effort: definite, and `missing` will say it is gone
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

    // The oversize REJECTION is made against the file's REAL size, not against
    // however much of it we chose to read — otherwise the bound would silently
    // become `min(bound, window)` and a file over the bound would be accepted
    // whenever the bound sits above the window.
    ulong size;
    try {
        size = getSize(path);
    } catch (Exception e) {
        logWarn("io", "image: cannot stat '" ~ path ~ "': " ~ e.msg);
        return false;
    }
    if (size > maxFileBytes) {
        import std.conv : to;
        logWarn("io", "image: rejected '" ~ path ~ "': " ~ size.to!string
            ~ " bytes, larger than the " ~ maxFileBytes.to!string
            ~ "-byte bound");
        return false;
    }

    // Read only the header WINDOW. `size` is already bounded, so both reads
    // below are bounded; the second one runs only for the rare file whose
    // header genuinely does not fit the window.
    immutable size_t want =
        size < IMAGE_HEADER_WINDOW ? cast(size_t) size : IMAGE_HEADER_WINDOW;
    ubyte[] bytes;
    try {
        bytes = cast(ubyte[]) read(path, want);
    } catch (Exception e) {
        logWarn("io", "image: cannot read '" ~ path ~ "': " ~ e.msg);
        return false;
    }

    ImageInfo info;
    if (!imageInfo(bytes, info)) {
        // Only a TRUNCATED read can be the reason here; a file that fitted the
        // window has already given its final answer. Retry once against the
        // whole (already size-checked) file so the window can never turn a
        // decodable image into a missing one.
        if (size <= want) return false;   // imageInfo already logged the reason
        try {
            bytes = cast(ubyte[]) read(path, cast(size_t) size);
        } catch (Exception e) {
            logWarn("io", "image: cannot read '" ~ path ~ "': " ~ e.msg);
            return false;
        }
        if (!imageInfo(bytes, info)) return false;
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
    import std.file : write, remove, tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import std.conv : to;

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
    /// Test-only view of the private `relativeUnder` predicate, so a fixture
    /// can PROVE its placement is outside an anchor instead of assuming it.
    bool relativeUnderProbe(string abs, string dir) {
        string rel;
        return relativeUnder(abs, dir, rel);
    }

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

// ---------------------------------------------------------------------------
// Task 0616 Ph6 — the header WINDOW. Two properties, and neither one alone
// says anything useful about the other.
//
// (a) A file LARGER than the window still parses. The `.v3d` reader calls this
//     once per image item, so the window exists to stop a File > Open reading
//     hundreds of megabytes it will not look at — but a window that quietly
//     turned every large photograph into a missing file would be a far worse
//     bug than the read it saves.
//
// (b) The oversize rejection fires on the file's REAL size, not on the number
//     of bytes the window happened to read. The discriminating bound is one
//     that sits BETWEEN the window and the file size: at 265000 against a
//     270054-byte file with a 262144-byte window, the correct implementation
//     refuses (270054 > 265000) and one that tests only what it read accepts
//     (262144 <= 265000) and reports real dimensions. A bound below the window
//     — the case the test above uses — reads the same either way, which is why
//     that test cannot cover this and this one exists.
// ---------------------------------------------------------------------------
unittest {
    auto dir  = imageTestDir("refresh_window");
    auto file = buildPath(dir, "big.bmp");
    writeTestBmp(file, 300, 300);          // 54 + 300*900 == 270054 bytes
    scope (exit) { if (exists(file)) remove(file); }

    immutable ulong sz = getSize(file);
    assert(sz > IMAGE_HEADER_WINDOW,
        "fixture: the file must be LARGER than the header window or neither "
        ~ "half of this test means anything — got " ~ sz.to!string
        ~ " against a window of " ~ IMAGE_HEADER_WINDOW.to!string);

    auto img = new ImageData();
    img.storedPath = file;
    assert(refreshImageMeta(img),
        "(a) a file larger than the header window still parses from its "
        ~ "prefix");
    assert(img.width == 300 && img.height == 300 && !img.missing,
        "…with its real dimensions, got "
        ~ img.width.to!string ~ "x" ~ img.height.to!string);

    // (b) a bound strictly between the window and the file size.
    immutable size_t between = 265_000;
    assert(between > IMAGE_HEADER_WINDOW && between < sz,
        "fixture: the bound must sit BETWEEN the window and the file size, "
        ~ "else it cannot separate the two implementations");
    assert(!refreshImageMeta(img, between),
        "(b) the oversize bound is measured against the FILE, not against the "
        ~ "window — a bound above the window must still refuse a file above "
        ~ "the bound");
    assert(img.missing && img.width == 0,
        "and that refusal leaves the unresolved state");
}

// ---------------------------------------------------------------------------
// Task 0616 Ph6 — the STORAGE rule.
//
// FOUR placements, FOUR DIFFERENT strings. The count is the test: a
// one-placement fixture cannot tell "always relative" from the real rule, and
// a two-placement one cannot tell "parent only" from "parent AND anything
// above it". The fourth (an untitled document) is the anchor-less case that a
// three-placement fixture would leave to a comment.
//
// The four expected strings are also asserted PAIRWISE DISTINCT, so a rule
// that collapsed two anchors onto one answer cannot pass by agreeing with
// itself.
// ---------------------------------------------------------------------------
unittest {
    auto root = imageTestDir("store_rule");
    auto docDir  = buildPath(root, "a", "b");
    auto doc     = buildPath(docDir, "scene.v3d");

    const beside = buildPath(docDir, "x.png");             // beside the document
    const nested = buildPath(docDir, "tex", "n.png");      // BELOW the document
    const above1 = buildPath(root, "a", "y.png");          // in the doc's parent
    const above2 = buildPath(root, "z.png");               // two directories up

    assert(storePathFor(beside, doc) == "x.png",
        "a file beside the document stores as a bare name, got "
        ~ storePathFor(beside, doc));
    assert(storePathFor(nested, doc) == "tex/n.png",
        "a file BELOW the document stores relative at depth (not just at "
        ~ "depth 1), got " ~ storePathFor(nested, doc));
    assert(storePathFor(above1, doc) == "../y.png",
        "a file in the document's PARENT stores with one `..`, got "
        ~ storePathFor(above1, doc));
    assert(storePathFor(above2, doc) == buildNormalizedPath(above2),
        "two directories up is past the last anchor and stores ABSOLUTE — "
        ~ "this is the placement that separates the real rule from "
        ~ "\"relativise against anything\", got " ~ storePathFor(above2, doc));
    assert(storePathFor(beside, "") == buildNormalizedPath(beside),
        "an UNTITLED document has no anchor at all, so even a file that "
        ~ "would otherwise be relative stores absolute, got "
        ~ storePathFor(beside, ""));

    // The four answers must be pairwise different, else the assertions above
    // could all hold under a rule that answers the same thing everywhere.
    string[5] got = [storePathFor(beside, doc), storePathFor(nested, doc),
                     storePathFor(above1, doc), storePathFor(above2, doc),
                     storePathFor(beside, "")];
    foreach (i; 0 .. 5)
        foreach (j; i + 1 .. 5)
            assert(got[i] != got[j],
                "fixture: placements " ~ i.to!string ~ "/" ~ j.to!string
                ~ " produce the same stored string, so this table cannot "
                ~ "discriminate between the rules it exists to separate");
}

// ---------------------------------------------------------------------------
// Task 0616 Ph6 — the RESOLVE rule, and specifically the anchor ORDER.
//
// The fixture puts a file with the SAME NAME beside the document AND in its
// parent. The document's own directory must win: an implementation that
// searched the parent first (or that searched only the parent) resolves to the
// other file, and the two files are distinguishable by their DIMENSIONS
// (3x2 vs 5x7), so the wrong answer is a different number and not merely a
// different string.
// ---------------------------------------------------------------------------
unittest {
    auto root   = imageTestDir("resolve_order");
    auto docDir = buildPath(root, "proj");
    auto doc    = buildPath(docDir, "scene.v3d");
    writeTestBmp(buildPath(docDir, "same.bmp"), 3, 2);   // beside the document
    writeTestBmp(buildPath(root,   "same.bmp"), 5, 7);   // in its parent

    auto img = new ImageData();
    img.storedPath = resolveStoredPath("same.bmp", doc);
    assert(refreshImageMeta(img), "the resolved path must be readable");
    assert(img.width == 3 && img.height == 2,
        "the document's OWN directory is the first anchor — resolving to the "
        ~ "parent's copy would read 5x7, got "
        ~ img.width.to!string ~ "x" ~ img.height.to!string);

    // Remove the near one: the SAME stored string must now find the parent's
    // copy. Without this half, "first hit wins" is indistinguishable from
    // "only ever look beside the document".
    remove(buildPath(docDir, "same.bmp"));
    auto img2 = new ImageData();
    img2.storedPath = resolveStoredPath("same.bmp", doc);
    assert(refreshImageMeta(img2), "the parent anchor must still resolve");
    assert(img2.width == 5 && img2.height == 7,
        "with the near copy gone the parent anchor answers, got "
        ~ img2.width.to!string ~ "x" ~ img2.height.to!string);
}

// ---------------------------------------------------------------------------
// Task 0616 Ph6 — THE DOCUMENT MOVES. This is the whole reason a stored path
// is relative, so it is tested by actually MOVING the files, not by munging
// strings.
//
// A/scene.v3d referencing A/img.bmp stores "img.bmp". Copy BOTH to B/ and
// resolve the same stored string against B/scene.v3d: it must land on
// B/img.bmp.
//
// Discriminating in the way the task names: A/img.bmp still EXISTS, so an
// implementation that had stored the absolute path resolves to a file that is
// really there and every "resolves to something" assertion passes. The
// assertion is therefore on the DIRECTORY, and the two copies additionally
// carry different dimensions (3x2 vs 9x4) so the wrong answer reads a
// different number too.
// ---------------------------------------------------------------------------
unittest {
    auto root = imageTestDir("doc_moved");
    auto dirA = buildPath(root, "A");
    auto dirB = buildPath(root, "B");
    auto docA = buildPath(dirA, "scene.v3d");
    auto docB = buildPath(dirB, "scene.v3d");
    writeTestBmp(buildPath(dirA, "img.bmp"), 3, 2);
    writeTestBmp(buildPath(dirB, "img.bmp"), 9, 4);

    const stored = storePathFor(buildPath(dirA, "img.bmp"), docA);
    assert(stored == "img.bmp",
        "precondition: the document stored the RELATIVE form — with an "
        ~ "absolute stored form this test would prove nothing, got " ~ stored);

    const resolvedInB = resolveStoredPath(stored, docB);
    assert(dirName(resolvedInB) == buildNormalizedPath(dirB),
        "the moved document must find the image BESIDE ITSELF, not the copy "
        ~ "left behind in A (which still exists), got " ~ resolvedInB);

    auto img = new ImageData();
    img.storedPath = resolvedInB;
    assert(refreshImageMeta(img));
    assert(img.width == 9 && img.height == 4,
        "and it is B's copy by its CONTENT too, not only by its path text — "
        ~ "got " ~ img.width.to!string ~ "x" ~ img.height.to!string);
}

// ---------------------------------------------------------------------------
// Task 0616 Ph6 — a stored path whose file is GONE still resolves to a
// definite absolute path, and that path re-stores to the SAME string.
//
// The round-trip property is what keeps a missing file from decaying: a
// resolve that answered "" would make the next save write "" and the document
// would have silently forgotten what it pointed at. Checked for all three
// anchor shapes, because each takes a different branch.
// ---------------------------------------------------------------------------
unittest {
    auto root   = imageTestDir("missing_stable");
    auto docDir = buildPath(root, "proj");
    mkdirRecurse(docDir);
    auto doc    = buildPath(docDir, "scene.v3d");

    // The third entry must sit OUTSIDE both anchors, or it is not the
    // absolute case at all: a path under `root` (the document's parent) would
    // legitimately re-store as `../…` and the assertion would be testing the
    // parent branch twice. That mistake was made here first and caught by the
    // re-store assertion below, which is the reason it is written this way.
    const outsideBothAnchors =
        buildNormalizedPath(tempDir(), "vibe3d_img_missing_stable_elsewhere", "gone.bmp");
    assert(!relativeUnderProbe(outsideBothAnchors, root),
        "fixture: the absolute case must not be reachable from either anchor");

    foreach (stored; ["gone.bmp", "../gone.bmp", outsideBothAnchors]) {
        const abs = resolveStoredPath(stored, doc);
        assert(abs.length > 0 && isAbsolute(abs),
            "a missing file still resolves to a DEFINITE absolute path (the "
            ~ "item keeps its statement), got '" ~ abs ~ "' for " ~ stored);
        assert(!exists(abs), "fixture: the file really is absent");

        auto img = new ImageData();
        img.storedPath = abs;
        assert(!refreshImageMeta(img), "and the refresh reports the failure");
        assert(img.missing && img.storedPath == abs,
            "…without erasing the path");

        assert(storePathFor(abs, doc) == stored,
            "re-storing a missing file must reproduce the SAME string — else "
            ~ "every save of a document with an unavailable asset would "
            ~ "rewrite the path. Expected '" ~ stored ~ "', got '"
            ~ storePathFor(abs, doc) ~ "'");
    }
}
