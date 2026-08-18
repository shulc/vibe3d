// Module unittests for `io.native`, moved verbatim out of source/io/native.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.io.native_test;

import std.file      : exists, read, write;
import std.json      : JSONValue, JSONType, parseJSON, JSONException;
import std.conv      : to;
import std.format    : format;
import mesh;
import math;
import document : Document, Layer, ItemXform, sanitizeItemXform,
                  MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG,
                  ItemKind, ImageData, ImagePlaneData,
                  kindInfo, kindFromToken, tokenOf;
import layer_params : LayerPropsProvider;
import params   : Param, paramToJson, injectParamsInto;
import io.image_path : storePathFor, resolveStoredPath, refreshImageMeta;
import seltype  : SelMode;
import log : logWarn, logInfo;
import std.file       : tempDir, mkdirRecurse, rmdirRecurse, readText;
import std.path       : buildPath, dirName, buildNormalizedPath;
import io.image_path  : writeTestBmp;
import document       : LinkState;
import io.native;

// ---------------------------------------------------------------------------
// Task 0616 Ph6 — THE WRITER WRITES EVERY ITEM, and `primaryLayer` is the RAW
// index into that unfiltered array.
//
// This test is the v7 test above it inverted. v7 skipped the non-mesh layer and
// renumbered `primaryLayer` against the filtered output; v8 must do neither,
// because `parent` and `links` encode their targets as indices into exactly
// this array (writer decision 4). The fixture is kept from v7 for the same
// reason it was chosen there: the primary sits in the MIDDLE, so
//   * a writer that still filters produces 2 layers and loads MeshA at index 0;
//   * a writer that filters but keeps the RAW index 1 loads MeshB;
//   * the correct writer produces 3 layers with primary at index 1.
// Three implementations, three different reads.
// ---------------------------------------------------------------------------
unittest {
    import std.file   : tempDir, remove, exists;
    import std.path   : buildPath;
    import std.format : format;
    import std.random : uniform;
    import mesh        : makeCube;

    auto path = buildPath(tempDir(),
        format("vibe3d_native_ut_%d.v3d", uniform(0, int.max)));
    scope(exit) if (exists(path)) remove(path);

    auto doc = Document.bootstrap(makeCube());     // "Layer 1" == MeshA
    auto meshA = doc.layers[0];
    auto empty = new Layer; empty.name = "Empty"; empty.kind = ItemKind.Empty;
    empty.xform.pos = Vec3(4.5f, -3.5f, 2.5f);     // a transform-only item, dialled in
    auto meshB = new Layer; meshB.name = "MeshB"; meshB.meshRef() = makeCube();
    doc.layers = [empty, meshA, meshB];
    doc.setActive(1);                              // MeshA stays primary (index 1)
    assert(doc.primary is meshA);
    assert(!empty.hasMesh, "fixture: the middle item really is non-mesh");

    // v8 can represent every item, so the write is COMPLETE — the `false`
    // return v7 used here has no remaining trigger.
    assert(writeV3d(doc, path),
        "a v8 write covers the whole document, non-mesh items included");

    Document loaded;
    assert(readV3d(path, loaded), "round-trip load must succeed");
    assert(loaded.layers.length == 3,
        "every item survives — a filtering writer reads 2 here, got "
        ~ loaded.layers.length.to!string);
    assert(loaded.layers[0].kind == ItemKind.Empty,
        "the non-mesh item came back AS a non-mesh item, in its own slot");
    assert(loaded.layers[0].name == "Empty");
    assert(loaded.layers[1].name == "Layer 1" && loaded.layers[1].hasMesh);
    assert(loaded.layers[2].name == "MeshB");
    assert(loaded.primary is loaded.layers[1],
        "`primaryLayer` is the RAW index into the unfiltered array: a writer "
        ~ "that filtered and renumbered lands the primary on layer 0, one that "
        ~ "filtered without renumbering lands it on MeshB");

    // The Empty's transform is a channel like any other and travels with it —
    // the v7 loss this phase closes.
    assert(loaded.layers[0].xform.pos.x == 4.5f
        && loaded.layers[0].xform.pos.y == -3.5f
        && loaded.layers[0].xform.pos.z == 2.5f,
        "a non-mesh item's item transform survives, got "
        ~ loaded.layers[0].xform.pos.x.to!string ~ ","
        ~ loaded.layers[0].xform.pos.y.to!string ~ ","
        ~ loaded.layers[0].xform.pos.z.to!string);
}

