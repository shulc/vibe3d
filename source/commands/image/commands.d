module commands.image.commands;

// ---------------------------------------------------------------------------
// Task 0616 Ph5 — the image-item commands.
//
// Four commands plus one shared predicate. Every one of them is driveable
// HEADLESSLY by path: the file dialog is a thin wrapper that runs only when
// the `path` argument is empty, and it feeds the SAME code path the argument
// does. There is deliberately no second "for tests" route — the divergence
// note in the plan (§2) records why: the previous task in this chain gave
// itself a test-only HTTP splice that bypassed Command/undo entirely, and its
// undo behaviour then had no test that could see it.
//
//   image.load   [path]           Model     — appends an image item
//   image.replace index [path]    Model     — re-points an item at another file
//   image.reload  index           SideEffect— re-reads the same file
//   image.remove  index           Model     — removes an image item
//   (rename)                      Model     — `layer.rename`, unchanged
//
// UNDO CLASSES — the criterion this codebase actually applies is NOT "is the
// field persisted". `layer.select` is `UiState` while its `selected` flag IS
// written to `.v3d`; `layer.rename` is `Model` while its `name` is written to
// the same file. What separates them is whether the command edits what the
// document IS (content) or how the user is currently LOOKING at it
// (selection, focus, edit mode). So:
//
//   * load / remove   — Model. They add and destroy an item: content, and the
//     thing consumers link to. Removal is the strong case: `LayerDelete`
//     reinserts the SAME `Layer` object on revert, which is what makes every
//     link that pointed at it Live again by identity (Ph3's "undo is exact
//     for free"). That only works if the removal is on the undo stack at all.
//   * replace         — Model. `storedPath` is authored content, persisted by
//     Ph6, and it is what every consumer of the item renders.
//   * rename          — Model, inherited from `layer.rename` and correct as
//     it stands: a display name is authored content. It is NOT the selection
//     case, so it is not `UiState`.
//   * reload          — SideEffect, i.e. NO undo entry. It writes only the
//     DERIVED fields (`width`/`height`/`channels`/`missing`), which are
//     recomputed from the file and never persisted. "Undo the reload" would
//     mean restoring metadata that the disk has already contradicted — the
//     editor would then hold, and could be asked to save, a number it knows
//     is wrong. There is no prior DOCUMENT state to restore, so there is
//     nothing for an undo entry to carry.
//
// PIXEL LIFETIME — stated explicitly because `io.image_decode.DecodedImage`
// is manual-release (an explicit `free()`, deliberately NO destructor, so GC
// finalisation will never call it for you):
//
//   NOTHING IN THIS PHASE MATERIALISES PIXELS. Every path here — load,
//   replace, reload — goes through `io.image_path.refreshImageMeta`, which
//   calls `imageInfo` (header only) and never `imageDecode`. No
//   `DecodedImage` is constructed, so the number of `free()` calls owed by
//   this phase is exactly zero, and "released exactly once" holds by
//   construction rather than by discipline. That is the plan's own lazy
//   decision ("a document with 50 images shows 50 resolutions having decoded
//   nothing") AND the ordering `document.d`'s `ImageData` doc comment
//   demands: the share count must exist BEFORE the first `.free()` call site
//   does, because two image ITEMS may legitimately carry the same
//   `storedPath` (`LayerDuplicate` produces exactly that pair — its clone
//   gets its own `ImageData` holding the source's path), so "this item is
//   going away" is not the same question as "these pixels are unreachable".
//   The count therefore belongs on the path-keyed CACHE ENTRY, not on the
//   payload. Shipping a release here, ahead of that count, would be the one
//   ordering the comment names as a mistake.
//
//   When the pixel cache lands, its acquire/release pair belongs behind the
//   same `refreshImageMeta` seam, so the release has one call site per
//   command exactly as the refresh does now.
// ---------------------------------------------------------------------------

import std.path : baseName, stripExtension;

import nfde;

import command;
import mesh;
import view;
import editmode;
import params    : Param;
import document  : Document, Layer, ItemKind, ImageData;
import seltype   : SelMode;
import io.formats     : FilterSpec;
import io.image_path  : refreshImageMeta;
import change_bus     : noteLayerChange, LayerChange;
import log            : logWarn;
import commands.layer.commands : LayerDelete;

// ---------------------------------------------------------------------------
// Shared base — the Document handle and an image-only index resolve.
// ---------------------------------------------------------------------------

private abstract class ImageCommandBase : Command {
    protected Document* doc;
    // Why the last `apply()` said no, in one clause (Ph5 review, S3). Surfaced
    // to an HTTP / script caller by the dispatch funnel, which appends it to
    // its generic "command 'x' did not apply". Every refusal in this module
    // sets it, because every refusal here is about ONE of two arguments and
    // "did not apply" alone cannot say which.
    protected string refusal_;
    // Active-layer-switch hook (installed by registration.d). Forwarded to the
    // inner `LayerDelete` by `ImageRemove`; unused by the others, which never
    // move the edit target.
    protected void delegate(size_t prev, size_t next) onSwitch;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode);
        this.doc      = doc;
        this.onSwitch = onSwitch;
    }

    /// Resolve an `index` argument to an image item with a CONSTRUCTED
    /// payload, or `null`.
    ///
    /// Two deliberate differences from `LayerCommandBase.resolveIndex`, both
    /// of which are the difference between "refuses" and "silently edits
    /// something else":
    ///
    ///   * NO default-to-active. `resolveIndex(-1)` answers `doc.activeIndex`,
    ///     which by the document invariant is a MESH — the single worst row
    ///     for an image command to fall back onto. A missing index is a
    ///     caller bug, so it is refused.
    ///   * NO out-of-range CLAMP. `resolveIndex` clamps a too-large index to
    ///     the LAST layer; here that would mean an off-by-one in the panel
    ///     (or a stale index in a script) removing whichever row happens to
    ///     sit at the end.
    ///
    /// The kind test is the capability (`hasImage`), never
    /// `kind == ItemKind.Image` — `document.d`'s capability table states that
    /// contract. The extra `imageOrNull() !is null` guard covers an
    /// image-KIND row whose payload was never constructed (reachable only
    /// through the still-open test-only injection route the plan tracks as
    /// R15).
    protected Layer resolveImage(int raw) {
        if (raw < 0) {
            refuse("needs an explicit `index` (no active-layer default)");
            return null;
        }
        immutable size_t i = cast(size_t) raw;
        if (i >= doc.layers.length) {
            refuse("index out of range");
            return null;
        }
        auto l = doc.layers[i];
        if (!l.hasImage || l.imageOrNull() is null) {
            refuse("layer is not a loaded image item");
            return null;
        }
        return l;
    }

    /// Record + log one refusal. One call site per reason, so the text the
    /// caller is handed and the text the log carries cannot drift apart.
    protected void refuse(string why) {
        refusal_ = why;
        logWarn("image", name() ~ " refused: " ~ why);
    }

    /// The dispatch funnel reads this after a false `apply()` (see
    /// `Command.refusalReason`). Cleared at the top of every `apply()` so it
    /// always describes the LATEST call — a stale reason on a command object
    /// that is applied more than once (redo, re-dispatch) would be worse than
    /// none.
    override string refusalReason() const { return refusal_; }
}

