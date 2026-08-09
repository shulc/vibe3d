module image_plane;

// ---------------------------------------------------------------------------
// Task 0612 — the reference-image plane, as a pure module.
//
// Everything that decides what a plane IS, as opposed to how it is drawn:
//
//   * the SOURCE half (Stage 3) — which clip a plane names, and what to say
//     when that answer is unusable;
//   * the PLACEMENT law (Stage 4) — `resolvePlacement`, the six-axis table,
//     and the live-path collection the pixel cache reconciles against
//     (~~"land here in a later stage"~~ — they landed);
//   * the PICKER contents (Stage 7) — which clips a plane's image combo
//     offers and which `layers[]` index each row dispatches.
//
// This module is deliberately the home of all of it, so the plane's rules sit
// in one place rather than being spread across the panel, the command and the
// document — and so the parts a headless test can reach are the parts that
// decide anything.
//
// No GL and no ImGui here, on purpose: this module is gated by
// `dub test --config=modeling`, which is where the assertions that matter can
// actually run.
// ---------------------------------------------------------------------------

import document : Document, Layer, LinkState, ImagePlaneData, ItemXform;
import math;
import view : ViewPreset, presetBasis;

/// The slot name a plane's image link lives under.
///
/// A named constant rather than the literal at each site, because the command
/// that writes it, the predicate that reads it and the reporter that shows it
/// would otherwise be three independent chances to type a slot name that
/// silently resolves to `Unset` — the link API's absent-slot answer and its
/// never-set answer are deliberately the same state, so a typo has no error
/// to raise.
///
/// `"image"` is a NEW name: the slot names already in the tree
/// (`"backdropImage"`, `"maskImage"`, `"decalImage"`) are fixture-only, and a
/// production slot that aliased one of them would make a test's decoy link
/// indistinguishable from a real one.
enum kImageLinkSlot = "image";

/// Why a plane can or cannot show pixels. Four states, deliberately NOT
/// collapsed into a bool:
///
/// * `Unbound`  — no clip has been chosen yet. The user's next move is to
///                pick one.
/// * `Dangling` — a clip was chosen and the clip ITEM is gone (deleted). The
///                user's next move is to undo, or to pick another.
/// * `Missing`  — the clip is there and its FILE is not. The user's next move
///                is on the filesystem, and the stored path is what they need
///                to see.
/// * `Ready`    — usable.
///
/// Each one implies a different next action, so a UI that collapses them can
/// only ever say "no image" and leave the user to guess which of three
/// unrelated problems they have. It is also why residency and drawing are
/// answered separately: a HIDDEN plane is `Ready` and simply not drawn, which
/// is not a source problem at all and must not be reported as one.
enum ImagePlaneSource : ubyte {
    Unbound  = 0,
    Dangling = 1,
    Missing  = 2,
    Ready    = 3,
}

/// The wire token for `s` — the spelling `/api/*` and any panel row use, so
/// the two cannot drift.
string sourceToken(ImagePlaneSource s) pure nothrow @safe {
    final switch (s) {
        case ImagePlaneSource.Unbound:  return "unbound";
        case ImagePlaneSource.Dangling: return "dangling";
        case ImagePlaneSource.Missing:  return "missing";
        case ImagePlaneSource.Ready:    return "ready";
    }
}

/// What `plane`'s image link resolves to, against `doc`.
///
/// Answers `Unbound` for a layer that is not a plane at all: an item with no
/// image slot has no image, which is the same observable, and inventing a
/// fifth state for "you asked the wrong item" would put a caller error into a
/// user-facing enum.
///
/// The three failure states are distinguished by ASKING THE RIGHT QUESTION IN
/// ORDER — link state first, then the clip's own `missing` flag — rather than
/// by one combined test. A single `resolve() is null || missing` check reads
/// the same for a deleted clip and a deleted file, and those are the two
/// cases whose remedies have nothing in common.
ImagePlaneSource imagePlaneSource(const ref Document doc, const(Layer) plane) {
    if (plane is null || !plane.hasImagePlane) return ImagePlaneSource.Unbound;

    auto link = plane.link(kImageLinkSlot);
    final switch (link.state(doc)) {
        case LinkState.Unset:    return ImagePlaneSource.Unbound;
        case LinkState.Dangling: return ImagePlaneSource.Dangling;
        case LinkState.Live:     break;
    }

    auto clip = link.resolve(doc);
    // A live link to an item that carries no image payload is `Missing`, not
    // `Ready`: there is a target and no pixels behind it, which is exactly
    // what `Missing` means to the user. (Reachable only through the test-only
    // injector, which can create an image-kind row with no payload — but a
    // predicate that answered `Ready` there would hand the draw a null.)
    auto img = clip is null ? null : clip.imageOrNull();
    if (img is null || img.missing) return ImagePlaneSource.Missing;
    return ImagePlaneSource.Ready;
}

// ---------------------------------------------------------------------------
// Stage 7 — what the plane's image picker offers.
//
// The picker is a combo box in the item-properties area, and the ONE thing it
// can get wrong is not visible on screen: the clips are a FILTERED subset of
// `Document.layers`, so the row's position in the combo is not the index the
// command takes. A picker that dispatched its own list position would bind the
// wrong clip on any document where a mesh or a plane sits before a clip — i.e.
// on every real document, since the mesh primary is always item 0. Building
// the list here rather than inside the ImGui body is what lets that be
// asserted at all: an ImGui body cannot be driven headlessly, so everything
// assertable about the picker lives in this pure function and what is left in
// the panel is a loop over its result.
// ---------------------------------------------------------------------------

/// One entry in a plane's image picker.
struct PlaneImageChoice {
    /// Index into `Document.layers` — NOT the position of this entry in the
    /// returned array. `-1` is the "no image" entry, which is what
    /// `imagePlane.setImage image:-1` clears the slot with.
    int    layerIndex;
    /// What the row reads. The clip item's display name, or "(none)".
    string label;
    /// True on the entry the plane is bound to right now — exactly one entry
    /// carries it (the "(none)" row when the link is `Unset`, and no entry at
    /// all when the link is `Dangling`, which is a state no clip in the list
    /// can represent).
    bool   current;
}

/// The picker's contents for `plane`, against `doc`.
///
/// Always leads with the "no image" entry: clearing a link has to be
/// reachable, and a picker whose first row was a clip would make "unbind"
/// impossible without deleting the clip.
///
/// Matching is by OBJECT identity against the link target, never by path and
/// never by name — the two decoys the link model's own comment names. Two
/// clips on one file, or two clips renamed alike, are two distinct rows here
/// and only the bound one is `current`.
PlaneImageChoice[] planeImageChoices(const ref Document doc, const(Layer) plane) {
    PlaneImageChoice[] out_;
    if (plane is null || !plane.hasImagePlane) return out_;

    // `targetUnchecked` rather than `resolve`: a DANGLING link names an
    // object that is no longer a member, and resolving it would answer null —
    // the same answer as `Unset`. The distinction does not change what the
    // picker offers, but it does change which row is marked, and marking
    // "(none)" for a dangling link would tell the user their choice was never
    // made rather than that it was lost.
    auto bound = plane.link(kImageLinkSlot).targetUnchecked();

    out_ ~= PlaneImageChoice(-1, "(none)", bound is null);
    foreach (i, l; doc.layers) {
        if (!l.hasImage) continue;
        out_ ~= PlaneImageChoice(cast(int) i,
                                 l.name.length ? l.name : "(unnamed)",
                                 l is bound);
    }
    return out_;
}

// ===========================================================================
// Stage 4 — the placement law
// ===========================================================================

/// The six axis-aligned views a plane can be a reference FOR.
///
/// Exactly six — deliberately NOT `ViewPreset`, which also carries
/// `Perspective` and `Camera`. Those two name no axis, and a plane holding
/// one would make §4.3's match predicate compare a cell's free-orbit preset
/// against a plane's, i.e. draw a plane in a cell that is looking anywhere at
/// all. With this enum that state is UNREPRESENTABLE rather than merely
/// untested.
enum PlaneAxis : ubyte { Top, Bottom, Front, Back, Left, Right }

