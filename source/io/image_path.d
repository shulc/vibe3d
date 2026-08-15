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
//     a document at `docPath`. The draw path that asks once per row per frame
//     does not call this directly: `ui/image_rows.d` (its only caller) keeps
//     a memoised wrapper of its own (task 0635, moved off `io/` and off
//     `ImageData` by task 0771) — a cache in front of this function, never a
//     second rule.
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

// `storePathForItem` — `storePathFor` memoised per image ITEM — used to live
// here (task 0635). Task 0771 moved the whole cache to `ui/image_rows.d`: its
// only caller was that module's `imageRowsInto`, so the memo gained nothing
// by living a layer below its one reader, and the move let the cache come off
// `ImageData` (document payload) entirely rather than merely off `document.d`
// (see that struct's doc comment there for why leaving it a FIELD of the
// document at all was still the wrong home). `storePathFor` below is the pure
// function the memo wraps; import it directly for an uncached read.

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