/// The one file-picker used by BOTH `image.load` and `image.replace`, so the
/// dialog cannot drift from the by-path route: it produces a path and then
/// falls into exactly the code an explicit `path` argument reaches. Formats
/// match what the decoder is actually compiled with (PNG / JPEG / TGA / BMP).
private string runImageOpenDialog() {
    FilterSpec[] fs = [FilterSpec("Images", "png,jpg,jpeg,tga,bmp")];
    string path;
    version (Windows) {
        import std.utf : toUTF16z;
        FilterItem[] items;
        foreach (ref f; fs)
            items ~= FilterItem(cast(const(ushort)*)f.name.toUTF16z,
                                cast(const(ushort)*)f.spec.toUTF16z);
        auto result = openDialog(path, items);
    } else {
        import std.string : toStringz;
        FilterItem[] items;
        foreach (ref f; fs)
            items ~= FilterItem(f.name.toStringz, f.spec.toStringz);
        auto result = openDialog(path, items);
    }
    assert(result != Result.error, getError());
    return path;
}

/// Ask for a path: the argument when there is one, the dialog otherwise.
/// Returns "" when there is no path to work with (cancelled, or suppressed in
/// test mode — the `commands/file/load.d` convention, so a headless run never
/// blocks on a native dialog nobody can click).
private string pathOrDialog(string arg, string who) {
    if (arg.length > 0) return arg;
    if (command.g_testMode) {
        logWarn("image", who ~ ": no path in test mode; native dialog suppressed");
        return "";
    }
    auto p = runImageOpenDialog();
    return p is null ? "" : p;
}

// ---------------------------------------------------------------------------
// The remove-time warning — the shared predicate, not a copy of one.
// ---------------------------------------------------------------------------

/// What a caller must know before removing an image item: whether anything
/// still references it, and what.
struct ImageRemoveWarning {
    bool    inUse;      ///< true iff at least one item still links to the target
    Layer[] referrers;  ///< those items, in `layers` order
}

/// The Images panel's confirm-before-remove predicate AND the warning
/// `image.remove` itself logs — one function, so the text the user is shown
/// and the condition the command acts on cannot disagree. This is the
/// `layerDeleteButtonState` shape (`commands/layer/commands.d`), which exists
/// for exactly this reason.
///
/// "Is this image still in use" is ANSWERABLE rather than guesswork only
/// because of Ph3: links are forward-only, so the target knows nothing about
/// its consumers, and `Document.referrersOf` is the reverse sweep that exists
/// to be paid at delete/panel time and never on a draw path.
///
/// It reports DANGLING referrers too (`referrersOf` matches on identity, not
/// on resolution) — which is the right answer here, since the caller asking
/// is the one about to make them dangle.
ImageRemoveWarning imageRemoveWarning(Document* doc, Layer target) {
    ImageRemoveWarning w;
    if (doc is null || target is null) return w;
    doc.referrersOf(target, w.referrers);
    w.inUse = w.referrers.length > 0;
    return w;
}

// ---------------------------------------------------------------------------
// image.load — append an image item. Model undo.
// ---------------------------------------------------------------------------

final class ImageLoad : ImageCommandBase {
    private string pathArg;
    // The created item is kept ACROSS undo, and re-appended (the same object)
    // on redo — see apply()'s comment. Not a leak: an undone load holds one
    // Layer + one ImageData, and the history entry that holds them is dropped
    // when the redo branch is discarded.
    private Layer  created_;
    private bool   applied;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "image.load"; }
    override string label() const { return "Load Image"; }
    // Model-undo (the base default): this creates document content.

    override Param[] params() {
        return [ Param.string_("path", "Path", &pathArg, "") ];
    }

    /// The created item, for a caller that needs it back (tests, and a panel
    /// that wants to select the new row). Null until a successful apply.
    Layer created() { return created_; }

    override bool apply() {
        // REDO re-appends the SAME object rather than building a fresh one.
        // This is not an optimisation. A consumer's link names the target
        // `Layer` OBJECT (Ph3: not its index, not its name, not its path), so
        // an implementation that minted a new Layer on redo would leave every
        // link that survived the undo pointing at an item the document no
        // longer contains — permanently Dangling, with a visually identical
        // row sitting right there. `LayerDelete.revert` reinserts the exact
        // removed object for the same reason.
        //
        // It also means redo does NOT re-read the file: redo restores the
        // document to what it was, it does not re-observe the disk. Observing
        // the disk is `image.reload`'s single job.
        //
        // DECIDED, not overlooked (review NIT 5). Undo, delete the file on
        // disk, redo: the restored row reports `missing == false` and the
        // width it had — a number whose file is now gone. That is the SAME
        // staleness every image row already carries, not a new class of it:
        // any file can vanish a millisecond after a plain successful load, and
        // the row keeps its numbers until something re-observes. The derived
        // half means "what the disk answered when last asked", and a redo
        // re-asserts an answer THIS session genuinely measured for THIS path.
        // That is what separates it from persisting the numbers to `.v3d`,
        // which `ImageData`'s comment condemns for the different reason that
        // there the numbers come back in a process that never opened the file
        // at all.
        //
        // Re-reading on the redo branch was the alternative and is worse: it
        // gives `apply()` two behaviours, because the first apply REFUSES an
        // unreadable file while a redo must not (a redo that returns false
        // desyncs the history stack against a document it already changed).
        // The only tolerable re-read would therefore be "read, and succeed
        // whatever it says" — a THIRD failure policy on top of the two this
        // module documents below, bought for a staleness the design accepts
        // everywhere else. `image.reload` is the recovery, and it is one
        // click.
        refusal_ = "";
        // A redo must not be able to re-append an item the document already
        // holds (review NIT 4). Not reachable through the history stack, which
        // never redoes an entry it has not first undone — but `apply()` is a
        // public method on a live object, and the guard is what makes the redo
        // branch TOTAL rather than correct-by-caller-discipline. Refusing (not
        // silently skipping the append) is the honest answer: the caller asked
        // for something already true.
        if (created_ !is null && doc.isMember(created_)) {
            refuse("already applied — the item is in the document");
            return false;
        }

        if (created_ is null) {
            const path = pathOrDialog(pathArg, "load");
            if (path.length == 0) { refuse("no path given"); return false; }

            auto img = new ImageData();
            img.storedPath = path;
            // A file that cannot be read means NO ITEM AT ALL — see the
            // module-level note below on why this differs from a file that
            // goes missing later.
            if (!refreshImageMeta(img)) {
                refuse("cannot read '" ~ path ~ "'");
                return false;
            }

            auto l = new Layer;
            l.kind    = ItemKind.Image;
            l.name    = itemNameFor(path);
            l.visible = true;
            l.imageRef() = img;
            created_ = l;
        }

        doc.layers ~= created_;
        applied = true;
        // Structural add. NOT `setActive`/`selectItem`: an image is not a
        // scene item, so there is no "make it active" to perform, and folding
        // an item-SELECTION change (UiState) into this Model command would
        // make one Ctrl+Z undo both. The panel selects the new row by
        // dispatching `layer.select` if it wants to — the same split the
        // layer panel already uses.
        noteLayerChange(LayerChange.Added);
        return true;
    }

    override bool revert() {
        if (!applied || created_ is null) return false;
        immutable size_t i = doc.indexOf(created_);
        if (i == doc.layers.length) return false;   // already gone — not ours to undo

        // The item may have been selected / focused since the load (an image
        // item is selectable through `layer.select` like any other item).
        // Move the selection off it through the MUTATOR before the splice, so
        // `focusedItem` cannot be left naming a non-member. Linear undo means
        // the selection's own UiState entry has normally been reverted first,
        // so this is a backstop, not the usual path.
        if (created_.selected) doc.selectItem(created_, SelMode.Remove);

        doc.layers = doc.layers[0 .. i] ~ doc.layers[i + 1 .. $];
        applied = false;
        noteLayerChange(LayerChange.Removed);
        return true;
    }
}

