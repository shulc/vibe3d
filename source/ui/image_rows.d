module ui.image_rows;

// ---------------------------------------------------------------------------
// Task 0616 Ph4 — the Images panel's ROW MODEL.
//
// WHY THIS MODULE EXISTS AT ALL, rather than the strings being built inline in
// `drawImageListPanel`: an ImGui panel body is not observable headlessly. An
// assertion written against the draw call can only ever say "the function ran",
// which is the inert-assertion shape this task has been caught by repeatedly.
// So the panel is split in two:
//
//   * this module answers "WHAT would the panel draw" — pure, allocation-only,
//     no ImGui, no globals (the document path is a PARAMETER, not a call to
//     `currentDocPath()`), and therefore fully assertable by in-module tests;
//   * `ui/panels.d`'s `drawImageListPanel` answers "where on screen", which is
//     the part no test here claims to cover.
//
// Everything the reference's measured list shows, and nothing it does not:
// see `doc/tasks/0616-evidence/clip_panel_shape.md` for the measurement and
// for the four presentations / marker column / visibility column that are
// deliberately NOT taken.
//
// WHAT THE MEASURED SHAPE ASKS FOR, and where each piece lives here:
//
//   * a TWO-LINE name cell — display name on line 1, the file path on line 2,
//     dimmer, elided from the RIGHT (the head is what survives). `ImageRow`
//     carries `name` and `pathText`; `elideEnd` is the truncation rule.
//   * PIXEL DIMENSIONS as their own column — `dimensionsText`.
//   * the PIXEL FORMAT as its own column — `pixelFormatText`. Note this is the
//     channel layout, NOT the file extension: the reference has no extension
//     column anywhere, and an earlier revision of our plan had that wrong.
//   * NO sorting and NO filter box. Rows come out in `document.layers` order,
//     which is creation order, and there is no comparator and no query string
//     in this module at all. Those are settled ABSENCES in the measurement,
//     not things nobody got to.
//   * per-item editable properties are NOT here. `colorspace` / `useAlpha`
//     are `Param`s on the item, edited in the shared item-properties form
//     (`layer_params.d`'s provider, bound through `itemPropsTarget`). The list
//     and the properties must not overlap, so this model exposes no setter and
//     the panel dispatches no `layer.attr`.
//
// NO THUMBNAIL FIELD. Nothing in the codebase decodes pixels yet (through Ph6
// only image HEADERS are ever read), and a thumbnail needs a decode plus a GPU
// texture with a release path through the four whole-document replacements the
// plan's R13 enumerates. A model field that could never be filled would be a
// promise this phase cannot keep; the slot is Stage 12's, deliberately last.
//
// COST. `imageRowsInto` fills the caller's buffer in place (the
// `Document.referrersOf` / `selectedItemsInto` idiom) so a panel holding one
// static buffer does not churn an array per frame; the two formatted strings
// per row are the only per-row allocation, bounded by the number of image
// items. What is deliberately NOT on this path is `Document.referrersOf` —
// its own doc comment forbids a draw-path call — so "is this image in use" is
// asked once, at CLICK time, through `imageRemoveConfirmText`.
// ---------------------------------------------------------------------------

import document        : Document, Layer, ImageData;
import io.image_path   : storePathFor;

/// The empty-state line. The measured list has its own empty text rather than
/// an empty rectangle; it has a second one pointing at a separate browsing
/// surface, which we have no equivalent of, so there is one string here.
enum string kNoImagesText = "(no images)";

/// What an unnamed row shows. Same literal the Layers panel uses, on purpose:
/// two lists of the same `document.layers` must not disagree about what an
/// item with no name is called.
enum string kUnnamedText = "(unnamed)";

/// One drawn row: exactly the fields the panel puts on screen, already in
/// display form. Display form rather than raw values is what makes a test
/// discriminating — a wrong implementation reads a DIFFERENT STRING here,
/// where a model of raw ints would have let the formatting bug live in the
/// untested half.
struct ImageRow {
    /// Index into `document.layers` — NOT the row's ordinal. Every command
    /// the panel dispatches (`layer.select`, `layer.rename`, `image.remove`,
    /// `image.reload`) is addressed by document index, and the image items
    /// are interleaved with meshes, so an implementation that passed the
    /// ordinal would target a different layer for every row after the first
    /// non-image one.
    size_t index;
    /// The item itself. Identity is the only reliable handle (Ph3): an index
    /// is spliced by `layer.delete` and permuted by `layer.reorder`.
    Layer  layer;

