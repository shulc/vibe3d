module ui.item_rows;

// ---------------------------------------------------------------------------
// Task 0639 — the item list's ROW MODEL.
//
// WHY THIS MODULE EXISTS, rather than the strings being built inline in
// `drawLayerListPanel`: an ImGui panel body is not observable headlessly. An
// assertion written against the draw call can only ever say "the function
// ran" — and this repository has shipped a panel whose declared contents were
// rendered nowhere while the test that asserted the declaration passed the
// whole time. So the panel is split in two, exactly as `ui/image_rows.d`
// already splits the Images list:
//
//   * this module answers "WHAT would the list show" — pure, allocation-only,
//     no ImGui, no globals (the document path and the dirty flag are
//     PARAMETERS, not calls to `currentDocPath()` / `docDirty()`), and
//     therefore fully assertable by the in-module tests at the bottom;
//   * `ui/panels.d`'s `drawLayerListPanel` answers "where on screen", and
//     `ui/item_glyphs.d` answers "which pixels" — neither of which any test
//     here claims to cover.
//
// The assertions below are about ROW CONTENT — the name a row shows, the
// glyph it draws, its indent depth, its role, which row is current — never
// about a row having been declared.
//
// ---------------------------------------------------------------------------
// Ph0 DECISION — WHAT A TYPE "ICON" IS HERE, and what it cost.
//
// Three options were priced before anything else was touched, because if
// icons were unaffordable the rest of the task still pays for itself and
// building around an assumption would have been the expensive mistake.
//
//   (a) GLYPHS FROM THE FONT — REJECTED, and not on grounds of taste. Two
//       independent facts kill it. First, `app.d`'s font setup loads the
//       vector UI face only `if (!command.g_testMode)`; a `--test` run keeps
//       ImGui's built-in bitmap font, which carries Latin-1 and nothing else.
//       Second, the normal-run glyph ranges are Basic Latin + Latin-1 +
//       Cyrillic + six punctuation code points — every geometric/pictographic
//       block (U+25xx, U+2B xx, the private-use ranges an icon font would
//       use) is outside them, and the shipped text face is a text face: it
//       does not contain object pictograms to rasterize even if the range
//       were widened. A row glyph would therefore be a blank box in the tests
//       AND a blank box in the app. Cost to fix properly: source or subset an
//       icon face, add it to the atlas, widen the ranges, and then decide
//       what `--test` does about the metric shift a second font introduces.
//
//   (b) A BITMAP ICON SET OF OUR OWN — REJECTED as disproportionate. It needs
//       artwork per kind, an atlas asset, a decode, and a GL texture with an
//       owner and a release path across every whole-document replacement.
//       That is a GPU resource introduced into a panel that owns none today,
//       for four pictures a dozen pixels across.
//
//   (c) VECTOR GLYPHS DRAWN INTO THE WINDOW'S DRAW LIST — TAKEN. Zero assets,
//       zero font work, no `--test` divergence (the shapes are geometry, not
//       text, so they rasterize identically in both fonts' absence), and the
//       primitives are already used in this codebase (`snap_render.d`,
//       `app.d`'s viewport overlays). The whole cost is `ui/item_glyphs.d`.
//
// What the model owns is the CHOICE of glyph — a named token per row, which
// is assertable here. What `ui/item_glyphs.d` owns is the shape that token
// draws, which is not.
// ---------------------------------------------------------------------------

import document : Document, Layer, ItemKind, kindInfo;

/// The glyph a row draws in its TYPE cell.
///
/// A TOKEN, not a shape: the shape lives in `ui/item_glyphs.d`. Keeping the
/// choice here is what makes "a plane row draws the plane glyph" a headless
/// assertion instead of a claim about pixels nobody can read.
enum ItemGlyph : ubyte {
    None = 0,   ///< nothing to draw
    Scene,      ///< the document root row
    Mesh,
    Empty,
    Plane,
}