/// The display name a freshly loaded item gets: the file's stem.
///
/// The stem rather than "Image N" because the name has to mean something in a
/// list whose rows are files, and rather than the full path because the path
/// is shown in its own right. Reference-unverified (the measured name was
/// probe-supplied, per the plan's §Premises) — and cheap to change, since
/// rename is a first-class operation on the row.
private string itemNameFor(string path) {
    auto stem = stripExtension(baseName(path));
    return stem.length ? stem : "Image";
}

// ---------------------------------------------------------------------------
// image.replace — re-point an image item at a different file. Model undo.
// ---------------------------------------------------------------------------

final class ImageReplace : ImageCommandBase {
    private int    indexArg = -1;
    private string pathArg;
    // The payload is captured at apply time so revert writes back through the
    // SAME object, not through whatever sits at `indexArg` later.
    private ImageData payload_;
    private string prevPath_;
    private int    prevW_, prevH_, prevC_;
    private bool   prevMissing_;
    private bool   applied;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "image.replace"; }
    override string label() const { return "Replace Image"; }

    override Param[] params() {
        return [ Param.int_("index", "Index", &indexArg, -1),
                 Param.string_("path", "Path", &pathArg, "") ];
    }

    override bool apply() {
        refusal_ = "";
        auto target = resolveImage(indexArg);
        if (target is null) return false;
        const path = pathOrDialog(pathArg, "replace");
        if (path.length == 0) { refuse("no path given"); return false; }

        // READ FIRST, COMMIT SECOND (Ph5 review, S2). The new file is refreshed
        // into a SCRATCH payload, and the live item is written only once that
        // has succeeded. A replace that cannot read its new file must leave a
        // working reference working, not trade it for a broken one — and here
        // that holds because the live item was never written, not because a
        // rollback branch put five fields back. The rollback version was
        // correct by discipline: any throw between the write and the restore
        // (and `refreshImageMeta` reads a file) left the item holding the bad
        // path, and no `scope(failure)` guarded it. This version has no
        // failure window to guard.
        auto probe = new ImageData();
        probe.storedPath = path;
        if (!refreshImageMeta(probe)) {
            refuse("cannot read '" ~ path ~ "'");
            return false;
        }

        auto img = target.imageOrNull();
        // Snapshot BOTH halves — the authored path and the derived answer —
        // so revert restores the document as it was rather than re-deriving
        // it from a disk that may have moved on.
        prevPath_    = img.storedPath;
        prevW_       = img.width;
        prevH_       = img.height;
        prevC_       = img.channels;
        prevMissing_ = img.missing;

        // THE WHOLE POINT OF THE INDIRECTION: this writes through the item's
        // OWN payload, in place. The `Layer` object does not change, the
        // `ImageData` object does not change, and not one consumer is
        // touched — every link still names this same item and therefore sees
        // the new file on its next read. An implementation that instead built
        // a new item and re-pointed the consumers would have to find them
        // all, and would silently miss the second one. (Which is also why the
        // scratch payload above is DISCARDED rather than installed: installing
        // it would swap the object every consumer's read goes through.)
        //
        // The two authored channels the probe never carried — `colorspace`
        // and `useAlpha` — are deliberately not copied across: they are the
        // ITEM's settings, not the file's, and a replace re-points the item at
        // another file rather than re-authoring it.
        img.storedPath = probe.storedPath;
        img.width      = probe.width;
        img.height     = probe.height;
        img.channels   = probe.channels;
        img.missing    = probe.missing;

        payload_ = img;
        applied  = true;
        noteLayerChange(LayerChange.PropertyChanged);
        return true;
    }

    override bool revert() {
        if (!applied || payload_ is null) return false;
        payload_.storedPath = prevPath_;
        payload_.width      = prevW_;
        payload_.height     = prevH_;
        payload_.channels   = prevC_;
        payload_.missing    = prevMissing_;
        noteLayerChange(LayerChange.PropertyChanged);
        return true;
    }
}

// ---------------------------------------------------------------------------
// image.reload — re-read the SAME file. No undo entry (SideEffect).
// ---------------------------------------------------------------------------

final class ImageReload : ImageCommandBase {
    private int indexArg = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "image.reload"; }
    override string label() const { return "Reload Image"; }
    /// SideEffect, so `isUndoable()` is false and no entry is recorded — see
    /// the undo-class note at the top of this module.
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override Param[] params() {
        return [ Param.int_("index", "Index", &indexArg, -1) ];
    }

    override bool apply() {
        refusal_ = "";
        auto target = resolveImage(indexArg);
        if (target is null) return false;   // a bad index IS a failure

        // The RESULT of the read is not the success of the command. "The file
        // is gone" is an answer the user asked for and the row must now show;
        // returning false here would report an error to the caller AFTER the
        // item's derived state had already changed — a throw on top of a
        // half-applied command, which is precisely the failure mode worth
        // avoiding. The authored path is untouched either way, so a file that
        // comes back resolves again on the next reload.
        refreshImageMeta(target.imageOrNull());
        noteLayerChange(LayerChange.PropertyChanged);
        return true;
    }
}

// ---------------------------------------------------------------------------
// image.remove — remove an image item. Model undo.
//
// The MUTATION is `layer.delete`'s, reused rather than reimplemented: it
// already snapshots the full prior selection set by identity, re-homes the
// primary, clears and restores orphaned parent links, and — load-bearing for
// Ph3 — reinserts the EXACT removed object on revert, which is what makes
// every link that named it Live again by identity. Duplicating that here to
// save one delegation would be duplicating the part of the codebase least
// affordable to get subtly wrong.
//
// What this command adds on top, and why it is not just `layer.delete`:
//   * a KIND guard with no clamp — `layer.delete index:7` on a seven-layer
//     document deletes the last MESH; the panel row index that produced the 7
//     came from a list that does not contain meshes at all.
//   * the in-use warning (`imageRemoveWarning`), reported before the removal.
// ---------------------------------------------------------------------------