// ---------------------------------------------------------------------------
// Task 0614 Phase 7 — the `.v3d` item-transform round-trip, enumerated PER
// FIELD and PER ITEM KIND rather than sampled.
//
// What already exists and what this adds. `test_layer_xform_io.d` drives
// LOAD -> SAVE (a hand-written file re-emitted, compared at 1e-6); the band
// case above drives SAVE -> LOAD but only to prove the REPAIR. Neither one
// answers the question a user actually has: I dialled a transform in, I
// saved, I re-opened — is what I get back the same item? That needs
// SAVE -> LOAD compared BIT-EXACTLY on all twelve channels, and it needs the
// answer for the things that are NOT channels: a non-mesh item, and the
// parent link.
//
// THE FIXTURE IS THE TEST. A serialiser bug is only visible if the numbers
// separate the wrong implementations from the right one, so the fixture is
// chosen against a named list of them and the separation is ASSERTED, not
// asserted-by-comment:
//   * every one of the twelve numbers differs from its channel identity
//     (0/0/1/0)  -> a dropped field reads a different number;
//   * the twelve are pairwise distinct in magnitude  -> a swapped pair
//     (pos<->pivot, x<->z, rot<->scl) reads a different number;
//   * `rot` has no zero and no multiple of 90        -> a permuted euler
//     triple composes to a different matrix (asserted below), which a
//     90-degree or single-axis rotation would NOT;
//   * `scl` is non-uniform and one component is NEGATIVE -> a serialiser
//     that writes a magnitude, or a single uniform factor, reads different
//     numbers;
//   * `pivot` is non-zero AND the pose is rotated+scaled -> dropping the
//     pivot changes the composed matrix (asserted below), which at
//     rot=0/scl=1 it would NOT (T(p)·I·T(-p) == I for any p).
// Bit-exactness is a legitimate bar, not an aspiration: `float` widens to
// `double` in `JSONValue`, std.json prints a double with enough digits to
// re-read it exactly, and the narrowing back to `float` is then exact.
//
// The two NON-channel answers this pins are LOSSES, and they are asserted as
// losses on purpose: the day either one is fixed, this test goes red and
// names the USAGE.md paragraph that has to change with it.
// ---------------------------------------------------------------------------
unittest {
    import std.file   : tempDir, remove, exists;
    import std.path   : buildPath;
    import std.format : format;
    import std.random : uniform;
    import std.math   : fabs, fmod;
    import mesh       : makeCube;
    import document   : ItemKind;

    auto path = buildPath(tempDir(),
        format("vibe3d_native_xform_rt_%d.v3d", uniform(0, int.max)));
    scope(exit) if (exists(path)) remove(path);

    // --- the fixture --------------------------------------------------------
    ItemXform src;
    src.pos   = Vec3( 1.3f,  -0.7f,   2.9f);
    src.rot   = Vec3(17.3f, -43.7f,  61.1f);   // no 0, no multiple of 90
    src.scl   = Vec3( 2.5f,   0.4f,  -1.75f);  // non-uniform, one mirror
    src.pivot = Vec3(-0.35f,  0.85f,  1.15f);

    // --- and the PROOF that the fixture discriminates -----------------------
    {
        immutable float[12] c = [src.pos.x, src.pos.y, src.pos.z,
                                 src.rot.x, src.rot.y, src.rot.z,
                                 src.scl.x, src.scl.y, src.scl.z,
                                 src.pivot.x, src.pivot.y, src.pivot.z];
        immutable float[12] identity = [0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0];
        foreach (i; 0 .. 12)
            assert(c[i] != identity[i],
                "fixture: channel " ~ i.to!string ~ " must differ from its "
              ~ "identity or a serialiser that DROPS it still passes");
        foreach (i; 0 .. 12)
            foreach (j; i + 1 .. 12)
                assert(fabs(c[i]) != fabs(c[j]),
                    "fixture: channels " ~ i.to!string ~ "/" ~ j.to!string
                  ~ " share a magnitude — a serialiser that swaps them "
                  ~ "still passes");
        foreach (v; [src.rot.x, src.rot.y, src.rot.z])
            assert(fmod(fabs(v), 90.0f) != 0.0f,
                "fixture: a multiple of 90 degrees makes the euler ORDER "
              ~ "unobservable in the composed matrix");

        // Euler order is observable AT THIS TRIPLE: reversing it composes to a
        // different rotation. (It would not for a single-axis rotation.)
        auto rA = matrixFromEulerZYX(src.rot);
        auto rB = matrixFromEulerZYX(Vec3(src.rot.z, src.rot.y, src.rot.x));
        bool orderMatters = false;
        foreach (i; 0 .. 16) if (fabs(rA[i] - rB[i]) > 1e-4f) orderMatters = true;
        assert(orderMatters,
            "fixture: this rot triple must be order-sensitive, else a codec "
          ~ "that reverses the components is invisible");

        // The pivot is load-bearing AT THIS POSE: zeroing it moves the item.
        ItemXform noPivot = src;
        noPivot.pivot = Vec3(0, 0, 0);
        auto mA = src.composedMatrix(), mB = noPivot.composedMatrix();
        bool pivotMatters = false;
        foreach (i; 0 .. 16) if (fabs(mA[i] - mB[i]) > 1e-4f) pivotMatters = true;
        assert(pivotMatters,
            "fixture: dropping the pivot must change the composed matrix, "
          ~ "else the pivot assertions below are decoration");
    }

    // --- the document: a mesh item, a NON-MESH item, and a PARENTED item ----
    auto doc  = Document.bootstrap(makeCube());
    auto A    = doc.layers[0];
    A.name    = "A";
    A.xform   = src;

    auto E    = new Layer;
    E.name    = "E";
    E.kind    = ItemKind.Empty;
    E.xform.pos = Vec3(9.5f, -8.5f, 7.5f);   // a transform-only item, dialled in

    auto C    = new Layer;
    C.name    = "C";
    C.meshRef() = makeCube();
    C.parent  = A;

    doc.layers = [A, E, C];
    doc.setActive(0);
    // Focus is deliberately moved OFF the primary and onto the non-mesh item —
    // the only state in which focus and primary can differ at all, and
    // therefore the only fixture in which "restored from the file" and
    // "re-derived onto the primary" read differently.
    doc.selectItem(E, SelMode.Add);
    assert(doc.primary is A,           "setup: A is the primary");
    assert(doc.focusedItem is E,       "setup: the focus is on the NON-MESH item, "
        ~ "which is what makes the focus assertion below non-vacuous");
    assert(C.parent is A,              "setup: C really is parented to A — "
        ~ "without this the parent assertion below is vacuous");
    assert(E.kind == ItemKind.Empty,   "setup: E really is a non-mesh item");

    // v8 represents every item, so the write is COMPLETE.
    assert(writeV3d(doc, path),
        "a v8 write covers a document holding a non-mesh item");

    Document loaded;
    assert(readV3d(path, loaded), "round-trip load must succeed");

    // === WHAT SURVIVES: all twelve channels, BIT-EXACT ======================
    auto got = loaded.layers[0].xform;
    assert(got.pos.x   == src.pos.x   && got.pos.y   == src.pos.y
        && got.pos.z   == src.pos.z,   "pos must round-trip bit-exact, got "
        ~ got.pos.x.to!string ~ "," ~ got.pos.y.to!string ~ "," ~ got.pos.z.to!string);
    assert(got.rot.x   == src.rot.x   && got.rot.y   == src.rot.y
        && got.rot.z   == src.rot.z,   "rot must round-trip bit-exact (DEGREES, "
        ~ "ZYX order), got " ~ got.rot.x.to!string ~ "," ~ got.rot.y.to!string
        ~ "," ~ got.rot.z.to!string);
    assert(got.scl.x   == src.scl.x   && got.scl.y   == src.scl.y
        && got.scl.z   == src.scl.z,   "scl must round-trip bit-exact INCLUDING "
        ~ "the negative (mirror) component, got " ~ got.scl.x.to!string ~ ","
        ~ got.scl.y.to!string ~ "," ~ got.scl.z.to!string);
    assert(got.pivot.x == src.pivot.x && got.pivot.y == src.pivot.y
        && got.pivot.z == src.pivot.z, "pivot must round-trip bit-exact, got "
        ~ got.pivot.x.to!string ~ "," ~ got.pivot.y.to!string ~ ","
        ~ got.pivot.z.to!string);

    // The observable that follows from the four: the item lands in the same
    // place. Implied by the channel equalities TODAY (the composed matrix is a
    // pure function of them) — kept because it is the property a user cares
    // about, and it survives a future codec that persists a matrix instead.
    assert(loaded.layers[0].xform.composedMatrix() == src.composedMatrix(),
        "the composed world matrix must be identical after a round-trip");

    // === Task 0616 Ph6: three v7 LOSSES, now GAINS =========================
    // Each assertion below was its own inverted twin until this phase; they
    // are kept in the same place so the diff reads as "the loss became a
    // round trip" rather than as three unrelated new checks.

    // GAIN #1 — the non-mesh item, and its own transform.
    assert(loaded.layers.length == 3,
        "every item survives a v8 round trip; the Empty is no longer dropped "
      ~ "— got " ~ loaded.layers.length.to!string ~ " layers");
    assert(loaded.layers[1].name == "E" && loaded.layers[1].kind == ItemKind.Empty,
        "the Empty item comes back in its own slot, AS an Empty");
    assert(loaded.layers[1].xform.pos.x == 9.5f
        && loaded.layers[1].xform.pos.y == -8.5f
        && loaded.layers[1].xform.pos.z == 7.5f,
        "…carrying the transform it was dialled to, got "
      ~ loaded.layers[1].xform.pos.x.to!string ~ ","
      ~ loaded.layers[1].xform.pos.y.to!string ~ ","
      ~ loaded.layers[1].xform.pos.z.to!string);
    assert(!loaded.layers[1].hasMesh,
        "and it is NOT written as an empty mesh — a codec that gave it a "
      ~ "geometry payload to fit the old shape would read hasMesh true here");

    // GAIN #2 — the item PARENT link, by OBJECT IDENTITY.
    assert(loaded.layers[2].name == "C", "sanity: layer 2 is the parented item");
    assert(loaded.layers[2].parent !is null,
        "the parent link now persists — a v7 codec reads null here");
    assert(loaded.layers[2].parent is loaded.layers[0],
        "…and it resolves to the RIGHT item. The parent sits at index 0 while "
      ~ "its child is at index 2 with a non-mesh item BETWEEN them, so an "
      ~ "off-by-one or a filtered-index encoding lands on \"E\" — got \""
      ~ loaded.layers[2].parent.name ~ "\"");
    assert(loaded.layers[0].parent is null && loaded.layers[1].parent is null,
        "and no OTHER item gained a parent it never had");

    // GAIN #3 — the item-selection FOCUS, distinct from the primary.
    assert(loaded.primary is loaded.layers[0],
        "the primary is still A");
    assert(loaded.focusedItem is loaded.layers[1],
        "the focus is restored onto the NON-MESH item, not collapsed onto the "
      ~ "primary. This is the ONLY document shape where the two can differ, "
      ~ "which is why the fixture focuses E — got \""
      ~ loaded.focusedItem.name ~ "\"");
}

