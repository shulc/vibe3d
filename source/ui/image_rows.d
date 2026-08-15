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
// three figures are now memoised (`RowTextMemo` and the side table below,
// task 0635; moved off `ImageData`/`document.d` by task 0771): a frame in
// which neither the document nor the panel width changed allocates nothing
// at all, so the per-frame cost no longer scales with the row count.
//
// `imageRowsInto` fills the caller's buffer in place (the
// `Document.referrersOf` / `selectedItemsInto` idiom) so a panel holding one
// static buffer does not churn an array per frame. What is deliberately NOT
// on this path is `Document.referrersOf` — its own doc comment forbids a
// draw-path call — so "is this image in use" is asked once, at CLICK time,
// through `imageRemoveConfirmText`.
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

// ---------------------------------------------------------------------------
// THE ROW TEXT MEMO (task 0635, moved here by task 0771).
//
// Cached RENDERINGS of an image item's fields, for this module's three
// per-row-per-frame text builders (`storePathForItem`, `dimensionsTextFor`,
// `elidedPathText` below). WHY: the clip list rebuilt every row's text from
// scratch, once per row on every frame the panel was open. MEASURED over 600
// frames on 1 mesh + 20 clips: 5120 bytes/frame for `imageRowsInto` alone, of
// which 4160 (81%) was the document-relative path and 960 the dimensions
// cell — ~300 KiB/s of GC churn on the UI thread, growing with the row count.
// All three renderings are pure functions of inputs that do not change
// between frames, which is the whole reason this is memoisable at all.
//
// A THIRD CATEGORY, and the distinction is the point. The authored fields on
// `ImageData` are what the document SAYS; the derived fields are what the
// disk ANSWERED; these renderings are neither — they carry no information of
// their own, nothing serialises them, nothing copies them across a
// duplicate, and losing the whole cache can only cost time.
//
// KEYED, NOT HOOKED — each slot stores the inputs it was computed from and is
// used only while those still compare equal, rather than being cleared by
// whoever mutates an input. A hook would have to sit at every mutation site
// and there are three shapes of site that would not get one: `image.replace`
// REVERT writes `storedPath` and the four derived fields back directly and
// never calls `refreshImageMeta`; `layer.duplicate` builds a fresh payload by
// copying fields, one more to remember; and the DOCUMENT PATH is not a field
// of anything here at all, so nothing could be notified a Save As moved the
// anchor even if it wanted to be. A key cannot be forgotten at a mutation
// site that does not exist yet.
//
// WHY THIS IS A SIDE TABLE AND NOT A FIELD OF `ImageData` (task 0771, closing
// the half 0721 left open). D10's finding was right twice over: a UI cache
// had no business being DECLARED in `document.d` (0721 fixed that — the type
// moved to a leaf module) and it had no business being HELD by the document's
// own payload class either, because it carries no information the document
// owns. The reason it took a second task is the reason it could not simply
// move to `ui/` in one step: `storePathForItem` — one of the three writers —
// lived in `io/image_path.d`, and `io/` must not import `ui/`. Its only
// caller was always this module, though (checked: `grep -rn
// storePathForItem source/` before this move found exactly one caller
// outside its own declaration), so it moves here bodily rather than staying
// behind as a stub; `io/image_path.d` keeps only the pure, uncached
// `storePathFor` it used to wrap.
//
// LIFETIME — the real question 0771 was filed to answer, because a table
// keyed by `ImageData` OBJECT IDENTITY holds a GC-STRONG reference to every
// key: an entry that outlives its clip is not a slow leak, it is a hard one,
// and there is no delete/undo hook to clear it FROM (see the KEYED-NOT-HOOKED
// paragraph above — two of the three inputs are not fields of any object at
// all, so a mutation-site hook has nowhere to stand even for the one input
// that is). The answer is a SWEEP, not a hook, riding the one pass that
// already visits every live row: `imageRowsInto` bumps `g_rowTextSweep` on
// entry and, via `scope(exit)`, prunes on the way out. Every one of the three
// memo functions stamps the slot it touches with the CURRENT sweep value
// (`touchRowTextMemo`, below); anything left with an OLDER stamp when
// `imageRowsInto` returns did not appear in `document.layers` this call and
// is removed. A deleted clip's entry therefore survives at most until the
// panel's NEXT draw, and if the panel never draws again the table cannot grow
// either — nothing else ever writes to it. `scope(exit)` rather than a
// trailing statement: `imageRowsInto` returns early when there are no image
// rows at all, and that empty-list call is exactly the one that must still
// prune a table that went from N clips to zero.
//
// ZERO-ALLOCATION ON A WARM FRAME, the property task 0635's own regression
// test (`R11`, below) pins to the byte, survives the move: a lookup of an
// EXISTING key and a `foreach` over the table that removes nothing are both
// plain reads over already-allocated bucket storage — no different from the
// per-item field access this replaces. Confirmed by construction, not by
// hope: the swept-but-nothing-stale case is the WARM case, and it is the
// only case `R11` measures with an `== 0` assertion.
//
// THE ELIDED LINE IS THE SLOT THAT WAS MISSING when this struct was first
// cut, and it is called out because the miss was a measurement artefact
// rather than an oversight anyone could have read off the code: the first
// harness drove `imageRowsInto`, which does not call `elideEnd` at all — the
// panel does, once per row, straight after the row build — so the cutting
// and the non-cutting build read the same zero and the agreement looked like
// corroboration. Measured through a call that really reaches it, `elideEnd`
// allocates 48 bytes per cutting row at the panel's floor budget of 8 and 80
// at its default 16; only a path SHORTER than the budget costs nothing,
// because that is the branch that returns its argument.
//
// The three `…Valid` flags model "no entry yet", which is a different state
// from "an entry whose value is the empty string" and cannot be inferred from
// the key. `dimsValid` is the one that demonstrably earns its byte: a born
// slot keys as `(0, 0, false)`, and a payload really carrying that
// measurement renders `"0 x 0"`, so without the flag the born slot would hand
// back `""` for it.
//
// WRITTEN FROM THE DRAW PATH, AND ONLY FROM IT. Every slot is filled by the
// function that reads it, on a MISS, which makes those three functions
// mutators of this table however read-only they look from the call site. The
// clip panel is their only caller and it runs on the UI thread, but they are
// public, so each one guards its RECOMPUTE branch with `glThreadGuard` — the
// miss is a cold branch, so the check is paid per input change rather than
// per frame. The stamp write on a HIT is not separately guarded: it is a
// same-thread bookkeeping write under the identical "UI thread only" rule the
// three functions already state, not a second write path.
// ---------------------------------------------------------------------------