final class ImageRemove : ImageCommandBase {
    private int         indexArg = -1;
    private LayerDelete inner_;
    private Layer[]     referrers_;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "image.remove"; }
    override string label() const { return "Remove Image"; }
    // Model-undo (the base default) — see the module note.

    override Param[] params() {
        return [ Param.int_("index", "Index", &indexArg, -1) ];
    }

    /// The items that still linked to the removed image at apply time. Empty
    /// before apply, after an apply that found none, and after an apply that
    /// was REFUSED. The panel reads `imageRemoveWarning` BEFORE dispatching
    /// (to confirm with the user); this is the same list as it was actually
    /// acted on — so a removal that did not happen must report nothing, or the
    /// panel is reading the referrers of an item that is still there.
    const(Layer)[] referrers() const { return referrers_; }

    override bool apply() {
        // Cleared FIRST, and re-published only on the success path below
        // (Ph5 review, S4). Both halves are load-bearing: the clear is what
        // keeps a re-dispatched command object from reporting the PREVIOUS
        // call's referrers after a refusal, and the late publish is what keeps
        // a removal that `LayerDelete` declined from reporting any.
        referrers_ = null;
        refusal_   = "";

        auto target = resolveImage(indexArg);
        if (target is null) return false;

        // Warn — do not refuse. The reference's list warns that the image is
        // still used and proceeds; a link that outlives its target is a state
        // Ph3 made well-defined (it resolves to Dangling, never to a
        // neighbour), so there is nothing here that a refusal would protect.
        auto w = imageRemoveWarning(doc, target);
        if (w.inUse) {
            import std.conv : to;
            string names;
            foreach (i, r; w.referrers) {
                if (i > 0) names ~= ", ";
                names ~= r.name;
            }
            logWarn("image", "'" ~ target.name ~ "' is still used by "
                ~ w.referrers.length.to!string ~ " item(s): " ~ names);
        }

        auto del = new LayerDelete(mesh, view, editMode, doc, onSwitch);
        del.setIndex(cast(int) doc.indexOf(target));
        if (!del.apply()) {                // e.g. the document's last layer
            refuse("the document declined to delete that item");
            return false;
        }
        inner_     = del;
        referrers_ = w.referrers;
        return true;
    }

    override bool revert() {
        return inner_ !is null && inner_.revert();
    }
}

// ---------------------------------------------------------------------------
// WHAT A FAILED LOAD LEAVES BEHIND — the decision, and why it is not the same
// answer Ph3 gave for a dangling LINK.
//
// `image.load` on an unreadable path leaves NO ITEM. `image.reload` on a file
// that has since gone leaves the ITEM, reporting itself unresolved.
//
// Those look inconsistent and are not. Ph3's rule was "report, do not sweep",
// and the reason it gave was about EXISTING document content: a link the user
// authored must not be silently erased just because its target went away,
// because the erasure is invisible and the user can never get it back.
// `image.reload` (and, in Ph6, opening a `.v3d` whose images have moved) is
// exactly that case — the path is content the document already asserts — so
// it gets exactly that answer: keep `storedPath` byte-for-byte, set
// `missing`, show the row, let a later reload resolve it.
//
// A failed `image.load` is the OPPOSITE situation. Nothing is being erased:
// the path was a brand-new assertion, one call old, with no document state
// behind it and nothing linking to it yet. The two candidate answers are
// "refuse" and "create a row that has never resolved anything" — and the
// second is strictly worse, because a typo'd path becomes a permanent row the
// user now has to notice and clean up, indistinguishable in the list from an
// asset that is genuinely offline. Refusing loses nothing (the caller still
// has the path; that is where it came from) and reports the failure at the
// moment the user can still fix it.
//
// So the shared principle is one rule, not two: NEVER destroy an assertion
// the document already made; DO refuse a new one that cannot be honoured.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
    import std.file : write, remove, exists;
    import std.path : buildPath;
    import io.image_path : writeTestBmp, imageTestDir;
    import mesh   : makeCube;
    import view   : View;

    // The fixture the tests share:
    //
    //   [0] meshA   (primary)
    //   [1] clipA   3x2
    //   [2] clipB   3x2   <-- the MIDDLE clip; every remove/replace targets it
    //   [3] clipC   3x2
    //   [4] consumerX  --link "backdropImage"--> clipB
    //   [5] consumerY  --link "backdropImage"--> clipB
    //
    // THREE clips, and the operations target the MIDDLE one: a one-clip
    // fixture cannot tell "removed the right one" from "removed the only
    // one", and a middle target is the case where an index-based
    // implementation silently addresses a NEIGHBOUR.
    //
    // TWO consumers, both on the same clip: one consumer cannot show that the
    // consumers were not individually re-pointed — an implementation that
    // updates the first referrer it finds reads identically to the correct
    // one until there is a second.
    struct ImgFixture {
        Document doc;
        View     view;
        Layer    meshA, clipA, clipB, clipC, consumerX, consumerY;
        string   dir;
        string   pathA, pathB, pathC;
    }

    ImgFixture makeImgFixture(string tag) {
        ImgFixture f;
        f.doc  = Document.bootstrap(makeCube());
        f.view = new View(0, 0, 800, 600);
        f.meshA = f.doc.layers[0];

        f.dir   = imageTestDir(tag);
        f.pathA = buildPath(f.dir, "alpha.bmp");
        f.pathB = buildPath(f.dir, "bravo.bmp");
        f.pathC = buildPath(f.dir, "charlie.bmp");
        writeTestBmp(f.pathA, 3, 2);
        writeTestBmp(f.pathB, 3, 2);
        writeTestBmp(f.pathC, 3, 2);

        f.clipA = loadInto(f, f.pathA);
        f.clipB = loadInto(f, f.pathB);
        f.clipC = loadInto(f, f.pathC);

        // Non-mesh consumers (`Empty`), because the real consumer this link
        // exists for is not a mesh either, and because a mesh-kind stand-in
        // would be `canBePrimary` and would quietly change what
        // `canDeleteLayer` permits inside these tests.
        f.consumerX = new Layer; f.consumerX.name = "consumerX"; f.consumerX.kind = ItemKind.Empty;
        f.consumerY = new Layer; f.consumerY.name = "consumerY"; f.consumerY.kind = ItemKind.Empty;
        f.doc.layers ~= f.consumerX;
        f.doc.layers ~= f.consumerY;
        f.consumerX.setLink("backdropImage", f.clipB);
        f.consumerY.setLink("backdropImage", f.clipB);
        return f;
    }

    // Load through the COMMAND, exactly as a caller reaches it — never by
    // hand-building a Layer, so the fixture itself exercises the load path.
    Layer loadInto(ref ImgFixture f, string path) {
        auto c = new ImageLoad(f.doc.activeMesh(), f.view, EditMode.Vertices,
                               &f.doc, null);
        c.pathArg = path;
        assert(c.apply(), "fixture: image.load must succeed on " ~ path);
        return c.created();
    }
}