/// The camera preset a plane's axis corresponds to. Total, and the ONLY
/// bridge between the two enums, so "which cell shows this plane" is one
/// comparison of `ViewPreset`s rather than two parallel token sets.
ViewPreset presetOf(PlaneAxis a) @safe pure nothrow @nogc {
    final switch (a) {
        case PlaneAxis.Top:    return ViewPreset.Top;
        case PlaneAxis.Bottom: return ViewPreset.Bottom;
        case PlaneAxis.Front:  return ViewPreset.Front;
        case PlaneAxis.Back:   return ViewPreset.Back;
        case PlaneAxis.Left:   return ViewPreset.Left;
        case PlaneAxis.Right:  return ViewPreset.Right;
    }
}

/// The wire token for `a` — the same six spellings the `projection` channel's
/// `Param.enum_` declares (`layer_params.d`), because that declaration is what
/// `.v3d` stores and what a caller writes.
string tokenOfPlaneAxis(PlaneAxis a) @safe pure nothrow {
    final switch (a) {
        case PlaneAxis.Top:    return "top";
        case PlaneAxis.Bottom: return "bottom";
        case PlaneAxis.Front:  return "front";
        case PlaneAxis.Back:   return "back";
        case PlaneAxis.Left:   return "left";
        case PlaneAxis.Right:  return "right";
    }
}

/// Parse a `projection` channel value. `false` for anything else, leaving
/// `a` at its `.init` (`Top`) — callers must check.
///
/// The refusal is not defensive decoration: the channel is a closed
/// `Param.enum_`, so every write route (form, argstring, `/api/command`,
/// `.v3d`'s `channels` block) already refuses an unknown token before it can
/// be stored. What is left is a direct field poke from a fixture, and the
/// honest answer there is "this names no axis", NOT a silent fallback to
/// `front` — a fallback would make a typo draw a plausible-looking plane on
/// the wrong axis.
bool planeAxisFromToken(string tok, out PlaneAxis a) @safe pure nothrow {
    switch (tok) {
        case "top":    a = PlaneAxis.Top;    return true;
        case "bottom": a = PlaneAxis.Bottom; return true;
        case "front":  a = PlaneAxis.Front;  return true;
        case "back":   a = PlaneAxis.Back;   return true;
        case "left":   a = PlaneAxis.Left;   return true;
        case "right":  a = PlaneAxis.Right;  return true;
        default:       return false;
    }
}

/// Everything a draw pass needs about one plane in one cell, and nothing it
/// could compute differently.
///
/// The geometry is a centre plus TWO world half-extent vectors rather than
/// `(width, height, angle)`: two vectors carry an arbitrary item rotation and
/// they carry the aspect ratio too (it is `|halfU| / |halfV|`), while one
/// angle plus one scalar carries neither. The four corners are
/// `center ± halfU ± halfV`.
///
/// `drawn` and `source` are two fields, never one collapsed enum, because
/// "not drawn" and "no usable image" are different questions with different
/// remedies — a HIDDEN plane is `drawn == false` with `source == Ready`, and
/// its texture deliberately STAYS resident.
///
/// Every field carries an explicit initialiser: `Vec3`'s components are plain
/// `float`, whose `.init` is NaN, so a default-constructed placement without
/// these would carry a NaN quad rather than an empty one.
struct ImagePlanePlacement {
    bool             drawn  = false;      ///< itemVisible && Ready && this cell shows it
    ImagePlaneSource source = ImagePlaneSource.Unbound; ///< why not, when `!drawn`
    Vec3             center = Vec3(0, 0, 0);
    Vec3             halfU  = Vec3(0, 0, 0);
    Vec3             halfV  = Vec3(0, 0, 0);
    bool             flipU  = false;
    bool             invert = false;
    bool             smooth = false;
    float            brightness   = 0.0f;
    float            contrast     = 0.0f;
    float            transparency = 0.0f;
    string           sourcePath;          ///< resolved absolute path; "" unless Ready
}

/// The component of `s` along the world axis `axis` names.
///
/// `axis` is always one of the six signed unit axes from `presetBasis`, so
/// this is a selection, not a projection: `abs` is applied to the AXIS (to
/// undo the basis vector's sign) and never to the scale, because a negative
/// scale component is a legitimate authored value and must reach the law
/// unchanged (see the P0-e interim note on `resolvePlacement`).
private float axisComponent(Vec3 axis, Vec3 s) @safe pure nothrow @nogc {
    import std.math : abs;
    return abs(axis.x) * s.x + abs(axis.y) * s.y + abs(axis.z) * s.z;
}

/// Rotate a DIRECTION by a column-major affine matrix: the linear 3x3 block
/// only, so the translation columns cannot leak into a half-extent vector.
private Vec3 rotateDir(const float[16] m, Vec3 v) @safe pure nothrow @nogc {
    return Vec3(m[0]*v.x + m[4]*v.y + m[ 8]*v.z,
                m[1]*v.x + m[5]*v.y + m[ 9]*v.z,
                m[2]*v.x + m[6]*v.y + m[10]*v.z);
}

