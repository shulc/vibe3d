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
// COST — MEASURED (task 0635), and this comment has now been wrong TWICE, in
// two different ways that are both worth keeping on the record because the
// second one was caused by fixing the first.
//
// Wrong the first time by a FACTOR OF FIVE: it used to say "the two formatted
// strings per row are the only per-row allocation". Two strings is what the
// SOURCE reads like; what it costs is what the functions behind them allocate
// on the way to producing them.
//
// Wrong the second time by an INERT ZERO, which is worse, because it read like
// a measurement. The replacement text said `elideEnd 0 — measured, both
// cutting and not`, and concluded a cache in front of it "would be pure
// liability". The harness behind that number drove `imageRowsInto`, and
// `imageRowsInto` does not call `elideEnd`: the PANEL does, once per row,
// immediately after the row build (`ui/panels.d`, line 2 of the name cell).
// So the cutting and the non-cutting build both read 0 for the same reason —
// neither ran the function — and re-running the harness reproduced the zero
// and looked like corroboration.
//
// A FRAME IS THEREFORE TWO STEPS, NOT ONE, and both now start in this module
// so that one measurement covers the lot: `imageRowsInto` (the row build, and
// the two renderings under it) and `elidedPathText` (the cut, which the panel
// used to reach past this module to make). The figures, each taken through a
// call that reaches the function it is a figure for:
//
//   the row build     5120 bytes/frame   — 600 frames, 1 mesh + 20 clips,
//                                          paths one directory below the doc
//     the path text   4160  (81%)  — `storePathFor`: two normalisations,
//                                    a `dirName`, a `relativePath`
//     the dimensions  960   (19%)  — two `to!string` + a concatenation
//
//   `elideEnd`        48 bytes PER CUTTING ROW at the panel's floor budget
//                     of 8, 80 at its default of 16 — an `appender` and its
//                     buffer. Measured by calling it directly on the three
//                     fixture row texts ("alpha.bmp", "tex/bravo.bmp",
//                     "../charlie.bmp") built at runtime so nothing folds:
//                     144 bytes/frame for those three rows at budget 8.
//                     A path SHORTER than the budget really is 0 — that
//                     branch returns its argument — which is precisely why a
//                     fixture that does not cut proves nothing here.
//
// At 60 fps with the panel open the row build alone was ≈300 KiB/s, ≈17.6
// MiB/min of GC churn on the UI thread, growing with the number of rows. All
// three figures are now memoised on the item (`RowTextMemo`, `document.d`): a
// frame in which neither the document nor the panel width changed allocates
// nothing at all, so the per-frame cost no longer scales with the row count.
//
// `imageRowsInto` fills the caller's buffer in place (the
// `Document.referrersOf` / `selectedItemsInto` idiom) so a panel holding one
// static buffer does not churn an array per frame. What is deliberately NOT
// on this path is `Document.referrersOf` — its own doc comment forbids a
// draw-path call — so "is this image in use" is asked once, at CLICK time,
// through `imageRemoveConfirmText`.
// ---------------------------------------------------------------------------

import document        : Document, Layer, ImageData;
import io.image_path   : storePathForItem;

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
    /// What the inline rename editor STARTS with — the item's raw `name`
    /// field, which is `""` for an unnamed item, NOT the `name` above.
    ///
    /// A separate field because the two are different strings for exactly the
    /// case that matters (review S5). Seeding the editor with the DISPLAY form
    /// means double-clicking an unnamed row prefills the literal "(unnamed)"
    /// placeholder, and pressing Enter renames the layer to it — after which
    /// the Layers panel, which reads the raw field, shows an item genuinely
    /// called "(unnamed)" and the placeholder can never be recovered.
    string renameSeed;
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