private struct RowTextMemo {
    // --- the document-relative path text: `storePathForItem` ---
    string storeText;     ///< the memoised value
    string storeSource;   ///< the `storedPath` it was computed from
    string storeAnchor;   ///< the document path it was anchored at
    bool   storeValid;    ///< false until the first computation

    // --- the dimensions cell: `dimensionsTextFor` ---
    string dimsText;      ///< the memoised value
    int    dimsW, dimsH;  ///< the measurement it was computed from
    bool   dimsMissing;   ///< …and the third input, which empties the cell
    bool   dimsValid;     ///< false until the first computation

    // --- the elided path line: `elidedPathText` ---
    //
    // The BUDGET is the second input and it is not a field of anything: the
    // panel derives it from the width available on the frame it is drawing
    // (`avail / charWidth`, floored at 8), so it moves when the window is
    // resized and at no other time. That is why it is keyed and not hooked,
    // for the same reason the document path is — there is nowhere to hang a
    // notification.
    string elideText;     ///< the memoised value
    string elideSource;   ///< the row text it was computed from
    size_t elideBudget;   ///< …and the code-point budget it was cut to
    bool   elideValid;    ///< false until the first computation
}

private struct RowTextMemoSlot {
    RowTextMemo memo;
    size_t      touchedAt;  ///< the `g_rowTextSweep` value as of the last touch
}

private __gshared RowTextMemoSlot[ImageData] g_rowTextMemo;  // UI thread only
private __gshared size_t                     g_rowTextSweep; // UI thread only

/// Get-or-create `img`'s memo slot and stamp it as seen in the CURRENT sweep.
/// Every one of the three memo functions below goes through this rather than
/// touching `g_rowTextMemo` directly, so "reached the table this call" and
/// "survives `sweepRowTextMemo`" cannot drift apart.
private ref RowTextMemo touchRowTextMemo(ImageData img) {
    auto slot = img in g_rowTextMemo;
    if (slot is null) {
        g_rowTextMemo[img] = RowTextMemoSlot.init;
        slot = img in g_rowTextMemo;
    }
    slot.touchedAt = g_rowTextSweep;
    return slot.memo;
}

/// Drop every entry `touchRowTextMemo` did NOT touch during the sweep that
/// just finished — i.e. every `ImageData` `imageRowsInto`'s last call did not
/// walk past. See the section comment above for why this, and not a hook, is
/// the table's whole lifetime policy.
private void sweepRowTextMemo() {
    foreach (img, ref slot; g_rowTextMemo)
        if (slot.touchedAt != g_rowTextSweep) g_rowTextMemo.remove(img);
}