// ---------------------------------------------------------------------------
// LOAD — an item appears, carrying the path, the derived metadata and the
// file's stem as its name.
//
// Discriminating: 3x2 (width != height), so a transposed read reads 2x3; the
// name is "alpha", which an implementation naming rows "Layer N" / "Image N"
// reads differently; and the item is NOT primary and NOT selected, which an
// implementation that copied `layer.add`'s `setActive` would break.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeImgFixture("load");

    assert(f.doc.layers.length == 6, "fixture: mesh + 3 clips + 2 consumers");
    assert(f.clipA.kind == ItemKind.Image, "load produced an image-kind item");
    assert(f.clipA.hasImage && f.clipA.imageOrNull() !is null,
        "load produced a LIVE image row, not a payload-null one");

    auto img = f.clipA.imageOrNull();
    assert(img.storedPath == f.pathA, "the item carries the path it was given");
    assert(img.width  == 3, "width comes from the file header");
    assert(img.height == 2, "height comes from the file header");
    assert(!img.missing, "a file that read successfully is not missing");
    assert(f.clipA.name == "alpha",
        "the row is named after the FILE STEM — not \"Layer N\", and not the "
        ~ "full path");

    assert(f.doc.primary is f.meshA, "an image never becomes the edit target");
    assert(!f.clipA.selected,
        "load does not touch the item selection: mixing a UiState change into "
        ~ "this Model command would make one Ctrl+Z undo both");
}

// ---------------------------------------------------------------------------
// LOAD of an unreadable path — the DECISION: no item at all.
//
// Discriminating: the assertion is the STATE AFTERWARDS, not merely that the
// command reported failure. An implementation that appends the item first and
// only then discovers the file is unreadable reads `layers.length == 7` here
// while still returning false — a failed command that half-committed, which
// is the failure that actually matters.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeImgFixture("load_missing");
    immutable before = f.doc.layers.length;

    auto c = new ImageLoad(f.doc.activeMesh(), f.view, EditMode.Vertices,
                           &f.doc, null);
    c.pathArg = buildPath(f.dir, "no_such_file.bmp");
    assert(!c.apply(), "a path that cannot be read is refused");
    assert(f.doc.layers.length == before,
        "and leaves NO item behind — not a row that reports itself unresolved");
    assert(c.created() is null, "nothing was constructed");

    // The same refusal for a file that exists but is not an image, so the
    // rejection is the DECODER's answer and not merely `exists()`.
    auto junk = buildPath(f.dir, "junk.bmp");
    write(junk, "not an image at all");
    scope (exit) { if (exists(junk)) remove(junk); }
    auto c2 = new ImageLoad(f.doc.activeMesh(), f.view, EditMode.Vertices,
                            &f.doc, null);
    c2.pathArg = junk;
    assert(!c2.apply(), "an unparseable file is refused too");
    assert(f.doc.layers.length == before, "and still leaves no item");
}

// ---------------------------------------------------------------------------
// LOAD undo/redo preserves the item's IDENTITY, which is what a consumer's
// link is made of.
//
// Discriminating: a consumer is linked to the loaded item, the load is undone
// and redone, and the link must be LIVE again pointing at the SAME object. An
// implementation whose redo mints a fresh `Layer` (the obvious one — apply()
// simply builds the item every time) reads Dangling/null here, with a
// visually identical row sitting in the list.
// ---------------------------------------------------------------------------
unittest {
    import document : LinkState;

    auto f = makeImgFixture("load_undo");
    immutable before = f.doc.layers.length;

    auto path = buildPath(f.dir, "delta.bmp");
    writeTestBmp(path, 9, 4);
    auto c = new ImageLoad(f.doc.activeMesh(), f.view, EditMode.Vertices,
                           &f.doc, null);
    c.pathArg = path;
    assert(c.apply(), "load applies");
    auto loaded  = c.created();
    auto payload = loaded.imageOrNull();

    f.consumerX.setLink("second", loaded);
    assert(f.consumerX.link("second").state(f.doc) == LinkState.Live,
        "fixture: the consumer links to the freshly loaded item");

    assert(c.revert(), "undo of a load removes it");
    assert(f.doc.layers.length == before, "the item is gone");
    assert(f.consumerX.link("second").state(f.doc) == LinkState.Dangling,
        "and the link that named it reports Dangling — never a neighbour");

    assert(c.apply(), "redo re-applies");
    assert(f.doc.layers.length == before + 1, "the item is back");
    assert(f.consumerX.link("second").resolve(f.doc) is loaded,
        "redo restores the SAME object, so the link is Live again by identity "
        ~ "— a redo that minted a fresh Layer leaves this permanently dangling");
    assert(loaded.imageOrNull() is payload,
        "and the SAME payload object, so nothing re-decoded either");

    // …and a SECOND apply without an intervening revert is refused rather
    // than appending the same object twice (review NIT 4). The history stack
    // never asks for this, but `apply()` is a public method and the guard is
    // what makes the redo branch total: without it the document holds one
    // `Layer` object at two indices, and every index-keyed thing downstream
    // (`indexOf`, Ph6's link encoding) then has two answers for one item.
    assert(!c.apply(), "a redo of an already-applied load is refused");
    assert(f.doc.layers.length == before + 1,
        "and appends nothing — without the guard this reads one more row, the "
        ~ "SAME object listed twice");
}

// ---------------------------------------------------------------------------
// REMOVE the MIDDLE clip.
//
// Discriminating: three clips, and the middle one goes. The survivors are
// asserted BY IDENTITY, so an implementation that removed the neighbour
// (index+1, the classic off-by-one after a splice) reads clipA + clipB where
// this expects clipA + clipC — a count-only assertion passes that bug.
// Undo then reinserts THE SAME OBJECT at the SAME slot, which is what makes
// both consumers' links Live again without anything having recorded them.
// ---------------------------------------------------------------------------
unittest {
    import document : LinkState;

    auto f = makeImgFixture("remove_middle");
    immutable size_t bIdx = f.doc.indexOf(f.clipB);
    assert(bIdx == 2, "fixture: clipB is the MIDDLE clip");

    auto c = new ImageRemove(f.doc.activeMesh(), f.view, EditMode.Vertices,
                             &f.doc, null);
    c.indexArg = cast(int) bIdx;
    assert(c.apply(), "remove applies");

    assert(f.doc.layers.length == 5, "one item left the document");
    assert(f.doc.indexOf(f.clipB) == f.doc.layers.length,
        "clipB is the one that went");
    assert(f.doc.indexOf(f.clipA) == 1 && f.doc.indexOf(f.clipC) == 2,
        "clipA and clipC are the survivors, and clipC has SHIFTED DOWN into "
        ~ "the vacated slot — the exact position an index-based link would "
        ~ "now silently resolve to");
    assert(f.consumerX.link("backdropImage").state(f.doc) == LinkState.Dangling,
        "the consumer's link is Dangling, NOT re-pointed at the neighbour");
    assert(f.consumerX.link("backdropImage").targetUnchecked() is f.clipB,
        "and still names clipB by identity — nothing swept it");

    assert(c.revert(), "undo restores it");
    assert(f.doc.layers.length == 6, "the item is back");
    assert(f.doc.layers[2] is f.clipB,
        "the SAME object, at its original slot");
    assert(f.consumerX.link("backdropImage").resolve(f.doc) is f.clipB
        && f.consumerY.link("backdropImage").resolve(f.doc) is f.clipB,
        "BOTH links are Live again by identity, with nothing recorded and "
        ~ "nothing restored");
}