    string name;         ///< line 1 of the name cell
    string pathText;     ///< line 2 — the STORED form, i.e. what a `.v3d`
                          ///< written next to this document would carry
    string pathTooltip;  ///< the absolute path, shown on hover

    string dimensions;   ///< "3 x 2"; empty while `missing`
    string pixelFormat;  ///< channel layout ("RGB"); empty while `missing`

    bool missing;        ///< the file did not read on the last observation
    bool selected;       ///< in the item-selection set (multi-select)
    bool focused;        ///< the item-selection FOCUS (at most one row)
}

/// True for the rows this list owns. `hasImage` is the CAPABILITY (never
/// `kind == ItemKind.Image` at a call site — that is `kItemKindTable`'s stated
/// contract), and it is the exact complement of the `isSceneItem` gate the
/// Layers panel skips on, so no item can fall between the two lists.
///
/// A payload-null image item IS listed (with an empty path and no dimensions)
/// rather than skipped. Skipping would make it appear in NO panel at all —
/// invisible, unselectable, undeletable — which is a worse answer than a row
/// that says it has no file. The state is only reachable through the
/// still-open test-injection hole the plan gives to Stage 10.
private bool isImageRow(const(Layer) l) {
    return l !is null && l.hasImage;
}

/// The pixel FORMAT cell: the channel layout of the source file.
///
/// DIVERGENCE, stated rather than papered over. The reference's vocabulary for
/// this column pairs a layout with a BIT DEPTH ("RGB 24", "RGBA 32", and float
/// variants). We hold `ImageData.channels` and nothing else — the header query
/// (`io/image_path.d`'s `refreshImageMeta` → `imageInfo`) measures the channel
/// count and never the depth. Printing "RGBA 32" would therefore be asserting
/// 8 bits per channel for a file nothing measured the depth of, which is a
/// fabricated number in a column whose entire purpose is to report what is
/// actually in the file. So this cell reports the half we measured.
///
/// It is emphatically NOT the file extension. There is no extension column
/// anywhere in the measured list, and an earlier revision of our plan had this
/// wrong; the note is here so it cannot be reintroduced by someone reading
/// only the code.
string pixelFormatText(int channels) {
    switch (channels) {
        case 1:  return "Grey";
        case 2:  return "Grey+A";
        case 3:  return "RGB";
        case 4:  return "RGBA";
        default: return "";
    }
}

/// The pixel-dimensions cell, `"<w> x <h>"`.
///
/// A `missing` item reports an EMPTY cell, not "0 x 0". Zero is a measurement;
/// the honest statement about a file that did not read is that there is no
/// measurement — the same reason `refreshImageMeta` clears the derived fields
/// instead of leaving them stale next to `missing == true`.
string dimensionsText(int width, int height, bool missing) {
    if (missing) return "";
    import std.conv : to;
    return to!string(width) ~ " x " ~ to!string(height);
}

/// Truncate `s` to at most `maxChars` CODE POINTS, keeping the HEAD and
/// marking the cut with a trailing ellipsis.
///
/// The direction is the measured one: the path under the name is elided from
/// the right, so the beginning survives. That is the useful half of a path in
/// a narrow column — `../assets/textures/` tells you where the file lives,
/// while the tail is very often the same `.png` on every row.
///
/// Code points, not bytes: a path may hold non-ASCII, and cutting a UTF-8
/// sequence in half produces a string ImGui cannot draw.
string elideEnd(string s, size_t maxChars) {
    import std.array : appender;

    if (maxChars == 0) return "";
    size_t n = 0;
    foreach (dchar c; s) { ++n; if (n > maxChars) break; }
    if (n <= maxChars) return s;          // fits whole — no ellipsis

    // One code point of the budget goes to the ellipsis itself.
    auto app = appender!string();
    size_t kept = 0;
    immutable size_t keep = maxChars - 1;
    foreach (dchar c; s) {
        if (kept == keep) break;
        app.put(c);
        ++kept;
    }
    app.put('…');
    return app.data;
}

