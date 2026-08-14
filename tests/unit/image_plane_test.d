// Module unittests for `image_plane`, moved verbatim out of source/image_plane.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.image_plane_test;

import document : Document, Layer, LinkState, ImagePlaneData, ItemXform;
import math;
import view : ViewPreset, presetBasis;
import document : ItemKind, ImageData, ImagePlaneData;
import mesh : makeCube;
import std.math : abs, isFinite;
import std.format : format;
import image_plane;

// rayHitsPlaneQuad — the boundary is the assertion.
//
// "The ray hits the quad" is trivially satisfied by a routine that returns true
// for any ray pointing roughly that way, so every case below is placed AT an
// edge the law must draw: just inside and just outside the same corner, the
// half-extent boundary itself, and the sign of `t`.
unittest {
    import std.math : abs, isFinite;

    // A 2x1 quad in the z = 5 plane, centred on the origin's line of sight.
    ImagePlanePlacement pl;
    pl.center = Vec3(0, 0, 5);
    pl.halfU  = Vec3(1, 0, 0);
    pl.halfV  = Vec3(0, 0.5f, 0);

    float t;
    // (1) Dead centre. `dir` is a UNIT vector here, so t is the world distance.
    assert(rayHitsPlaneQuad(pl, Vec3(0, 0, 0), Vec3(0, 0, 1), t));
    assert(abs(t - 5.0f) < 1e-5f, "t must be the world distance for a unit dir");

    // (2) The U boundary, from both sides. 0.95 of the half-extent is inside;
    //     1.05 is outside. Without both, "inside" could be any test at all.
    assert( rayHitsPlaneQuad(pl, Vec3(0.95f, 0, 0), Vec3(0, 0, 1), t));
    assert(!rayHitsPlaneQuad(pl, Vec3(1.05f, 0, 0), Vec3(0, 0, 1), t));
    //     …and the V boundary, which is a DIFFERENT half-extent (0.5, not 1.0).
    //     A quad tested against one extent on both axes passes the U pair and
    //     fails this one.
    assert( rayHitsPlaneQuad(pl, Vec3(0, 0.45f, 0), Vec3(0, 0, 1), t));
    assert(!rayHitsPlaneQuad(pl, Vec3(0, 0.55f, 0), Vec3(0, 0, 1), t));

    // (3) Behind the eye. Same geometry, ray reversed: the quad is at t = -5,
    //     and a negative t is not "under the cursor".
    assert(!rayHitsPlaneQuad(pl, Vec3(0, 0, 0), Vec3(0, 0, -1), t));

    // (4) Parallel: the ray runs in the plane's own span and never meets it.
    assert(!rayHitsPlaneQuad(pl, Vec3(0, 0, 0), Vec3(1, 0, 0), t));

    // (5) THE CROSS-KIND COMPARISON PREMISE. `t` is expressed in units of the
    //     GIVEN `dir`, not of world distance — that is what lets a plane hit be
    //     compared against a mesh hit built from the same unnormalised screen
    //     ray. Halving the direction must double t.
    float tHalf;
    assert(rayHitsPlaneQuad(pl, Vec3(0, 0, 0), Vec3(0, 0, 0.5f), tHalf));
    assert(abs(tHalf - 10.0f) < 1e-5f,
        "t is in units of dir; a half-length dir must report twice the t");

    // (6) A degenerate quad (no extent on one axis) has no interior to hit.
    ImagePlanePlacement flat = pl;
    flat.halfU = Vec3(0, 0, 0);
    assert(!rayHitsPlaneQuad(flat, Vec3(0, 0, 0), Vec3(0, 0, 1), t));

    // (7) A default-constructed placement — the answer for "this layer is not a
    //     plane" — is never hit, from any direction.
    ImagePlanePlacement empty;
    assert(!rayHitsPlaneQuad(empty, Vec3(0, 0, 0), Vec3(0, 0, 1), t));
    assert(!rayHitsPlaneQuad(empty, Vec3(0, 0, 0), Vec3(0, 1, 0), t));

    // (8) A ROTATED quad, so the test is not secretly axis-aligned arithmetic.
    //     Same quad turned 45 degrees about Y: its half-U now runs diagonally,
    //     so a point 0.9 along the DIAGONAL is inside and 0.9 along world X is
    //     not (0.9 world-X is 1.27 along the diagonal).
    immutable float s = 0.70710678f;
    ImagePlanePlacement rot;
    rot.center = Vec3(0, 0, 5);
    rot.halfU  = Vec3(s, 0, s);
    rot.halfV  = Vec3(0, 0.5f, 0);
    assert(rayHitsPlaneQuad(rot, Vec3(0.9f * s, 0, 0), Vec3(0, 0, 1), t));
    assert(!rayHitsPlaneQuad(rot, Vec3(0.9f, 0, 0), Vec3(0, 0, 1), t));
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

