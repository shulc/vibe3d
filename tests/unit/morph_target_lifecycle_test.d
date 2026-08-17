// The morph ROUTING TARGET's lifecycle and its SCOPE (task 1073, review B2 +
// SF2). Both are about the same property of the binding and neither is about
// the routing seam itself: the target is ONE app-global NAME, resolved per
// use against whatever mesh the caller happens to hand it.
//
// That makes two things load-bearing that the seam cannot express:
//
//   B2 — WHEN the binding must be dropped. Task 1069 shipped
//        `morph_target.d`'s header claiming the target is cleared on a
//        primary-layer change and by File → New; `grep -rn clearMorphTarget
//        source/` returned exactly one caller (`MorphSelect`). Nothing was
//        wired. A name that outlives its document re-resolves against the
//        NEXT one, so the next edit lands in a same-named map the user never
//        selected — and because `/api/reset` fires `scene.reset`, it also
//        outlived a test in the shared `--test` process and bled into the
//        following one.
//
//   SF2 — WHICH MESH the binding applies to. `displayVertices` /
//        `displayPosition` are handed background layers too:
//        `ui/viewport_render.d` uploads every visible background layer and
//        `snap.d` walks them for candidates. A DUPLICATED layer carries the
//        same map names by construction, so without a primary test the user
//        binds one target and every same-named layer in the scene is drawn,
//        snapped to and picked MORPHED.
//
// The third B2 site — `app.d`'s `onActiveLayerChanged` — is not reachable
// from a module unittest (app.d is the entry module and the hook is a local
// delegate); it is covered by the layer-switch case in
// `tests/test_morph_routing.d`.
module tests.unit.morph_target_lifecycle_test;

import math        : Vec3;
import mesh        : Mesh, MapKind, makeCube;
import document    : Document;
import view        : View;
import editmode    : EditMode;
import morph_target;

// ---------------------------------------------------------------------------
// B2 — scene.reset (which is what File → New and `/api/reset` both fire).
//
// Mutation: delete the `clearMorphTarget()` call from `SceneReset.apply()`
// -> the post-apply assertion reddens (verified).
// ---------------------------------------------------------------------------
unittest {
    import commands.scene.reset : SceneReset;
    import io.doc_state : requestDocRebaseline, syncDocRevision, clearCurrentDoc;

    // `morph_target` and `io.doc_state` are both process-global main-thread
    // state; leave both as this block found them.
    scope (exit) {
        clearMorphTarget();
        clearCurrentDoc(); requestDocRebaseline(); syncDocRevision(0);
    }

    auto doc = Document.bootstrap(makeCube());
    auto v   = new View(0, 0, 800, 600);
    EditMode em = EditMode.Vertices;

    auto cmd = new SceneReset(doc.activeMesh(), v, em, &em, null);
    cmd.setDocument(&doc);

    setMorphTarget("m", MapKind.morphRelative);
    assert(hasMorphTarget(), "setup: a target is bound before the reset");

    assert(cmd.apply(), "scene.reset must apply");
    assert(!hasMorphTarget(),
        "a reset is a clean slate: the morph routing target must not survive "
      ~ "it. The binding is a NAME, so a survivor re-resolves against the "
      ~ "NEXT document -- and because /api/reset fires this command, a "
      ~ "survivor also bleeds from one HTTP test into the next");
}