/// `storePathFor` for an image ITEM, memoised on the side table above (task
/// 0635; moved off `io/image_path.d` and off `ImageData` by task 0771 — see
/// the section comment for why both moves were needed).
///
/// Same value as `storePathFor(img.storedPath, docPath)` — this is a cache in
/// front of that function and nothing else; if the two could ever disagree
/// the cache would be a second rule, which is the thing the whole
/// storage/display story exists to avoid.
///
/// WHY IT EXISTS: the clip list calls this once per row per frame while its
/// panel is open, and `storePathFor` allocates (four transient strings, none
/// of which survive the row). Measured over 600 frames on 1 mesh + 20 clips,
/// it was 81% of the row build's 5120 bytes/frame.
///
/// WHY IT IS SAFE: `storePathFor` reads no file — it is `buildNormalizedPath`
/// + `relativePath` over two strings — so its answer is a total function of
/// the pair `(storedPath, docPath)`, which is exactly the pair kept beside
/// the cached value. `resolveStoredPath` (`io/image_path.d`) is the opposite
/// case and must never get the same treatment: it calls `exists()`, so its
/// answer changes when a file appears or disappears with nothing in the
/// document changing at all.
///
/// (One input is implicit and shared with the uncached function: a
/// `storedPath` that is not absolute is absolutised against the process CWD.
/// `storedPath` is absolute in memory by `io/image_path.d`'s storage rule,
/// and the CWD does not move between two frames of one panel, so the key is
/// complete for every reachable state.)
///
/// IT WRITES, and the guard says which thread may. See `imageRowsInto`.
string storePathForItem(ImageData img, string docPath) {
    if (img is null) return "";
    ref slot = touchRowTextMemo(img);
    if (slot.storeValid
        && slot.storeSource == img.storedPath
        && slot.storeAnchor == docPath)
        return slot.storeText;

    import gl_thread_guard : glThreadGuard;
    glThreadGuard("imageRowText");

    const text = storePathFor(img.storedPath, docPath);
    slot.storeText   = text;
    slot.storeSource = img.storedPath;
    slot.storeAnchor = docPath;
    slot.storeValid  = true;
    return text;
}

/// `dimensionsText` for an image ITEM, memoised on the side table above
/// (task 0635; moved off `ImageData` by task 0771).
///
/// The second half of the row build's per-frame garbage, and the smaller one:
/// 960 of the measured 5120 bytes/frame, against the relative path's 4160. It
/// is taken anyway because the task's bar is that an open panel not allocate
/// IN PROPORTION TO THE NUMBER OF ROWS, and three `to!string`-and-concatenate
/// results per frame per row is exactly that shape — leaving it would have met
/// the byte target while leaving the property unmet.
///
/// The key is the three inputs, which are `refreshImageMeta`'s three outputs;
/// see the section comment above for why the cache is keyed on them rather
/// than cleared by whoever writes them.
///
/// IT WRITES, and the guard says which thread may. See `imageRowsInto`.
string dimensionsTextFor(ImageData img) {
    if (img is null) return "";
    ref slot = touchRowTextMemo(img);
    if (slot.dimsValid
        && slot.dimsW == img.width
        && slot.dimsH == img.height
        && slot.dimsMissing == img.missing)
        return slot.dimsText;

    import gl_thread_guard : glThreadGuard;
    glThreadGuard("imageRowText");

    const text = dimensionsText(img.width, img.height, img.missing);
    slot.dimsText    = text;
    slot.dimsW       = img.width;
    slot.dimsH       = img.height;
    slot.dimsMissing = img.missing;
    slot.dimsValid   = true;
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
/// budget the panel derived from the width it has — memoised in the side
/// table above (task 0635; moved off `ImageData` by task 0771).
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
/// `img` is the memo's KEY (task 0771 moved the memo off it into the side
/// table above) and may be null (a payload-null image item, see
/// `isImageRow`); that case falls through to the bare function, which for the
/// empty path text it carries is the no-allocation branch anyway.
///
/// IT WRITES, and the guard says which thread may. See `imageRowsInto`.
string elidedPathText(ImageData img, string pathText, size_t maxChars) {
    if (img is null) return elideEnd(pathText, maxChars);
    ref slot = touchRowTextMemo(img);
    if (slot.elideValid
        && slot.elideBudget == maxChars
        && slot.elideSource == pathText)
        return slot.elideText;

    import gl_thread_guard : glThreadGuard;
    glThreadGuard("imageRowText");

    const text = elideEnd(pathText, maxChars);
    slot.elideText   = text;
    slot.elideSource = pathText;
    slot.elideBudget = maxChars;
    slot.elideValid  = true;
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
/// half. Since task 0635 the three text helpers below fill a memo when they
/// miss — on the ITEM itself until task 0771, now in this module's own side
/// table (`g_rowTextMemo`, above `dimensionsTextFor`) — so building the rows
/// WRITES to that table for every item whose inputs moved since the last
/// frame, AND stamps every item this call walked past so the table's own
/// sweep can tell a live entry from a stale one. What that write is and is
/// not:
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
    // Task 0771 — the memo table's whole lifetime policy: bump the sweep
    // BEFORE walking any row, and prune on the way OUT regardless of which
    // return below fires (including the empty-list one right after this,
    // which is exactly the call that must still notice a document that went
    // from N image items to zero). See `sweepRowTextMemo`'s doc comment.
    ++g_rowTextSweep;
    scope(exit) sweepRowTextMemo();

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
        ~ "allocating: the path and dimensions text are memoised."
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
