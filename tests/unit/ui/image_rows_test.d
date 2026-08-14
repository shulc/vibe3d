// Module unittests for `ui.image_rows`, moved verbatim out of source/ui/image_rows.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ui.image_rows_test;

import document        : Document, Layer, ImageData;
import io.image_path   : storePathForItem;
import std.file : exists, remove;
import std.path : buildPath;
import std.json : parseJSON;
import document                : ItemKind, Document, Layer;
import io.image_path           : writeTestBmp, imageTestDir, refreshImageMeta;
import commands.image.commands : ImageLoad, ImageReplace, ImageReload;
import commands.layer.commands : LayerAdd;
import params                  : injectParamsInto;
import mesh                    : makeCube;
import view                    : View;
import editmode                : EditMode;
import seltype                 : SelMode;
import std.json : JSONValue;
import core.memory : GC;
import std.conv    : to;
import std.range   : walkLength;
import ui.image_rows;

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

    // ADD, not Set (task 0668): an exclusive select of a clip leaves NO
    // primary, and the index assertion below turns on the primary being a
    // DIFFERENT, live layer — against `null` it could not tell an
    // implementation that reads `activeIndex` from one that reads the focus.
    f.doc.selectItem(f.bravo, SelMode.Add);
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
