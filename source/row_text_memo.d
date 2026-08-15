module row_text_memo;

// ---------------------------------------------------------------------------
// THE CLIP-ROW TEXT MEMO (task 0721, audit №4 item D10).
//
// D10's finding is right and its PRESCRIPTION IS NOT AVAILABLE, so this file
// is the half of it that is. The finding: a UI cache was declared in the
// middle of `document.d`, whose own header promises "no GL, no render, no UI".
// The prescription: move it to `ui/`. That cannot be done — the struct is a
// FIELD of `ImageData`, which is the document's image payload, so putting the
// declaration under `ui/` would make `document.d` import `ui.*` and invert the
// dependency the finding is about. Worse than the state it fixes.
//
// So the memo moves to a LEAF instead: this module imports nothing, `ui/` and
// `document/` both import it, and neither depends on the other through it.
// `document.d` stops DECLARING a rendering cache while still holding the field.
//
// The remaining half — getting the memo off the document object entirely, into
// a side table the panel owns — is a redesign with a real lifetime question,
// and task 0635 put it here for measured reasons (there is no hook site: two
// of the three inputs are not fields of the object at all). It is filed as
// 0771 rather than smuggled in here.
// ---------------------------------------------------------------------------

/// Task 0635 — cached RENDERINGS of `ImageData`'s fields, for the clip list's
/// draw path.
///
/// WHY: the clip list rebuilt every row's text from scratch, once per row on
/// every frame the panel was open. MEASURED over 600 frames on 1 mesh + 20
/// clips: 5120 bytes/frame for `imageRowsInto` alone, of which 4160 (81%) was
/// the document-relative path and 960 the dimensions cell — ≈300 KiB/s of GC
/// churn on the UI thread, growing with the number of rows. All three
/// renderings are pure functions of inputs that do not change between frames,
/// which is the whole reason this is memoisable at all.
///
/// THE ELIDED LINE IS THE SLOT THAT WAS MISSING, and it is here because the
/// first cut of this struct left it out on a measurement that could not see
/// it — an inert zero, in the shape this task exists to stop. The header
/// of `ui/image_rows.d` said `elideEnd` cost zero; the harness behind that
/// number drove `imageRowsInto`, which does not call `elideEnd` at all — the
/// panel does, one call per row, straight after the row build. Both the
/// cutting and the non-cutting variant therefore read the same 0 and the
/// re-measurement looked like corroboration. Measured through a call that
/// really reaches it, `elideEnd` allocates 48 bytes per cutting row at the
/// panel's floor budget of 8 and 80 at its default 16; only a path SHORTER
/// than the budget costs nothing, because that is the branch that returns its
/// argument. See `elidedPathText` for the figures and the call path.
///
/// A THIRD CATEGORY, and the distinction is the point. The authored fields are
/// what the document SAYS; the derived fields are what the disk ANSWERED;
/// these are neither — they carry no information of their own, nothing
/// serialises them, nothing copies them across a duplicate, and throwing the
/// whole struct away can only cost time. That is what makes it safe to park
/// them on the same object as the two halves that do mean something.
///
/// KEYED, NOT HOOKED — each slot stores the inputs it was computed from and is
/// used only while those still compare equal, rather than being cleared by
/// whoever mutates an input. A hook would have to be added at every mutation
/// site and there are already three shapes of site that would not get one:
///
///   * `image.replace`'s REVERT writes `storedPath` and the four derived
///     fields back directly and never calls `refreshImageMeta` (deliberately —
///     it restores the document as it was rather than re-reading a disk that
///     may have moved on). A cache cleared only in `refreshImageMeta` would
///     show the replacement's path for the rest of the session after an undo.
///   * `layer.duplicate` builds a fresh payload by copying seven fields; a
///     hook there is one more field to remember.
///   * the DOCUMENT PATH is not a field on this object at all. Nothing here
///     can be notified that a Save As moved the anchor, so the anchor has to
///     be part of the key no matter what the other half does.
///
/// A key cannot be forgotten at a mutation site that does not exist yet.
///
/// WHAT MUST NOT BE MEMOISED HERE, stated so it is not added by analogy:
/// `resolveStoredPath` (the other direction) calls `exists()`. Its answer
/// changes when a file appears or disappears with no mutation to the document
/// at all, so it has no key — which is exactly why `resolvedPath` is not a
/// field on `ImageData` either (see the note above). `storePathFor` touches
/// the filesystem nowhere: it is `buildNormalizedPath` + `relativePath` over
/// two strings, and that is the property this whole struct rests on.
///
/// WRITTEN FROM THE DRAW PATH, AND ONLY FROM IT. Every slot is filled by the
/// function that reads it, on a MISS, which makes those three functions
/// mutators of the document however read-only they look from the call site.
/// The clip panel is their only caller and it runs on the UI thread, but they
/// are public, so each one guards its write with `glThreadGuard` — the miss is
/// a cold branch, so the check is paid per input change rather than per frame.
/// See `ui/image_rows.d`'s `imageRowsInto` for the full statement.
///
/// The three `…Valid` flags model "no entry yet", which is a different state
/// from "an entry whose value is the empty string" and cannot be inferred from
/// the key. `dimsValid` is the one that demonstrably earns its byte: a born
/// slot keys as `(0, 0, false)`, and a payload really carrying that
/// measurement renders `"0 x 0"`, so without the flag the born slot would hand
/// back `""` for it.
struct RowTextMemo {
    // --- the document-relative path text: `io.image_path.storePathForItem` ---
    string storeText;     ///< the memoised value
    string storeSource;   ///< the `storedPath` it was computed from
    string storeAnchor;   ///< the document path it was anchored at
    bool   storeValid;    ///< false until the first computation

    // --- the dimensions cell: `ui.image_rows.dimensionsTextFor` ---
    string dimsText;      ///< the memoised value
    int    dimsW, dimsH;  ///< the measurement it was computed from
    bool   dimsMissing;   ///< …and the third input, which empties the cell
    bool   dimsValid;     ///< false until the first computation

    // --- the elided path line: `ui.image_rows.elidedPathText` ---
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