/// Fill `outBuf` with one `ImageRow` per image item, in `document.layers`
/// order — creation order, because the measured list has no sort and no
/// reorder command, and because that is the order every other view of
/// `layers` already uses.
///
/// `docPath` is the anchor the row's path text is relativised against, and it
/// is a PARAMETER rather than a `currentDocPath()` call so this function is
/// pure with respect to global state and a test can move the document without
/// moving the process. The panel passes `currentDocPath()`.
///
/// The row text is `storePathFor(storedPath, docPath)` — the SAME function
/// `writeV3d` stores with, not a second rule that happens to agree. A user who
/// reads `../assets/logo.png` in this panel must find that exact string in the
/// `.v3d`; two rules that agree today would make every path bug ambiguous
/// about which of them was wrong. The tooltip is `storedPath` itself, which is
/// absolute in memory — relative in the row, absolute on hover, as measured.
void imageRowsInto(Document* doc, string docPath, ref ImageRow[] outBuf) {
    size_t n = 0;
    if (doc !is null)
        foreach (l; doc.layers) if (isImageRow(l)) ++n;
    if (outBuf.length != n) outBuf.length = n;
    if (n == 0) return;

    size_t k = 0;
    foreach (i, l; doc.layers) {
        if (!isImageRow(l)) continue;
        auto img = l.imageOrNull();
        ImageRow r;
        r.index       = i;
        r.layer       = l;
        r.name        = l.name.length ? l.name : kUnnamedText;
        r.selected    = l.selected;
        r.focused     = doc.focusedItem is l;
        if (img is null) {
            // Payload-null image item — see `isImageRow`. Everything derived
            // from the payload stays empty; `missing` is the honest answer.
            r.missing = true;
        } else {
            r.pathTooltip = img.storedPath;
            r.pathText    = storePathFor(img.storedPath, docPath);
            r.dimensions  = dimensionsText(img.width, img.height, img.missing);
            r.pixelFormat = pixelFormatText(img.missing ? 0 : img.channels);
            r.missing     = img.missing;
        }
        outBuf[k++] = r;
    }
}

/// The Remove button's target + enabled state, in the shape of
/// `layerDeleteButtonState` (`commands/layer/commands.d`) and for the same
/// reason: the button's greying and the command's own refusal must be two
/// readings of ONE function, never two copies of one rule. Two copies is
/// exactly how the Layers panel's delete bug happened (the button asked about
/// the primary while the click dispatched against the focus).
///
/// The target is `doc.focusedItem` — the row this panel highlights — and it
/// is enabled only when that focus is an image item the document will part
/// with. `image.remove` refuses a non-image target itself; this makes the
/// affordance say so first.
///
/// `referrersOf` is deliberately NOT consulted here: this runs every frame,
/// and its doc comment forbids a draw-path call. "Is it in use" is asked at
/// click time, by `imageRemoveConfirmText`.
struct ImageRemoveTarget {
    size_t index;   ///< index into `layers`; meaningless when `!enabled`
    Layer  layer;   ///< the target item, or null
    bool   enabled;
}

ImageRemoveTarget imageRemoveTarget(Document* doc) {
    import commands.layer.commands : canDeleteLayer;
    ImageRemoveTarget t;
    if (doc is null) return t;
    auto target = doc.focusedItem;
    if (!isImageRow(target)) return t;
    t.index   = doc.indexOf(target);
    t.layer   = target;
    t.enabled = t.index < doc.layers.length && canDeleteLayer(doc, target);
    return t;
}

/// The confirm text shown before removing an image that something still
/// references, or `""` when nothing does (in which case the panel removes
/// straight away, with nothing to warn about).
///
/// Built on `imageRemoveWarning` — the SAME predicate `image.remove` logs
/// from — so the sentence the user is asked to confirm and the condition the
/// command acted on cannot drift apart. This is a click-time call: the reverse
/// sweep it performs is O(items × slots) and belongs nowhere near a draw.
string imageRemoveConfirmText(Document* doc, Layer target) {
    import commands.image.commands : imageRemoveWarning;
    import std.conv : to;
    if (doc is null || target is null) return "";
    auto w = imageRemoveWarning(doc, target);
    if (!w.inUse) return "";

    string names;
    foreach (i, r; w.referrers) {
        if (i) names ~= ", ";
        names ~= r.name.length ? r.name : kUnnamedText;
    }
    immutable label = target.name.length ? target.name : kUnnamedText;
    return "\"" ~ label ~ "\" is still used by "
         ~ to!string(w.referrers.length) ~ " item(s): " ~ names;
}