// ---------------------------------------------------------------------------
// REMOVE warns when the image is still in use — and does not warn when it is
// not.
//
// Discriminating in two directions: clipB has TWO referrers, so a
// "found one, stop looking" sweep reads 1; and clipA has ZERO, so an
// implementation that reports "every consumer in the document" (the lazy way
// to make the first assertion pass) reads 2 here. Both halves are needed.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeImgFixture("remove_warn");

    auto wB = imageRemoveWarning(&f.doc, f.clipB);
    assert(wB.inUse, "clipB is still used");
    assert(wB.referrers.length == 2,
        "by BOTH consumers — a first-match-and-stop sweep reads 1");
    assert(wB.referrers[0] is f.consumerX && wB.referrers[1] is f.consumerY,
        "reported in layers order");

    auto wA = imageRemoveWarning(&f.doc, f.clipA);
    assert(!wA.inUse && wA.referrers.length == 0,
        "clipA is used by nobody — an implementation reporting the document's "
        ~ "consumers rather than THIS item's would read 2");

    // The warning does not become a refusal.
    auto c = new ImageRemove(f.doc.activeMesh(), f.view, EditMode.Vertices,
                             &f.doc, null);
    assert(c.referrers().length == 0, "nothing is reported before an apply");
    c.indexArg = cast(int) f.doc.indexOf(f.clipB);
    assert(c.apply(), "a still-used image is removed anyway — warn, not refuse");
    assert(c.referrers().length == 2,
        "and the command reports what it acted over");

    // A REFUSED apply reports NOTHING (review round 3, S4). The list is a
    // report of a removal that happened; the panel that reads it is deciding
    // what to tell the user about an item that is now gone, and reading last
    // call's two referrers for an item still sitting in the list is the wrong
    // answer twice over. Re-aiming the same command object is how a caller
    // reaches this (the panel holds one command per row and re-dispatches it);
    // an implementation that publishes `referrers_` BEFORE the delete — and
    // never clears it — reads 2 here.
    c.indexArg = 0;                            // the mesh row: kind-refused
    assert(!c.apply(), "the re-aimed remove is refused");
    assert(c.referrers().length == 0,
        "and reports no referrers — the previous call's list must not survive "
        ~ "a refusal");
}

// ---------------------------------------------------------------------------
// REMOVE refuses a target that is not an image, and refuses an out-of-range
// index instead of clamping it.
//
// Discriminating: `LayerCommandBase.resolveIndex` — the shape every layer.*
// command uses — CLAMPS an out-of-range index to the last layer. Inheriting
// that here would make `image.remove index:99` delete consumerY. Both
// assertions read the layer count AND the identity of what survived.
//
// A SECOND MESH is added first, and it is what makes the kind assertion mean
// anything (review round 3, blocker 1). `canDeleteLayer` refuses to delete the
// last `canBePrimary` layer, and the shared fixture has exactly one — so on
// that fixture `image.remove index:0` fails WITH the kind guard and fails
// WITHOUT it, and the assertion reads the same either way. The failure the
// guard exists to prevent is a remove landing on a MESH the document would
// otherwise have deleted, so the document has to be one where the delete
// would in fact go through. The `layer.delete` control below is the proof
// that it would: same index, same instant, and it succeeds.
// ---------------------------------------------------------------------------
unittest {
    import commands.layer.commands : LayerDelete, canDeleteLayer;

    auto f = makeImgFixture("remove_guard");

    // Two meshes, so deleting the first is permitted by the document.
    auto meshB = new Layer;
    meshB.kind = ItemKind.Mesh;
    meshB.name = "meshB";
    f.doc.layers ~= meshB;
    assert(canDeleteLayer(&f.doc, f.meshA),
        "fixture: with a second mesh present the document PERMITS deleting "
        ~ "meshA — without this the assertion below passes on the "
        ~ "last-canBePrimary refusal and never sees the kind guard at all");

    auto onMesh = new ImageRemove(f.doc.activeMesh(), f.view, EditMode.Vertices,
                                  &f.doc, null);
    onMesh.indexArg = 0;                      // the mesh primary
    assert(!onMesh.apply(), "a mesh row is not an image item");
    assert(f.doc.layers.length == 7 && f.doc.primary is f.meshA,
        "and nothing was removed");
    assert(f.doc.layers[0] is f.meshA,
        "the mesh is still there BY IDENTITY — a count-only check passes an "
        ~ "implementation that removed it and put something else in its place");

    // THE CONTROL, at the same index and against the same document:
    // `layer.delete 0` DOES apply. So the refusal above is this command's kind
    // guard and nothing else. Reverted immediately so the rest of the test
    // runs against the document it expects.
    {
        auto ctl = new LayerDelete(f.doc.activeMesh(), f.view, EditMode.Vertices,
                                   &f.doc, null);
        ctl.setIndex(0);
        assert(ctl.apply(),
            "control: `layer.delete 0` succeeds where `image.remove 0` was "
            ~ "refused — the two commands differ by the kind guard, and this "
            ~ "is the row it saved");
        assert(f.doc.indexOf(f.meshA) == f.doc.layers.length,
            "control: it really did remove the mesh");
        assert(ctl.revert() && f.doc.layers[0] is f.meshA,
            "control: and the same object goes back where it was");
    }

    // The clamp only BITES when the row it clamps onto is itself an image —
    // otherwise the kind guard would refuse anyway and the assertion below
    // would be true for the wrong reason. So put an image at the tail first:
    // now "clamped to the last layer" and "refused" read differently.
    auto clipD = loadInto(f, f.pathA);
    assert(f.doc.layers[$ - 1] is clipD, "fixture: an IMAGE now sits last");

    auto oob = new ImageRemove(f.doc.activeMesh(), f.view, EditMode.Vertices,
                               &f.doc, null);
    oob.indexArg = 99;
    assert(!oob.apply(), "an out-of-range index is refused, not clamped");
    assert(f.doc.layers.length == 8 && f.doc.layers[$ - 1] is clipD,
        "the LAST row — what a clamp would have hit — is untouched");

    // The no-default rule. `doc.activeIndex` is not the only plausible wrong
    // default and is the INERT one to test against (it names a mesh, which the
    // kind guard refuses anyway); the reachable wrong default is
    // `doc.focusedItem`, which is what the Layers panel's own delete button
    // targets (`layerDeleteButtonState`) and which CAN be an image. So focus
    // an image row first: an implementation that defaulted to the focus would
    // remove clipD here, and every assertion is a read of clipD.
    f.doc.selectItem(clipD, SelMode.Add);
    assert(f.doc.focusedItem is clipD && f.doc.primary is f.meshA,
        "fixture: an IMAGE is the item-selection focus while the mesh stays "
        ~ "the edit target");

    auto noIdx = new ImageRemove(f.doc.activeMesh(), f.view, EditMode.Vertices,
                                 &f.doc, null);
    assert(!noIdx.apply(),
        "a missing index does NOT fall back to a default — neither to the "
        ~ "active layer (a mesh) nor to the focused item (an image, which "
        ~ "would go through)");
    assert(f.doc.layers.length == 8 && f.doc.indexOf(clipD) == 7,
        "and removed nothing — a focus default reads 7 layers with clipD gone");
}

