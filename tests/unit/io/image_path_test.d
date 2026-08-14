// Module unittests for `io.image_path`, moved verbatim out of source/io/image_path.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.io.image_path_test;

import std.file : read, exists, getSize;
import std.path : isAbsolute, absolutePath, buildNormalizedPath, dirName,
                  relativePath, isDirSeparator;
import document       : ImageData;
import io.image_decode : ImageInfo, imageInfo, MAX_IMAGE_BYTES;
import log            : logWarn;
import std.file : write, remove, tempDir, mkdirRecurse, rmdirRecurse;
import std.path : buildPath;
import std.conv : to;
import std.path : dirName;
import io.image_path;

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
