module commands.image_plane.commands;

// ---------------------------------------------------------------------------
// Task 0612 Stage 3/7 — the reference-image plane's commands.
//
//   imagePlane.add     name image projection   Model — create a plane
//   imagePlane.setImage index image            Model — point it at a clip
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
import document   : Document, Layer, ItemKind, ImagePlaneData, kindInfo;
import seltype    : SelMode;
import image_plane : kImageLinkSlot;
import change_bus : noteLayerChange, LayerChange;
import log        : logWarn;

// ---------------------------------------------------------------------------
// imagePlane.add — create a reference-image plane item.
//
// THE ROUTE THAT MAKES THE FEATURE EXIST. Until this command, a plane could
// only be put in a live document by `POST /api/test/layer`, the test-only
// injector — the draw pass, the placement law and the link were all correct
// and all unreachable. This is the producer.
//
// WHY THE CREATION BAN THIS LIFTS DOES NOT APPLY. Task 0615 shipped its
// non-mesh kind with no creation route on a stated premise: nothing
// serialised a non-mesh item, so a created one would be gone after a save.
// v8 (task 0616) writes and reads the item — its `"type"` token, its name,
// its visibility, its twelve transform components and its link slots all
// round-trip. ~~What does NOT round-trip is the plane's OWN payload object …
// the ten channels read their defaults.~~
//
// CLOSED (task 0612 Stage 9), and the finding was worth stating here: the
// reader's payload block does two jobs — it reads a block off the wire AND it
// constructs the object the channel injection binds into — and it had an arm
// for `hasMesh`, an arm for `hasImage` and nothing else. The plane needs only
// the second job, which is why an analysis that asked "does this kind need a
// block in the file?" answered correctly (no) and still shipped a hole. The
// arm exists now; `kV3dFormatVersion` never moved off 8.
//
// UNDO CLASS — Model (the base default): this creates document content.
//
// SELECTION IS FOLDED IN, and that is a deliberate split from `image.load`
// one module over, which pointedly does NOT fold it. The two differ on the
// axis their own comments name: an image clip is a document RESOURCE with
// no place in the scene, so there is no "make it active" to perform; a plane
// is a SCENE ITEM, and `layer.add` — the other scene-item creator — makes
// the item it created the active one inside the same Model command. Creating
// a plane and then having to find it in the list to edit its channels is the
// behaviour that split would buy, and one Ctrl+Z undoing "the plane I just
// made appeared and got selected" is the behaviour a user expects from Add.
// ---------------------------------------------------------------------------

final class ImagePlaneAdd : Command {
    private Document* doc;
    private string nameArg;                    // "" → auto "Plane N"
    private int    imageArg = -1;              // -1 → created unbound
    private string projectionArg = "front";

    // Held BY OBJECT across undo and re-appended on redo, for the reason
    // `ImageLoad.apply` spells out: a link names the target `Layer` OBJECT,
    // so a redo that minted a fresh item would leave every link that
    // survived the undo pointing at a non-member — permanently `Dangling`,
    // with a visually identical row sitting right there. A plane is on the
    // consumer side of that relation today, but `Document.referrersOf` is a
    // sweep over items, and nothing stops a future consumer naming a plane.
    private Layer created_;
    private Layer target_;               ///< the clip resolved from `image`
    /// TASK 0671 — the whole item-selection state, captured once. Replaces
    /// the `prevSelected` / `prevPrimary` / `prevFocus` trio, which recorded a
    /// set of bits plus two DERIVED-or-coupled pointers and had to be replayed
    /// in a careful order to avoid one step undoing the previous one.
    private Document.ItemSelectionState prevSelection;
    private Layer prevPrimary;           ///< only for the switch-hook comparison
    private bool  applied;
    private string refusal_;

    /// app.d's `onActiveLayerChanged` (task 0668). Defaulted to `null` so the
    /// unit-test constructions that only want `name()` keep compiling;
    /// `registration.d` forwards the real one.
    private void delegate(size_t, size_t) onSwitch;