/// What a row reports in its ROLE cell — the item-selection state, as ONE
/// three-valued token.
///
/// It replaces two controls the panel used to draw side by side: a `>`/`@`/`*`
/// text marker, and an "F" checkbox that reported `Document.foreground(l)` —
/// `visible && selected`. That checkbox CONFLATED two independent facts, so a
/// cleared box could mean "not selected" or "hidden" with no way to tell
/// which. Here `visible` is its own cell and this one is purely about the
/// selection, so "foreground" is the conjunction of the two and neither fact
/// hides the other.
///
/// ---------------------------------------------------------------------------
/// TASK 0672 — WHAT THIS ENUM USED TO SAY, AND WHY IT NO LONGER SAYS IT.
///
/// It had two more values, and the pair of them was the owner-reported bug:
///
///   ~~`Focus`   — the item-selection FOCUS, but not the mesh edit target~~
///   ~~`Primary` — the mesh edit target (ALWAYS SELECTED + VISIBLE)~~
///
/// The parenthesis is the claim that was tested and is now FALSE. It held
/// while task 0654's invariant kept "is the edit target" and "is selected"
/// welded together. Task 0671 made the edit target the head of a walk over
/// *[current selection] ++ [deselect history]*, so a mesh stays the target
/// after it has been deselected — and a `Primary` row that is not selected at
/// all became reachable by the plainest route there is: create an image plane,
/// which selects the plane and deselects the mesh. `isCurrentRole` then drew
/// that row with the highlight AND the accent ink, i.e. as selected, which is
/// the report: "the mesh layer still looks selected. It is not selected."
///
/// The fix is not a second colour for the target. It is MEASURED (Ph0/Ph1,
/// `tests/fixtures/item_row_appearance.json`) that the reference does not draw
/// the edit target at all: a row that is the target but not selected is
/// pixel-identical to a row that is neither — 0 px of 15 225, on two rows, in
/// two independent boots, with the lever that swaps *which* of two foreground
/// meshes is the target moving nothing. What its third treatment marks is the
/// **first element of the item selection**, whatever its kind — a locator that
/// can never be a mesh edit target takes it while the mesh that IS the target
/// sits in the other shade.
///
/// So the target and the focus are not row treatments here either, and the
/// three values below are the three the measurement found. `Document` still
/// answers `isPrimary` / `isFocused`; this list simply does not ask.
/// ---------------------------------------------------------------------------
///
/// The ordering is deliberate: each value is strictly more specific than the
/// one before it.
enum RowRole : ubyte {
    None = 0,       ///< not in the item selection (derived background)
    Selected,       ///< in the item selection, but not its first element
    SelectedFirst,  ///< the FIRST element of the item selection, any kind
}

/// One drawn row's COLOUR, as plain channel bytes.
///
/// Bytes rather than a packed `IM_COL32` because this module is deliberately
/// ImGui-free (see the header): the panel packs. It also makes the assertion a
/// test writes read as the value a pixel would take, which is the whole point
/// of moving the choice out of the draw call — an ImGui panel body has no
/// headless observable, so a colour decided inside `drawLayerListPanel` can
/// only ever be asserted as "the function ran".
///
/// `a == 0` means DRAW NOTHING, which is a different statement from drawing
/// the panel's own backdrop colour: an unselected row has no fill of its own.
struct RowColor {
    ubyte r, g, b, a;
}

/// The pixels a row is drawn with: its background fill and its ink (the name
/// text, and every glyph on the row).
struct RowLook {
    RowColor background;  ///< the whole-row fill; `a == 0` = no fill
    RowColor ink;         ///< name text and glyphs
}

// The palette. Two shades for the two SELECTED treatments and nothing else —
// the relation between them is the reference's own (task 0672): the row that
// is not first in the selection is the first one's background LIGHTENED by 8
// per channel and its ink dimmed by 11/12/12, rather than a new colour. The
// values themselves are ours: the panel runs on a light grey backdrop where
// the reference's are unreadable, and the fixture is explicit that what ports
// is the partition, not the RGBs.
private enum RowColor kInk          = RowColor(  0,   0,   0, 255); // ordinary
private enum RowColor kInkOff       = RowColor( 97,  97,  97, 255); // greyed
private enum RowColor kBgFirst      = RowColor( 88,  88,  96, 255);
private enum RowColor kBgSelected   = RowColor( 96,  96, 104, 255);
private enum RowColor kInkFirst     = RowColor(255, 176,  75, 255);
private enum RowColor kInkSelected  = RowColor(244, 164,  63, 255);
private enum RowColor kInkFirstDim  = RowColor(158, 120,  74, 255);
private enum RowColor kInkSelDim    = RowColor(147, 108,  62, 255);