// ===========================================================================
// Tests
//
// The fixture is SEVEN items and THREE images, and the assertions read row
// identity and per-row values rather than counts:
//
//   [0] meshA   (primary, and the baseline focus)
//   [1] alpha   3x2    beside the document      -> "alpha.bmp"
//   [2] meshB
//   [3] bravo   5x7    one directory down       -> "tex/bravo.bmp"
//   [4] charlie 11x13  one directory UP         -> "../charlie.bmp"
//   [5] consumerX --link--> bravo
//   [6] consumerY --link--> bravo
//
// Three shapes are doing work here and none of them is decoration:
//   * the images sit at layer indices 1/3/4 while their ROW ordinals are
//     0/1/2, so an implementation that reports the ordinal reads a different
//     number for every row;
//   * every image has a different size and a different path ANCHOR, so
//     "rendered the right row" is distinguishable from "rendered a row";
//   * two consumers point at the MIDDLE image, so an implementation that
//     stops at the first referrer, or that sweeps the whole document, reads a
//     different count and different names.
// ===========================================================================

version (unittest) {
    import std.file : exists, remove;
    import std.path : buildPath;
    import std.json : parseJSON;

    import document                : ItemKind, Document, Layer;
    import io.image_path           : writeTestBmp, imageTestDir,
                                     refreshImageMeta;
    import commands.image.commands : ImageLoad;
    import commands.layer.commands : LayerAdd;
    import params                  : injectParamsInto;
    import mesh                    : makeCube;
    import view                    : View;
    import editmode                : EditMode;
    import seltype                 : SelMode;

    struct RowFixture {
        Document doc;
        View     view;
        Layer    meshA, meshB, alpha, bravo, charlie, consumerX, consumerY;
        string   dir, docPath, pathA, pathB, pathC;
    }

    RowFixture makeRowFixture(string tag) {
        RowFixture f;
        f.doc  = Document.bootstrap(makeCube());
        f.view = new View(0, 0, 800, 600);
        f.meshA = f.doc.layers[0];
        f.meshA.name = "meshA";

        // Scratch layout: the document lives in `<dir>/scene/`, so `<dir>`
        // itself is its PARENT — which is what makes the third image store as
        // "../charlie.bmp" and exercise the second anchor rather than only the
        // first. Nothing is written outside the scratch directory.
        f.dir     = imageTestDir(tag);
        f.docPath = buildPath(f.dir, "scene", "scene.v3d");
        f.pathA   = buildPath(f.dir, "scene", "alpha.bmp");
        f.pathB   = buildPath(f.dir, "scene", "tex", "bravo.bmp");
        f.pathC   = buildPath(f.dir, "charlie.bmp");
        writeTestBmp(f.pathA, 3, 2);
        writeTestBmp(f.pathB, 5, 7);
        writeTestBmp(f.pathC, 11, 13);

        f.alpha = loadInto(f, f.pathA);          // layers[1]
        f.meshB = addMesh(f, "meshB");           // layers[2]
        f.bravo = loadInto(f, f.pathB);          // layers[3]
        f.charlie = loadInto(f, f.pathC);        // layers[4]

        f.consumerX = new Layer;
        f.consumerX.name = "consumerX";
        f.consumerX.kind = ItemKind.Empty;
        f.consumerY = new Layer;
        f.consumerY.name = "consumerY";
        f.consumerY.kind = ItemKind.Empty;
        f.doc.layers ~= f.consumerX;             // layers[5]
        f.doc.layers ~= f.consumerY;             // layers[6]
        f.consumerX.setLink("backdropImage", f.bravo);
        f.consumerY.setLink("backdropImage", f.bravo);

        // `layer.add` moved primary + focus to meshB; put them back so every
        // test starts from a stated baseline (focus on a MESH — i.e. the
        // Remove affordance disabled) instead of inheriting whatever the last
        // fixture step happened to leave.
        f.doc.selectItem(f.meshA, SelMode.Set);
        return f;
    }

    /// Load through the real command, addressed exactly as `/api/command`
    /// addresses it (`injectParamsInto` over the declared `Param` set), so
    /// the fixture cannot drift from what a user's load actually produces —
    /// and so a renamed `path` parameter breaks the fixture instead of
    /// silently loading nothing (task 0633: an unknown attr is accepted).
    Layer loadInto(ref RowFixture f, string path) {
        auto c = new ImageLoad(f.doc.activeMesh(), f.view, EditMode.Vertices,
                               &f.doc, null);
        auto ps = c.params();
        auto pj = parseJSON(`{"path":` ~ jsonString(path) ~ `}`);
        injectParamsInto(ps, pj);
        assert(c.apply(), "fixture: image.load must succeed on " ~ path);
        return c.created();
    }

    Layer addMesh(ref RowFixture f, string name) {
        auto c = new LayerAdd(f.doc.activeMesh(), f.view, EditMode.Vertices,
                              &f.doc, null);
        auto ps = c.params();
        auto pj = parseJSON(`{"name":` ~ jsonString(name) ~ `}`);
        injectParamsInto(ps, pj);
        assert(c.apply(), "fixture: layer.add must succeed");
        return f.doc.layers[$ - 1];
    }

    string jsonString(string s) {
        import std.json : JSONValue;
        return JSONValue(s).toString();
    }
}