    this(Mesh* m, ref View v, EditMode em, Document* d,
         void delegate(size_t, size_t) onSwitch = null) {
        super(m, v, em);
        this.doc = d;
        this.onSwitch = onSwitch;
    }

    /// `LayerCommandBase.fireSwitchIfChanged`, restated here because this
    /// command does not extend that base (it is not an index-addressed layer
    /// command). Same contract: fire iff the primary LAYER OBJECT changed,
    /// after the mutation, with the PRE-mutation index.
    ///
    /// TASK 0668 — this command could not move the primary before, and its own
    /// comment said so. Now that an exclusive select of a plane clears the mesh
    /// edit target, it moves it on EVERY apply (mesh → none) and back on every
    /// revert, so the hook has to run: it drops the armed tool (whose bound
    /// `Mesh*` would otherwise keep writing into a layer that is now read-only
    /// background), re-uploads the GPU buffers against the absent target,
    /// resizes the pick caches and publishes `ActiveChanged`.
    private void fireSwitchIfChanged(Layer prevLayer, size_t prevIndex) {
        if (onSwitch is null) return;
        if (doc.active() is prevLayer) return;
        onSwitch(prevIndex, doc.activeIndex);
    }

    override string name()  const { return "imagePlane.add"; }
    override string label() const { return "Add Image Plane"; }

    override Param[] params() {
        return [
            Param.string_("name", "Name", &nameArg, ""),
            // Optional at creation: a plane with no image is a legal,
            // observable state (`Unbound`, §4.5) and the panel's Add button
            // has no clip to offer before the user picks one.
            Param.int_("image", "Image", &imageArg, -1),
            // The SAME closed token set as the channel's own declaration in
            // `layer_params.d`. Declared as `enum_` rather than `string_` so
            // `injectParamsInto` rejects an unknown token at the wire edge —
            // otherwise `projection:frnt` would create a plane whose channel
            // holds a value no viewport can ever match, and the failure
            // would present as "my reference image never appears".
            Param.enum_("projection", "Projection", &projectionArg,
                        [["top",    "Top"],
                         ["bottom", "Bottom"],
                         ["front",  "Front"],
                         ["back",   "Back"],
                         ["right",  "Right"],
                         ["left",   "Left"]],
                        "front"),
        ];
    }

    /// The created item, for a caller that wants it back (tests, and a panel
    /// that wants to name the new row). Null until a successful apply.
    Layer created() { return created_; }

    override bool apply() {
        refusal_ = "";

        // Same total-redo guard as `ImageLoad.apply`: not reachable through
        // the history stack, but `apply()` is a public method and refusing is
        // the honest answer to "do the thing that is already done".
        if (created_ !is null && doc.isMember(created_)) {
            refuse("already applied — the item is in the document");
            return false;
        }

        if (created_ is null) {
            if (imageArg >= 0) {
                target_ = resolveClip(imageArg);
                if (target_ is null) return false;   // refusal already set
            }
            auto l = new Layer;
            l.kind    = ItemKind.ImagePlane;
            l.visible = true;
            // The payload is constructed HERE and not lazily: `layer_params
            // .d`'s bundle binds its ten `Param` pointers straight into this
            // object, and its documented fallback for a null payload is the
            // BASE bundle — i.e. a plane created without one would present
            // as an item with no channels at all rather than as an error.
            l.imagePlaneRef() = new ImagePlaneData();
            l.imagePlaneRef().projection = projectionArg;
            l.name = nameArg.length ? nameArg : autoName();
            if (target_ !is null) l.setLink(kImageLinkSlot, target_);
            created_ = l;
        }

        // Snapshot the prior selection BEFORE the mutator collapses it, by
        // OBJECT identity (the `LayerDuplicate` / `LayerDelete` pattern) so a
        // multi-selection is restored exactly and not flattened to a
        // set-of-one by the undo.
        prevPrimary   = doc.primary;
        prevSelection = doc.captureItemSelection();   // task 0671: the WHOLE state
        immutable size_t prevActiveIndex = doc.activeIndex;

        doc.layers ~= created_;
        // SET-of-one, and since task 0668 it is a genuine SET-of-ONE: the
        // exclusive select drops every other item, INCLUDING the mesh that
        // was the edit target. It used to spare the mesh, which is how
        // creating a reference plane left the model selected alongside it.
        // The plane becomes the item-selection FOCUS — what the properties
        // form binds (`itemPropsTarget`), which is what makes the new plane's
        // channels editable the moment it exists — and the document is left
        // with NO mesh edit target until the user selects a mesh again.
        doc.selectItem(created_, SelMode.Set);
        applied = true;
        noteLayerChange(LayerChange.Added);
        // Task 0668: the primary DID move (mesh → none), so the switch hook
        // runs. Ordered after `noteLayerChange(Added)` for the same reason
        // `LayerDelete` orders its pair that way — the structural event
        // describes the list, the switch event describes the edit target, and
        // the hook itself publishes `ActiveChanged`.
        fireSwitchIfChanged(prevPrimary, prevActiveIndex);
        return true;
    }