/// The row's look — the ONE place a row's colours are decided.
///
/// ITS SIGNATURE IS THE LOAD-BEARING PART. It cannot see the `Document`, the
/// edit target or the focus, so "the target is not a row treatment" is a
/// property of what this function is ABLE to read rather than of a branch
/// someone can add back. Re-introducing the reported bug means changing this
/// signature, which is a visible act.
///
/// `dimmed` — "selected, but the item gizmo will not move this row" — is the
/// one cue that is ours rather than the reference's, and it is orthogonal to
/// the three treatments: it re-inks a SELECTED row and can never fire on an
/// unselected one, so it cannot reach the state this task is about.
RowLook lookOf(RowRole role, bool dimmed) pure nothrow @nogc @safe {
    final switch (role) {
        case RowRole.None:
            // No fill at all — the panel's own backdrop shows through. The
            // edit target that is not selected lands HERE, which is the whole
            // point of task 0672.
            return RowLook(RowColor(0, 0, 0, 0), dimmed ? kInkOff : kInk);
        case RowRole.Selected:
            return RowLook(kBgSelected, dimmed ? kInkSelDim : kInkSelected);
        case RowRole.SelectedFirst:
            return RowLook(kBgFirst, dimmed ? kInkFirstDim : kInkFirst);
    }
}

/// What an unnamed item shows. The SAME literal `ui/image_rows.d` uses, on
/// purpose: two lists over the same `document.layers` must not disagree about
/// what an item with no name is called.
enum string kUnnamedText = "(unnamed)";

/// What the root row calls a document that has never been saved. The same
/// word the window title uses (`app.d`, "untitled"), so the two surfaces
/// naming one document name it identically.
enum string kUntitledDocText = "untitled";

/// The unsaved-changes marker on the root row.
///
/// TRAILING, where the window title puts it in front. That is a deliberate
/// divergence from our own title bar and it follows the reference's list: in
/// a column of names the left edge is the scan axis, and a leading punctuation
/// character on one row shifts that row's first letter out of the column.
enum string kDirtyMark = "*";

/// `ItemRow.index` for the root row, which names no layer.
enum size_t kNoLayerIndex = size_t.max;

/// One drawn row: exactly the cells the panel puts on screen, already in
/// display form. Display form rather than raw values is what makes a test
/// discriminating — a wrong implementation reads a DIFFERENT STRING or a
/// DIFFERENT TOKEN here, where a model of raw fields would have let the
/// presentation bug live in the untested half.
struct ItemRow {
    /// Index into `document.layers` — NOT the row's ordinal, and
    /// `kNoLayerIndex` on the root. Every command the panel dispatches
    /// (`layer.select`, `layer.rename`, `layer.setVisible`, `layer.delete`,
    /// `layer.reorder`) is addressed by document index; the list both hides
    /// items (a document RESOURCE kind) and prepends a root, so an
    /// implementation that passed the ordinal would target a different layer
    /// for nearly every row.
    size_t index = kNoLayerIndex;

    /// The item itself, or `null` on the root. Identity is the only reliable
    /// handle: an index is spliced by `layer.delete` and permuted by
    /// `layer.reorder`.
    Layer layer;

    string name;        ///< what the name cell shows
    /// What the inline rename editor STARTS with — the item's raw `name`
    /// field, which is `""` for an unnamed item, NOT the `name` above.
    /// Seeding the editor with the display form means double-clicking an
    /// unnamed row prefills the literal placeholder and Enter renames the
    /// item to it, after which "no name" can never be recovered.
    string renameSeed;

    ItemGlyph glyph;    ///< the TYPE cell
    /// Indent depth: 0 for the root, 1 for a top-level item, +1 per ancestor
    /// that is itself a row. Real state, not a constant — `layer.parent` is a
    /// user-reachable command and a parented item is drawn under its parent.
    int depth;
    RowRole role;       ///< the ROLE cell
    /// The colours this row is drawn with — `lookOf(role, dimmed)`, carried on
    /// the row so a test can read the END of the chain (`itemRowsInto` →
    /// `roleOf` → `lookOf`) rather than re-deriving the middle of it.
    RowLook look;