// ---------------------------------------------------------------------------
// R1 — the rows ARE the image items, in document order, carrying the DOCUMENT
// index.
//
// Discriminating three ways at once: the count (an unfiltered implementation
// reads 7), the identity per row (`is`, so "some image" cannot pass), and the
// index (ordinals would read 0/1/2 where the layers are 1/3/4).
// ---------------------------------------------------------------------------
unittest {
    auto f = makeRowFixture("rows_identity");
    assert(f.doc.layers.length == 7, "fixture: 2 meshes + 3 images + 2 consumers");

    ImageRow[] rows;
    imageRowsInto(&f.doc, f.docPath, rows);

    {
        import std.conv : to;
        assert(rows.length == 3,
            "only the image items are rows — meshes and consumers are not; got "
            ~ to!string(rows.length));
    }
    assert(rows[0].layer is f.alpha,   "row 0 is alpha");
    assert(rows[1].layer is f.bravo,   "row 1 is bravo");
    assert(rows[2].layer is f.charlie, "row 2 is charlie");

    import std.conv : to;
    assert(rows[0].index == 1, "row 0 carries the LAYER index (1), not its "
        ~ "ordinal (0); got " ~ to!string(rows[0].index));
    assert(rows[1].index == 3, "row 1 carries the LAYER index (3), not its "
        ~ "ordinal (1); got " ~ to!string(rows[1].index));
    assert(rows[2].index == 4, "row 2 carries the LAYER index (4), not its "
        ~ "ordinal (2); got " ~ to!string(rows[2].index));

    // Vacuity guard: the index axis only discriminates because the images are
    // NOT contiguous from zero. Pin that the fixture really is interleaved.
    assert(f.doc.layers[2] is f.meshB,
        "fixture precondition: a mesh sits BETWEEN two image rows, or the "
        ~ "ordinal and the layer index would coincide and the check above "
        ~ "would be inert");
}