/// `dimensionsText` for an image ITEM, memoised on the item (task 0635).
///
/// The second half of the row build's per-frame garbage, and the smaller one:
/// 960 of the measured 5120 bytes/frame, against the relative path's 4160. It
/// is taken anyway because the task's bar is that an open panel not allocate
/// IN PROPORTION TO THE NUMBER OF ROWS, and three `to!string`-and-concatenate
/// results per frame per row is exactly that shape — leaving it would have met
/// the byte target while leaving the property unmet.
///
/// The key is the three inputs, which are `refreshImageMeta`'s three outputs;
/// see `RowTextMemo` in `document.d` for why the cache is keyed on them rather
/// than cleared by whoever writes them.
///
/// IT WRITES, and the guard says which thread may. See `imageRowsInto`.
string dimensionsTextFor(ImageData img) {
    if (img is null) return "";
    if (img.rowText.dimsValid
        && img.rowText.dimsW == img.width
        && img.rowText.dimsH == img.height
        && img.rowText.dimsMissing == img.missing)
        return img.rowText.dimsText;

    import gl_thread_guard : glThreadGuard;
    glThreadGuard("imageRowText");

    const text = dimensionsText(img.width, img.height, img.missing);
    img.rowText.dimsText    = text;
    img.rowText.dimsW       = img.width;
    img.rowText.dimsH       = img.height;
    img.rowText.dimsMissing = img.missing;
    img.rowText.dimsValid   = true;
    return text;
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
///
/// NEVER THROWS, and that is a requirement rather than a courtesy (review S3).
/// `foreach (dchar c; s)` decodes, and decoding throws `UTFException` on
/// invalid UTF-8 — which a POSIX path is perfectly entitled to be, since a
/// Linux filename is a byte string with no encoding guarantee at all. This
/// runs inside `drawImageListPanel`, between `ImGui.Begin` and `ImGui.End`, so
/// a throw here does not merely lose one row: it unwinds past `End()` and the
/// style pop, and the window/style stacks come apart. The failure then
/// surfaces one frame LATER as an assertion deep inside ImGui, nowhere near
/// this function.
///
/// A path we cannot decode is therefore elided BY BYTE, on a code-point
/// boundary found by scanning back over UTF-8 continuation bytes
/// (`0b10xxxxxx`). The result may be shorter than the budget and it may not be
/// what the user would have typed, but it is a drawable, well-formed string
/// and the row appears.
string elideEnd(string s, size_t maxChars) {
    import std.array : appender;

    if (maxChars == 0) return "";
    // `Exception`, not `std.utf.UTFException`: the throw comes from druntime's
    // own decoder (`core.internal.utf`), which raises
    // `core.exception.UnicodeException` — a sibling class, not a subclass.
    // MEASURED: catching `UTFException` alone left this function throwing.
    // And the contract here is "never throws on the draw path", which is a
    // statement about the whole class of failures, not about one of them.
    try {
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
    } catch (Exception) {
        return elideUndecodable(s, maxChars);
    }
}

/// The `elideEnd` fallback for a string that is not valid UTF-8: cut at most
/// `maxChars` BYTES, then walk back off any UTF-8 continuation byte so the
/// result never ends mid-sequence, and append the ellipsis.
///
/// Separate and `private` so the throwing path above stays readable, and so a
/// test can aim at it directly.
private string elideUndecodable(string s, size_t maxChars) {
    if (maxChars == 0) return "";
    // One code point of the budget goes to the marker, exactly as above.
    size_t cut = maxChars - 1;
    if (cut > s.length) cut = s.length;
    // 0b10xxxxxx is a continuation byte: back up while the byte AT the cut is
    // one, so the cut never lands inside a multi-byte sequence. (`cut ==
    // s.length` is already a boundary — there is no byte there to inspect.)
    while (cut > 0 && cut < s.length && (s[cut] & 0xC0) == 0x80) --cut;
    return s[0 .. cut] ~ "�";
}

/// The path line exactly as the panel draws it: THIS row's text, cut to the
/// budget the panel derived from the width it has — memoised on the item
/// (task 0635).
///
/// WHY IT IS HERE AND NOT INLINE IN THE PANEL. Two reasons, and the second is
/// the one that matters.
///
///   * The cut is per row per FRAME, like the two renderings above it, and it
///     allocates for exactly the rows that get cut — an `appender` and its
///     buffer. MEASURED through this call path (the fixture's three row texts,
///     built at runtime so nothing constant-folds): 48 bytes per cutting row
///     at the panel's floor budget of 8 — 144 bytes/frame for three rows —
///     and 80 at its default of 16. A row whose path is SHORTER than the
///     budget costs 0, because `elideEnd` returns its argument on that branch.
///   * A number nobody can reach is a number nobody can check. `elideEnd`
///     used to be called only from `ui/panels.d`, so the harness that
///     measured "the row build" never ran it, read 0, and this module's header
///     wrote that zero down as a measurement — with and without the cut, which
///     is what made it look corroborated. Moving the call here puts it on the
///     same path R11 measures, so the byte assertion covers the whole of what
///     a frame does rather than the part that happened to be reachable.
///
/// THE KEY IS `(pathText, budget)`. The text side is already memoised
/// (`storePathForItem`), so on a steady frame it is the same string — the
/// comparison is a byte compare that allocates nothing either way. The budget
/// is not a field of anything: the panel computes it from the content width
/// available on the frame it is drawing, floored at 8, so it changes when the
/// window is resized and at no other time. Both halves are therefore stable
/// across the frames this is meant to make free, and a resize costs one
/// recompute per row — the same price the old code paid every frame.
///
/// `img` is the memo's home and may be null (a payload-null image item, see
/// `isImageRow`); that case falls through to the bare function, which for the
/// empty path text it carries is the no-allocation branch anyway.
///
/// IT WRITES, and the guard says which thread may. See `imageRowsInto`.
string elidedPathText(ImageData img, string pathText, size_t maxChars) {
    if (img is null) return elideEnd(pathText, maxChars);
    if (img.rowText.elideValid
        && img.rowText.elideBudget == maxChars
        && img.rowText.elideSource == pathText)
        return img.rowText.elideText;

    import gl_thread_guard : glThreadGuard;
    glThreadGuard("imageRowText");

    const text = elideEnd(pathText, maxChars);
    img.rowText.elideText   = text;
    img.rowText.elideSource = pathText;
    img.rowText.elideBudget = maxChars;
    img.rowText.elideValid  = true;
    return text;
}

/// `elidedPathText` addressed by ROW, which is how the panel holds it.
///
/// The row's `layer` is the handle (identity, per Ph3) and the payload hangs
/// off it, so the panel does not have to reach through `imageOrNull` at the
/// draw site and cannot pass one row's text with another row's memo.
string elidedPathText(ref ImageRow r, size_t maxChars) {
    return elidedPathText(r.layer is null ? null : r.layer.imageOrNull(),
                          r.pathText, maxChars);
}

/// Fill `outBuf` with one `ImageRow` per image item, in `document.layers`
/// order — creation order, because the measured list has no sort and no
/// reorder command, and because that is the order every other view of
/// `layers` already uses.
///
/// `docPath` is the anchor the row's path text is relativised against, and it
/// is a PARAMETER rather than a `currentDocPath()` call: it READS no global
/// state, so a test can move the document without moving the process. The
/// panel passes `currentDocPath()`.
///
/// IT IS NOT, HOWEVER, A PURE READ OF THE DOCUMENT — this comment said "pure
/// with respect to global state" and that was only ever true of the reading
/// half. Since task 0635 the three text helpers below fill a memo ON THE ITEM
/// when they miss, so building the rows WRITES to `ImageData.rowText` for
/// every item whose inputs moved since the last frame. What that write is and
/// is not:
///
///   * it carries no information — `RowTextMemo` is a rendering of fields that
///     already exist, nothing serialises it, nothing copies it across a
///     duplicate, and discarding it can only cost time. So it bumps no
///     mutation version and raises no dirty flag, deliberately: a redraw is
///     not an edit and must not make the document look edited.
///   * it is NOT thread-safe, and the functions are public. Two threads
///     filling one slot would tear a `string` (pointer and length are written
///     separately), and a reader could see the new pointer with the old
///     length. Today the only caller is this function and its only caller is
///     the clip panel on the UI thread — so the write is guarded rather than
///     locked: each of `storePathForItem` / `dimensionsTextFor` /
///     `elidedPathText` calls `glThreadGuard("imageRowText")` on the MISS
///     branch, which turns a future HTTP-thread caller into a named error at
///     the offending call instead of a torn read somewhere else. The guard
///     costs one atomic load and one TLS read, and only when a slot is
///     actually being filled — never on the steady frame this exists to make
///     free. (It is inert under `dub test`, which never marks a main thread.)
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
        r.renameSeed  = l.name;              // RAW — see the field's comment
        r.selected    = l.selected;
        r.focused     = doc.focusedItem is l;
        if (img is null) {
            // Payload-null image item — see `isImageRow`. Everything derived
            // from the payload stays empty; `missing` is the honest answer.
            r.missing = true;
        } else {
            r.pathTooltip = img.storedPath;
            // MEMOISED (task 0635), not because the values are expensive but
            // because this runs once per row EVERY FRAME the panel is open —
            // see `RowTextMemo`. Both wrappers return exactly what the bare
            // functions return; the only difference is that a frame in which
            // nothing changed does not allocate.
            r.pathText    = storePathForItem(img, docPath);
            r.dimensions  = dimensionsTextFor(img);
            // `img.channels` UNCONDITIONALLY — there is no `missing ? 0 :`
            // guard here, and there was one (review, inert-assertion 2).
            //
            // It could not fire: `refreshImageMeta` zeroes width/height/
            // channels BEFORE every one of its early returns, so `missing`
            // implies `channels == 0` for every payload in the document —
            // `image.replace` copies all five fields from a probe that went
            // through that same function, and its revert restores all five
            // together. A branch that cannot be taken is not a safety net; it
            // is a second, untested statement of a rule that already has one
            // owner, and it made "a missing file reports no format" pass here
            // even if the clearing over there were removed.
            //
            // `dimensionsText` keeps its `missing` argument, and that is not
            // an inconsistency: a 0x0 measurement would render as "0 x 0",
            // which is a plausible-looking lie, whereas `pixelFormatText(0)`
            // is already "" by its own vocabulary.
            r.pixelFormat = pixelFormatText(img.channels);
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
    import commands.image.commands : ImageLoad, ImageReplace, ImageReload;
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

    // The rename editor's seed is the RAW field, and on a NAMED item the two
    // agree — which is why the unnamed case below is the only one that can
    // discriminate, and why it has to exist (review S5).
    foreach (i, r; rows)
        assert(r.renameSeed == r.name,
            "a named item seeds the editor with what it displays");

    f.bravo.name = "";
    imageRowsInto(&f.doc, f.docPath, rows);
    assert(rows[1].name == kUnnamedText,
        "an unnamed item DISPLAYS the placeholder; got '" ~ rows[1].name ~ "'");
    assert(rows[1].renameSeed == "",
        "…and seeds the rename editor with NOTHING. Seeding it with the "
        ~ "displayed text means Enter renames the layer to the literal \""
        ~ kUnnamedText ~ "\", which the Layers panel then shows as a real "
        ~ "name and which cannot be undone back to 'no name'. Got '"
        ~ rows[1].renameSeed ~ "'");
    assert(rows[1].name != rows[1].renameSeed,
        "vacuity guard: the display form and the seed really are different "
        ~ "strings here — everywhere else they coincide and this assertion "
        ~ "would be inert");
    f.bravo.name = "bravo";     // restore for anything reading the fixture after

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
// R5 — the format column is the PIXEL FORMAT of THAT row's file.
//
// Discriminating in two steps, because one is not enough:
//
//   * the baseline pins the value read from a real header (24-bit BMP → three
//     channels → "RGB"), which already excludes every extension-shaped answer
//     — "bmp", ".bmp" and "BMP" are all != "RGB". An earlier revision followed
//     it with an explicit `!= "bmp"` triple; that could not fail once the
//     equality above had passed, and is replaced here rather than kept.
//   * the replacement moves ONE row's channel count off the shared value. Now
//     the rows do not agree, so an implementation reading a constant, or the
//     extension, or the FIRST item's channels, reads the same token twice
//     where the correct one reads two different tokens. The equality baseline
//     alone could not separate any of those from each other.
//
// Poking `channels` directly is the right seam: turning a FILE into a channel
// count is `refreshImageMeta`'s job and is pinned by its own tests (a 24-bit
// BMP reads 3, a vanished file reads 0). This module's job is only the map
// from that number to a token.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeRowFixture("rows_format");
    ImageRow[] rows;
    imageRowsInto(&f.doc, f.docPath, rows);

    foreach (i, r; rows)
        assert(r.pixelFormat == "RGB",
            "a 24-bit BMP is three channels; got '" ~ r.pixelFormat ~ "'");

    // One row's measurement moves; the other two do not.
    f.bravo.imageOrNull().channels = 4;
    imageRowsInto(&f.doc, f.docPath, rows);
    assert(rows[1].pixelFormat == "RGBA",
        "the row reports ITS OWN item's channel count; got '"
        ~ rows[1].pixelFormat ~ "'");
    assert(rows[0].pixelFormat == "RGB" && rows[2].pixelFormat == "RGB",
        "…and its neighbours are untouched — an implementation reading one "
        ~ "item's channels for every row reads 'RGBA' here, and one reading "
        ~ "the file extension reads the same token on all three");
    assert(rows[0].pixelFormat != rows[1].pixelFormat,
        "vacuity guard: the two rows really do disagree now, which is the "
        ~ "whole basis of the assertions above");

    assert(pixelFormatText(1) == "Grey");
    assert(pixelFormatText(2) == "Grey+A");
    assert(pixelFormatText(4) == "RGBA");
    assert(pixelFormatText(0) == "",
        "an unmeasured channel count reports nothing, not a default layout");

    // A missing item reports no format either — same rule as its dimensions.
    // The MECHANISM is asserted first: the row is empty because the refresh
    // cleared the count, not because the row model carries a second `missing`
    // rule of its own (it deliberately does not — see `imageRowsInto`).
    remove(f.pathA);
    refreshImageMeta(f.alpha.imageOrNull());
    assert(f.alpha.imageOrNull().channels == 0,
        "precondition: a failed refresh clears the channel count. Without "
        ~ "this the assertion below would pass on a row model that hard-coded "
        ~ "an empty cell for `missing`, and would not notice a refresh that "
        ~ "left the stale 3 behind");
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

    // THE BUDGET, SWEPT. Reading `walkLength` off the literal spelled out one
    // line above proves nothing — the literal already has ten code points, so
    // the assertion is a restatement of the equality, not a second check
    // (review, inert-assertion 4). Sweeping every budget that cuts is a real
    // one: an off-by-one in the ellipsis accounting (`keep = maxChars` rather
    // than `maxChars - 1`) reads 11 at the very first iteration, and no single
    // hand-written expectation would have to be updated to see it.
    import std.range : walkLength;
    import std.conv  : to;
    foreach (budget; 1 .. p.length) {          // 1 .. 26 — every budget that cuts
        immutable got = elideEnd(p, budget);
        assert(walkLength(got) == budget,
            "budget " ~ budget.to!string ~ " must produce exactly that many "
            ~ "code points, ellipsis included; got '" ~ got ~ "' ("
            ~ walkLength(got).to!string ~ ")");
    }

    assert(elideEnd(p, 1) == "…", "a one-point budget is all ellipsis");
    assert(elideEnd(p, 0) == "",       "a zero budget draws nothing");

    // Multi-byte input must not be cut mid-sequence. Four two-byte code
    // points, so `length` (8) and code-point count (4) differ — which is what
    // makes a byte-based implementation visible.
    immutable uni = "äöüß";
    assert(uni.length == 8, "fixture: eight BYTES, four code points");
    import std.utf : validate;

    immutable ucut = elideEnd(uni, 3);
    assert(ucut == "äö…", "code points, not bytes; got '" ~ ucut ~ "'");

    // BUDGET FOUR IS THE ONE THAT DISCRIMINATES, and budget three is not
    // (review, inert-assertion 5). A byte-based implementation slices "äöüß"
    // at byte 2 for budget 3 — exactly the end of "ä" — so the result is
    // accidentally well-formed and `validate` cannot fire. At budget 4 the
    // same implementation still thinks the string does not fit (8 bytes > 4)
    // and cuts at byte 3, in the MIDDLE of "ö".
    immutable ufit = elideEnd(uni, 4);
    assert(ufit == uni,
        "four code points fit a budget of four, untouched and with no "
        ~ "ellipsis — a byte-based implementation measures 8 and cuts; got '"
        ~ ufit ~ "'");
    validate(ufit);     // …and what it cut to would be invalid UTF-8
    validate(ucut);
}

// ---------------------------------------------------------------------------
// R6b — a path that is not valid UTF-8 is ELIDED, not thrown over (review S3).
//
// A POSIX filename is a byte string; nothing guarantees it decodes. `foreach
// (dchar c; s)` throws `UTFException` on one that does not, and this function
// runs between `ImGui.Begin` and `ImGui.End` — so the throw would not lose a
// row, it would unwind past the window and style pops and leave ImGui's stacks
// one deep, surfacing as an assertion inside ImGui on the NEXT frame.
//
// Discriminating: the input is a real lone-continuation byte (0x80, illegal as
// a lead), the assertion is that the call RETURNS, and the returned text is
// checked to be non-empty and short enough to draw. An implementation that
// simply lets the decode throw does not reach the first assertion at all — the
// unittest dies with a UTFException, which is a different and very loud red.
// ---------------------------------------------------------------------------
unittest {
    import std.conv  : to;
    import std.range : walkLength;

    // "bad/" + 0x80 + "name.png" — 0x80 is a UTF-8 CONTINUATION byte with no
    // lead in front of it, which no decoder accepts.
    immutable string bad = "bad/" ~ cast(string)[cast(char) 0x80] ~ "name.png";
    {
        import std.utf : validate;
        bool threw = false;
        try validate(bad); catch (Exception) threw = true;
        assert(threw, "fixture: the input really is undecodable, or this test "
            ~ "exercises the ordinary path and proves nothing");
    }

    immutable got = elideEnd(bad, 8);
    assert(got.length > 0,
        "an undecodable path still draws something; got an empty string");
    assert(got.length <= bad.length,
        "…and it is not longer than what it elided; got " ~ got.length.to!string);

    // A short-enough undecodable path is returned as-is-ish rather than lost.
    assert(elideEnd(bad, 400).length > 0,
        "a generous budget over an undecodable path still yields text");

    // And the ordinary path is untouched by the guard: a decodable string of
    // the same shape still elides by CODE POINT.
    assert(walkLength(elideEnd("bad/xname.png", 8)) == 8,
        "the valid-UTF-8 path still honours the budget in code points");
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
// R10 — WHEN the panel is empty, and when it only looks like it should be.
//
// Discriminating, first half: the mesh-only document has a layer, so an
// unfiltered implementation reads 1 row rather than 0.
//
// Second half: an image item whose PAYLOAD was never constructed still gets a
// row. `isImageRow`'s doc comment states this, and nothing asserted it —
// `assert(kNoImagesText.length > 0)` stood here instead, which is a claim
// about a compile-time literal and could not fail (review, inert-assertion 3).
// The consequence it protects is concrete: `isImageRow` is the exact
// complement of the Layers panel's `isSceneItem` skip, so an implementation
// that filtered a payload-null item out here would leave that item in NO panel
// at all — invisible, unselectable, and undeletable — while this list confidently
// printed its empty text over the top of it.
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

    // …and now an image item with no payload joins it.
    auto orphan = new Layer;
    orphan.name = "no payload";
    orphan.kind = ItemKind.Image;
    doc.layers ~= orphan;
    assert(orphan.imageOrNull() is null,
        "fixture: the payload really is unconstructed — if it were not, this "
        ~ "would be the ordinary row case and would prove nothing");

    imageRowsInto(&doc, "", rows);
    assert(rows.length == 1,
        "a payload-null image item is LISTED, not skipped: skipping puts it "
        ~ "in no panel at all. Got " ~ to!string(rows.length) ~ " row(s)");
    assert(rows[0].layer is orphan, "…and it is that item");
    assert(rows[0].name == "no payload", "…drawn under its own name");
    assert(rows[0].missing,
        "…reported as missing, which is the honest answer for an item that "
        ~ "names no file");
    assert(rows[0].pathText == "" && rows[0].pathTooltip == "",
        "…with no path text of any kind, rather than a fabricated one");
    assert(rows[0].dimensions == "" && rows[0].pixelFormat == "",
        "…and no measurements");
}

// ===========================================================================
// Task 0635 — the row-text MEMO. Four tests, and the split between them is
// the whole design of this section.
//
// THE ASSERTION HAS TO BE ABOUT BYTES, because correctness is not evidence
// here. Every assertion in R1..R10 above passes with no cache whatsoever —
// they check WHAT the row says, and a memo that is never consulted says the
// same thing. So R11 measures GC bytes across two consecutive FRAMES of an
// unchanged document, which is the only reading that can tell "memoised" from
// "recomputed and identical".
//
// AND IT HAS TO MEASURE THE WHOLE FRAME. R11's first cut measured
// `imageRowsInto` and stopped, which is only part of what a frame does: the
// panel then cuts each row's path to the width it has. A green R11 therefore
// implied a property — "an open panel does not allocate per row" — that did
// not hold, and the module header stated `elideEnd`'s cost as a measured ZERO
// which was really the reading of a function the harness never called. R11 now
// takes FOUR readings, build and cut separately, so each term has its own
// vacuity guard and its own zero, and neither can hide inside the other.
//
// AND THE BYTE TEST HAS TO BE PAIRED WITH INVALIDATION, because it is blind in
// exactly the opposite direction: a cache that is filled once and NEVER
// invalidated passes R11 perfectly while showing a stale path for the rest of
// the session. R12, R13 and R14 are that half — one per input.
//
// All three invalidation tests need MORE THAN ONE clip, and clips whose texts
// DIFFER, or "the row followed the change" cannot be told from "the rows were
// the same string anyway". The seven-item fixture already has three images at
// three different anchors, which is why it is reused rather than replaced.
// ===========================================================================

/// The budget R11 measures at, and the panel's own FLOOR (`ui/panels.d`:
/// `budget = b < 8 ? 8 : b`).
///
/// EIGHT RATHER THAN THE DEFAULT SIXTEEN, and the choice is the whole point of
/// the extension. This fixture's three row texts are 9, 13 and 14 code points,
/// so at 16 not one of them is long enough to cut, `elideEnd` returns its
/// ARGUMENT, and the reading is 0 whether the function is memoised, correct,
/// or deleted. That is the inert measurement that put a false zero in this
/// module's header. At 8 all three cut. The last assertion in R11 pins both
/// halves of that so it cannot quietly stop being true.
version (unittest) private enum size_t kMeasureBudget = 8;

// ---------------------------------------------------------------------------
// R11 — a frame in which nothing changed allocates NOTHING.
//
// A FRAME IS TWO STEPS, and this test measures both: `imageRowsInto` builds
// the rows, then the panel cuts each row's path text to the width it has
// (`elidedPathText`, once per row, `ui/panels.d` line 2 of the name cell).
// Measuring only the first is how the module header came to state `elideEnd`'s
// cost as a measured zero — the harness never called it, so the cutting and
// the non-cutting build agreed, and the agreement read as corroboration.
//
// FOUR READINGS, not two, so the two terms cannot hide inside each other: a
// broken path memo and a broken elide memo would otherwise both surface as one
// number, and at this fixture's size they even collide (144 bytes either way).
// Each term gets its own vacuity guard — the COLD reading must be non-zero, or
// "the warm one was zero" is a statement about a function that never allocates
// — and its own exact zero.
//
// ZERO, NOT "MATERIALLY LESS". Zero is the only reading that proves the cost
// stopped scaling with the row count. Three of the four break checks below
// leave a warm reading a ratio threshold would accept: 144 against a cold 1216
// is an 88% cut, and still an allocation per row per frame.
//
// BREAK-VERIFIED — five wrong implementations, each read through this test.
// The last two are the ones the four-reading split buys: one that this test
// deliberately does NOT catch, and one aimed at the test itself.
//
//   * path memo disabled          warm build 1072 (cold 1216)
//   * dimensions memo disabled    warm build  144
//   * elide memo disabled         warm cut    144 (cold cut 144)
//   * elide memo keyed on the
//     text only, not the budget   R11 GREEN — see R14, which is why that
//                                 test exists as well as this one
//   * `kMeasureBudget` moved to
//     the panel's DEFAULT of 16   cold cut 0 — the vacuity guard fires. This
//                                 is the mutation that reproduces the original
//                                 bug: a budget nothing reaches makes every
//                                 elide reading zero, and a zero nobody can
//                                 make non-zero is not a measurement.
// ---------------------------------------------------------------------------
unittest {
    import core.memory : GC;
    import std.conv    : to;
    import std.range   : walkLength;

    auto f = makeRowFixture("rows_memo_bytes");

    size_t nImages = 0;
    foreach (l; f.doc.layers) if (l !is null && l.hasImage) ++nImages;
    assert(nImages == 3,
        "fixture drift: the buffer below is pre-sized from this count, and a "
        ~ "mismatch would put a resize inside the measured window; got "
        ~ to!string(nImages));

    // PRE-SIZED on purpose. `imageRowsInto` grows the caller's buffer once,
    // and that one-off is not what this measures — the panel holds a static
    // buffer across frames for exactly this reason, so a pre-sized buffer IS
    // the panel's steady state rather than a convenience for the test.
    ImageRow[] rows;
    rows.length = nImages;

    // Held so the cut cannot be optimised away as a dead result. Assigning a
    // slice allocates nothing, so it is not part of any reading below.
    string line;

    // The four readings are taken with the two steps spelled out rather than
    // wrapped in a nested function: a delegate over these locals can put a
    // closure allocation inside the very first window.
    immutable a = GC.stats().allocatedInCurrentThread;
    imageRowsInto(&f.doc, f.docPath, rows);
    immutable b = GC.stats().allocatedInCurrentThread;
    foreach (ref r; rows) line = elidedPathText(r, kMeasureBudget);
    immutable c = GC.stats().allocatedInCurrentThread;
    imageRowsInto(&f.doc, f.docPath, rows);
    immutable d = GC.stats().allocatedInCurrentThread;
    foreach (ref r; rows) line = elidedPathText(r, kMeasureBudget);
    immutable e = GC.stats().allocatedInCurrentThread;

    immutable coldBuild = b - a;
    immutable coldCut   = c - b;
    immutable warmBuild = d - c;
    immutable warmCut   = e - d;

    immutable readings = " (cold build " ~ to!string(coldBuild)
                       ~ ", cold cut "   ~ to!string(coldCut)
                       ~ ", warm build " ~ to!string(warmBuild)
                       ~ ", warm cut "   ~ to!string(warmCut)
                       ~ " bytes for "   ~ to!string(nImages) ~ " rows)";

    assert(coldBuild > 0,
        "vacuity guard: the FIRST row build must allocate, or 'the second "
        ~ "built nothing' says nothing about a cache." ~ readings);
    assert(coldCut > 0,
        "vacuity guard: the FIRST cut must allocate too. A budget this "
        ~ "fixture's paths do not reach makes `elideEnd` return its argument, "
        ~ "and then the warm zero below is a fact about the fixture rather "
        ~ "than about the memo — which is exactly the inert reading this "
        ~ "extension exists to close." ~ readings);

    assert(warmBuild == 0,
        "a frame in which nothing changed must build the rows without "
        ~ "allocating: the path and dimensions text are memoised on the item."
        ~ readings);
    assert(warmCut == 0,
        "…and must cut them without allocating either. `elideEnd` allocates "
        ~ "an appender per CUTTING row — 48 bytes at this budget, 144 for "
        ~ "these three — so an unmemoised cut leaves the per-row-per-frame "
        ~ "cost the task exists to remove." ~ readings);

    // …and the memo changed the COST, not the ANSWER.
    assert(rows[0].pathText == "alpha.bmp" && rows[0].dimensions == "3 x 2",
        "row 0 still reads what R2/R4 pin");
    assert(rows[1].pathText == "tex/bravo.bmp" && rows[1].dimensions == "5 x 7",
        "row 1 still reads what R2/R4 pin");
    assert(rows[2].pathText == "../charlie.bmp" && rows[2].dimensions == "11 x 13",
        "row 2 still reads what R2/R4 pin");
    assert(elidedPathText(rows[1], kMeasureBudget) == "tex/bra…",
        "…and the cut still reads what `elideEnd` returns; got '"
        ~ elidedPathText(rows[1], kMeasureBudget) ~ "'");

    // THE FIXTURE REALLY CUTS, both ways round. Without the first half the
    // `coldCut > 0` guard above could be satisfied by one long row while the
    // others were free; without the second, nobody reading this test would
    // know that measuring at the panel's DEFAULT budget instead of its floor
    // silently turns the whole thing inert.
    foreach (i, ref r; rows) {
        immutable got = elideEnd(r.pathText, kMeasureBudget);
        assert(got != r.pathText,
            "fixture: row " ~ to!string(i) ~ " ('" ~ r.pathText ~ "') must be "
            ~ "longer than the budget, or its cut allocates nothing and the "
            ~ "measurement above is inert");
        assert(walkLength(got) == kMeasureBudget,
            "…and cut to exactly the budget; got '" ~ got ~ "'");
        assert(elideEnd(r.pathText, 16) == r.pathText,
            "fixture: at the panel's DEFAULT budget of 16 this row does NOT "
            ~ "cut — which is why R11 measures at the floor of 8. Measuring "
            ~ "at 16 reads zero for a memoised, an unmemoised and a deleted "
            ~ "implementation alike; got '" ~ elideEnd(r.pathText, 16) ~ "'");
    }

    // THE BORN SLOT IS NOT AN ANSWER. A never-computed memo keys as
    // `(0, 0, false)` — the same key a payload that genuinely measures zero
    // pixels and is not missing would produce — and that payload's cell reads
    // "0 x 0", not "". This is what `RowTextMemo.dimsValid` is for; without it
    // the born slot hands back its empty default for a real measurement.
    auto fresh = new ImageData();
    fresh.missing = false;                    // 0x0, and NOT missing
    immutable born = dimensionsTextFor(fresh);
    assert(born == "0 x 0",
        "an empty memo slot must not be mistaken for a cached empty cell; got '"
        ~ born ~ "'");
}

// ---------------------------------------------------------------------------
// R12 — the item's own inputs move, and the row follows.
//
// Two shapes, because they invalidate through different fields and a cache can
// get one right and the other wrong:
//
//   * `image.replace` — the PATH moves (and the measurement with it);
//   * `image.reload` after the file is rewritten in place — the MEASUREMENT
//     moves and the path does not. A dimensions memo keyed on the path alone
//     reads the old "5 x 7" here.
//
// And then the UNDO of the replace, which is the case that decides the whole
// design. `image.replace` refreshes a SCRATCH payload and copies five fields
// onto the live one; its revert writes the five fields back directly. Neither
// direction calls `refreshImageMeta` on the item the panel draws — so a cache
// cleared by a hook inside `refreshImageMeta` is never cleared here at all,
// and the row shows the replacement's path for the rest of the session. That
// is why `RowTextMemo` is keyed on its inputs instead. Break-verified against
// a real hook implementation (no key, `refreshImageMeta` clears both slots):
// the assertion below reads 'tex/bravo.bmp' after the replace.
//
// Discriminating: the OTHER two rows are asserted unchanged at every step, so
// a single memo entry shared by all items (rather than one per item) drags
// them along and reads differently; and every value asserted is distinct from
// every other value in the fixture, so no assertion can pass by coincidence.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;

    auto f = makeRowFixture("rows_memo_inputs");
    ImageRow[] rows;
    imageRowsInto(&f.doc, f.docPath, rows);      // WARMS every row's memo
    assert(rows[1].pathText == "tex/bravo.bmp" && rows[1].dimensions == "5 x 7",
        "control: the warm state is the one R2/R4 pin");

    // --- the path moves -----------------------------------------------------
    immutable newPath = buildPath(f.dir, "scene", "other", "renamed.bmp");
    writeTestBmp(newPath, 9, 4);                 // a size no other row carries

    auto rep = new ImageReplace(f.doc.activeMesh(), f.view, EditMode.Vertices,
                                &f.doc, null);
    {
        auto ps = rep.params();
        auto pj = parseJSON(`{"index":` ~ to!string(f.doc.indexOf(f.bravo))
                            ~ `,"path":` ~ jsonString(newPath) ~ `}`);
        injectParamsInto(ps, pj);
    }
    assert(rep.apply(), "fixture: image.replace must apply");

    imageRowsInto(&f.doc, f.docPath, rows);
    assert(rows[1].pathText == "other/renamed.bmp",
        "the row text follows the item's new path — a memo that never "
        ~ "invalidates reads 'tex/bravo.bmp' here and would keep reading it "
        ~ "for the rest of the session; got '" ~ rows[1].pathText ~ "'");
    assert(rows[1].dimensions == "9 x 4",
        "…and so does the measurement; got '" ~ rows[1].dimensions ~ "'");
    assert(rows[0].pathText == "alpha.bmp" && rows[0].dimensions == "3 x 2",
        "one item's change moves one item: a single shared memo entry would "
        ~ "drag row 0 along");
    assert(rows[2].pathText == "../charlie.bmp" && rows[2].dimensions == "11 x 13",
        "…and row 2 likewise");

    // --- the undo, which never goes through `refreshImageMeta` --------------
    assert(rep.revert(), "fixture: the replace must undo");
    imageRowsInto(&f.doc, f.docPath, rows);
    assert(rows[1].pathText == "tex/bravo.bmp",
        "undo restores the path the document made, and the row must say so. "
        ~ "`revert` writes the five fields back directly, so a cache cleared "
        ~ "only inside `refreshImageMeta` reads 'other/renamed.bmp' here; got '"
        ~ rows[1].pathText ~ "'");
    assert(rows[1].dimensions == "5 x 7",
        "…and the restored measurement, not the replacement's; got '"
        ~ rows[1].dimensions ~ "'");

    // --- the file moves under a path that does not ---------------------------
    writeTestBmp(f.pathB, 21, 22);
    auto rl = new ImageReload(f.doc.activeMesh(), f.view, EditMode.Vertices,
                              &f.doc, null);
    {
        auto ps = rl.params();
        auto pj = parseJSON(`{"index":` ~ to!string(f.doc.indexOf(f.bravo)) ~ `}`);
        injectParamsInto(ps, pj);
    }
    assert(rl.apply(), "fixture: image.reload must apply");

    imageRowsInto(&f.doc, f.docPath, rows);
    assert(rows[1].dimensions == "21 x 22",
        "the file changed under an unchanged path: a dimensions memo keyed on "
        ~ "the PATH reads the stale '5 x 7' here; got '"
        ~ rows[1].dimensions ~ "'");
    assert(rows[1].pathText == "tex/bravo.bmp",
        "…and the path text did not move, because the path did not; got '"
        ~ rows[1].pathText ~ "'");
}