// ---------------------------------------------------------------------------
// REPLACE — every consumer follows, and not one consumer is touched.
//
// Discriminating (this is the property the whole indirection exists for):
//   * TWO consumers, and BOTH read the new file afterwards. With one
//     consumer, an implementation that created a NEW item for the new file
//     and re-pointed the referrer it found would pass;
//   * the layer COUNT is unchanged and the `ImageData` object is the SAME
//     object — so the payload was mutated in place rather than swapped;
//   * the new file is 5x7 against the old 3x2, so both dimensions move and a
//     transposed or half-refreshed read is visible;
//   * the consumers' own link slots are asserted unchanged (same slot name,
//     same target identity) — "the consumers followed" must not be achieved
//     BY editing the consumers.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeImgFixture("replace");
    auto payloadBefore = f.clipB.imageOrNull();
    auto newPath = buildPath(f.dir, "echo.bmp");
    writeTestBmp(newPath, 5, 7);

    immutable slotsX = f.consumerX.linkSlots().length;

    auto c = new ImageReplace(f.doc.activeMesh(), f.view, EditMode.Vertices,
                              &f.doc, null);
    c.indexArg = cast(int) f.doc.indexOf(f.clipB);
    c.pathArg  = newPath;
    assert(c.apply(), "replace applies");

    assert(f.doc.layers.length == 6,
        "replace adds NO item — an implementation that loaded the new file as "
        ~ "a new row and re-pointed the referrers reads 7 here");
    assert(f.clipB.imageOrNull() is payloadBefore,
        "the payload is the SAME object, mutated in place");

    foreach (i, consumer; [f.consumerX, f.consumerY]) {
        immutable who = i == 0 ? "consumerX" : "consumerY";
        auto seen = consumer.link("backdropImage").resolve(f.doc);
        assert(seen is f.clipB, who ~ " still names the same item");
        assert(seen.imageOrNull().storedPath == newPath,
            who ~ " sees the NEW file without having been touched");
        assert(seen.imageOrNull().width == 5 && seen.imageOrNull().height == 7,
            who ~ " sees the new file's dimensions (5x7, not the old 3x2)");
    }
    assert(f.consumerX.linkSlots().length == slotsX
        && f.consumerX.linkSlots()[0].name == "backdropImage",
        "no consumer's slot set was edited to make this work");
    // Vacuity guard ([[0617]]'s second half — breaking a line proves the
    // assertion DEPENDS on it, not that the assertion can express a wrong
    // answer at all): a DIFFERENT clip in the same document still reads the
    // old path and the old 3x2, so "5x7 at the new path" is a value this
    // fixture distinguishes rather than a constant every row would satisfy.
    assert(f.clipA.imageOrNull().storedPath == f.pathA
        && f.clipA.imageOrNull().width == 3 && f.clipA.imageOrNull().height == 2,
        "vacuity guard: clipA is untouched by clipB's replace");

    assert(c.revert(), "undo restores the previous file");
    assert(f.clipB.imageOrNull() is payloadBefore, "still the same payload object");
    assert(f.clipB.imageOrNull().storedPath == f.pathB, "the old path is back");
    assert(f.clipB.imageOrNull().width == 3 && f.clipB.imageOrNull().height == 2,
        "and so is the old derived metadata — undo restores the DOCUMENT, it "
        ~ "does not re-observe the disk");
    assert(f.consumerY.link("backdropImage").resolve(f.doc).imageOrNull().storedPath
        == f.pathB, "and both consumers follow the undo too");
}

// ---------------------------------------------------------------------------
// REPLACE THE COPY of a duplicated image row — the SOURCE does not follow.
//
// Reachable end to end through registered commands: `image.load` (in the
// fixture) → `layer.duplicate` that row → `image.replace` the COPY. That is
// what made this live rather than latent: `LayerDuplicate` handed its clone
// the source's payload OBJECT, which was inert until Ph5 shipped the first
// command that writes one.
//
// Discriminating: the SOURCE's path and BOTH dimensions are read after the
// copy is re-pointed at a 5x7 file. Through a shared payload the source reads
// the new path and 5x7, and the undo of that replace writes through both rows
// as well — so the last assertion here is a second, independent read of the
// same defect.
// ---------------------------------------------------------------------------
unittest {
    import std.json : parseJSON;
    import std.conv  : to;
    import params    : injectParamsInto;
    import commands.layer.commands : LayerDuplicate;

    auto f = makeImgFixture("dup_replace");
    auto srcPayload = f.clipB.imageOrNull();
    auto newPath    = buildPath(f.dir, "foxtrot.bmp");
    writeTestBmp(newPath, 5, 7);

    // Duplicate clipB through the command, driven by the generic param
    // injection (its `indexArg` is private to its own module).
    auto dup = new LayerDuplicate(f.doc.activeMesh(), f.view, EditMode.Vertices,
                                  &f.doc, null);
    auto dj = parseJSON(`{"index":` ~ f.doc.indexOf(f.clipB).to!string ~ `}`);
    injectParamsInto(dup.params(), dj);
    assert(dup.apply(), "layer.duplicate applies to an image row");

    auto copy = f.doc.layers[$ - 1];
    assert(copy !is f.clipB && copy.kind == ItemKind.Image,
        "fixture: the clone is a NEW image item at the tail");
    assert(copy.imageOrNull() !is null
        && copy.imageOrNull().storedPath == f.pathB,
        "fixture: the clone starts on the source's file");

    auto c = new ImageReplace(f.doc.activeMesh(), f.view, EditMode.Vertices,
                              &f.doc, null);
    c.indexArg = cast(int)(f.doc.layers.length - 1);   // the COPY
    c.pathArg  = newPath;
    assert(c.apply(), "replace applies to the copy");

    assert(copy.imageOrNull().storedPath == newPath
        && copy.imageOrNull().width == 5 && copy.imageOrNull().height == 7,
        "the COPY is re-pointed, which is what was asked for");
    assert(f.clipB.imageOrNull() is srcPayload,
        "the source still holds its own payload OBJECT");
    assert(f.clipB.imageOrNull().storedPath == f.pathB,
        "and it still names the OLD file — through a shared payload this "
        ~ "reads the replacement's path");
    assert(f.clipB.imageOrNull().width == 3 && f.clipB.imageOrNull().height == 2,
        "with the OLD dimensions — 3x2, not the replacement's 5x7");
    assert(f.consumerX.link("backdropImage").resolve(f.doc).imageOrNull()
            .storedPath == f.pathB,
        "so a consumer of the SOURCE saw nothing happen at all");

    // The undo is the second read of the same defect: through a shared payload
    // it restores the pre-replace path into BOTH rows, which is only visible
    // if the copy is checked afterwards.
    assert(c.revert(), "undo of the replace");
    assert(copy.imageOrNull().storedPath == f.pathB, "the copy is back");
    assert(f.clipB.imageOrNull().storedPath == f.pathB
        && f.clipB.imageOrNull().width == 3,
        "and the source was never part of any of it");
}