/// Where one plane's quad sits in the world, and whether the cell described
/// by `cellPreset` / `cellOrtho` draws it.
///
/// PURE — no GL, no ImGui, no cache, no `Document`. Its argument list is
/// exactly the measured law's input set: `p` carries `pixelSize` and the mode,
/// `clipW`/`clipH` carry the image's pixel dimensions (from the LINKED CLIP's
/// payload, which is where the disk's answer lives), and `x` carries the
/// scale. That is what makes every placement assertion a comparison of
/// numbers instead of an assertion about a pixel.
///
/// ── THE SIZE LAW (measured 2026-08-09, `doc/tasks/0612-evidence/`) ────────
///
///     W, H = clip pixel dimensions;  p = pixelSize;  su, sv = the item scale
///     components along the plane's own u / v axes.
///
///     keepAspect (the DEFAULT):  extentU = W*p*m,  extentV = H*p*m,
///                                where m = min(su, sv)      <- ONE scalar
///     !keepAspect:               extentU = H*p*su, extentV = H*p*sv
///                                                  ^^^ HEIGHT on BOTH axes
///
/// Three things there are counter-intuitive and each is pinned by measurement,
/// so none of them may be "cleaned up":
///
///   1. Under the default the scale collapses to ONE scalar, `min`. Raising
///      only one scale axis therefore changes NOTHING (the other axis still
///      supplies the minimum). That is what "keep aspect" means mechanically;
///      it is not a bug and there is a test that goes red if it is "fixed".
///   2. Keep-aspect OFF does not mean "use the raw pixel dimensions". It
///      means: make the quad SQUARE AT THE IMAGE'S HEIGHT, then stretch it
///      per axis. A tall fixture separates height from `min(W,H)`.
///   3. Scale never reaches the quad's corners. It is consumed HERE and
///      nowhere else.
///
/// ── THE CARRY ────────────────────────────────────────────────────────────
///
/// Position and rotation carry the quad RIGIDLY, so the matrix built below is
/// `T(pos)·T(pivot)·R·T(-pivot)` — deliberately `ItemXform.composedMatrix()`
/// MINUS its scale factor. **`composedMatrix()` must not be called from this
/// module**: it contains `S`, and pushing the corners through it applies the
/// scale a second time, on top of the extent formula that already consumed
/// it. That is a real, previously-shipped design, not a hypothetical.
///
/// ── TWO INTERIMS, LABELLED AS SUCH ───────────────────────────────────────
///
/// * **Which two scale components** (P0-d). Every captured row used a `front`
///   plane, where "item-local X/Y" and "the two axes spanning the plane" are
///   the same sentence. This takes the PLANE'S OWN SPANNING AXES, which makes
///   "the third component does nothing" a statement about the plane rather
///   than about the world, and degenerates to the measured behaviour for
///   `front`. It bites only a non-uniformly scaled non-front plane.
/// * **A negative scale component** (P0-e). `min(-1, 1) == -1` negates BOTH
///   half-extents, which is a 180° rotation rather than a mirror — plausible
///   and probably not what the reference does. The raw `min` is passed
///   through unchanged precisely so this code contains NO invented rule for a
///   case nobody has measured.
///
/// `pivot` is handled exactly as every other item's is; that is a
/// vibe3d-internal consistency claim (P0-f), not a parity one.
ImagePlanePlacement resolvePlacement(const ImagePlaneData p,
                                     bool itemVisible,
                                     int clipW, int clipH,
                                     ImagePlaneSource source, string absPath,
                                     ViewPreset cellPreset, bool cellOrtho,
                                     const ref ItemXform x)
{
    import std.math : isFinite;

    ImagePlanePlacement r;
    r.source = source;
    if (p is null) return r;

    // The look channels pass straight through: they are the shader's inputs,
    // not the placement's, and folding any of them into the geometry (a flip
    // implemented by negating `halfU`, say) would mirror the plane's PLACEMENT
    // as well as its pixels.
    r.flipU        = p.flipHorizontal;
    r.invert       = p.invert;
    r.smooth       = p.smooth;
    r.brightness   = p.brightness;
    r.contrast     = p.contrast;
    r.transparency = p.transparency;
    if (source == ImagePlaneSource.Ready) r.sourcePath = absPath;

    PlaneAxis axis;
    if (!planeAxisFromToken(p.projection, axis)) return r;
    Vec3 right, up;
    if (!presetBasis(presetOf(axis), right, up)) return r;   // unreachable: six axes

    // Scale-free RIGID carry — position and rotation only. See the warning
    // above about `composedMatrix()`.
    immutable float[16] rigid =
        matMul4(translationMatrix(x.pos),
        matMul4(translationMatrix(x.pivot),
        matMul4(matrixFromEulerZYX(x.rot),
                translationMatrix(Vec3(-x.pivot.x, -x.pivot.y, -x.pivot.z)))));
    r.center = transformPoint(rigid, Vec3(0, 0, 0));

    immutable float su = axisComponent(right, x.scl);
    immutable float sv = axisComponent(up,    x.scl);
    float extentU, extentV;
    if (p.keepAspect) {
        immutable float m = (su < sv) ? su : sv;
        extentU = clipW * p.pixelSize * m;
        extentV = clipH * p.pixelSize * m;
    } else {
        extentU = clipH * p.pixelSize * su;
        extentV = clipH * p.pixelSize * sv;
    }

    // The struct carries HALVES and the law is in FULL extents. This one
    // multiply is the whole conversion, written once, here — getting it wrong
    // makes every plane in the document twice its stated size, which reads as
    // a design choice rather than a bug until it is stood next to a 1 m cube.
    //
    // The finiteness gate is this side of the `Param` guard on purpose:
    // `enforceBounds` clamps with `<` / `>` comparisons, both of which are
    // FALSE against NaN, so a NaN `pixelSize` or scale reaches here intact.
    // A non-finite corner is undefined behaviour for the draw and an
    // uninterpretable number for the endpoint, so the plane is not drawable —
    // which is what `drawn == false` with an empty extent says.
    // The CENTRE is checked too, not only the extents: a non-finite `rot`
    // reaches the rigid matrix rather than the extent formula, so an
    // extents-only gate would let a NaN quad through by the other door.
    // (`sanitizeXform` rejects a non-finite component at every WRITE path, so
    // this is the second layer, not the only one — but this function is
    // public and pure, and a caller that assembles an `ItemXform` itself does
    // not go through that path.)
    if (!isFinite(extentU) || !isFinite(extentV)
     || !isFinite(r.center.x) || !isFinite(r.center.y) || !isFinite(r.center.z)) {
        r.center = Vec3(0, 0, 0);
        return r;
    }
    r.halfU = rotateDir(rigid, right * (0.5f * extentU));
    r.halfV = rotateDir(rigid, up    * (0.5f * extentV));

    // Which cell shows it — EXACT preset equality for an ortho cell (measured:
    // a `front` plane is NOT mirrored into `back`, and is not drawn in `top`),
    // and the plane's own opt-out for a free-orbit one (measured: it IS drawn
    // in perspective by default). An ortho cell whose preset is `Perspective`
    // or `Camera` (a free-orbit ortho, `view.d`'s own case) matches nothing,
    // because `presetOf` cannot return either.
    immutable bool cellShows = cellOrtho ? (cellPreset == presetOf(axis))
                                         : p.showInPerspective;
    r.drawn = itemVisible && source == ImagePlaneSource.Ready && cellShows;
    return r;
}

/// Every absolute file path a live plane→clip link names, for the pixel
/// cache to reconcile residency against.
///
/// This is the only code that knows what "live" MEANS, and it means two
/// things deliberately:
///
///   * `source == Ready` — the link resolves and the clip's file was read.
///     A `Dangling` / `Missing` / `Unbound` plane names no file to hold.
///   * **visibility is NOT consulted.** Residency follows the LINK; drawing
///     follows visibility (`resolvePlacement`'s `itemVisible`). Hiding a
///     backdrop and showing it again must be instant, not a trip through the
///     decoder — so a hidden plane keeps its texture, and that asymmetry is
///     the design, not an oversight.
///
/// Duplicates are not filtered: two clips on one file legitimately produce
/// the same path twice, and the cache treats a repeated path as one entry.
/// Filtering here would put a second, weaker copy of that rule in the caller.
string[] collectLivePlanePaths(const ref Document doc) {
    import io.image_path : resolveStoredPath;
    import io.doc_state  : currentDocPath;

    string[] paths;
    foreach (l; doc.layers) {
        if (l is null || !l.hasImagePlane) continue;
        if (imagePlaneSource(doc, l) != ImagePlaneSource.Ready) continue;
        auto clip = l.link(kImageLinkSlot).resolve(doc);
        if (clip is null) continue;
        auto img = clip.imageOrNull();
        if (img is null) continue;
        const abs = resolveStoredPath(img.storedPath, currentDocPath());
        if (abs.length) paths ~= abs;
    }
    return paths;
}