// ---------------------------------------------------------------------------
// R2 — the name cell's two lines and the two path forms.
//
// Discriminating: three DIFFERENT stored forms, one per anchor (beside the
// document, below it, above it), so an implementation that emitted the base
// name, or the absolute path, or the tooltip and the row text swapped, reads a
// different string on at least two rows.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeRowFixture("rows_paths");
    ImageRow[] rows;
    imageRowsInto(&f.doc, f.docPath, rows);

    assert(rows[0].name == "alpha",   "line 1 is the display name");
    assert(rows[1].name == "bravo",   "line 1 is the display name");
    assert(rows[2].name == "charlie", "line 1 is the display name");

    assert(rows[0].pathText == "alpha.bmp",
        "beside the document -> bare name, got '" ~ rows[0].pathText ~ "'");
    assert(rows[1].pathText == "tex/bravo.bmp",
        "below the document -> a nested relative path (NOT the base name), "
        ~ "got '" ~ rows[1].pathText ~ "'");
    assert(rows[2].pathText == "../charlie.bmp",
        "above the document -> the parent anchor, got '"
        ~ rows[2].pathText ~ "'");

    // The tooltip is the ABSOLUTE path, and it is a different string from the
    // row text on every row — so a swap is visible, not merely possible.
    import std.path : isAbsolute;
    foreach (i, r; rows) {
        assert(isAbsolute(r.pathTooltip),
            "the tooltip is absolute on every row");
        assert(r.pathTooltip != r.pathText,
            "row text and tooltip must be the relative and absolute forms, "
            ~ "not one string used twice");
    }
    assert(rows[1].pathTooltip == f.bravo.imageOrNull().storedPath,
        "the tooltip is `storedPath` itself");
}

// ---------------------------------------------------------------------------
// R3 — the row's path text is `storePathFor`, not a second rule that agrees.
//
// Discriminating without re-deriving the expected value from the function
// under test: the document is MOVED (a different anchor is passed) and the row
// text must move with it. A base-name implementation is anchor-blind and reads
// the same string for both anchors.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeRowFixture("rows_anchor");
    ImageRow[] here, elsewhere;

    imageRowsInto(&f.doc, f.docPath, here);
    // The same document, saved where NEITHER anchor reaches the images: two
    // directories below `tex/`, so `bravo.bmp` is under neither that directory
    // nor its parent. (A sibling of the scratch root would NOT do — the system
    // temp directory is a common ancestor of both, so the parent anchor would
    // still produce a relative form and the assertion below would be about the
    // wrong thing.)
    imageRowsInto(&f.doc,
                  buildPath(f.dir, "scene", "tex", "sub", "deep", "other.v3d"),
                  elsewhere);

    assert(here[1].pathText == "tex/bravo.bmp",
        "control: anchored at the document, the path is relative; got '"
        ~ here[1].pathText ~ "'");
    import std.path : isAbsolute;
    assert(isAbsolute(elsewhere[1].pathText),
        "anchored elsewhere, the same item's row text must go ABSOLUTE — an "
        ~ "implementation that showed the base name would read "
        ~ "'bravo.bmp' for both, got '" ~ elsewhere[1].pathText ~ "'");
    assert(here[1].pathText != elsewhere[1].pathText,
        "the row text follows the document, so the two forms differ");

    // And an untitled document (no anchor at all) stores absolute.
    ImageRow[] untitled;
    imageRowsInto(&f.doc, "", untitled);
    assert(isAbsolute(untitled[0].pathText),
        "an untitled document has no anchor: every row is absolute");
}

// ---------------------------------------------------------------------------
// R4 — the dimensions column, and what a MISSING file reports.
//
// Discriminating: 5x7 and 11x13 are both non-square and mutually distinct, so
// a transposed read and a copied-from-the-wrong-row read are both visible; and
// after the file is deleted the cell must EMPTY while the path text survives
// (blanking the path is the silent-forget failure the task forbids).
// ---------------------------------------------------------------------------
unittest {
    auto f = makeRowFixture("rows_dims");
    ImageRow[] rows;
    imageRowsInto(&f.doc, f.docPath, rows);

    assert(rows[0].dimensions == "3 x 2",   "got '" ~ rows[0].dimensions ~ "'");
    assert(rows[1].dimensions == "5 x 7",   "width first, then height — a "
        ~ "transposed read gives '7 x 5'; got '" ~ rows[1].dimensions ~ "'");
    assert(rows[2].dimensions == "11 x 13", "got '" ~ rows[2].dimensions ~ "'");
    foreach (r; rows) assert(!r.missing, "control: every file is present");

    // The file goes away under the document, and the item re-observes.
    remove(f.pathC);
    assert(!refreshImageMeta(f.charlie.imageOrNull()),
        "precondition: the refresh must actually fail, or the rest of this "
        ~ "test asserts nothing about the missing path");

    imageRowsInto(&f.doc, f.docPath, rows);
    assert(rows[2].missing, "the row reports the file as missing");
    assert(rows[2].dimensions == "",
        "a missing file has no measurement — '0 x 0' would be a number "
        ~ "nothing measured; got '" ~ rows[2].dimensions ~ "'");
    assert(rows[2].pathText == "../charlie.bmp",
        "a missing file must NOT erase what the document says it points at; "
        ~ "got '" ~ rows[2].pathText ~ "'");
    assert(rows[0].dimensions == "3 x 2" && !rows[0].missing,
        "the other rows are untouched by one item's disappearance");
}