// ---------------------------------------------------------------------------
// R13 — the DOCUMENT moves, and every row re-anchors.
//
// The input people forget, because it does not live on `ImageData` at all:
// nothing on the item can be notified that a Save As moved the anchor, so the
// anchor has to be part of the key. R3 already pins that the row text follows
// the `docPath` ARGUMENT; what this adds is that it still follows once the
// memo is WARM, and that it comes BACK — a cache that stored the first anchor
// and kept answering from it is invisible to a single one-way move if the
// caller only ever asks once.
//
// Discriminating: the new anchor is `tex/`, under which all three images
// resolve to three DIFFERENT forms — a sibling, a parent-relative, and an
// absolute — and none of the three equals its form under the old anchor. An
// anchor-blind memo reads three stale strings; a memo that re-anchors only the
// first row reads one new and two stale.
// ---------------------------------------------------------------------------
unittest {
    import std.path : isAbsolute;

    auto f = makeRowFixture("rows_memo_anchor");
    ImageRow[] rows;
    imageRowsInto(&f.doc, f.docPath, rows);      // WARMS every row's memo
    immutable a0 = rows[0].pathText;
    immutable a1 = rows[1].pathText;
    immutable a2 = rows[2].pathText;
    assert(a0 == "alpha.bmp" && a1 == "tex/bravo.bmp" && a2 == "../charlie.bmp",
        "control: the warm state is the one R2 pins");

    // Save As into `tex/` — the same document, one directory deeper.
    immutable inner = buildPath(f.dir, "scene", "tex", "inner.v3d");
    imageRowsInto(&f.doc, inner, rows);

    assert(rows[1].pathText == "bravo.bmp",
        "the image beside the new document is now a bare name; got '"
        ~ rows[1].pathText ~ "'");
    assert(rows[0].pathText == "../alpha.bmp",
        "the image one directory up takes the parent anchor; got '"
        ~ rows[0].pathText ~ "'");
    assert(isAbsolute(rows[2].pathText),
        "and the image neither anchor reaches goes absolute; got '"
        ~ rows[2].pathText ~ "'");
    assert(rows[0].pathText != a0 && rows[1].pathText != a1
        && rows[2].pathText != a2,
        "vacuity guard: all three forms really did change, so 'the rows "
        ~ "re-anchored' is a difference this fixture can express");

    // …and back to where the document was. Restoring the ORIGINAL three forms
    // is what separates a memo that re-checks its anchor from one that simply
    // overwrote itself with the last thing it was asked for.
    imageRowsInto(&f.doc, f.docPath, rows);
    assert(rows[0].pathText == a0 && rows[1].pathText == a1
        && rows[2].pathText == a2,
        "the rows re-anchor back; got '" ~ rows[0].pathText ~ "', '"
        ~ rows[1].pathText ~ "', '" ~ rows[2].pathText ~ "'");
}