// ---------------------------------------------------------------------------
// REPLACE with an unreadable path leaves the item exactly as it was.
//
// Discriminating: the assertion is the STATE AFTERWARDS on all five fields. A
// "write the path first, refresh, return false on failure" implementation
// reads the bad path in `storedPath` and `missing == true` — a working
// reference traded for a broken one by a command that reported failure.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeImgFixture("replace_bad");
    auto img = f.clipB.imageOrNull();

    auto c = new ImageReplace(f.doc.activeMesh(), f.view, EditMode.Vertices,
                              &f.doc, null);
    c.indexArg = cast(int) f.doc.indexOf(f.clipB);
    c.pathArg  = buildPath(f.dir, "nope.bmp");
    assert(!c.apply(), "an unreadable replacement is refused");

    assert(img.storedPath == f.pathB, "the old path is untouched");
    assert(img.width == 3 && img.height == 2 && img.channels == 3,
        "and so is every derived field");
    assert(!img.missing, "the item is still resolved — it never stopped being");
    assert(f.consumerX.link("backdropImage").resolve(f.doc).imageOrNull().storedPath
        == f.pathB, "the consumers never saw a broken intermediate state");
}

// ---------------------------------------------------------------------------
// RELOAD re-reads the same path.
//
// Discriminating: the file is REWRITTEN in place at a different size while
// the item holds it. Before the reload the item must still read 3x2 (nothing
// re-reads implicitly), and after it 5x7 — a reload that is a no-op, or that
// serves a cached answer, reads 3x2 on the second assertion. `storedPath` is
// asserted unchanged throughout: the path is what did NOT change here.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeImgFixture("reload");
    auto img = f.clipB.imageOrNull();
    assert(img.width == 3 && img.height == 2, "fixture: the item read 3x2");

    writeTestBmp(f.pathB, 5, 7);              // same path, different content
    assert(img.width == 3 && img.height == 2,
        "control: nothing re-reads the file behind the command's back");

    auto c = new ImageReload(f.doc.activeMesh(), f.view, EditMode.Vertices,
                             &f.doc, null);
    c.indexArg = cast(int) f.doc.indexOf(f.clipB);
    assert(c.apply(), "reload applies");
    assert(img.width == 5 && img.height == 7,
        "the item now reports what is ON DISK — a no-op reload reads 3x2");
    assert(img.storedPath == f.pathB, "and the path is what did not change");

    // A reload is NOT undoable: it writes only derived state, and there is no
    // prior document state for an undo entry to carry.
    assert(!c.isUndoable(),
        "image.reload records no undo entry (SideEffect) — undoing it would "
        ~ "restore metadata the disk has already contradicted");
}

// ---------------------------------------------------------------------------
// RELOAD of a file that has gone: the item SURVIVES and reports itself
// unresolved. This is the other half of the failed-load decision.
//
// Discriminating: three separate reads. `storedPath` byte-identical (an
// implementation that "cleaned up" the dead path reads ""), the item still
// present (one that dropped the row reads a shorter document), and
// `missing == true` with cleared dimensions (one that left the stale 3x2
// beside `missing` reads 3). Then the file comes back and a second reload
// resolves it again — which is only possible because the path survived.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeImgFixture("reload_gone");
    auto img = f.clipB.imageOrNull();
    remove(f.pathB);

    auto c = new ImageReload(f.doc.activeMesh(), f.view, EditMode.Vertices,
                             &f.doc, null);
    c.indexArg = cast(int) f.doc.indexOf(f.clipB);
    assert(c.apply(),
        "the reload SUCCEEDS: \"the file is gone\" is the answer the caller "
        ~ "asked for, and failing here would report an error on top of a "
        ~ "state change that already happened");

    assert(f.doc.layers.length == 6, "the item is still in the document");
    assert(img.storedPath == f.pathB,
        "and still names the vanished file, byte for byte");
    assert(img.missing, "reporting itself unresolved");
    assert(img.width == 0 && img.height == 0,
        "with the derived fields cleared, not stale beside `missing`");

    writeTestBmp(f.pathB, 6, 8);              // the asset comes back
    auto c2 = new ImageReload(f.doc.activeMesh(), f.view, EditMode.Vertices,
                              &f.doc, null);
    c2.indexArg = cast(int) f.doc.indexOf(f.clipB);
    assert(c2.apply());
    assert(!img.missing && img.width == 6 && img.height == 8,
        "and resolves again — which is only reachable because the path was "
        ~ "never erased");
}

// ---------------------------------------------------------------------------
// RENAME is `layer.rename`, unchanged — and it must not touch the file.
//
// There is no `image.rename`: the existing command already does exactly the
// right thing (it writes `Layer.name` and nothing else), and a wrapper would
// only add a second way to be wrong. What this test pins is that the
// behaviour survives contact with an image row:
//
//   * the file on disk is untouched, asserted by BYTES at the old path (an
//     implementation that renamed the file on disk reads a missing file) and
//     by the absence of any file at the new name;
//   * `storedPath` is untouched — the name and the path are different fields;
//   * and, the discriminating one, the new name SURVIVES A RELOAD. An
//     implementation that derived the display name from the path (or that had
//     `image.reload` refresh the name along with the metadata — a very easy
//     line to write) reads "bravo" again here, and would have looked correct
//     in every assertion above it.
// ---------------------------------------------------------------------------
unittest {
    import std.file : read;
    import std.json : JSONValue, parseJSON;
    import std.conv : to;
    import params   : injectParamsInto;
    import commands.layer.commands : LayerRename;

    auto f = makeImgFixture("rename");
    auto img = f.clipB.imageOrNull();
    auto bytesBefore = cast(ubyte[]) read(f.pathB);

    auto r = new LayerRename(f.doc.activeMesh(), f.view, EditMode.Vertices,
                             &f.doc, null);
    // Driven through the generic param injection — the same route
    // `/api/command` uses — rather than by poking private fields, so the attr
    // NAMES used here are the ones a caller actually has to spell. A
    // misspelled name is silently ignored by the injector (task 0633), which
    // would leave the default index (-1 => the active MESH) and rename the
    // wrong row: the `f.clipB.name` assertion below is what catches that.
    auto pj = parseJSON(`{"index":` ~ f.doc.indexOf(f.clipB).to!string
                        ~ `,"name":"Backdrop plate"}`);
    injectParamsInto(r.params(), pj);
    assert(r.apply(), "layer.rename applies to an image row");

    assert(f.clipB.name == "Backdrop plate", "the display name changed");
    assert(img.storedPath == f.pathB,
        "the PATH did not — the name is a different field entirely");
    assert(exists(f.pathB), "the file is still where it was");
    assert(cast(ubyte[]) read(f.pathB) == bytesBefore,
        "byte for byte — renaming the ROW must never rename the FILE");
    assert(!exists(buildPath(f.dir, "Backdrop plate.bmp")),
        "and no file appeared under the new name");

    auto rl = new ImageReload(f.doc.activeMesh(), f.view, EditMode.Vertices,
                              &f.doc, null);
    rl.indexArg = cast(int) f.doc.indexOf(f.clipB);
    assert(rl.apply());
    assert(f.clipB.name == "Backdrop plate",
        "the rename survives a reload — a name DERIVED from the path would "
        ~ "read \"bravo\" here");

    assert(r.revert(), "and the rename undoes");
    assert(f.clipB.name == "bravo", "back to the file stem");
    assert(cast(ubyte[]) read(f.pathB) == bytesBefore, "still untouched on disk");
}