/// A digest of every input the image-plane draw pass reads, for the viewport
/// cell's dirty key (`viewport.d`'s `DirtyKey.imagePlaneKey`).
///
/// DERIVED, NOT BUMPED, and that is the whole design. The alternative — a
/// counter incremented at every write site — would need a bump at each plane
/// channel, the item transform, link set and clear, a clip's path change and
/// the texture upload; and item-transform writes go through `layer_params.d`'s
/// generic `Param` pointers, which are raw `float*` stores with nowhere to
/// hang a hook. A digest folded from what the pass CONSUMES cannot miss a
/// write the way a hand-kept list of bump sites can. It is the same argument
/// the `DrawPlan` terms in `DirtyKey` make for storing resolved plans.
///
/// The fold covers exactly `resolvePlacement`'s argument set (minus the cell,
/// which is the cell's own camera and is already in the key's `view`/`proj`),
/// plus the layer's INDEX — so a reorder that changes nothing else still
/// repaints — and `cacheEpoch`, which the caller supplies as the pixel cache's
/// decode count so a first upload repaints the cells that were waiting for it.
///
/// Floats are folded BY BIT PATTERN, deliberately: two NaNs compare unequal as
/// floats and identical as bits, and for a dirty key "nothing changed" is the
/// answer that must not flicker.
ulong imagePlaneDigest(const ref Document doc, ulong cacheEpoch) {
    import io.image_path : resolveStoredPath;
    import io.doc_state  : currentDocPath;

    ulong h = 0xcbf29ce484222325UL;                 // FNV-1a 64, offset basis
    void mixU(ulong v) {
        foreach (i; 0 .. 8) {
            h ^= (v >> (i * 8)) & 0xFF;
            h *= 0x100000001b3UL;                   // FNV prime
        }
    }
    void mixF(float f) {
        union U { float f; uint u; }
        U u; u.f = f;
        mixU(u.u);
    }
    void mixS(string s) { mixU(s.length); foreach (c; s) mixU(cast(ubyte) c); }
    void mixV(Vec3 v) { mixF(v.x); mixF(v.y); mixF(v.z); }

    mixU(cacheEpoch);
    foreach (i, l; doc.layers) {
        if (l is null || !l.hasImagePlane) continue;
        mixU(i);
        mixU(l.visible ? 1 : 0);
        auto p = l.imagePlaneOrNull();
        if (p is null) { mixU(0xDEAD); continue; }
        mixS(p.projection);
        mixU(p.showInPerspective ? 1 : 0);
        mixF(p.pixelSize);
        mixU(p.keepAspect ? 1 : 0);
        mixF(p.brightness); mixF(p.contrast); mixF(p.transparency);
        mixU(p.invert ? 1 : 0);
        mixU(p.flipHorizontal ? 1 : 0);
        mixU(p.smooth ? 1 : 0);
        const x = l.xform;
        mixV(x.pos); mixV(x.rot); mixV(x.scl); mixV(x.pivot);
        immutable src = imagePlaneSource(doc, l);
        mixU(cast(ulong) src);
        if (src == ImagePlaneSource.Ready) {
            auto clip = l.link(kImageLinkSlot).resolve(doc);
            auto img  = clip is null ? null : clip.imageOrNull();
            if (img !is null) {
                mixU(cast(ulong) img.width);
                mixU(cast(ulong) img.height);
                mixS(resolveStoredPath(img.storedPath, currentDocPath()));
            }
        }
    }
    return h;
}

// ===========================================================================
// Tests
// ===========================================================================

version (unittest) {
    import document : ItemKind, ImageData, ImagePlaneData;

    /// [mesh, clipA, clipB(middle target), clipC, plane] — three clips, the
    /// plane bound to the MIDDLE one, and clipA / clipC sharing ONE file path
    /// with it. The sharing is the point: with three distinct paths a
    /// path-identity bug would resolve to nothing and look like a broken
    /// link; with two decoys on the same path it resolves to the WRONG clip
    /// and every count still adds up.
    Document planeFixture(out Layer plane, out Layer target) {
        import mesh : makeCube;
        auto doc = Document.bootstrap(makeCube());

        Layer clip(string name, string path, bool missing) {
            auto l = new Layer;
            l.name = name;
            l.kind = ItemKind.Image;
            l.imageRef() = new ImageData();
            l.imageRef().storedPath = path;
            l.imageRef().missing    = missing;
            if (!missing) { l.imageRef().width = 5; l.imageRef().height = 7; }
            return l;
        }

        auto a = clip("decoy A", "sheet.png", false);
        auto b = clip("target",  "sheet.png", false);
        auto c = clip("decoy C", "sheet.png", false);

        auto p = new Layer;
        p.name = "front";
        p.kind = ItemKind.ImagePlane;
        p.imagePlaneRef() = new ImagePlaneData();

        doc.layers ~= a;      // 1
        doc.layers ~= b;      // 2  <- the target
        doc.layers ~= c;      // 3
        doc.layers ~= p;      // 4
        plane  = p;
        target = b;
        return doc;
    }
}

// The four states are four DIFFERENT answers, reached in order, from one
// fixture that can express all of them.
//
// Deliberate break (performed, then restored): folding the three failure
// states into one `resolve() is null || missing ⇒ Unbound` test reads
// "unbound" for the deleted-clip and deleted-file cases — the two whose
// remedies have nothing in common.
unittest {
    Layer plane, target;
    auto doc = planeFixture(plane, target);

    assert(imagePlaneSource(doc, plane) == ImagePlaneSource.Unbound,
        "a plane that has chosen no clip is Unbound");

    plane.setLink(kImageLinkSlot, target);
    assert(imagePlaneSource(doc, plane) == ImagePlaneSource.Ready,
        "bound to a readable clip: Ready");
    assert(plane.link(kImageLinkSlot).resolve(doc) is target,
        "and it resolves to the MIDDLE clip — the two decoys carry the same "
        ~ "path, so a path-keyed lookup lands on one of THEM, not on nothing");

    // The file goes away under a clip that is still there.
    target.imageRef().missing = true;
    assert(imagePlaneSource(doc, plane) == ImagePlaneSource.Missing,
        "the item is present and its file is not: Missing, never Dangling");
    target.imageRef().missing = false;

    // The clip ITEM goes away. The link is untouched — links are never swept
    // — and resolution is what notices.
    doc.layers = doc.layers[0 .. 2] ~ doc.layers[3 .. $];
    assert(imagePlaneSource(doc, plane) == ImagePlaneSource.Dangling,
        "the item is gone: Dangling, never Missing — the remedy is undo, not "
        ~ "the filesystem");
    assert(plane.link(kImageLinkSlot).targetUnchecked() is target,
        "the link still NAMES the removed clip: that is what makes re-adding "
        ~ "it (undo) restore the binding by identity, with nothing to redo");

    // Undo's shape: the same object back in the list, and the link is Live
    // again with no link-side work at all.
    doc.layers = doc.layers[0 .. 2] ~ target ~ doc.layers[2 .. $];
    assert(imagePlaneSource(doc, plane) == ImagePlaneSource.Ready,
        "re-inserting the SAME object makes the link Live again by identity");
}

// A live link to a payload-less image row is Missing, not Ready. Reachable
// through the test-only injector, and the state a draw would otherwise
// dereference a null in.
//
// Deliberate break (performed, then restored): returning `Ready` for any
// `Live` link reads "ready" for a clip with no payload at all.
unittest {
    Layer plane, target;
    auto doc = planeFixture(plane, target);
    auto bare = new Layer;
    bare.name = "no payload";
    bare.kind = ItemKind.Image;          // capability, but `imageRef()` unset
    doc.layers ~= bare;
    plane.setLink(kImageLinkSlot, bare);
    assert(imagePlaneSource(doc, plane) == ImagePlaneSource.Missing,
        "a live link to a row with no pixels behind it is Missing");
}

// Asking a non-plane is Unbound, not an assertion and not a fifth state.
unittest {
    Layer plane, target;
    auto doc = planeFixture(plane, target);
    assert(imagePlaneSource(doc, doc.layers[0]) == ImagePlaneSource.Unbound,
        "a mesh has no image link");
    assert(imagePlaneSource(doc, null) == ImagePlaneSource.Unbound,
        "and neither has null");
}

// The four tokens are four distinct strings — the wire spelling every reader
// keys on. A token table that repeated one value would make two states
// indistinguishable to every HTTP test downstream, while the enum above
// stayed perfectly correct.
unittest {
    import std.traits : EnumMembers;
    bool[string] seen;
    foreach (s; EnumMembers!ImagePlaneSource) {
        auto t = sourceToken(s);
        assert(t.length > 0, "every state has a token");
        assert(t !in seen, "tokens are pairwise distinct: '" ~ t ~ "' repeats");
        seen[t] = true;
    }
    assert(seen.length == 4, "four states, four tokens");
}

