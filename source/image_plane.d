module image_plane;

// ---------------------------------------------------------------------------
// Task 0612 — the reference-image plane, as a pure module.
//
// Stage 3 ships the SOURCE half: which clip a plane names, and what to say
// when that answer is unusable. The placement law (`resolvePlacement`) and the
// live-path collection the pixel cache reconciles against land here in a later
// stage; this module is deliberately their home too, so the plane's rules sit
// in one place rather than being spread across the panel, the command and the
// document.
//
// No GL and no ImGui here, on purpose: this module is gated by
// `dub test --config=modeling`, which is where the assertions that matter can
// actually run.
// ---------------------------------------------------------------------------

import document : Document, Layer, LinkState;

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