// ---------------------------------------------------------------------------
// B2 — file.load (File → Open).
//
// The discriminating detail is that the loaded document CARRIES a map of the
// bound name: that is the only configuration in which the surviving binding
// does anything at all, and it is the realistic one (the user re-opens a
// document they authored the morph in). A test whose loaded file has no such
// map cannot tell "cleared" from "still bound but unresolvable".
//
// Mutation: delete the `clearMorphTarget()` call from `FileLoad.apply()`
// -> the post-load assertion reddens (verified).
// ---------------------------------------------------------------------------
unittest {
    import commands.file.load : FileLoad;
    import commands.file.save : FileSave;
    import std.file : tempDir, remove, exists;
    import std.path : buildPath;
    import std.random : uniform;
    import std.format : format;
    import io.doc_state : requestDocRebaseline, syncDocRevision, clearCurrentDoc;

    scope (exit) {
        clearMorphTarget();
        clearCurrentDoc(); requestDocRebaseline(); syncDocRevision(0);
    }

    const path = buildPath(tempDir(),
        format("vibe3d_1073_morphtarget_load_%d.v3d", uniform(0, int.max)));
    scope (exit) if (exists(path)) remove(path);

    auto doc = Document.bootstrap(makeCube());
    auto v   = new View(0, 0, 800, 600);

    // Author a morph map named "m" and persist it, so the file we re-open
    // really does contain a map the stale binding could resolve against.
    {
        auto m = doc.activeMesh();
        assert(m.addMeshMapOfKind(MapKind.morphRelative, "m") !is null);
        assert(m.setMorphValue("m", 0, Vec3(0, 0, 0.5f)));
        auto save = new FileSave(m, v, EditMode.Vertices, &doc);
        save.setPath(path);
        assert(save.apply(), "setup: the .v3d must save");
    }

    setMorphTarget("m", MapKind.morphRelative);
    assert(hasMorphTarget(), "setup: a target is bound before the load");

    auto load = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);
    load.setPath(path);
    assert(load.apply(), "file.load must apply");

    assert(doc.activeMesh().meshMap("m") !is null,
        "setup: the loaded document really does carry a map of the bound "
      ~ "name -- otherwise the assertion below could not discriminate");
    assert(!hasMorphTarget(),
        "opening a document must drop the routing target: the binding names "
      ~ "a map in the document that was just replaced, and silently "
      ~ "re-pointing it at a same-named map in the NEW one routes the user's "
      ~ "next edit into a map they never selected");
}

// ---------------------------------------------------------------------------
// SF2 — the preview is scoped to the PRIMARY mesh.
//
// Both meshes below carry a morph map of the SAME name with the SAME nonzero
// entry, which is what a duplicated layer produces. The primary must draw
// morphed and the other must draw its base; asserting only the second half
// would also pass with the preview dead everywhere, so both are asserted in
// one block.
//
// Mutation: drop the `isMorphPreviewMesh(m)` gate from `resolveMorphTarget`
// -> the background assertions redden (verified).
// ---------------------------------------------------------------------------
unittest {
    import display_sync : activeMeshResolver;

    auto oldResolver = activeMeshResolver;
    scope (exit) { activeMeshResolver = oldResolver; clearMorphTarget(); }

    auto primary    = new Mesh;  *primary    = makeCube();
    auto background = new Mesh;  *background = makeCube();
    foreach (m; [primary, background]) {
        assert(m.addMeshMapOfKind(MapKind.morphRelative, "m") !is null);
        assert(m.setMorphValue("m", 0, Vec3(0, 0, 0.5f)));
    }

    activeMeshResolver = () => primary;
    setMorphTarget("m", MapKind.morphRelative);

    // The primary draws base + delta.
    assert(morphPreviewActive(primary), "the primary's preview is live");
    auto dvPrimary = displayVertices(primary);
    assert(dvPrimary.length == primary.vertices.length);
    assert(dvPrimary[0].z == primary.vertices[0].z + 0.5f,
        "the PRIMARY must draw base + delta");
    assert(displayPosition(primary, 0).z == primary.vertices[0].z + 0.5f);

    // The background layer draws its BASE, even though it carries a map of
    // the same name with the same value.
    assert(!morphPreviewActive(background),
        "a background layer is not the edit target: the app-global binding "
      ~ "must not resolve against it");
    assert(displayVertices(background) is null,
        "...so `displayVertices` returns null and every consumer falls back "
      ~ "to `mesh.vertices` -- the GPU upload in ui/viewport_render.d and the "
      ~ "snap walk in snap.d both hand background meshes to these functions");
    assert(displayPosition(background, 0).z == background.vertices[0].z,
        "and the per-vertex read agrees with the whole-array one");

    // The gate is about IDENTITY, not content: with the resolver pointing at
    // the other mesh the roles swap exactly.
    activeMeshResolver = () => background;
    assert(morphPreviewActive(background) && !morphPreviewActive(primary),
        "the primary is whatever `activeMeshResolver` says it is");
}