// ---------------------------------------------------------------------------
// Stage 7 — the image picker's contents.
//
// The fixture is built here rather than reusing `planeFixture` for one
// specific reason: there the three clips sit at layer indices 1, 2, 3 and
// would land at picker positions 1, 2, 3 — so the bug this test exists to
// catch (dispatching the picker POSITION instead of the layer index) would
// produce the right answer by coincidence and the test would be inert. The
// non-clip rows below are interleaved so no clip's layer index equals its
// picker position.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import std.format : format;

    auto doc = Document.bootstrap(makeCube());     // 0: mesh

    Layer clip(string name) {
        auto l = new Layer;
        l.name = name;
        l.kind = ItemKind.Image;
        l.imageRef() = new ImageData();
        l.imageRef().storedPath = "sheet.png";     // all three share one path
        l.imageRef().width = 5; l.imageRef().height = 7;
        return l;
    }
    Layer bareplane(string name) {
        auto l = new Layer;
        l.name = name;
        l.kind = ItemKind.ImagePlane;
        l.imagePlaneRef() = new ImagePlaneData();
        return l;
    }

    auto decoy = bareplane("other plane");
    auto meshB = new Layer; meshB.name = "mesh B"; meshB.meshRef() = makeCube();
    auto a = clip("A"), b = clip("B"), c = clip("C");
    auto plane = bareplane("front");
    doc.layers ~= decoy;   // 1  — a plane, not a clip: never an entry
    doc.layers ~= a;       // 2
    doc.layers ~= meshB;   // 3  — a mesh: never an entry
    doc.layers ~= b;       // 4  <- the one we bind, the MIDDLE clip
    doc.layers ~= c;       // 5
    doc.layers ~= plane;   // 6

    auto ch = planeImageChoices(doc, plane);
    assert(ch.length == 4,
        format("one 'no image' row plus one row per CLIP — read %d", ch.length));
    assert(ch[0].layerIndex == -1 && ch[0].label == "(none)",
        "the clear-the-link row leads, or unbinding is unreachable");

    // The load-bearing three: a picker row's `layerIndex` is its index in
    // `Document.layers`, never its position in this array.
    assert(ch[1].layerIndex == 2,
        format("clip A is layer 2, picker row 1 — read %d", ch[1].layerIndex));
    assert(ch[2].layerIndex == 4,
        format("clip B is layer 4, picker row 2 — read %d", ch[2].layerIndex));
    assert(ch[3].layerIndex == 5,
        format("clip C is layer 5, picker row 3 — read %d", ch[3].layerIndex));
    assert(ch[1].label == "A" && ch[2].label == "B" && ch[3].label == "C",
        "rows are labelled by the clip's own name, in `layers` order");

    // Unbound: the "(none)" row is the marked one, and no clip is.
    assert(ch[0].current, "an unbound plane is currently showing no image");
    assert(!ch[1].current && !ch[2].current && !ch[3].current,
        "and no clip row is marked");

    // Bound to the MIDDLE clip. The two decoys carry the SAME file path, so a
    // path-keyed `current` test marks all three; an object-keyed one marks B.
    plane.setLink(kImageLinkSlot, b);
    ch = planeImageChoices(doc, plane);
    size_t marked = 0;
    foreach (e; ch) if (e.current) ++marked;
    assert(marked == 1, format("exactly one row is current — read %d", marked));
    assert(ch[2].current,
        "and it is the row for the clip the link NAMES, not one of the two "
        ~ "decoys sharing its path");

    // Dangling: the clip is spliced out. No row can represent it, so nothing
    // is marked — including "(none)", which would say the choice was never
    // made rather than that it was lost.
    doc.layers = doc.layers[0 .. 4] ~ doc.layers[5 .. $];
    ch = planeImageChoices(doc, plane);
    assert(ch.length == 3, format("two clips left plus '(none)' — read %d", ch.length));
    marked = 0;
    foreach (e; ch) if (e.current) ++marked;
    assert(marked == 0,
        format("a dangling link marks nothing, not '(none)' — read %d marked", marked));

    // Asking a non-plane offers nothing at all (an empty picker, not a
    // picker showing every clip against an item that cannot hold one).
    assert(planeImageChoices(doc, doc.layers[0]).length == 0,
        "a mesh has no image picker");
    assert(planeImageChoices(doc, null).length == 0, "and neither has null");
}

// ---------------------------------------------------------------------------
// Stage 4 — the placement law
//
// Every assertion message below carries the OBSERVED number, not just the
// expected one. That is not decoration: `assert(a == b, "msg")` prints only
// `msg`, so an assertion whose message omits what it read tells a deliberate
// break WHICH line went red and never WHAT it produced — and "the observed
// red value" is exactly what a break-and-restore pass has to report.
// ---------------------------------------------------------------------------

version (unittest) {
    private bool near(float a, float b, float tol = 1e-4f) {
        import std.math : abs, isFinite;
        return isFinite(a) && isFinite(b) && abs(a - b) <= tol;
    }
    private bool nearV(Vec3 a, Vec3 b, float tol = 1e-4f) {
        return near(a.x, b.x, tol) && near(a.y, b.y, tol) && near(a.z, b.z, tol);
    }
    private string fmtV(Vec3 v) {
        import std.format : format;
        return format("(%.6f, %.6f, %.6f)", v.x, v.y, v.z);
    }

    /// A plane's channels at their defaults, with `projection` overridable.
    private ImagePlaneData planeData(string projection = "front") {
        auto p = new ImagePlaneData();
        p.projection = projection;
        return p;
    }

    /// Resolve with the boilerplate a placement test does not care about:
    /// visible, `Ready`, a Front ortho cell.
    private ImagePlanePlacement place(const ImagePlaneData p, int w, int h,
                                      ItemXform x,
                                      ViewPreset cell = ViewPreset.Front,
                                      bool ortho = true, bool visible = true,
                                      ImagePlaneSource src = ImagePlaneSource.Ready)
    {
        return resolvePlacement(p, visible, w, h, src, "/tmp/fixture.png",
                                cell, ortho, x);
    }
}

// T-P1 — THE REFERENCE ROW, and the number the capture's own gate had to
// reproduce before it was trusted with anything else: a 512x256 image at
// pixelSize 0.01 with Keep Aspect on and an identity transform is
// 5.12 m x 2.56 m in the world.
//
// The image is deliberately NON-SQUARE, so a transpose is a different answer
// rather than the same one. Wrong implementations this separates, each
// reading a different number: a transpose (halfU 1.28), pixelSize applied to
// one axis only (halfV 128), pixelSize ignored (halfU 256), and
// half-vs-full-extent confusion (halfU 5.12 — every plane in the document
// twice its stated size, which looks like a design choice until it is stood
// beside a 1 m cube).
unittest {
    import std.format : format;
    auto p = planeData();
    ItemXform x;                       // identity: pos 0, rot 0, scl 1, pivot 0
    auto r = place(p, 512, 256, x);

    assert(nearV(r.halfU, Vec3(2.56f, 0, 0)),
        format("T-P1 halfU: expected (2.56, 0, 0), got %s", fmtV(r.halfU)));
    assert(nearV(r.halfV, Vec3(0, 1.28f, 0)),
        format("T-P1 halfV: expected (0, 1.28, 0), got %s", fmtV(r.halfV)));
    assert(nearV(r.center, Vec3(0, 0, 0)),
        format("T-P1 center: expected the origin, got %s", fmtV(r.center)));
    // Stated in FULL extents too, because that is the unit the measurement is
    // in and the unit a QA pass measures against a cube.
    assert(near(2 * r.halfU.length, 5.12f) && near(2 * r.halfV.length, 2.56f),
        format("T-P1 full extent: expected 5.120000 x 2.560000, got %.6f x %.6f",
               2 * r.halfU.length, 2 * r.halfV.length));
    assert(r.drawn, "T-P1: a Ready, visible plane in its own ortho cell draws");
    assert(r.sourcePath == "/tmp/fixture.png",
        "T-P1: a Ready placement carries the resolved path for the draw to look up");
}