// ---------------------------------------------------------------------------
// Task 1200 — a TWO-CORNER polygon survives the .v3d round trip, and every
// face-parallel array stays aligned to it.
//
// The reader used to drop every face with fewer than three corners, silently,
// on the way in. That was harmless while nothing could BUILD such a face; task
// 1200 made `mesh.makePolygon` build one (the reference does — ledger row 7,
// `two_points_only`), and the drop turned into data loss in the editor's OWN
// format: the writer wrote the face, the reader ate it, and — worse than losing
// it — `faceSubpatch` / `faceMaterial` / `facePart` are applied BY POSITION
// against the post-drop list, so every face after the dropped one inherited its
// neighbour's attributes.
//
// The fixture puts the 2-corner face in the MIDDLE for exactly that reason.
// Three implementations, three different reads:
//   * a reader that still drops it       -> 2 faces, and the trailing quad
//                                           wears the middle face's material;
//   * a reader that keeps it but shifts  -> 3 faces, wrong materials;
//   * the correct reader                 -> 3 faces, materials 7 / 5 / 9.
// ---------------------------------------------------------------------------
unittest {
    import std.file   : tempDir, remove, exists;
    import std.path   : buildPath;
    import std.format : format;
    import std.random : uniform;

    auto path = buildPath(tempDir(),
        format("vibe3d_twocorner_%d.v3d", uniform(0, int.max)));
    scope(exit) if (exists(path)) remove(path);

    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1),
                  Vec3(2, 0, 0), Vec3(3, 0, 0),
                  Vec3(4, 0, 0), Vec3(5, 0, 0), Vec3(5, 0, 1), Vec3(4, 0, 1)];
    m.faces = [[0u, 1u, 2u, 3u], [4u, 5u], [6u, 7u, 8u, 9u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.faceMaterial = [7u, 5u, 9u];
    m.facePart     = [1u, 2u, 3u];
    assert(m.faces[1].length == 2, "fixture: the middle face really has 2 corners");

    writeV3d(m, path);

    Mesh back;
    assert(readV3d(path, back),
        "a document whose faces include a 2-corner polygon must LOAD — before "
        ~ "task 1200 a file of nothing but such faces was rejected outright "
        ~ "with 'no polygons'");

    assert(back.faces.length == 3,
        format("all three faces must come back, got %d — the 2-corner face was "
               ~ "dropped", back.faces.length));
    assert(back.faces[1].length == 2,
        "and the middle one must still have exactly two corners");
    assert(back.vertices.length == 10, "no vertex is lost either");

    // The alignment, which is the half a bare face count cannot see.
    assert(back.faceMaterial[0] == 7 && back.faceMaterial[1] == 5
        && back.faceMaterial[2] == 9,
        format("per-face materials must stay on their own faces, got [%d,%d,%d]",
               back.faceMaterial[0], back.faceMaterial[1], back.faceMaterial[2]));
    assert(back.facePart[0] == 1 && back.facePart[1] == 2 && back.facePart[2] == 3,
        "per-face parts must stay on their own faces too");

    // The floor is TWO, and it did not become "anything goes": a face the
    // editor cannot build is still dropped rather than loaded.
    auto raw = cast(string) read(path);
    auto j = parseJSON(raw);
    j["layers"].array[0]["mesh"]["faces"].array ~= JSONValue([JSONValue(6)]);
    write(path, j.toString());
    Mesh back2;
    assert(readV3d(path, back2), "the file must still load");
    assert(back2.faces.length == 3,
        "a ONE-corner face is still dropped — the reader's floor tracks the "
        ~ "kernel's, and neither engine was ever seen to build one");
}
