module commands.image_plane.commands;

// ---------------------------------------------------------------------------
// Task 0612 Stage 3 — the reference-image plane's commands.
//
//   imagePlane.setImage index image   Model — point a plane at an image clip
//
// This is the tree's FIRST PRODUCTION `setLink` CALLER. The link mechanism
// shipped a task ago with no producer at all: every slot name in the tree so
// far (`"backdropImage"`, `"maskImage"`, `"decalImage"`) belongs to a fixture.
// So the whole of the link model — checked resolution, identity-by-object,
// never-swept, restored-by-undo-for-free — becomes reachable here for the
// first time, and this command is what a test can finally drive it through.
//
// UNDO CLASS — Model, by the criterion the sibling image commands write down:
// not "is the field persisted" but "does this edit change what the document
// IS, or how the user is currently looking at it". Which image a plane shows
// is content: it is what the plane renders, it is what `.v3d` carries, and it
// is the whole reason the item exists. `layer.select` is `UiState` while its
// flag IS persisted; this is the mirror case.
//
// WHY THE LINK IS NOT A `Param`. Every other channel on a plane rides the
// generic `layer.attr` path (`layer_params.d` declares them, one declaration
// driving the panel row, the write and the read-back). A link cannot: it
// names a `Layer` OBJECT, and a `Param` is a typed pointer to a scalar. An
// index would be the obvious encoding and is exactly the identity scheme the
// link model rejects — `layers[]` is spliced by delete and permuted by
// reorder, and a stored index survives neither, failing by addressing the
// NEIGHBOUR rather than by breaking. So the link gets a command, and the
// index it takes is resolved to an object AT DISPATCH TIME, while the array
// it indexes is the one the caller was looking at.
// ---------------------------------------------------------------------------

import command;
import mesh;
import view;
import editmode;
import params     : Param;
import document   : Document, Layer, ItemKind, kindInfo;
import image_plane : kImageLinkSlot;
import change_bus : noteLayerChange, LayerChange;
import log        : logWarn;

// ---------------------------------------------------------------------------
// imagePlane.setImage — bind (or clear) a plane's image link.
// ---------------------------------------------------------------------------

final class ImagePlaneSetImage : Command {
    private Document* doc;
    private int  planeArg = -1;
    private int  imageArg = -1;
    // Both ends are resolved ONCE, on the first apply, and then held BY
    // OBJECT. A redo must re-establish the binding this command originally
    // made, and by the time it runs `layers[]` may have been spliced or
    // permuted by anything else on the stack — so re-resolving the stored
    // INDEX on redo is how a redo silently binds the neighbour. Same reason
    // the link model refuses to store an index in the first place.
    private Layer plane_;      ///< the plane, resolved at the first apply
    private Layer target_;     ///< the clip it was asked to bind (null = clear)
    private Layer prevTarget_; ///< what the slot held BEFORE, for revert
    private bool  resolved;    ///< true once the pair above has been resolved
    private bool  applied;
    private string refusal_;

    this(Mesh* m, ref View v, EditMode em, Document* d) {
        super(m, v, em);
        this.doc = d;
    }

    override string name()  const { return "imagePlane.setImage"; }
    override string label() const { return "Set Plane Image"; }

    override Param[] params() {
        return [
            // `index` names the PLANE; `image` names the clip. Two indices
            // into one array is exactly the shape an argument mix-up hides
            // in, so each is resolved through its own capability-checked
            // helper below and a swap is refused rather than silently
            // performed on the wrong pair.
            Param.int_("index", "Plane",  &planeArg, -1),
            Param.int_("image", "Image",  &imageArg, -1),
        ];
    }

    override bool apply() {
        refusal_ = "";

        // Applying twice without a revert in between would overwrite
        // `prevTarget_` with this command's OWN result, and the revert would
        // then restore the intermediate state instead of the original. Not
        // reachable through the history stack (it never redoes an entry it
        // has not first undone), but `apply()` is a public method and the
        // guard is what makes the redo branch total rather than
        // correct-by-caller-discipline. Refusing is the honest answer: the
        // caller asked for something already true.
        if (applied) { refuse("already applied"); return false; }

        if (!resolved) {
            plane_ = resolvePlane(planeArg);
            if (plane_ is null) return false;
            if (imageArg >= 0) {
                target_ = resolveClip(imageArg);
                if (target_ is null) return false;
            }
            resolved = true;
        }

        // Capture the PREVIOUS target before the write, by object.
        prevTarget_ = plane_.link(kImageLinkSlot).targetUnchecked();

        plane_.setLink(kImageLinkSlot, target_);
        applied = true;
        noteLayerChange(LayerChange.PropertyChanged);
        return true;
    }

    override bool revert() {
        if (!applied || plane_ is null) return false;
        // `setLink(name, null)` REMOVES the slot rather than leaving an unset
        // one behind, which is what makes "there was no link before" restore
        // exactly, with no second representation of "points at nothing" for a
        // later reader to have to tell apart.
        plane_.setLink(kImageLinkSlot, prevTarget_);
        applied = false;
        noteLayerChange(LayerChange.PropertyChanged);
        return true;
    }

    override string refusalReason() const { return refusal_; }

    /// Resolve an index to an image-PLANE item, or null.
    ///
    /// No default-to-active and no out-of-range clamp, for the reasons the
    /// image commands' own resolver states: `-1` would answer the active
    /// layer, which the document invariant makes a MESH — the worst possible
    /// fallback for this command — and a clamp would silently retarget an
    /// off-by-one at whichever row sits last.
    private Layer resolvePlane(int raw) {
        if (raw < 0) { refuse("needs an explicit `index` naming the plane"); return null; }
        immutable size_t i = cast(size_t) raw;
        if (i >= doc.layers.length) { refuse("`index` out of range"); return null; }
        auto l = doc.layers[i];
        // The CAPABILITY, never `kind == ItemKind.ImagePlane`.
        if (!l.hasImagePlane) { refuse("layer " ~ istr(raw) ~ " is not an image plane"); return null; }
        return l;
    }

    /// Resolve an index to an image clip WITH a payload, or null.
    private Layer resolveClip(int raw) {
        immutable size_t i = cast(size_t) raw;
        if (i >= doc.layers.length) { refuse("`image` out of range"); return null; }
        auto l = doc.layers[i];
        if (!l.hasImage || l.imageOrNull() is null) {
            refuse("layer " ~ istr(raw) ~ " is not a loaded image item");
            return null;
        }
        return l;
    }

    private static string istr(int v) { import std.conv : to; return v.to!string; }

    private void refuse(string why) {
        refusal_ = why;
        logWarn("imagePlane", "imagePlane.setImage refused: " ~ why);
    }
}