    bool isRoot;            ///< the scene root (no layer, no dispatch)
    bool visible;           ///< the EYE cell's state
    /// Whether the eye cell is drawn at all. FALSE on the root: there is no
    /// document-wide visibility state behind it, and a disabled eye that
    /// cannot be clicked is exactly the dead ornament this task forbids.
    bool canToggleVisible;
    bool canRename;         ///< false on the root (nothing to rename)
    /// Selected, but the item gizmo will NOT move it. Drawn greyed, so "this
    /// does not move" is visible instead of being discovered by dragging.
    ///
    /// A MOVING-SET fact, and the only cue on this row that is ours rather
    /// than the reference's (task 0672 measured no dimming there at all). It
    /// keys on `Document.isTransformTarget`, so it fires only on a row that is
    /// SELECTED — an unselected edit target is never dimmed, and the state
    /// this task exists to fix is out of its reach. Where it does correlate
    /// with the edit target is the one narrowing our transform model has: a
    /// mesh-less item in focus moves alone, and the row that then stops moving
    /// is the mesh target. That correlation belongs to `itemTransformTargets`
    /// (task 0671, approximation D), not to this panel, which draws what the
    /// gizmo will do and nothing else.
    bool dimmed;

    /// This row is the ENTIRE item selection — so a plain (exclusive) click on
    /// it would change nothing, and the panel skips the dispatch.
    ///
    /// TASK 0672. Both click guards used to ask whether the row was the EDIT
    /// TARGET (`isCurrentRole(r.role)` on the role cell, `document.isPrimary`
    /// on the name), which was a faithful spelling of "already the sole
    /// selection" only while the target could not be unselected. After task
    /// 0671 it can: with the target latched onto a deselected mesh, clicking
    /// that mesh's row to select it back was SWALLOWED — the same defect 0671
    /// found and fixed in `app.d`'s viewport item-click guard, still standing
    /// in the panel. Asking about the selection instead makes the guard say
    /// what it means.
    bool isSoleSelection;
}

/// The TYPE token for a kind.
///
/// A `final switch`, so a kind added to `kItemKindTable` breaks THIS build
/// rather than silently drawing nothing. The compile-time proof below closes
/// the other half: a listed kind must map to a real glyph.
ItemGlyph glyphFor(ItemKind k) pure nothrow @nogc @safe {
    final switch (k) {
        case ItemKind.Mesh:       return ItemGlyph.Mesh;
        case ItemKind.Empty:      return ItemGlyph.Empty;
        case ItemKind.ImagePlane: return ItemGlyph.Plane;
        // A document RESOURCE kind is never a row here (see `isItemRow`), so
        // it has no glyph rather than a placeholder one.
        case ItemKind.Image:      return ItemGlyph.None;
    }
}

// Every kind this list SHOWS must have a glyph to show it with. Same shape as
// `document.d`'s own capability proofs, and for the same reason: a future row
// in `kItemKindTable` with `isSceneItem == true` and no arm in `glyphFor`
// would draw an empty type cell, which reads as "unknown kind" and is
// indistinguishable from a drawing bug.
private import std.traits : EnumMembers;
static foreach (k; EnumMembers!ItemKind)
    static assert(!kindInfo(k).isSceneItem || glyphFor(k) != ItemGlyph.None,
        "ItemKind." ~ k.stringof ~ " is listed in the item panel "
        ~ "(isSceneItem) but glyphFor() gives it no glyph");

/// True for the rows this list owns.
///
/// `isSceneItem` is the CAPABILITY, never `kind == ItemKind.Mesh` at a call
/// site, and it is the exact complement of the Images list's `hasImage` gate
/// — so no item can fall between the two lists and end up in neither.
private bool isItemRow(const(Layer) l) {
    return l !is null && kindInfo(l.kind).isSceneItem;
}

/// The root row's name: the document, plus the unsaved-changes marker.
///
/// The BASE NAME, not the path. A full path in a narrow list pushes the part
/// that identifies the document off the right edge; the window title made the
/// same choice for the same reason.
string documentRootName(string docPath, bool dirty) {
    import std.path : baseName;
    immutable base = docPath.length ? baseName(docPath) : kUntitledDocText;
    return dirty ? base ~ kDirtyMark : base;
}