// T-P2 — THE RETRACTED-DESIGN DETECTOR.
//
// An earlier revision of this feature built the quad at the base extent and
// pushed its corners through `ItemXform.composedMatrix()`. That product
// contains the SCALE block, so the scale would be applied twice: once by the
// extent formula that consumes it, and again by the matrix. This case has a
// non-uniform scale, a rotation, a translation AND a non-zero pivot, so the
// two designs disagree on every corner.
//
// Expected, computed independently of the implementation:
//   m        = min(sx, sy) = min(2, 3) = 2
//   |halfU|  = 0.5 * 512 * 0.01 * 2 = 5.12
//   |halfV|  = 0.5 * 256 * 0.01 * 2 = 2.56
//   center   = pos + pivot - R*pivot     (the closed form of T·Tp·R·Tp^-1 at the origin)
//   halfU    = R * (right * |halfU|),  halfV = R * (up * |halfV|)
unittest {
    import std.format : format;
    import std.math   : cos, sin, PI;

    auto p = planeData();
    ItemXform x;
    x.pos   = Vec3(1, 2, 3);
    x.rot   = Vec3(0, 0, 30);
    x.scl   = Vec3(2, 3, 1);
    x.pivot = Vec3(0.5f, 0, 0);
    auto r = place(p, 512, 256, x);

    assert(near(r.halfU.length, 5.12f),
        format("T-P2 |halfU|: expected 5.120000 (base 2.56 x min(2,3)=2), got %.6f",
               r.halfU.length));
    assert(near(r.halfV.length, 2.56f),
        format("T-P2 |halfV|: expected 2.560000 (base 1.28 x min(2,3)=2, NOT x3), "
               ~ "got %.6f", r.halfV.length));

    immutable float c = cos(30.0f * PI / 180.0f), s = sin(30.0f * PI / 180.0f);
    // R * pivot, with pivot on +X.
    immutable Vec3 rp = Vec3(0.5f * c, 0.5f * s, 0);
    immutable Vec3 expCenter = Vec3(1 + 0.5f - rp.x, 2 + 0 - rp.y, 3);
    assert(nearV(r.center, expCenter, 1e-3f),
        format("T-P2 center: expected %s (pos + pivot - R*pivot), got %s",
               fmtV(expCenter), fmtV(r.center)));

    immutable Vec3 expHalfU = Vec3( 5.12f * c, 5.12f * s, 0);
    immutable Vec3 expHalfV = Vec3(-2.56f * s, 2.56f * c, 0);
    assert(nearV(r.halfU, expHalfU, 1e-3f),
        format("T-P2 halfU: expected %s, got %s", fmtV(expHalfU), fmtV(r.halfU)));
    assert(nearV(r.halfV, expHalfV, 1e-3f),
        format("T-P2 halfV: expected %s, got %s", fmtV(expHalfV), fmtV(r.halfV)));

    // The four corners, restated from centre ± halves, are what a draw pass
    // consumes — asserted here so a sign error in the fan cannot hide behind
    // two correct magnitudes.
    immutable Vec3 c0 = r.center - r.halfU - r.halfV;
    immutable Vec3 expC0 = expCenter - expHalfU - expHalfV;
    assert(nearV(c0, expC0, 1e-3f),
        format("T-P2 corner0: expected %s, got %s", fmtV(expC0), fmtV(c0)));
}

// T-P3 — the six projections produce six DISTINCT (halfU, halfV) pairs, and
// each is restated here as a literal rather than recomputed from
// `presetBasis`, so a sign flip in that table has to fail here.
//
// A non-square image is load-bearing: with a square one, "up and right
// swapped" produces the identical pair and the test proves nothing.
unittest {
    import std.format : format;
    ItemXform x;
    struct Row { string tok; Vec3 halfU, halfV; }
    immutable Row[6] rows = [
        Row("top",    Vec3( 2.56f, 0, 0),      Vec3(0, 0, -1.28f)),
        Row("bottom", Vec3( 2.56f, 0, 0),      Vec3(0, 0,  1.28f)),
        Row("front",  Vec3( 2.56f, 0, 0),      Vec3(0, 1.28f, 0)),
        Row("back",   Vec3(-2.56f, 0, 0),      Vec3(0, 1.28f, 0)),
        Row("left",   Vec3(0, 0,  2.56f),      Vec3(0, 1.28f, 0)),
        Row("right",  Vec3(0, 0, -2.56f),      Vec3(0, 1.28f, 0)),
    ];
    Vec3[] seenU, seenV;
    foreach (row; rows) {
        auto r = place(planeData(row.tok), 512, 256, x);
        assert(nearV(r.halfU, row.halfU),
            format("T-P3 %s halfU: expected %s, got %s",
                   row.tok, fmtV(row.halfU), fmtV(r.halfU)));
        assert(nearV(r.halfV, row.halfV),
            format("T-P3 %s halfV: expected %s, got %s",
                   row.tok, fmtV(row.halfV), fmtV(r.halfV)));
        foreach (i; 0 .. seenU.length)
            assert(!(nearV(seenU[i], r.halfU) && nearV(seenV[i], r.halfV)),
                format("T-P3 %s: its (halfU, halfV) pair repeats an earlier "
                       ~ "projection's — two axes that draw the same quad", row.tok));
        seenU ~= r.halfU; seenV ~= r.halfV;
    }
}

// T-P4 — `flipHorizontal` reaches `flipU` and NOTHING else. The tempting
// wrong implementation flips by negating `halfU`, which mirrors the plane's
// PLACEMENT as well as its pixels: the image would move to the other side of
// the item's centre instead of being mirrored in place.
unittest {
    import std.format : format;
    ItemXform x;
    auto plain   = place(planeData(), 512, 256, x);
    auto flipped = { auto p = planeData(); p.flipHorizontal = true;
                     return place(p, 512, 256, x); }();

    assert(!plain.flipU && flipped.flipU,
        format("T-P4 flipU: expected false then true, got %s then %s",
               plain.flipU, flipped.flipU));
    assert(flipped.halfU == plain.halfU,
        format("T-P4 halfU must be BYTE-IDENTICAL under a flip: %s vs %s",
               fmtV(plain.halfU), fmtV(flipped.halfU)));
    assert(flipped.halfV == plain.halfV && flipped.center == plain.center,
        "T-P4: a flip changes no other placement field");
}

// T-P5 — FOUR distinguishable outcomes, not three. The three bad source
// states each read a different enum, and `Hidden` is the fourth: `drawn ==
// false` while `source` stays `Ready`.
//
// The tempting simplification — folding visibility into `source` — makes a
// hidden plane read `Unbound`, which collapses "a perfectly good image the
// user hid" into "no image chosen", and takes with it the only observable of
// the rule that a hidden plane KEEPS its texture.
unittest {
    import std.format : format;
    ItemXform x;
    foreach (bad; [ImagePlaneSource.Unbound, ImagePlaneSource.Dangling,
                   ImagePlaneSource.Missing]) {
        auto r = place(planeData(), 512, 256, x, ViewPreset.Front, true, true, bad);
        assert(!r.drawn, format("T-P5 %s must not draw", sourceToken(bad)));
        assert(r.source == bad,
            format("T-P5: the source state must survive to the caller — expected "
                   ~ "%s, got %s", sourceToken(bad), sourceToken(r.source)));
        assert(r.sourcePath.length == 0,
            "T-P5: a non-Ready placement carries no path for the draw to look up");
    }
    auto hidden = place(planeData(), 512, 256, x, ViewPreset.Front, true,
                        /*visible*/ false, ImagePlaneSource.Ready);
    assert(!hidden.drawn, "T-P5 Hidden: an invisible layer does not draw");
    assert(hidden.source == ImagePlaneSource.Ready,
        format("T-P5 Hidden: source must stay 'ready' (hiding is not a source "
               ~ "problem, and the texture stays resident) — got %s",
               sourceToken(hidden.source)));
}

// T-P6 lives in `tests/test_image_plane_view.d`, NOT here, and this comment
// is the reason.
//
// Its subject is "two clips of different dimensions bound to two otherwise
// identical planes produce different extents", whose wrong implementation is
// reading the dimensions off the WRONG clip. `resolvePlacement` takes
// `clipW`/`clipH` as arguments, so in this module that bug is unrepresentable
// and the test would be a green line guarding nothing. The clip→plane routing
// only exists at the caller, which is where the assertion has to live.

