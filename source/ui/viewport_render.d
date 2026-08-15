module ui.viewport_render;

// Task 0722 (audit §2C A3). `renderViewportSceneToFbo` is not a panel: 871
// lines, 22 gl* calls, and NOT ONE reference to ImGui. It ended up inside
// `ui/panels.d` as a side effect of 0419, which moved every remaining
// draw-something entry point out of app.d's main() in one sweep and did not
// separate the ImGui panels from the one GL scene pass among them. This file
// is that separation, and nothing else: the body below is byte-identical to
// what stood in panels.d, including its function-local `import bindbc.opengl`.
//
// Consequence measured, not assumed: after the move `ui/panels.d` contains
// ZERO gl* calls and zero GL_ constants, so it drops `bindbc.opengl` and seven
// other imports that only this function needed.
//
// Import surface: built by the COMPILER, not harvested. panels.d and
// editor_app.d both carry a copied block of ~250 imports from app.d and say so
// in their own headers; repeating that here would have made the third copy.
// Instead the module started with no imports at all and each one below was
// added in answer to a named error from a semantic-only pass over this single
// module -- which is why the list is short.

import math;                 // Vec3, Viewport, ModelSpace, identityMatrix, matMul4
import mesh;                 // Mesh
import editmode;             // EditMode
import seltype;              // SelType, viewportPickType
import mesh_gpu              : BaseWire;
import handles.gl_util       : setThickLineScreenSize;
import document              : Layer, kindInfo;
import viewport              : Viewport3D;
import editor_app            : EditorApp, OverlayMode, BgGpu,
                               edgeKey, countSelected, buildItemFrame;
import perf_probe            : g_fc, g_perf, DrawPass, Cat;
import toolpipe.pipeline     : g_pipeCtx;
import toolpipe.stage        : TaskCode;
import toolpipe.packets      : SubjectPacket;
import toolpipe.stages.workplane : WorkplaneStage;
import operator              : VectorStack;
import viewgrid              : g_viewGrid, viewGridSizeFor, viewGridFadeRadius;
import tools.slice.loop_slice_tool : LoopSliceTool;
import tools.transform.transform   : TransformTool;

// The copilot ghost overlay at the tail of the scene pass; compiled out of
// `modeling-noai` exactly as it is in ui/panels.d, whose block this mirrors.
version (WithAI) import commands.ui.copilot_panel : g_copilotPanelShown;
version (WithAI) {
    import ai.copilot_gate : kCopilotEnabled;
    import copilot_overlay : drawCopilotFindingOverlay;
}

// =============================================================================
// Phase 6 -- renderViewportSceneToFbo, the last panel entry point. Reads
// shader/checkerShader/gridShader/gridVao/gridOnlyVertCount/hover x3/
// faceSelEdgesCache+PrevSel/rebuildLoopHoverMask/litShader/gpu/mesh plus
// bgGpuByLayer [Б2] and edgeKey/countSelected/buildItemFrame [Б1] -- all
// relocated to editor_app.d in Phase 1 and imported at this module's header;
// this phase is a verbatim body move. Keeps its original 6 parameters,
// EditorApp app prepended as the first (per the plan's Phase 6 note).
// =============================================================================