/// The `layer.select mode:` a click on an item row dispatches, as the QUOTED
/// JSON token the panel splices — modifiers in, mode out.
///
/// Here rather than at the two call sites in `ui/panels.d` for this module's
/// standing reason: a decision taken inside an ImGui panel body has no headless
/// observable, so it can only ever be asserted as "the function ran". As a pure
/// function of the two modifier bits it is a table a unit test can read off.
///
/// The law (task 1880), stated three times over in the reference's own docs and
/// NOT the same as the viewport's:
///
///   plain  -> `set`     exclusive; drops everything else
///   Ctrl   -> `toggle`  non-sequential add, and remove on an already-selected row
///   Shift  -> `range`   the contiguous span from the anchor to this row
///
/// In the VIEWPORT Shift adds and Ctrl removes. The asymmetry is the
/// reference's, deliberate, and confirmed by the owner before this shipped.
///
/// ⚠ Ctrl+Shift together is NOT covered by any reference doc we hold. Shift
/// wins, because `range` is the only mode the pair could plausibly mean and
/// letting Ctrl win would make Shift silently inert on a two-modifier press.
/// Unmeasured — see the task card.
string itemClickMode(bool ctrl, bool shift) pure @safe {
    if (shift) return `"range"`;
    if (ctrl)  return `"toggle"`;
    return `"set"`;
}

unittest {
    // Every cell of the 2x2, because the interesting one is the pair and a
    // three-case test would not have it.
    assert(itemClickMode(false, false) == `"set"`);
    assert(itemClickMode(true,  false) == `"toggle"`);
    assert(itemClickMode(false, true)  == `"range"`);
    assert(itemClickMode(true,  true)  == `"range"`,   // Shift wins the pair
        "Ctrl+Shift must not fall back to toggle — Shift would be inert");
}

/// The row's standing in the item selection.
///
/// SELECTION FIRST AND ONLY (task 0672). This used to ask `doc.isPrimary(l)`
/// before it asked whether the row was selected at all, which is how an
/// unselected edit target came to be drawn as selected. Neither the edit
/// target nor the focus is consulted now — see `RowRole`'s comment for the
/// measurement that removed them.
private RowRole roleOf(Document* doc, Layer l) {
    if (!l.selected)            return RowRole.None;
    if (doc.isFirstSelected(l)) return RowRole.SelectedFirst;
    return RowRole.Selected;
}

/// The nearest ancestor that is itself a row, or `null` when the item hangs
/// at the top level.
///
/// Walks PAST an ancestor with no row (a `layer.parent` may name any index,
/// including a document resource) so a child does not disappear with its
/// unlisted parent, and the walk is CAP-BOUNDED for the same reason
/// `layer.parent`'s own cycle guard is: a hand-edited `.v3d` can carry a
/// cycle this process never created.
private Layer rowParentOf(Document* doc, Layer l) {
    size_t cap = doc.layers.length;
    Layer p = l.parent;
    while (p !is null && cap-- > 0) {
        if (isItemRow(p)) return p;
        p = p.parent;
    }
    return null;
}