// ---------------------------------------------------------------------------
// R5 — the format column is the PIXEL FORMAT, never the file extension.
//
// Discriminating: every fixture file is a `.bmp`, so an extension-based
// implementation reads the same token on all three rows AND a token containing
// a dot; the correct one reads the channel layout the header declared. The
// direct `pixelFormatText` cases pin the whole vocabulary, including that an
// unmeasured channel count is EMPTY rather than a guess.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeRowFixture("rows_format");
    ImageRow[] rows;
    imageRowsInto(&f.doc, f.docPath, rows);

    foreach (i, r; rows)
        assert(r.pixelFormat == "RGB",
            "a 24-bit BMP is three channels; got '" ~ r.pixelFormat ~ "'");
    // The discriminator against "extension": the fixture's extension is "bmp",
    // and nothing in the column may be it.
    foreach (r; rows) {
        assert(r.pixelFormat != "bmp" && r.pixelFormat != ".bmp" && r.pixelFormat != "BMP",
            "the format column is the channel layout, not the file type");
    }

    assert(pixelFormatText(1) == "Grey");
    assert(pixelFormatText(2) == "Grey+A");
    assert(pixelFormatText(4) == "RGBA");
    assert(pixelFormatText(0) == "",
        "an unmeasured channel count reports nothing, not a default layout");

    // A missing item reports no format either — same rule as its dimensions.
    remove(f.pathA);
    refreshImageMeta(f.alpha.imageOrNull());
    imageRowsInto(&f.doc, f.docPath, rows);
    assert(rows[0].missing && rows[0].pixelFormat == "",
        "a missing file has no format; got '" ~ rows[0].pixelFormat ~ "'");
}

// ---------------------------------------------------------------------------
// R6 — the path is elided from the RIGHT: the head survives.
//
// Discriminating: the two directions produce different strings for the same
// input, and the assertion names the surviving END. A left-eliding
// implementation reads "…/textures/logo.png".
// ---------------------------------------------------------------------------
unittest {
    immutable p = "../assets/textures/logo.png";
    assert(p.length == 27, "fixture length changed; the budgets below move");

    assert(elideEnd(p, 40) == p, "a path that fits is untouched, with no ellipsis");
    assert(elideEnd(p, 27) == p, "exactly at the budget is still untouched");
    assert(elideEnd(p, 26) != p, "one under the budget IS cut — the boundary "
        ~ "above is a real edge, not a wide margin");

    immutable cut = elideEnd(p, 10);
    assert(cut == "../assets…",
        "the HEAD survives and the ellipsis marks the cut; got '" ~ cut ~ "'");

    import std.range : walkLength;
    assert(walkLength(cut) == 10,
        "the result honours the budget in code points");

    assert(elideEnd(p, 1) == "…", "a one-point budget is all ellipsis");
    assert(elideEnd(p, 0) == "",       "a zero budget draws nothing");

    // Multi-byte input must not be cut mid-sequence: four two-byte code
    // points, budget three, so the result is two of them plus the ellipsis.
    immutable uni = "äöüß";
    immutable ucut = elideEnd(uni, 3);
    assert(ucut == "äö…",
        "code points, not bytes; got '" ~ ucut ~ "'");
    import std.utf : validate;
    validate(ucut);
}