    override bool revert() {
        if (!applied || created_ is null) return false;
        immutable size_t i = doc.indexOf(created_);
        if (i == doc.layers.length) return false;   // already gone

        // Task 0668: the undo RESTORES the edit target the apply cleared, so
        // it is a primary move in its own right and owes the hook the same
        // pre-mutation pair the apply does. Captured here, before anything
        // moves — at this point `active()` is normally null (the apply left
        // the plane alone in the selection).
        auto   prevLayer = doc.active();
        immutable size_t prevIdx = doc.activeIndex;

        // Move the selection off the item through the MUTATOR before the
        // splice, so `focusedItem` can never be left naming a non-member.
        if (created_.selected) doc.selectItem(created_, SelMode.Remove);
        doc.layers = doc.layers[0 .. i] ~ doc.layers[i + 1 .. $];

        // TASK 0671 — one exact restore replaces the set / primary / focus
        // trio. ~~Restore the exact prior selection set, then the prior
        // primary, then the prior FOCUS. The third step is the one
        // `LayerDuplicate.revert` does not need and this command does:
        // `setPrimary` homes the focus onto the primary…~~ — a three-step
        // reconstruction existed because the state was three loosely coupled
        // pointers and each step could undo the previous one's side effect.
        // The snapshot carries the current list, its order, the deselect
        // history and the focus together, so there are no side effects to
        // sequence and no `prevFocus` field at all.
        //
        // 0668's note here — "make sure the undo returns the previous PRIMARY
        // rather than leaving the document empty" — is satisfied for a reason
        // that no longer needs stating at this site: the apply never took the
        // target away (a plane's selection flushes the PLANE bucket), so there
        // is nothing for the undo to put back.
        doc.restoreItemSelection(prevSelection);

        applied = false;
        noteLayerChange(LayerChange.Removed);
        fireSwitchIfChanged(prevLayer, prevIdx);
        return true;
    }

    override string refusalReason() const { return refusal_; }

    /// "Plane N", numbered over the planes that already exist rather than
    /// over `layers.length` — `layer.add`'s "Layer N" counts the whole list,
    /// which on a document holding meshes, clips and planes produces names
    /// that jump. Not unique by construction (a rename or a delete can
    /// collide it) and not required to be: nothing addresses an item by name.
    private string autoName() {
        import std.conv : to;
        size_t n = 0;
        foreach (l; doc.layers) if (l.hasImagePlane) ++n;
        return "Plane " ~ to!string(n + 1);
    }

    /// Resolve an index to an image clip WITH a payload, or null. Same rule
    /// as `ImagePlaneSetImage.resolveClip` below and the same reason: no
    /// default-to-active (which the document invariant makes a MESH) and no
    /// clamp (which would silently retarget an off-by-one at the last row).
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
        logWarn("imagePlane", "imagePlane.add refused: " ~ why);
    }
}

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