// -------------------------------------------------------------------------
// Phase 2 — FBO scene render
// -------------------------------------------------------------------------
// Renders the active viewport's scene (mesh + grid + gizmos) into v.fbo.
// Called AFTER picking / hover-resolution (so hover state is current for
// this frame) and BEFORE ImGui.Render() (so the ImGui.Image draw command
// recorded inside the "Viewport" window samples the freshly-filled texture
// at RenderDrawData → same-frame content, zero latency).
//
// Captured from the outer scope: gpu, shader, litShader, checkerShader,
// gridShader, cameraView, mesh, document, activeTool, pipeGizmoHost,
// hoveredVertex/Edge/Face, faceSelEdgesCache/PrevSel, editMode, bgGpuByLayer,
// gridVao, gridOnlyVertCount, g_pipeCtx, etc.
void renderViewportSceneToFbo(EditorApp app, Viewport3D v, ref Viewport vp,
                               OverlayMode overlayMode,
                               bool showVertHover, bool showEdgeHover,
                               bool showFaceHover) {
    with (app) {
    import bindbc.opengl;
    import display_state : DrawPlan, resolveDrawPlan;

    // The value `LitShader`'s constructor seeds `u_fillColor` to. Restoring to
    // it (rather than to whichever plan just drew) keeps the program in the
    // state every non-plan caller — create-tool previews, gizmo draws — was
    // built expecting. Taken from a default-constructed plan so there is one
    // source of truth for it and not two.
    static immutable float[3] kDefaultFill = DrawPlan.init.fillColor;

    // ---- Resolve this cell's display state into what each pass may draw ----
    //
    // Task 0559 Phase 1 (doc/viewport_display_modes_plan.md). Before this,
    // every mesh pass below was unconditional: faces always, edges always,
    // background layers always the same two passes dimmed. That left no way
    // to observe — let alone test — what the renderer decided to draw.
    //
    // Now the passes read a resolved plan and nothing else, so the renderer
    // is structurally unable to draw what the plan does not describe. The
    // display endpoint dumps these same two structs, which is what makes a
    // plan dump a real assertion about drawing rather than a re-derivation
    // that can drift.
    //
    // The plan is resolved FROM THE CELL (`v.display`), not from a frame
    // value — display style is the first genuinely per-cell render input, and
    // the cell's dirty key is stamped from these same two calls.
    //
    // Phase-1 neutrality: `v.display` defaults to today's behaviour and
    // nothing writes it yet, so both plans resolve to exactly the set of
    // passes that ran before — faces lit, wireframe on, no forced vertex
    // dots, backdrop dimmed by the same factor that used to be a local
    // constant here.
    immutable DrawPlan activePlan   = resolveDrawPlan(v.display, false);
    immutable DrawPlan backdropPlan = resolveDrawPlan(v.display, true);

    // Bind FBO — scene draws go here instead of the default framebuffer.
    // Viewport covers the entire FBO (offsets zeroed: FBO origin IS the
    // viewport corner).
    glBindFramebuffer(GL_FRAMEBUFFER, v.fbo.fbo);
    glViewport(0, 0, v.fbo.w, v.fbo.h);
    // Per-cell thick-line screen size. g_thickLine.screenW/H is now a
    // per-cell scratch: each cell sets its own FBO size here before its
    // overlay gizmos draw, so the geometry-shader line extrusion is
    // always correct for the current cell (not the full window).
    setThickLineScreenSize(v.fbo.w, v.fbo.h);

    glClearColor(0.36f, 0.40f, 0.42f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    // ---- Reference-image planes (task 0612) ------------------------------
    //
    // FIRST, immediately after the clear and BEFORE the grid below: the grid,
    // the symmetry plane, the background layers and the primary all draw over
    // it, which is what "behind the geometry" means.
    //
    // The draw contains NO placement logic. `resolvePlacement` is a pure
    // function of the plane's channels, the linked clip's pixel dimensions and
    // the item transform, and it also answers whether THIS cell shows THIS
    // plane — so this loop is a lookup and a submission, and the geometry is
    // asserted as numbers in `image_plane.d` rather than as pixels here.
    //
    // The cache is only ever LOOKED UP here. It cannot decode from a draw, by
    // construction (`lookup` has no load path), which is what stops the
    // per-cell dirty skip from turning into a decode-per-frame loop. A `Ready`
    // placement whose path is somehow not resident draws nothing this frame —
    // a state the once-per-frame `reconcile` in `app.d` makes unreachable, and
    // which must be treated as "skip", never as "decode now".
    //
    // Ordered far-to-near by view-space depth of the centre, so several planes
    // in one perspective cell composite in the right order under
    // `transparency`. With the depth test off, submission order IS the
    // ordering, so this is not optional the moment there is more than one.
    {
        import image_plane : resolvePlacementFor, ImagePlanePlacement;
        import image_cache : imagePixelCache;
        import handles.gl_util : drawImagePlane;
        import view : ProjKind;
        import std.algorithm : sort;

        static struct Drawable { float depth; ImagePlanePlacement pl; }
        Drawable[] drawables;
        foreach (lyr; document.layers) {
            if (lyr is null || !lyr.hasImagePlane) continue;
            // The clip lookup + the pure law, in one call (task 0643's
            // extraction): the item ray asks the identical question, and two
            // spellings of it could hit-test a quad this pass never drew.
            auto pl = resolvePlacementFor(document, lyr,
                                          v.camera.viewPreset,
                                          v.camera.projKind == ProjKind.Ortho);
            if (!pl.drawn) continue;
            // View-space Z of the centre; more negative = further away under
            // the GL convention, so ascending sort is far-to-near.
            immutable Vec3 c = pl.center;
            immutable float z = vp.view[2]*c.x + vp.view[6]*c.y
                              + vp.view[10]*c.z + vp.view[14];
            drawables ~= Drawable(z, pl);
        }
        if (drawables.length > 1)
            drawables.sort!((a, b) => a.depth < b.depth);
        foreach (d; drawables) {
            immutable uint tex = imagePixelCache().lookup(d.pl.sourcePath);
            drawImagePlane(d.pl.center, d.pl.halfU, d.pl.halfV,
                           d.pl.flipU, d.pl.invert, d.pl.smooth,
                           d.pl.brightness, d.pl.contrast, d.pl.transparency,
                           // restore to NO program: the very next statement
                           // below is `shader.useProgram(...)`, which binds
                           // the one this pass would otherwise have to guess.
                           tex, vp, 0);
        }
    }

    // Per-item (per-layer) transform — RENDER-ONLY (channels P4). Feed-site #1.
    // NOTE (task 0617): `document.primaryModelSpace()`, the ModelSpace picking
    // resolves against, folds ONLY `itemMatrix` — not the `tt.gpuMatrix` fold
    // below. Currently fine because picking isn't exercised mid-drag; see
    // `primaryModelSpace()`'s doc comment in document.d if that ever changes.
    // Task 0654 — with an empty item selection there is no primary and no
    // foreground geometry: `app.mesh` resolves to the empty stand-in, so the
    // pass below submits zero triangles and the matrix only has to be
    // well-formed. IDENTITY, never layer 0's transform — borrowing an
    // unrelated item's frame here would place the (empty) foreground somewhere
    // arbitrary the moment anything is selected again mid-frame.
    float[16] itemMatrix = document.hasEditTarget()
        ? document.primary.xform.composedMatrix() : identityMatrix;
    float[16] meshModel  = itemMatrix;
    {
        TransformTool tt = cast(TransformTool)activeTool;
        if (tt !is null)
            meshModel = matMul4(itemMatrix, tt.gpuMatrix);
    }

    shader.useProgram(meshModel, vp);

    // Deliberately UNINSTRUMENTED in v1 (task 0196): the grid +
    // symmetry-plane draws below (tiny constant cost) and the
    // background-layer faces/edges loop further down (skipped entirely
    // when document.layers.length == 1) have no Cat timer — a choice,
    // not an omission. If wanted later, background faces fold into
    // Cat.drawMesh and background edges into Cat.drawEdges.
    // ---- Grid axis lines (alpha-blended, distance + edge fade) ----
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    // ---- The grid step (task 0570) ----
    //
    // The lattice in `gridVao` is a UNIT lattice; the step it is drawn at is
    // this cell's own, derived from this cell's own zoom. So the model matrix
    // carries a uniform scale of `gridStep` and the buffer is never rebuilt.
    //
    // `gridStep` is always a LADDER RUNG, so the drawn spacing moves in
    // visible steps as the camera zooms rather than gliding — that difference
    // is the feature, not a rounding of it.
    //
    // A zero step means the view has no usable scale (a degenerate camera);
    // fall back to the unit lattice rather than collapsing the grid to a
    // point.
    float gridStep = viewGridSizeFor(vp, g_viewGrid);
    if (!(gridStep > 0)) gridStep = 1.0f;

    float[16] gridModel = [
        gridStep, 0, 0, 0,
        0, gridStep, 0, 0,
        0, 0, gridStep, 0,
        0, 0, 0,        1,
    ];
    if (auto wp = cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work)) {
        if (!wp.isAuto) {
            Vec3 n, a1, a2;
            wp.currentBasis(n, a1, a2);
            Vec3 c = wp.center;
            // Same scale, applied to the work plane's own basis. The
            // translation column is NOT scaled: the plane's origin is a
            // world point, not a lattice coordinate.
            gridModel = [
                a1.x * gridStep, a1.y * gridStep, a1.z * gridStep, 0,
                n.x  * gridStep, n.y  * gridStep, n.z  * gridStep, 0,
                a2.x * gridStep, a2.y * gridStep, a2.z * gridStep, 0,
                c.x,             c.y,             c.z,             1,
            ];
        }
    }
    // The distance fade radius is the grid's OWN half-extent, not a multiple
    // of the camera distance.
    //
    // It used to be `camera.distance * 2`, which happened to sit inside the
    // fixed 50-unit lattice at ordinary zooms and outside it when you pulled
    // far back — a latent hard square edge nobody hit often. With a
    // screen-anchored step the coincidence is gone in the other direction:
    // the lattice's half-extent becomes `50 * step`, which at the bottom of a
    // rung is ~1250 screen pixels while `2 * distance` is ~3 * the pane
    // height, so on a tall pane the fade would reach PAST the lattice and the
    // square boundary would be visible at every zoom. Tying the fade to the
    // extent removes that class of defect at every zoom and every pane size:
    // the grid always fades to nothing exactly where it ends.
    immutable float gridFade = viewGridFadeRadius(gridStep);

    // Width/height in PIXELS = FBO dims; offsets zeroed (FBO origin = corner).
    gridShader.useProgram(gridModel, vp,
        gridFade,
        cast(float)v.fbo.w, cast(float)v.fbo.h,
        0.0f, 0.0f);
    glBindVertexArray(gridVao);
    // Perf: the ground grid is three fixed submissions whose vertex count
    // tracks the lattice size, so it is a CONSTANT floor under every scene
    // frame. Counting it separately from the mesh passes is what lets a
    // reader say "the model costs N draws" without the grid in the number.
    glUniform3f(gridShader.locColor, 0.5f, 0.5f, 0.5f);
    glDrawArrays(GL_LINES, 0, gridOnlyVertCount);
    g_fc.draw(DrawPass.grid, gridOnlyVertCount);
    glUniform3f(gridShader.locColor, 0.5f, 0.15f, 0.15f);
    glDrawArrays(GL_LINES, gridOnlyVertCount, 2);
    g_fc.draw(DrawPass.grid, 2);
    glUniform3f(gridShader.locColor, 0.15f, 0.15f, 0.5f);
    glDrawArrays(GL_LINES, gridOnlyVertCount + 2, 2);
    g_fc.draw(DrawPass.grid, 2);
    glBindVertexArray(0);

    // ---- Symmetry plane ----
    //
    // DELIBERATELY NOT scaled by the grid step (task 0570), even though it
    // borrows the same lattice buffer. This is a plane INDICATOR — it exists
    // to show where the mirror is — not a measuring grid, and the read that
    // makes the ground grid a screen length says nothing about it. Tying its
    // size to zoom would be a second appearance change smuggled in on the
    // first one's evidence. It keeps its unit lattice and its
    // camera-distance fade until someone decides otherwise on purpose.
    {
        import toolpipe.stages.symmetry : SymmetryStage;
        auto sym = cast(SymmetryStage)
                   g_pipeCtx.pipeline.findByTask(TaskCode.Symm);
        if (sym !is null && sym.enabled) {
            Vec3 n, a1, a2;
            Vec3 c;
            if (sym.useWorkplane) {
                if (auto wpst = cast(WorkplaneStage)
                                g_pipeCtx.pipeline.findByTask(TaskCode.Work)) {
                    wpst.currentBasis(n, a1, a2);
                    c = wpst.center;
                } else {
                    n = Vec3(0, 1, 0); a1 = Vec3(1, 0, 0); a2 = Vec3(0, 0, 1);
                }
            } else {
                final switch (sym.axisIndex) {
                    case 0:
                        n  = Vec3(1, 0, 0);
                        a1 = Vec3(0, 1, 0); a2 = Vec3(0, 0, 1);
                        c  = Vec3(sym.offset, 0, 0); break;
                    case 1:
                        n  = Vec3(0, 1, 0);
                        a1 = Vec3(1, 0, 0); a2 = Vec3(0, 0, 1);
                        c  = Vec3(0, sym.offset, 0); break;
                    case 2:
                        n  = Vec3(0, 0, 1);
                        a1 = Vec3(1, 0, 0); a2 = Vec3(0, 1, 0);
                        c  = Vec3(0, 0, sym.offset); break;
                }
            }
            float[16] symModel = [
                a1.x, a1.y, a1.z, 0,
                n.x,  n.y,  n.z,  0,
                a2.x, a2.y, a2.z, 0,
                c.x,  c.y,  c.z,  1,
            ];
            gridShader.useProgram(symModel, vp,
                v.camera.distance * 2.0f,
                cast(float)v.fbo.w, cast(float)v.fbo.h,
                0.0f, 0.0f);
            glBindVertexArray(gridVao);
            glUniform3f(gridShader.locColor, 0.85f, 0.5f, 0.15f);
            glDrawArrays(GL_LINES, 0, gridOnlyVertCount);
            g_fc.draw(DrawPass.symmetry, gridOnlyVertCount);
            glBindVertexArray(0);
        }
    }

    glDisable(GL_BLEND);

    // ---- Background layers ----
    //
    // TASK 0654 — the `> 1` fast path is now `> 1 || no edit target`, and that
    // second clause is the difference between "everything is background" and
    // "everything went dark". (Formula updated, task 0678 D4: background is
    // derived by `Document.roleOf` over the selection HISTORY since 0671 —
    // the old `visible && !selected` reading here was the one 0671 struck
    // out.) This DRAW pass and its eviction twin deliberately test
    // `visible && !isPrimary`, NOT `document.background()`: a Foreground-role
    // non-primary layer would otherwise be drawn by neither pass (the
    // foreground pass renders only the primary) — and the rule of this very
    // comment is "dim, not disappear". The snap-source gate below is the one
    // that follows `document.background()`. An empty selection makes every
    // visible layer background; the per-layer `isPrimary` skip below already
    // lets them all through. But on a
    // SINGLE-layer document the old gate short-circuited before the loop, and
    // that one layer would then have been drawn by neither pass — the
    // foreground pass skips it (it is not the primary; there is no primary) and
    // this pass never ran. The user clicks empty space and their model
    // vanishes. It must dim, not disappear.
    if (document.layers.length > 1 || !document.hasEditTarget()) {
        import std.math : isNaN;
        Layer[] toDrop;
        foreach (lyr, bg; bgGpuByLayer) {
            bool stillBg = false;
            foreach (ll; document.layers)
                // Task 0615 (tier-2, §Tier-2 :2083-2090): a non-mesh layer must
                // never be "still bg" — it never gets a BgGpu entry to begin
                // with, so any prior entry for it (impossible today, but the
                // guard is the eviction side of the drawsGeometry gate below)
                // must be dropped.
                if (ll is lyr && ll.visible && !document.isPrimary(ll)
                    && kindInfo(ll.kind).drawsGeometry) {
                    stillBg = true;
                    break;
                }
            if (!stillBg) toDrop ~= lyr;
        }
        foreach (lyr; toDrop) {
            bgGpuByLayer[lyr].gpu.destroy();
            bgGpuByLayer.remove(lyr);
        }

        // The dim factor moved into the display model (it is now an output of
        // plan resolution, `backdropPlan.dim`) — it is the ONE thing that
        // distinguishes a background layer today, and the backdrop axis is
        // what will eventually replace it with a genuinely different
        // representation. Cache upkeep below stays UNCONDITIONAL on purpose:
        // a display change must never invalidate or skip a `bgGpuByLayer`
        // upload, only the DRAWS are gated.
        foreach (i, lyr; document.layers) {
            if (document.isPrimary(lyr) || !lyr.visible) continue;
            // Task 0615 Stage 4 (§Tier-2 :2102): a non-mesh layer participates
            // in neither the bg draw nor the GPU upload — skip BEFORE the
            // `BgGpu` allocation below, not after (mirrors the eviction guard
            // just above).
            if (!kindInfo(lyr.kind).drawsGeometry) continue;
            float[16] bgModel = lyr.xform.composedMatrix();

            auto pp = lyr in bgGpuByLayer;
            BgGpu* bg;
            if (pp is null) {
                bg = new BgGpu;
                bg.gpu.init();
                bgGpuByLayer[lyr] = bg;
            } else {
                bg = *pp;
            }
            if (bg.uploadedVersion != lyr.meshRef().mutationVersion) {
                bg.gpu.upload(lyr.meshRef());
                bg.uploadedVersion = lyr.meshRef().mutationVersion;
            }

            // Perf: attribute this layer's submissions to the BACKDROP slots.
            // The two draws below are the same GpuMesh entry points the
            // primary uses, so without the redirect a four-layer scene's
            // backdrop would be indistinguishable from an expensive model —
            // and the fixes for those two are not the same fix.
            auto zBackdrop = g_fc.backdrop();
            if (backdropPlan.drawFaces) {
                litShader.useProgram(bgModel, vp);
                litShader.setSurfaces(lyr.meshRef().surfaces);
                litShader.setDim(backdropPlan.dim);
                litShader.setLit(backdropPlan.facesLit);
                litShader.setFillColor(backdropPlan.fillColor);
                bg.gpu.drawFaces(litShader);
                litShader.setLit(true);
                litShader.setFillColor(kDefaultFill);
                litShader.setDim(1.0f);
            }

            if (backdropPlan.drawWire) {
                shader.useProgram(bgModel, vp);
                shader.setDim(backdropPlan.dim);
                // Background layers carry no selection or hover state, so the
                // base pass is all there is here — and it reads the BACKDROP
                // side of the activity axis, never the active side.
                bg.gpu.drawEdges(shader.locColor, -1, [], [],
                    BaseWire(true, shader.locAlpha, backdropPlan.wireAlpha));
                shader.setDim(1.0f);
            }
        }
    }

    // Install background snap sources (layers Stage 5). The parallel
    // `snapSrcLayerIdx` (topology-pen P0 NIT-3) records each source's
    // Document-layer index (this loop's `i`) so the CONS stage's
    // background-surface raycast can publish a real Document-layer index
    // in `ConstrainHitPacket.layer` instead of the bgSrc-order slot.
    {
        import snap : setBackgroundSnapSources;
        import document : Document;
        const(Mesh)*[] snapSrc;
        ModelSpace[]   snapSrcSpaces;
        int[] snapSrcLayerIdx;
        if (document.layers.length > 1) {
            foreach (i, lyr; document.layers) {
                // Task 0615 Stage 4 (§Tier-2 :2162): a non-mesh layer is not a
                // snap source.
                if (document.background(lyr) && lyr.hasMesh) {
                    snapSrc ~= cast(const(Mesh)*)&lyr.meshRef();
                    // Task 0617 Stage 4: same source as `bgModel` in the draw
                    // loop above (`lyr.xform.composedMatrix()`) — a background
                    // layer now snaps where it is DRAWN, not at its identity
                    // pose.
                    //
                    // The three arrays are appended together under ONE guard so
                    // they stay index-aligned: a layer that is not a snap source
                    // contributes to none of them. Splitting the guard is how
                    // they would silently drift apart.
                    snapSrcSpaces ~= lyr.xform.modelSpace();
                    snapSrcLayerIdx ~= cast(int)i;
                }
            }
        }
        setBackgroundSnapSources(snapSrc, snapSrcSpaces, snapSrcLayerIdx);
    }
    // Install item snap frames (Stage 3).
    {
        import snap : setItemSnapFrames, ItemSnapFrame;
        import document : kindInfo;
        ItemSnapFrame[] itemFrames;
        foreach (lyr; document.layers) {
            if (!lyr.visible) continue;
            // Task 0616 Stage 2 (Bend #1): a kind with no transform
            // capability (e.g. an image — a document RESOURCE, not a thing
            // positioned in space) has no pivot to snap to. Without this
            // gate `buildItemFrame` would read `Layer.xform`'s inert default
            // identity and offer (0,0,0) as a snap target for every such
            // item — meaningless, since nothing ever authors that field for
            // a kind `layer_params.d` does not expose it on.
            if (!kindInfo(lyr.kind).hasXform) continue;
            itemFrames ~= buildItemFrame(lyr);
        }
        setItemSnapFrames(itemFrames);
    }

    // ---- Which selection type this cell draws FEEDBACK for (task 0655) -----
    //
    // The SAME query the viewport pick asks — the ordering with the
    // item-inclusive candidate set — and it is the same query on purpose:
    // "which elements can this click select" and "which elements does this
    // frame show as selected" are one question, and the two answers drifting
    // apart is exactly the state that was measured as a divergence.
    //
    // NOT `editMode`, which the three gates below used to read. `editMode` is
    // that query asked WITHOUT `Item`, so under the item type it still names a
    // geometry type — and the passes kept painting orange vertex dots, the
    // checker overlay and selected-edge colour for a geometry selection the
    // click could no longer reach. Measured against the reference: under the
    // item type a standing geometry selection is KEPT (it is still in
    // `/api/selection`) and NOT DRAWN. Keeping it is the mesh's business and
    // nothing here touches it; not drawing it is this line.
    //
    // The item-highlight pass further down asks `currentSelType` directly.
    // That is the same answer by construction — with all four types always in
    // the ordering, the item-inclusive resolve IS the front — and it is left
    // spelled its own way because it is asking a different question ("is the
    // item type current"), not gating an element pass.
    immutable SelType selFeedbackType = viewportPickType(selTypeOrder);

    // ---- Faces (Blinn-Phong, or a flat fill) ----
    // Gated on the plan's SHADING group. `drawFaces == false` means no face
    // pass AT ALL — not a depth-only one: a lines-only style has to be
    // see-through, so back-side edges stay visible.
    //
    // `facesLit == false` is the Solid style (0589, corrected in 0592): the
    // SAME face pass, the same geometry, the same highlight branches — but
    // neither the lighting term NOR the material. The fill's base becomes
    // `activePlan.fillColor` (the viewport colour scheme's), which is why the
    // two uniforms are set together below: "unlit" and "not from the material"
    // are one decision, and a call site that set only the first would draw a
    // black surface.
    //
    // Still deliberately not a separate pass or a separate program. The
    // reference does register Solid as its own style, and its style record is
    // genuinely a different shape — no light setup, one draw sub-pass instead
    // of three. But everything that differs is expressible here: the light
    // term is behind a uniform branch, the missing background sub-pass is a
    // resolved `drawFaces`, and we have no transparency sub-pass to omit. What
    // a second draw path would buy is a second place for hover tint, selection
    // highlight and per-surface colour to quietly diverge, which is the actual
    // risk this axis carries.
    {
        auto zMesh = g_perf.scope_(Cat.drawMesh);
        if (activePlan.drawFaces) {
            litShader.useProgram(meshModel, vp);
            litShader.setSurfaces(mesh.surfaces);
            litShader.setLit(activePlan.facesLit);
            litShader.setFillColor(activePlan.fillColor);
            bool toolFaceHover = activeTool !is null
                              && activeTool.wantsHoverForType(EditMode.Polygons)
                              && hoveredFace >= 0;
            if (selFeedbackType == SelType.Polygon) {
                gpu.drawFacesHighlighted(litShader, hoveredFace, mesh.selectedFaces);
            } else if (toolFaceHover) {
                gpu.drawFacesHighlighted(litShader, hoveredFace, (bool[]).init);
            } else {
                gpu.drawFaces(litShader);
            }
            // Restore, same discipline as the backdrop pass's setDim: the
            // program is shared with every preview/gizmo draw downstream.
            litShader.setLit(true);
            litShader.setFillColor(kDefaultFill);
        }
    }

    // Checkerboard overlay for selected faces (Polygons mode).
    if (selFeedbackType == SelType.Polygon) {
        if (mesh.hasAnySelectedFaces()) {
            auto zOv = g_perf.scope_(Cat.drawOverlays);
            checkerShader.useProgram(meshModel, vp, 1.0f, 0.5f, 0.1f);
            glDisable(GL_DEPTH_TEST);
            gpu.drawSelectedFacesOverlay(mesh.selectedFaces);
            glEnable(GL_DEPTH_TEST);
        }
    }

    shader.useProgram(meshModel, vp);

    // ---- Edges ----
    // The plan's OVERLAY group reaches every branch of the chain below, not
    // just the bare-wireframe one, and it reaches them through `BaseWire` —
    // which addresses the base (unselected, unhovered) line pass INSIDE
    // drawEdges and leaves the selection and hover passes alone. That is the
    // whole point: switching the overlay off must not take selection feedback
    // with it. Gating the chain itself, or early-returning from drawEdges,
    // would do exactly that, and is the named wrong implementation.
    immutable BaseWire baseWire = BaseWire(
        activePlan.drawWire, shader.locAlpha, activePlan.wireAlpha);
    {
        auto zEdges = g_perf.scope_(Cat.drawEdges);
        if (selFeedbackType == SelType.Edge) {
            // A tool can pre-highlight the WHOLE ring it will act on: Loop
            // Slice shows the ring its cut will land on (via wantsEdgeLoop-
            // Hover + rebuildLoopHoverMask). And while that tool DRAGS, the
            // per-frame edge picker is frozen (pickEdges early-returns on
            // isDragging), so `hoveredEdge` keeps a stale numeric index that
            // now aliases an unrelated edge once the tool's mutate/revert
            // preview rebuilds the edge array — highlighting it would light
            // a random edge far from the cursor (task 0231). Suppress the
            // single-edge hover then; the live cut geometry already shows
            // what will happen. Task 0232 widens this suppression to
            // ALSO cover an ARMED (but not currently dragging) Loop Slice
            // standing preview: `isDragging()` alone (== `scrubbing_`)
            // goes false the instant the mouse releases, but the
            // preview's edge array keeps getting rebuilt on every HUD/
            // panel scrub while armed — so the same frozen-numeric-index
            // aliasing risk applies for the WHOLE armed period, not just
            // the held-drag sub-window. `hasUncommittedEdit()` (==
            // `armed_` for this tool) is the generic, already-existing
            // Tool hook for exactly this "an uncommitted edit is live"
            // condition — every other tool defaults it to false, so this
            // is a no-op change for them.
            int          hovForDraw = hoveredEdge;
            const(bool)[] loopMask  = (bool[]).init;
            if (activeTool !is null) {
                if (activeTool.isDragging() || activeTool.hasUncommittedEdit())
                    hovForDraw = -1;
                else if (activeTool.wantsEdgeLoopHover()
                         && showEdgeHover && hoveredEdge >= 0)
                    loopMask = rebuildLoopHoverMask(hoveredEdge);
            }
            gpu.drawEdges(shader.locColor, hovForDraw, mesh.selectedEdges, loopMask,
                          baseWire);
        } else if (selFeedbackType == SelType.Polygon) {
            if (faceSelEdgesPrevSel != mesh.selectedFaces) {
                faceSelEdgesPrevSel = mesh.selectedFaces.dup;
                if (faceSelEdgesCache.length != mesh.edges.length)
                    faceSelEdgesCache = new bool[](mesh.edges.length);
                faceSelEdgesCache[] = false;

                bool allSel = (countSelected(mesh.selectedFaces) == cast(int)mesh.selectedFaces.length);
                if (allSel) {
                    faceSelEdgesCache[] = true;
                } else {
                    if (mesh.hasAnySelectedFaces()) {
                        bool[ulong] edgeSet;
                        foreach (fi, face; mesh.faces) {
                            if (!mesh.isFaceSelected(fi)) continue;
                            foreach (e; mesh.faceEdges(cast(uint)fi))
                                edgeSet[edgeKey(e.a, e.b)] = true;
                        }
                        foreach (ei, edge; mesh.edges) {
                            if (edgeKey(edge[0], edge[1]) in edgeSet)
                                faceSelEdgesCache[ei] = true;
                        }
                    }
                }
            }
            gpu.drawEdges(shader.locColor, -1, faceSelEdgesCache, [], baseWire);

            // Task 0399: Loop Slice ring-preview in Polygons mode. The
            // Edges-mode branch above previews the ring through
            // `hoveredEdge` (`wantsEdgeLoopHover` + `rebuildLoopHoverMask`),
            // but Polygons mode never sets a hovered EDGE — only
            // hovered/selected FACES — so that seed doesn't exist here.
            // Loop Slice's Polygons activation instead seeds from the
            // shared/interior edge(s) of the selected faces (task 0245:
            // `activationSeeds`/`interiorEdgesOfSelectedFaces`), so the
            // preview is built from THAT via the tool's own
            // `selectionRingPreviewMask()` helper (mirrors
            // `rebuildLoopHoverMask`'s sliceRing branch, but unioned over
            // every seed instead of a single hovered edge). Same
            // arm/drag suppression as the Edges branch —
            // `wantsEdgeLoopHover()` goes false while armed, and
            // `isDragging()`/`hasUncommittedEdit()` belt-and-suspenders
            // it — the live cut geometry already shows the result once
            // armed; a stale ring overlay would just be noise. Gated on
            // `hasAnySelectedFaces()` so an empty selection draws
            // nothing extra (no wasted redraw pass). Other Polygons-mode
            // tools are unaffected: `wantsEdgeLoopHover()` defaults false
            // on the `Tool` base, so this block is a no-op for them.
            if (activeTool !is null
                && activeTool.wantsEdgeLoopHover()
                && !(activeTool.isDragging() || activeTool.hasUncommittedEdit())
                && mesh.hasAnySelectedFaces()) {
                if (auto lst = cast(LoopSliceTool) activeTool) {
                    const(bool)[] loopSelMask = lst.selectionRingPreviewMask();
                    gpu.drawEdges(shader.locColor, -1, mesh.selectedEdges,
                                  loopSelMask, baseWire);
                }
            }
        } else if (showEdgeHover && hoveredEdge >= 0) {
            const bool[] loopMask =
                (activeTool !is null && activeTool.wantsEdgeLoopHover())
                    ? rebuildLoopHoverMask(hoveredEdge)
                    : (bool[]).init;
            gpu.drawEdges(shader.locColor, hoveredEdge, [], loopMask, baseWire);
        } else if (activePlan.drawWire) {
            // The bare-overlay branch: no selection set, no hover index, so
            // `baseWire` is the ONLY thing it would draw. Kept as an explicit
            // early-out rather than a `BaseWire(false, ...)` call so that an
            // overlay of "none" with nothing selected issues no GL at all —
            // not a VAO bind and a loop over zero batches.
            gpu.drawEdges(shader.locColor, -1, [], [], baseWire);
        }
    }

    // ---- Item highlight (task 0647) ----
    //
    // Under the Item selection type the unit of both selection and hover is the
    // WHOLE item, so the feedback changes scale with it: the item under the
    // cursor has its entire wireframe repainted, and so does every selected
    // item. All of it MEASURED (doc fixture `tests/fixtures/
    // item_hover_highlight.json`) — and the parts that were measured are the
    // parts a plausible wrong implementation gets wrong:
    //
    //   * the UNIT is the item, not the polygon under the cursor. A second
    //     probe on a different polygon of the same item painted the identical
    //     pixel set.
    //   * what is painted is EDGES. A probe 1x1 m deep inside a face changed
    //     0 of 1600 pixels, so this is not a surface tint; interior edges DID
    //     paint (307 px of 956), so it is not a silhouette either.
    //   * the COLOUR is a three-state function of (selected, hovered), and the
    //     hover colour is NOT the selection colour — that was the question the
    //     capture existed to answer. `itemHighlightColor` owns the law.
    //
    // WHY HERE, after the edges pass and before the vertex dots: this pass
    // paints OVER the base wireframe, which must already be down, and under
    // the gizmo, which must stay on top. Every layer is drawn in this one
    // place rather than each in its own pass — a background layer highlighted
    // back in the backdrop loop would be painted over by the primary's own
    // depth-writing face pass, which runs after it.
    //
    // The gate is `currentSelType`, not `editMode`: `editMode` still reads
    // whatever geometry type was last used (that is what makes 1/2/3 restore
    // it), so an implementation gated on it would light items in Vertices mode.
    {
        import seltype          : currentSelType, SelType;
        import document         : kindInfo;
        import viewport_scheme  : itemHighlight, itemHighlightColor, ItemHighlight;
        import hover_state      : g_hoveredItem;
        import image_plane      : resolvePlacementFor;
        import handles.gl_util  : drawWorldSegment;
        import view             : ProjKind;

        if (currentSelType(selTypeOrder) == SelType.Item) {
            auto zItem = g_perf.scope_(Cat.drawOverlays);
            foreach (li, lyr; document.layers) {
                if (lyr is null || !lyr.visible) continue;

                // One colour law for every kind of item — computed before the
                // kind branch precisely so the two cannot drift into two rules.
                immutable ItemHighlight state =
                    itemHighlight(lyr.selected, cast(int)li == g_hoveredItem);
                if (state == ItemHighlight.none) continue;

                // An IMAGE PLANE is highlighted by its BORDER, because it has
                // no wireframe to repaint — measured (`doc/tasks/0647-evidence/`):
                // the reference paints a plane's rectangular border, 2 px wide,
                // in the same three colours as a mesh's edges, and never tints
                // the image itself. Handled before the `drawsGeometry` gate
                // below, which a plane fails by construction: task 0643 made
                // planes pickable, so leaving them out here would produce an
                // item that can be hovered and selected with no cue at all.
                if (lyr.hasImagePlane) {
                    auto pl = resolvePlacementFor(document, lyr,
                                                  v.camera.viewPreset,
                                                  v.camera.projKind == ProjKind.Ortho);
                    if (!pl.drawn) continue;   // same gate the plane draw used
                    immutable Vec3 pc = itemHighlightColor(state);
                    // A FIXED-SIZE array, so the corner pairs live on the stack:
                    // a `[[a,b], …]` slice literal here would allocate on the GC
                    // every frame a backdrop is lit.
                    immutable Vec3[2][4] segs = [
                        [pl.center - pl.halfU - pl.halfV, pl.center + pl.halfU - pl.halfV],
                        [pl.center + pl.halfU - pl.halfV, pl.center + pl.halfU + pl.halfV],
                        [pl.center + pl.halfU + pl.halfV, pl.center - pl.halfU + pl.halfV],
                        [pl.center - pl.halfU + pl.halfV, pl.center - pl.halfU - pl.halfV],
                    ];
                    // `smooth = false`: this colour is READ BACK as an exact
                    // value by the item tests, and an anti-aliased edge carries
                    // a blend of it rather than it.
                    foreach (seg; segs)
                        drawWorldSegment(seg[0], seg[1], vp, pc, 2.0f,
                                         shader.program, 1.0f, /*smooth=*/false);
                    continue;
                }

                // Same capability bit the item ray picks against
                // (`item_pick.d`), so nothing can be hovered that cannot be
                // painted, or painted that cannot be hovered.
                if (!kindInfo(lyr.kind).drawsGeometry) continue;

                immutable Vec3 c = itemHighlightColor(state);

                // The primary draws through the SAME GpuMesh and the SAME
                // model matrix the passes above used — `meshModel`, which
                // folds a live tool matrix, so a highlighted item being
                // dragged stays on its geometry instead of trailing it.
                // Background layers use the buffers the backdrop loop
                // uploaded; a visible non-primary geometry layer always has an
                // entry there (its gate is the same three conditions as this
                // loop's, minus selection), so a missing one means the two
                // gates have drifted and skipping is the safe read.
                if (document.isPrimary(lyr)) {
                    shader.useProgram(meshModel, vp);
                    gpu.drawItemHighlight(shader.locColor, c.x, c.y, c.z);
                } else if (auto bg = lyr in bgGpuByLayer) {
                    // Named, not inlined: `useProgram` takes the matrix by
                    // `ref const`, so the composed rvalue needs a home.
                    float[16] itemModel = lyr.xform.composedMatrix();
                    shader.useProgram(itemModel, vp);
                    (*bg).gpu.drawItemHighlight(shader.locColor, c.x, c.y, c.z);
                }
            }
            // Leave the program bound to the primary's matrix: everything
            // downstream (vertex dots, tool overlays) was written expecting it.
            shader.useProgram(meshModel, vp);
        }
    }

    // ---- Vertex dots ----
    // `drawVerts` is a FORCING term from the surface style (a lines-only
    // style draws vertices as well as edges). The selection-type gate beside
    // it is a separate, unmodelled axis; the two are OR-ed. Today no style
    // forces it, so this reads as it always did — except under the item type,
    // where the dots (and with them the orange SELECTED dots) now go away.
    // That is the pass the reference's per-vertex colour census measured as
    // absent, and it is the visible half of "kept but not drawn".
    if (activePlan.drawVerts || selFeedbackType == SelType.Vertex) {
        auto zOv = g_perf.scope_(Cat.drawOverlays);
        gpu.drawVertices(shader.locColor, hoveredVertex, mesh.selectedVertices);
    } else if (showVertHover && hoveredVertex >= 0) {
        auto zOv = g_perf.scope_(Cat.drawOverlays);
        gpu.drawVertices(shader.locColor, hoveredVertex, (bool[]).init);
    }

    // ---- Active tool / falloff gizmo draws ----
    // Task 0206 (Quad/Split multi-cell overlays): `overlayMode` decides
    // WHICH cells draw and HOW:
    //   - None:        nothing (no tool/falloff active for this cell's
    //                   call, or a non-eligible tool — see the N-cell
    //                   loop's `_multiCellEligible` gate).
    //   - Interactive: the overlay-owner (origin cell during a drag,
    //                   else the active cell) — today's exact path,
    //                   visualOnly=false. Pins cachedVp + runs the
    //                   arbiter cycle; this is the primary Step-B
    //                   freeze mechanism for multi-viewport drag
    //                   correctness.
    //   - Visual:      every OTHER live cell, when the active tool/
    //                   falloff is multi-cell-eligible (v1: XfrmTransformTool
    //                   + CommandWrapperTool + no-tool falloff — see
    //                   doc/quad_overlays_all_cells_plan.md). Draws the
    //                   SAME world-derived gizmo geometry reprojected
    //                   under THIS cell's vp with visualOnly=true — no
    //                   cachedVp / ToolHandles writes, so this cell's
    //                   draw cannot corrupt the owner cell's
    //                   interaction state (see Tool.draw's doc comment).
    // NOTE: activeTool.update() already ran ONCE in the main loop
    // (against the origin snapshot) before this function is called for
    // any cell this frame, so handle-hover state is current for all of
    // them.
    if (overlayMode != OverlayMode.None) {
        // Cat.drawOverlays (enum) — distinct from the OverlayMode param
        // gating this block; the `Cat.` qualifier disambiguates for the
        // human reader (compiler never confuses them).
        auto zOv = g_perf.scope_(Cat.drawOverlays);
        bool visualOnly = (overlayMode == OverlayMode.Visual);
        if (activeTool) {
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
            activeTool.draw(shader, vp, vts, visualOnly);
        } else if (anyFalloffActive()) {
            import toolpipe.packets : FalloffPacket;
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
            FalloffPacket fp;
            if (auto p = vts.get!FalloffPacket()) fp = *p;
            if (fp.enabled)
                pipeGizmoHost.draw(shader, vp, fp, pipeGizmoHost.ownPool(), visualOnly);
        }
    }

    // ---- AI Modeling Copilot: ghost highlight of the active finding
    // (task 0402 Phase 3, doc/ai_copilot_plan.md) ----
    // Passive-only: this draws, nothing else — see copilot_overlay.d's
    // doc comment. Gated on all three: the AI master switch, the
    // "AI Findings" panel actually being shown (same visibility
    // predicate as the panel's own draw call below — a hidden panel's
    // stale active index shouldn't paint a ghost nobody can see the
    // list for), and a valid `active()` index into the CURRENT findings
    // list (out-of-range/-1, e.g. right after copilot.analyze before
    // any row was clicked, draws nothing). AI-off (or modeling-noai,
    // where the master switch never turns on) ⇒ byte-identical to
    // before this phase — same discipline as every other AI-gated draw
    // in this codebase (doc/ai_model_adapter_live_wiring_plan.md).
    // version(WithAI)-only — the whole findings panel/overlay is
    // compiled out of modeling-noai (see import block doc comment).
    // static if kCopilotEnabled (task 0422): ghost overlay skipped while
    // the copilot is paused; flip the flag to restore.
    version (WithAI)
    static if (kCopilotEnabled)
    {
        immutable bool panelShown = !command.g_testMode || g_copilotPanelShown;
        if (aiState.enabled && panelShown) {
            immutable int activeIdx = copilotPanel.active();
            const findings = copilotPanel.findings();
            if (activeIdx >= 0 && activeIdx < cast(int) findings.length)
                drawCopilotFindingOverlay(mesh(), findings[activeIdx], vp, shader.program);
        }
    }

    // Restore default framebuffer.
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }
}