// T-P7 — THE FROZEN LAW. Every `uniform = 0` row of the 2026-08-09 capture
// (`doc/tasks/0612-evidence/phase0_size_law.txt`), asserted against the pure
// function with an identity rigid part.
//
// THE VALUES ARE THE LAW'S, NOT THE CAPTURE'S PIXELS. Row `E` measured
// 1.2500 m where the law says 1.28 — a 0.96 px rasterisation residual on a
// 40.96 px target. Freezing 1.25 would freeze the instrument's error into our
// source and make a CORRECT implementation red.
//
// TWENTY-FOUR PASSING ROWS ARE NOT TWENTY-FOUR PROOFS. Classified, so nobody
// reads the row count as a coverage count:
//   * LOAD-BEARING: W2 W3 W4 X1 X2 X3 (+ D, T3, T4) — the `min` collapse.
//     X1/X2 are an asymmetric pair (0.5 arriving from x, then from y) and
//     kill "use sx" and "use sy"; X3 is non-integer and separates `min` (1.5)
//     from mean (2.0) and geometric mean (1.936); W4 kills `max`.
//   * LOAD-BEARING: T1/T2, the tall 256x512 image — T1 catches a transpose in
//     the keep-aspect base, T2 catches width-instead-of-height AND
//     min(W,H)-instead-of-height in the other one.
//   * LOAD-BEARING: B, C, X5 — the `min` collapse wrongly applied to the
//     !keepAspect branch. A, W7 — a pixelSize frozen at import.
//   * ONCE: V (and W8, F1, which are exact repeats of it — in the CAPTURE
//     they were state-leak controls, against a pure function they are the
//     same call and cannot fail independently). Y0 repeats W1.
//   * WEAK: X4 (a uniform scale cannot separate `min` from per-axis, mean or
//     max — it catches only "scale ignored entirely"); E (same class as
//     A/W7 at the largest residual and the smallest extent).
//   * The `uniform = 1` rows (R, R0, W6) are out of v1 scope and are NOT in
//     the table; `A2pre` is an ORDERING control and `resolvePlacement` has no
//     ordering, so it is not expressible here at all.
unittest {
    import std.format : format;
    struct Row {
        string label; int w, h; float p, sx, sy, sz; bool keepAspect;
        float extU, extV;
    }
    immutable Row[] table = [
        //     label     W    H     p      sx    sy    sz   keep    extU     extV
        Row("V",   512, 256, 0.010f, 1.0f, 1.0f, 1.0f, false,  2.56f,  2.56f),
        Row("A",   512, 256, 0.020f, 1.0f, 1.0f, 1.0f, false,  5.12f,  5.12f),
        Row("E",   512, 256, 0.005f, 1.0f, 1.0f, 1.0f, false,  1.28f,  1.28f),
        Row("F1",  512, 256, 0.010f, 1.0f, 1.0f, 1.0f, false,  2.56f,  2.56f),
        Row("B",   512, 256, 0.010f, 1.0f, 2.0f, 1.0f, false,  2.56f,  5.12f),
        Row("C",   512, 256, 0.010f, 3.0f, 2.0f, 1.0f, false,  7.68f,  5.12f),
        Row("D",   512, 256, 0.010f, 3.0f, 2.0f, 1.0f, true,  10.24f,  5.12f),
        Row("W1",  512, 256, 0.010f, 1.0f, 1.0f, 1.0f, true,   5.12f,  2.56f),
        Row("W2",  512, 256, 0.010f, 3.0f, 1.0f, 1.0f, true,   5.12f,  2.56f),
        Row("W3",  512, 256, 0.010f, 1.0f, 3.0f, 1.0f, true,   5.12f,  2.56f),
        Row("W4",  512, 256, 0.010f, 2.0f, 3.0f, 1.0f, true,  10.24f,  5.12f),
        Row("W5",  512, 256, 0.010f, 1.0f, 1.0f, 3.0f, true,   5.12f,  2.56f),
        Row("W7",  512, 256, 0.020f, 1.0f, 1.0f, 1.0f, true,  10.24f,  5.12f),
        Row("W8",  512, 256, 0.010f, 1.0f, 1.0f, 1.0f, false,  2.56f,  2.56f),
        Row("T1",  256, 512, 0.010f, 1.0f, 1.0f, 1.0f, true,   2.56f,  5.12f),
        Row("T2",  256, 512, 0.010f, 1.0f, 1.0f, 1.0f, false,  5.12f,  5.12f),
        Row("T3",  256, 512, 0.010f, 3.0f, 1.0f, 1.0f, true,   2.56f,  5.12f),
        Row("T4",  256, 512, 0.010f, 1.0f, 3.0f, 1.0f, true,   2.56f,  5.12f),
        Row("Y0",  512, 256, 0.010f, 1.0f, 1.0f, 1.0f, true,   5.12f,  2.56f),
        Row("X1",  512, 256, 0.010f, 0.5f, 4.0f, 1.0f, true,   2.56f,  1.28f),
        Row("X2",  512, 256, 0.010f, 4.0f, 0.5f, 1.0f, true,   2.56f,  1.28f),
        Row("X3",  512, 256, 0.010f, 1.5f, 2.5f, 1.0f, true,   7.68f,  3.84f),
        Row("X4",  512, 256, 0.010f, 2.0f, 2.0f, 1.0f, true,  10.24f,  5.12f),
        Row("X5",  512, 256, 0.010f, 0.5f, 4.0f, 1.0f, false,  1.28f, 10.24f),
    ];
    foreach (row; table) {
        auto p = planeData();
        p.pixelSize  = row.p;
        p.keepAspect = row.keepAspect;
        ItemXform x;
        x.scl = Vec3(row.sx, row.sy, row.sz);
        auto r = place(p, row.w, row.h, x);
        immutable float gotU = 2 * r.halfU.length, gotV = 2 * r.halfV.length;
        assert(near(gotU, row.extU, 1e-3f) && near(gotV, row.extV, 1e-3f),
            format("T-P7 row %s (%dx%d px, p=%.3f, scl=(%.1f,%.1f,%.1f), keepAspect=%s): "
                   ~ "expected %.6f x %.6f m, got %.6f x %.6f m",
                   row.label, row.w, row.h, row.p, row.sx, row.sy, row.sz,
                   row.keepAspect, row.extU, row.extV, gotU, gotV));
    }
}

// T-P8 — THE COUNTER-INTUITIVE ONE, and the test that exists to go red when
// somebody "fixes" measured behaviour.
//
// With Keep Aspect on, raising ONE scale axis changes the extent by nothing,
// because the other axis still supplies the minimum. Half the Scale gizmo's
// travel is visually inert on a backdrop, which is what "retains the aspect
// ratio" means mechanically — and which the first manual-QA pass will file as
// a bug unless it is written down in three places, of which this is one.
unittest {
    import std.format : format;
    auto p = planeData();
    ItemXform unit;
    auto base = place(p, 512, 256, unit);

    foreach (scl; [Vec3(3, 1, 1), Vec3(1, 3, 1)]) {
        ItemXform x; x.scl = scl;
        auto r = place(p, 512, 256, x);
        assert(r.halfU == base.halfU && r.halfV == base.halfV,
            format("T-P8 scl=(%.0f,%.0f,%.0f): the extent must be BYTE-IDENTICAL "
                   ~ "to the unit-scale one (%.6f x %.6f m) — got %.6f x %.6f m. "
                   ~ "If this went red because one axis now enlarges the plane, "
                   ~ "that is not a fix: it is the measured `min(sx, sy)` collapse "
                   ~ "being removed.",
                   scl.x, scl.y, scl.z,
                   2 * base.halfU.length, 2 * base.halfV.length,
                   2 * r.halfU.length,    2 * r.halfV.length));
    }
}