// ---------------------------------------------------------------------------
// R14 — the CUT's two inputs move, and the line follows.
//
// R11 proves the elided line is memoised; this proves the memo is still a
// cache and not a snapshot. Two inputs, and a plausible implementation gets
// each one wrong on its own:
//
//   * THE BUDGET. It is not a field of anything — the panel derives it from
//     the content width it has on the frame it is drawing, so it moves when
//     the window is resized. A memo keyed on the row TEXT alone is the obvious
//     shape ("the width hardly ever changes"), it passes R11 in full, and it
//     pins the first width the panel was ever drawn at for the rest of the
//     session: widen the panel and the paths stay chopped.
//   * THE TEXT. A memo keyed on the budget alone survives every resize and
//     shows the previous file's path after a replace.
//
// Discriminating, and this is why the budget pair is 8 and 16 rather than two
// arbitrary numbers: at 8 all three of this fixture's paths cut, at 16 none of
// them do. So the two answers differ on EVERY row, in both directions — a
// budget-blind memo warmed at 8 reads a chopped 'alpha.b…' where 'alpha.bmp'
// is due, and one warmed at 16 reads the whole path where a cut is due. A pair
// that cut at both widths would still discriminate, but a pair that cut at
// NEITHER (say 40 and 60) would read the same string either way and prove
// nothing at all — the inert shape this section is full of warnings about.
//
// The OTHER two rows are asserted unchanged at each step, so a single memo
// shared by all items rather than one per item reads differently.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;

    auto f = makeRowFixture("rows_memo_cut");
    ImageRow[] rows;
    imageRowsInto(&f.doc, f.docPath, rows);

    // --- warm at the floor budget, where all three cut ----------------------
    assert(elidedPathText(rows[0], 8) == "alpha.b…", "control, row 0: got '"
        ~ elidedPathText(rows[0], 8) ~ "'");
    assert(elidedPathText(rows[1], 8) == "tex/bra…", "control, row 1: got '"
        ~ elidedPathText(rows[1], 8) ~ "'");
    assert(elidedPathText(rows[2], 8) == "../char…", "control, row 2: got '"
        ~ elidedPathText(rows[2], 8) ~ "'");

    // --- the panel is widened: the budget moves and nothing else ------------
    assert(elidedPathText(rows[0], 16) == "alpha.bmp",
        "a wider panel shows the whole path. A memo keyed on the row text "
        ~ "alone answers from the budget it was warmed at and reads "
        ~ "'alpha.b…' here — chopped for the rest of the session; got '"
        ~ elidedPathText(rows[0], 16) ~ "'");
    assert(elidedPathText(rows[1], 16) == "tex/bravo.bmp",
        "…and so does row 1; got '" ~ elidedPathText(rows[1], 16) ~ "'");
    assert(elidedPathText(rows[2], 16) == "../charlie.bmp",
        "…and row 2; got '" ~ elidedPathText(rows[2], 16) ~ "'");

    // …and narrowed again. Restoring the original three cuts separates a memo
    // that re-checks its budget from one that merely overwrote itself with the
    // last thing it was asked for.
    assert(elidedPathText(rows[0], 8) == "alpha.b…"
        && elidedPathText(rows[1], 8) == "tex/bra…"
        && elidedPathText(rows[2], 8) == "../char…",
        "narrowing the panel cuts them again");

    // --- the row TEXT moves under an unchanged budget -----------------------
    immutable newPath = buildPath(f.dir, "scene", "other", "renamed.bmp");
    writeTestBmp(newPath, 9, 4);

    auto rep = new ImageReplace(f.doc.activeMesh(), f.view, EditMode.Vertices,
                                &f.doc, null);
    {
        auto ps = rep.params();
        auto pj = parseJSON(`{"index":` ~ to!string(f.doc.indexOf(f.bravo))
                            ~ `,"path":` ~ jsonString(newPath) ~ `}`);
        injectParamsInto(ps, pj);
    }
    assert(rep.apply(), "fixture: image.replace must apply");

    imageRowsInto(&f.doc, f.docPath, rows);
    assert(rows[1].pathText == "other/renamed.bmp",
        "precondition (R12's ground): the row text followed the replace, or "
        ~ "the cut below has nothing new to cut; got '"
        ~ rows[1].pathText ~ "'");
    assert(elidedPathText(rows[1], 8) == "other/r…",
        "the drawn line follows the row text. A memo keyed on the BUDGET "
        ~ "alone reads the previous file's 'tex/bra…' here; got '"
        ~ elidedPathText(rows[1], 8) ~ "'");
    assert(elidedPathText(rows[0], 8) == "alpha.b…"
        && elidedPathText(rows[2], 8) == "../char…",
        "one item's change moves one item: a single memo shared by every row "
        ~ "would drag its neighbours along");
}