/// Fill `outBuf` with the list's rows: the document root first, then one row
/// per scene item, each under its parent.
///
/// `docPath` / `dirty` are PARAMETERS rather than `currentDocPath()` /
/// `docDirty()` calls so this function is pure with respect to global state
/// and a test can move or dirty the document without moving the process. The
/// panel passes the globals.
///
/// `rootExpanded` false emits the root ALONE — the collapse triangle on the
/// root row is a real control, not decoration.
///
/// Fills in place (the `Document.selectedItemsInto` / `imageRowsInto` idiom)
/// so a panel holding one static buffer does not churn an array per frame.
void itemRowsInto(Document* doc, string docPath, bool dirty,
                  bool rootExpanded, ref ItemRow[] outBuf) {
    size_t n = 1;                                   // the root always exists
    if (doc !is null && rootExpanded)
        foreach (l; doc.layers) if (isItemRow(l)) ++n;
    if (outBuf.length != n) outBuf.length = n;

    size_t k = 0;
    {
        ItemRow root;
        root.isRoot           = true;
        root.index            = kNoLayerIndex;
        root.name             = documentRootName(docPath, dirty);
        root.glyph            = ItemGlyph.Scene;
        root.depth            = 0;
        root.role             = RowRole.None;
        root.look             = lookOf(RowRole.None, false);
        root.visible          = true;
        root.canToggleVisible = false;
        root.canRename        = false;
        outBuf[k++] = root;
    }
    if (doc is null || !rootExpanded) return;

    // PER-CALL SCRATCH, not state. `static` so a 60 Hz draw does not allocate
    // a fresh `bool[]` every frame — the same reason the row buffer itself is
    // filled in place, and the same class of per-frame churn this codebase has
    // been bitten by before. It is fully rewritten at the top of every call, so
    // nothing survives between calls; the tests below call this repeatedly on
    // one fixture, so a missing reset would read ONE row (the root alone) on
    // the second call and fail loudly rather than quietly.
    static bool[] emitted;
    if (emitted.length < doc.layers.length) emitted.length = doc.layers.length;
    emitted[0 .. doc.layers.length] = false;

    // ONCE, not per row: `selectedItemCount` walks `layers`, and asking it
    // inside `emit` would make a panel draw quadratic in the item count — the
    // same `@property`-in-a-loop trap this codebase has been bitten by twice.
    immutable size_t selCount = doc.selectedItemCount();

    void emit(Layer l, size_t li, int depth) {
        if (emitted[li]) return;
        emitted[li] = true;
        ItemRow r;
        r.index            = li;
        r.layer            = l;
        r.name             = l.name.length ? l.name : kUnnamedText;
        r.renameSeed       = l.name;             // RAW — see the field comment
        r.glyph            = glyphFor(l.kind);
        r.depth            = depth;
        r.role             = roleOf(doc, l);
        r.visible          = l.visible;
        r.canToggleVisible = true;
        r.canRename        = true;
        r.dimmed           = l.selected && !doc.isTransformTarget(l);
        r.look             = lookOf(r.role, r.dimmed);
        r.isSoleSelection  = l.selected && selCount == 1;
        outBuf[k++] = r;

        foreach (ci, c; doc.layers)
            if (isItemRow(c) && !emitted[ci] && rowParentOf(doc, c) is l)
                emit(c, ci, depth + 1);
    }

    foreach (i, l; doc.layers)
        if (isItemRow(l) && !emitted[i] && rowParentOf(doc, l) is null)
            emit(l, i, 1);

    // ORPHAN RESCUE, and it is load-bearing rather than defensive padding: a
    // parent CYCLE (A→B→A, reachable through a hand-edited or corrupt `.v3d`)
    // leaves every member of the cycle with a non-null row parent, so the
    // sweep above starts nowhere and the whole cycle would be absent from the
    // panel — invisible, unselectable and undeletable. Anything still
    // unemitted is listed at the top level.
    foreach (i, l; doc.layers)
        if (isItemRow(l) && !emitted[i])
            emit(l, i, 1);

    // THE EMITTED COUNT IS THE TRUTH; the pre-size above is only an upper
    // bound that saves a reallocation. This was an `assert(k == n)` and that
    // was the wrong shape: a pre-sized buffer means a walk that emits fewer
    // rows than it counted leaves DEFAULT-CONSTRUCTED rows on the end, so
    // `rows.length` reported the count that was intended rather than the one
    // produced — and the orphan-rescue test above could not see its own
    // subject, because the internal assertion fired before any assertion the
    // test wrote (and would have been stripped entirely under `-release`,
    // shipping blank rows). Truncating here makes the shortfall a VALUE a
    // caller reads.
    if (outBuf.length != k) outBuf.length = k;
}

// ---------------------------------------------------------------------------
// The "Add Item" menu.
//
// ONE button with a drop-down, replacing the row of one-button-per-kind that
// was already two wide and would have grown a button per future kind.
//
// The `command` strings are what the menu DISPATCHES, and they are asserted
// against the command classes' own `name()` below — a typo here is otherwise
// a button that silently does nothing, which is the failure mode a list of
// literals invites.
// ---------------------------------------------------------------------------

struct AddItemChoice {
    string label;    ///< what the menu entry reads
    string command;  ///< the command id dispatched
    string args;     ///< its JSON argument object
    string tooltip;  ///< hover text, or "" for none
}

/// The creatable kinds, in menu order.
///
/// `ItemKind.Empty` is deliberately absent: it has no channels, no payload
/// and nothing to draw, so an entry for it would add a row a user can do
/// nothing with.
immutable AddItemChoice[] kAddItemChoices = [
    AddItemChoice("Mesh", "layer.add", "{}",
                  "Add an empty mesh item"),
    AddItemChoice("Image Plane", "imagePlane.add", "{}",
                  "Add a reference-image plane"),
];