// The finiteness gate. `Param.enforceBounds` clamps with `<` and `>`, and
// BOTH comparisons are false against NaN, so a NaN `pixelSize` walks through
// the channel guard untouched and arrives here. A NaN corner is undefined
// behaviour for the draw and an uninterpretable number over the wire, so the
// answer is an empty extent and `drawn == false` — never a NaN quad.
unittest {
    import std.format : format;
    auto p = planeData();
    p.pixelSize = float.nan;
    ItemXform x;
    auto r = place(p, 512, 256, x);
    assert(r.halfU == Vec3(0, 0, 0) && r.halfV == Vec3(0, 0, 0),
        format("a non-finite pixelSize must produce an EMPTY extent, got %s / %s",
               fmtV(r.halfU), fmtV(r.halfV)));
    assert(!r.drawn, "and a plane with no finite size is not drawable");
    assert(r.source == ImagePlaneSource.Ready,
        "but the SOURCE is still fine — a bad number is not a bad file");

    // …and the other door: a non-finite ROTATION reaches the rigid matrix, not
    // the extent formula, so an extents-only gate lets a NaN quad through with
    // perfectly finite half-extents and a NaN centre.
    auto q = planeData();
    ItemXform bad;
    bad.rot = Vec3(0, float.nan, 0);
    auto rr = place(q, 512, 256, bad);
    assert(rr.center == Vec3(0, 0, 0) && rr.halfU == Vec3(0, 0, 0),
        format("a non-finite ROTATION must produce an empty placement, got "
               ~ "center %s halfU %s", fmtV(rr.center), fmtV(rr.halfU)));
    assert(!rr.drawn, "and it is not drawable either");
}

// INTERIM (P0-d), labelled as one. Every captured row used a `front` plane,
// where "item scale X/Y" and "the two components spanning the plane" are the
// same sentence. They differ for a `right` plane, which spans world Z (u) and
// Y (v) — and the walkthrough uses one.
//
// This asserts the SPANNING-AXES reading: for `right`, u takes scl.z and v
// takes scl.y, so scl.X is the inert component. The item-local reading would
// take scl.x and scl.y instead and differ by a factor of two here. **If the
// P0-d capture reads the other way, this assertion and the law change
// together — it is not a parity claim today.**
unittest {
    import std.format : format;
    auto p = planeData("right");
    ItemXform x;
    x.scl = Vec3(4, 1, 0.5f);          // the P0-d case
    auto r = place(p, 512, 256, x, ViewPreset.Right);
    // Spanning axes: min(scl.z, scl.y) = min(0.5, 1) = 0.5 -> half size.
    assert(near(2 * r.halfU.length, 2.56f, 1e-3f),
        format("P0-d INTERIM (spanning axes): expected a 2.560000 m u-extent "
               ~ "(min(sz,sy)=0.5), got %.6f. The item-local reading "
               ~ "(min(sx,sy)=1) would read 5.120000.", 2 * r.halfU.length));
}

// The viewport-match rule, in-module: exact preset equality for an ortho
// cell, the plane's own opt-out for a perspective one. `tests/
// test_image_plane_view.d` asserts the same rows through the endpoint against
// real cells; this one pins the predicate itself, where the cell is an
// argument and cannot be misconfigured.
unittest {
    import std.format : format;
    ItemXform x;
    struct Row { ViewPreset cell; bool ortho; bool drawn; string why; }
    immutable Row[] rows = [
        Row(ViewPreset.Front, true,  true,  "its own cell"),
        Row(ViewPreset.Back,  true,  false, "NOT mirrored into the opposite view"),
        Row(ViewPreset.Top,   true,  false, "not every ortho cell"),
        Row(ViewPreset.Perspective, false, true,  "shown in perspective by default"),
        Row(ViewPreset.Perspective, true,  false, "a free-orbit ORTHO cell matches no axis"),
    ];
    foreach (row; rows) {
        auto r = place(planeData(), 512, 256, x, row.cell, row.ortho);
        assert(r.drawn == row.drawn,
            format("viewport match: a `front` plane in cell %s (ortho=%s) should "
                   ~ "be drawn=%s (%s), got drawn=%s",
                   row.cell, row.ortho, row.drawn, row.why, r.drawn));
    }
    // …and the opt-out is a channel, not a constant.
    auto noPersp = planeData(); noPersp.showInPerspective = false;
    auto rp = place(noPersp, 512, 256, x, ViewPreset.Perspective, false);
    auto rf = place(noPersp, 512, 256, x, ViewPreset.Front, true);
    assert(!rp.drawn, "showInPerspective=false hides it in the perspective cell");
    assert(rf.drawn,  "…and ONLY there — the Front cell still draws it");
}

// T-D1, the half a `DirtyKey` field test cannot make: EVERY input the draw
// pass reads moves the digest.
//
// `viewport.d`'s own unittest proves the key discriminates on the field. This
// one proves the value stamped into that field is not blind to half of what
// changes — the failure mode this file's history is full of is not "no term",
// it is "a term that does not cover the thing that moved". So each mutation
// below is applied to the SAME document and compared against the digest
// immediately before it, and every one must produce a different number.
//
// Wrong implementations this separates, and what each reads: a digest over the
// channels only (the xform rows read UNCHANGED — a moved plane never
// repaints); one that omits `visible` (the hide row reads unchanged — hiding
// leaves the picture on screen until the camera moves); one that omits the
// link (the bind row reads unchanged — choosing a clip does nothing); one that
// omits `cacheEpoch` (the upload row reads unchanged — the first frame after a
// decode never repaints, so a freshly bound image stays invisible).
unittest {
    import std.format : format;
    Layer plane, target;
    auto doc = planeFixture(plane, target);

    ulong epoch = 0;
    ulong h = imagePlaneDigest(doc, epoch);
    void step(string what, void delegate() mutate) {
        mutate();
        immutable ulong now = imagePlaneDigest(doc, epoch);
        assert(now != h,
            format("digest: %s must move the reference-image dirty-key term — "
                   ~ "it stayed 0x%016X, so a cell holding a cached image would "
                   ~ "not repaint", what, h));
        h = now;
    }

    step("binding the clip",        { plane.setLink(kImageLinkSlot, target); });
    step("a pixelSize edit",        { plane.imagePlaneRef().pixelSize = 0.02f; });
    step("a keepAspect toggle",     { plane.imagePlaneRef().keepAspect = false; });
    step("a projection change",     { plane.imagePlaneRef().projection = "right"; });
    step("a showInPerspective toggle",
                                    { plane.imagePlaneRef().showInPerspective = false; });
    step("a brightness edit",       { plane.imagePlaneRef().brightness = 0.25f; });
    step("a contrast edit",         { plane.imagePlaneRef().contrast = -0.5f; });
    step("a transparency edit",     { plane.imagePlaneRef().transparency = 0.5f; });
    step("an invert toggle",        { plane.imagePlaneRef().invert = true; });
    step("a flipHorizontal toggle", { plane.imagePlaneRef().flipHorizontal = true; });
    step("a smooth toggle",         { plane.imagePlaneRef().smooth = true; });
    step("a move",                  { plane.xform.pos   = Vec3(1, 0, 0); });
    step("a rotation",              { plane.xform.rot   = Vec3(0, 0, 15); });
    step("a scale",                 { plane.xform.scl   = Vec3(2, 2, 1); });
    step("a pivot move",            { plane.xform.pivot = Vec3(0.5f, 0, 0); });
    step("hiding the item",         { plane.visible = false; });
    step("a clip resize on disk",   { target.imageRef().width = 99; });
    step("the file going missing",  { target.imageRef().missing = true; });
    step("a texture upload",        { ++epoch; });
    step("clearing the link",       { plane.setLink(kImageLinkSlot, null); });

    // …and the converse: reading it twice with nothing touched must give the
    // same number, or every cell would re-render every frame and the dirty
    // gate would be decoration.
    assert(imagePlaneDigest(doc, epoch) == h,
        "digest: an unchanged document must digest identically — otherwise the "
        ~ "dirty gate never fires and every cell re-renders every frame");
}