// ---------------------------------------------------------------------------
// R7 — multi-select and focus are per-row and independent.
//
// Discriminating: TWO image rows are selected and only ONE of them is the
// focus, so three wrong implementations read differently — one that reports
// primary-ness reads all-false (an image can never be primary), one that
// equates focus with selection reads two focused rows, and one that reports
// the document's single focus on every row reads three.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeRowFixture("rows_selection");
    ImageRow[] rows;

    imageRowsInto(&f.doc, f.docPath, rows);
    foreach (r; rows)
        assert(!r.selected && !r.focused,
            "baseline: loading an image does not select it");

    f.doc.selectItem(f.bravo,   SelMode.Add);
    f.doc.selectItem(f.charlie, SelMode.Add);
    imageRowsInto(&f.doc, f.docPath, rows);

    assert(!rows[0].selected, "alpha was never selected");
    assert(rows[1].selected,  "bravo is in the selection SET");
    assert(rows[2].selected,  "charlie is in the selection SET — the list is "
        ~ "multi-select, so a second add does not drop the first");

    assert(!rows[0].focused && !rows[1].focused,
        "focus is a single row, and it is not one of these");
    assert(rows[2].focused,
        "the most recently touched row is the focus");
    assert(f.meshA.selected,
        "control: `add` extends the set, it does not replace it — if this "
        ~ "were false the two adds above would not have proven multi-select");
}

// ---------------------------------------------------------------------------
// R8 — the Remove affordance targets the FOCUSED image row.
//
// Discriminating: the focus is moved to the MIDDLE image (layer index 3) while
// the primary stays on meshA (layer 0), so an implementation reading
// `activeIndex`/`primary` reads 0, and one that ignores the item kind stays
// enabled on the mesh baseline.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeRowFixture("rows_remove_target");

    auto onMesh = imageRemoveTarget(&f.doc);
    assert(!onMesh.enabled,
        "the baseline focus is a MESH — Remove must be disabled, because "
        ~ "`image.remove` would refuse it");
    assert(onMesh.layer is null, "a disabled affordance names no target");

    f.doc.selectItem(f.bravo, SelMode.Set);
    auto onImage = imageRemoveTarget(&f.doc);
    assert(onImage.enabled, "an image row is removable");
    assert(onImage.layer is f.bravo, "the target is the FOCUSED row");
    import std.conv : to;
    assert(onImage.index == 3,
        "and it is addressed by its layer index; the primary is still layer "
        ~ "0, so an implementation reading `activeIndex` reads 0. Got "
        ~ to!string(onImage.index));
    assert(f.doc.indexOf(f.doc.primary) == 0,
        "vacuity guard: the primary really is a DIFFERENT layer from the "
        ~ "focus, or the index assertion above could not discriminate");
}

// ---------------------------------------------------------------------------
// R9 — the confirm text names the target and every referrer.
//
// Discriminating: two consumers point at the MIDDLE image and none at the
// others. An implementation that stopped at the first referrer reads "1", one
// that swept the whole document reads "6", and one asking about the wrong item
// reads the empty string.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeRowFixture("rows_remove_confirm");

    immutable used = imageRemoveConfirmText(&f.doc, f.bravo);
    import std.algorithm : canFind;
    assert(used.canFind("bravo"),      "names the item being removed: " ~ used);
    assert(used.canFind("2 item(s)"),  "counts BOTH referrers: " ~ used);
    assert(used.canFind("consumerX"),  "names the first referrer: " ~ used);
    assert(used.canFind("consumerY"),  "names the second referrer: " ~ used);

    assert(imageRemoveConfirmText(&f.doc, f.alpha) == "",
        "an image nothing references needs no confirmation — an "
        ~ "implementation that swept every layer would warn here too");
    assert(imageRemoveConfirmText(&f.doc, f.charlie) == "",
        "and the same for the third image");
}

// ---------------------------------------------------------------------------
// R10 — a document with no images has no rows, and its own empty text.
//
// Discriminating: the mesh-only document has a layer, so an unfiltered
// implementation reads 1 row rather than 0.
// ---------------------------------------------------------------------------
unittest {
    auto doc = Document.bootstrap(makeCube());
    assert(doc.layers.length == 1,
        "vacuity guard: there IS a layer, so 'no rows' is a filter result "
        ~ "and not an empty document");

    ImageRow[] rows = [ImageRow(99)];   // pre-dirtied, so a no-op fill shows
    imageRowsInto(&doc, "", rows);
    import std.conv : to;
    assert(rows.length == 0,
        "a mesh is not an image row; got " ~ to!string(rows.length));
    assert(kNoImagesText.length > 0, "the empty state has its own text");
}