// ===========================================================================
// Tests
//
// The fixture is SIX layers, and it is shaped so that the axes under test
// cannot coincide:
//
//   [0] meshA        (primary, and the baseline focus)
//   [1] clipA        ItemKind.Image — a document RESOURCE, NOT a row here
//   [2] plane        ItemKind.ImagePlane
//   [3] clipB        ItemKind.Image — a second resource
//   [4] meshB
//   [5] marker       ItemKind.Empty
//
// TWO resources, and that is not padding. Prepending the scene root shifts
// every ordinal UP by one and skipping a resource shifts it DOWN by one, so
// with a SINGLE interleaved resource the two cancel exactly and a row's
// position in `rows` equals its `layers` index for every row after it — an
// implementation reporting the ordinal would have read the right number and
// the index assertions would have been inert. (This was not theory: the first
// revision of this fixture had one resource and the vacuity guard caught it.)
// With a second resource the cancellation stops, and meshB's row differs from
// BOTH wrong readings — its `rows` position is 3, its position among the items
// is 2, and its layer index is 4.
//
// Three different listed kinds are present, so "drew a glyph" is
// distinguishable from "drew the right glyph".
// ===========================================================================

version (unittest) {
    import mesh     : makeCube;
    import seltype  : SelMode;

    struct ItemFixture {
        Document doc;
        Layer meshA, clipA, plane, clipB, meshB, marker;
    }

    ItemFixture makeItemFixture() {
        ItemFixture f;
        f.doc = Document.bootstrap(makeCube());
        f.meshA = f.doc.layers[0];
        f.meshA.name = "meshA";

        f.clipA  = addLayer(f, "clipA",  ItemKind.Image);
        f.plane  = addLayer(f, "plane",  ItemKind.ImagePlane);
        f.clipB  = addLayer(f, "clipB",  ItemKind.Image);
        f.meshB  = addLayer(f, "meshB",  ItemKind.Mesh);
        f.marker = addLayer(f, "marker", ItemKind.Empty);

        // A stated baseline: the primary mesh is the sole selection and the
        // focus, so every test starts from one place instead of inheriting
        // whatever the last fixture step left behind.
        f.doc.selectItem(f.meshA, SelMode.Set);
        return f;
    }

    /// Appended directly rather than through `layer.add`: that command only
    /// ever creates a mesh, and this fixture needs three other kinds. Nothing
    /// here asserts anything about creation — the row model reads `layers`.
    Layer addLayer(ref ItemFixture f, string name, ItemKind k) {
        auto l = new Layer;
        l.name    = name;
        l.kind    = k;
        l.visible = true;
        f.doc.layers ~= l;
        return l;
    }
}




// ---------------------------------------------------------------------------
// I3b — a parent CYCLE still lists every item.
//
// Not defensive padding: `layer.parent` refuses to create a cycle, but a
// hand-edited or corrupt `.v3d` can carry one, and the tree walk starts from
// the items with no row parent — of which a cycle has none. Without the
// orphan rescue the whole cycle is absent from the panel, i.e. invisible,
// unselectable and undeletable.
//
// Discriminating: the count. A rescue-less implementation reads 3 rows (root
// + the two items outside the cycle) where the correct one reads 5.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;
    auto f = makeItemFixture();

    f.meshA.parent = f.meshB;
    f.meshB.parent = f.meshA;               // a cycle no command would make
    assert(rowParentOf(&f.doc, f.meshA) !is null
        || rowParentOf(&f.doc, f.meshB) !is null,
        "fixture: at least one cycle member reports a row parent, or the "
        ~ "ordinary walk would have reached them and this proves nothing");

    ItemRow[] rows;
    itemRowsInto(&f.doc, "", false, true, rows);
    assert(rows.length == 5,
        "every item is listed even inside a parent cycle — a row that reaches "
        ~ "no panel cannot be selected or deleted; got "
        ~ to!string(rows.length));

    bool sawA = false, sawB = false;
    foreach (r; rows) {
        if (r.layer is f.meshA) sawA = true;
        if (r.layer is f.meshB) sawB = true;
    }
    assert(sawA && sawB, "and both cycle members are among them");

    // …and no row is a HOLE. The count above is only a real check because the
    // buffer is truncated to what was actually emitted; if it were left at the
    // pre-sized upper bound, a walk that dropped the cycle would still report
    // five rows, two of them blank.
    foreach (i, r; rows)
        assert(r.isRoot || r.layer !is null,
            "row " ~ to!string(i) ~ " is a default-constructed hole, not an "
            ~ "item — the length is padding rather than content");
}
