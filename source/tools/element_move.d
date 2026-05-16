module tools.element_move;

import bindbc.sdl;

import tools.move;
import mesh;
import editmode;
import math : Vec3, Vec4, projectToWindowFull, pivotRotationMatrix,
              pivotScaleMatrix, mulMV, closestOnSegment2DSquared,
              pointInPolygon2D;
import shader;
import params : Param;

import std.math : PI;

import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage    : TaskCode;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.packets  : FalloffType, ElementMode;

/// ElementMoveTool — Move with a click-to-pick pre-step. On LMB-down
/// that doesn't hit the gizmo, the tool hit-tests the cursor against
/// the mesh (vertex → edge → face fallback in Automatic mode, or
/// only the current editMode in Manual mode) and writes the picked
/// element's centroid into the active FalloffStage's pickedCenter.
/// Subsequent drag is plain MoveTool behaviour (translate weighted
/// by the now-positioned element-falloff sphere).
///
/// Mirrors MODO `tool.set "ElementMove" on`'s Automatic mode default;
/// Manual mode (forced to current selection type) selectable via
/// `tool.attr xfrm.elementMove mode manual`.
class ElementMoveTool : MoveTool {
public:
    // Stage 14.5 — combined T/R/S attrs mirroring MODO's
    // `xfrm.transform`. MoveTool already exposes TX/TY/TZ; we add
    // RX/RY/RZ + SX/SY/SZ here so a single `tool.doApply` can chain
    // translate → rotate → scale (matching MODO ElementMove's
    // preset attr surface). All defaults are no-op (0 for trans/rot,
    // 1 for scale).
    private Vec3 headlessRotate = Vec3(0, 0, 0);
    private Vec3 headlessScale  = Vec3(1, 1, 1);

    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        super(mesh, gpu, editMode);
    }

    override string name() const { return "Element Move"; }

    // Per-element-type hover opt-in (Stage 14.9). Drives which of
    // pickVertices / pickEdges / pickFaces app.d runs while this tool
    // is active, and which highlight the renderer draws. Reads the
    // active FalloffStage's `elementMode` so the hover preview
    // matches what `tryPickElement` will actually click-pick:
    //   Auto / AutoCent → all three types (priority vert → edge →
    //                      face resolved post-pick in the render path)
    //   Vertex          → verts only
    //   Edge / EdgeCent → edges only
    //   Polygon/PolyCent→ polygons only
    override bool wantsHoverForType(EditMode type) const {
        if (g_pipeCtx is null) return false;
        auto fs = cast(FalloffStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Wght);
        if (fs is null) return false;
        final switch (fs.elementMode) {
            case ElementMode.Auto:
            case ElementMode.AutoCent: return true;  // all three
            case ElementMode.Vertex:   return type == EditMode.Vertices;
            case ElementMode.Edge:
            case ElementMode.EdgeCent: return type == EditMode.Edges;
            case ElementMode.Polygon:
            case ElementMode.PolyCent: return type == EditMode.Polygons;
        }
    }

    // The move gizmo should sit on whichever element the user just
    // click-picked — tryPickElement parks that element's centroid on
    // the FalloffStage's pickedCenter. MODO's ElementMove behaves
    // the same way (gizmo follows the click). Override the pivot
    // query so MoveTool.update() snaps handler.center there instead
    // of averaging over the (often empty) ACEN.Element selection-
    // centroid.
    //
    // Falls back to the base implementation when no Element falloff
    // is active — for example with the legacy `move.element` preset
    // that has ACEN.Element but no falloff.element.
    override Vec3 queryActionCenter() {
        if (g_pipeCtx !is null) {
            auto fs = cast(FalloffStage)
                      g_pipeCtx.pipeline.findByTask(TaskCode.Wght);
            if (fs !is null && fs.type == FalloffType.Element)
                return fs.pickedCenter;
        }
        return super.queryActionCenter();
    }

    override void activate() {
        super.activate();
        headlessRotate = Vec3(0, 0, 0);
        headlessScale  = Vec3(1, 1, 1);
    }

    // Element falloff applies to the WHOLE mesh: the picked element
    // gets weight 1 (via FalloffStage.pickedVerts) and surrounding
    // verts attenuate through the sphere. The base TransformTool
    // builds the cache from the active selection only — fine for
    // generic Move/Rotate/Scale, but here it would exclude the
    // clicked element whenever the user has a prior selection that
    // doesn't overlap the pick (e.g. face[0] selected, click face[2]
    // — picked verts never enter the iteration, so the picked face
    // doesn't move). Overriding the cache to cover every vert keeps
    // selection-derived ACEN / AXIS paths intact (they don't use
    // this list) while letting `elementWeight` do the per-vert
    // gating it was designed for.
    //
    // No-op when Element falloff isn't the active type — preserves
    // the existing semantics for `move.element` (no falloff stage)
    // and any other ElementMoveTool reuse without an Element WGHT
    // stage.
    override void buildVertexCacheIfNeeded() {
        if (!vertexCacheDirty) {
            super.buildVertexCacheIfNeeded();
            return;
        }
        FalloffStage fs = activeFalloffStage();
        if (fs is null || fs.type != FalloffType.Element) {
            super.buildVertexCacheIfNeeded();
            return;
        }
        int n = cast(int)mesh.vertices.length;
        vertexIndicesToProcess.length = n;
        foreach (i; 0 .. n) vertexIndicesToProcess[i] = i;
        vertexProcessCount = n;
        vertexCacheDirty   = false;
        if (toProcess.length != cast(size_t)n)
            toProcess.length = n;
        toProcess[] = true;
    }

    // Numeric rotate / scale attrs. TX/TY/TZ come from MoveTool's
    // params() (base above). Element-pick mode lives on the
    // FalloffStage now (`tool.pipe.attr falloff mode <auto|...>`)
    // matching MODO 9, not on the tool itself.
    override Param[] params() {
        auto base = super.params();
        base ~= Param.float_("RX", "Rotate X", &headlessRotate.x, 0.0f);
        base ~= Param.float_("RY", "Rotate Y", &headlessRotate.y, 0.0f);
        base ~= Param.float_("RZ", "Rotate Z", &headlessRotate.z, 0.0f);
        base ~= Param.float_("SX", "Scale X",  &headlessScale.x,  1.0f);
        base ~= Param.float_("SY", "Scale Y",  &headlessScale.y,  1.0f);
        base ~= Param.float_("SZ", "Scale Z",  &headlessScale.z,  1.0f);
        return base;
    }

    // Headless apply chain: translate (MoveTool) → rotate → scale.
    // Order matches MODO's xfrm.transform documented order (T → R → S).
    // Rotate/Scale use pivotRotationMatrix / pivotScaleMatrix around
    // the ACEN-supplied pivot captured BEFORE the translate step —
    // ACEN.Element re-averages face centroids on every query, so
    // re-evaluating after super.applyHeadless's TX would drift the
    // pivot off the picked-element centroid into wherever the
    // translated geometry now averages. MODO's ElementMove caches
    // the pivot once at apply start; we mirror that.
    override bool applyHeadless() {
        // Pivot snapshot — must happen before super.applyHeadless
        // mutates mesh.vertices (see comment above).
        Vec3 pivot = queryActionCenter();

        // Snapshot per-vert weights at the BASELINE positions —
        // MODO's xfrm.transform applies a single weight per vert
        // through the whole T → R → S chain (computed against the
        // pre-mutation positions). Without this snapshot the scale
        // step would re-evaluate falloff against the post-translate
        // mesh, where verts have moved into / out of the falloff
        // sphere; both engines need to agree on the formula for
        // cross-engine diff to PASS.
        captureFalloffForDrag();
        captureSymmetryForDrag();
        vertexCacheDirty = true;
        buildVertexCacheIfNeeded();
        if (vertexProcessCount == 0) return false;
        float[] cachedWeights = new float[](mesh.vertices.length);
        foreach (i; 0 .. mesh.vertices.length) cachedWeights[i] = 0.0f;
        foreach (vi; vertexIndicesToProcess)
            cachedWeights[vi] = falloffWeightAt(mesh.vertices[vi],
                                                cast(int)vi);

        // Step 1: translate via MoveTool's implementation. Reuses
        // the same captureFalloffForDrag (already done above —
        // super's call is idempotent) + vertex cache. The
        // falloff-weighted translate inside applyDeltaImmediate
        // also evaluates falloffWeight live, but at this point the
        // mesh hasn't been mutated yet so live weight == cached
        // weight.
        if (!super.applyHeadless()) return false;

        bool hasRot = (headlessRotate.x != 0.0f
                    || headlessRotate.y != 0.0f
                    || headlessRotate.z != 0.0f);
        bool hasScl = (headlessScale.x != 1.0f
                    || headlessScale.y != 1.0f
                    || headlessScale.z != 1.0f);
        if (!hasRot && !hasScl) return true;

        cachedCenter = pivot;

        // Rotate per non-zero axis. AXIS-stage right/up/fwd give us
        // the local basis (Element mode points them at the picked
        // element's local frame).
        if (hasRot) {
            Vec3 bX, bY, bZ;
            currentBasis(bX, bY, bZ);
            applyAxisRotate(pivot, bX, headlessRotate.x, cachedWeights);
            applyAxisRotate(pivot, bY, headlessRotate.y, cachedWeights);
            applyAxisRotate(pivot, bZ, headlessRotate.z, cachedWeights);
        }

        // Scale per-axis around pivot. Like the rotate, the per-vert
        // weight blends the scale toward identity (1) so verts
        // outside the falloff stay put. Uses the SAME cachedWeights
        // as translate / rotate (see snapshot comment above).
        if (hasScl) {
            foreach (vi; vertexIndicesToProcess) {
                float w = cachedWeights[vi];
                if (w == 0.0f) continue;
                float sx = 1.0f + (headlessScale.x - 1.0f) * w;
                float sy = 1.0f + (headlessScale.y - 1.0f) * w;
                float sz = 1.0f + (headlessScale.z - 1.0f) * w;
                auto m = pivotScaleMatrix(pivot, sx, sy, sz);
                auto v0 = Vec4(mesh.vertices[vi].x, mesh.vertices[vi].y,
                               mesh.vertices[vi].z, 1.0f);
                auto v1 = mulMV(m, v0);
                mesh.vertices[vi] = Vec3(v1.x, v1.y, v1.z);
            }
        }
        return true;
    }

    private void applyAxisRotate(Vec3 pivot, Vec3 axis, float deg,
                                  float[] cachedWeights) {
        if (deg == 0.0f) return;
        foreach (vi; vertexIndicesToProcess) {
            float w = cachedWeights[vi];
            if (w == 0.0f) continue;
            float phi = deg * w * cast(float)(PI / 180.0);
            auto m = pivotRotationMatrix(pivot, axis, phi);
            auto v0 = Vec4(mesh.vertices[vi].x, mesh.vertices[vi].y,
                           mesh.vertices[vi].z, 1.0f);
            auto v1 = mulMV(m, v0);
            mesh.vertices[vi] = Vec3(v1.x, v1.y, v1.z);
        }
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        // Element-pick happens BEFORE MoveTool's standard mouse-down
        // handling so the picked-centre lands on the FalloffStage
        // before any drag starts. Skip when not LMB (right-click owns
        // lasso / camera modes) or when modifier held (Alt = camera,
        // Ctrl/Shift = selection modifiers handled by app.d).
        bool picked = false;
        bool ctrlMod = false;
        if (e.button == SDL_BUTTON_LEFT) {
            SDL_Keymod mods = SDL_GetModState();
            ctrlMod = (mods & KMOD_CTRL) != 0;
            bool plain = (mods & (KMOD_ALT | KMOD_CTRL | KMOD_SHIFT)) == 0;
            if (plain) picked = tryPickElement(e.x, e.y);
        }

        // Let MoveTool handle gizmo-arrow hits + falloff endpoint
        // handles first — those have priority over click-to-drag.
        if (super.onMouseButtonDown(e)) return true;

        // Click landed off the gizmo. MODO ElementMove docs (help/
        // ...element_move.html): "you can drag to move the element
        // in 3D space ... after you release the mouse button, use
        // the handles to move the element along an axis". Mirror
        // that: when we picked an element, start a screen-plane
        // drag from its centroid right away. ACEN's normal click-
        // relocate gate (acenAllowsClickRelocate refuses Element
        // mode) doesn't apply — Element mode IS the gate.
        if (picked) {
            auto fs = activeFalloffStage();
            if (fs !is null && fs.type == FalloffType.Element) {
                beginScreenPlaneDragAt(e.x, e.y, fs.pickedCenter,
                                       ctrlMod, /*notifyAcen=*/false);
                return true;
            }
        }
        return false;
    }

private:
    // Hit-test mesh elements against (mx, my) and update the active
    // FalloffStage.pickedCenter to the picked element's centroid.
    // Pick priority in Automatic mode: vertex → edge → face (matches
    // MODO's "element under cursor" semantic — verts are most
    // specific, faces fill in the rest). Manual mode restricts to
    // the current editMode.
    //
    // Picking pixel radius: 16 px around the cursor — matches the
    // existing select tolerance in app.d's pick code.
    // Returns true if an element was picked (and pickedCenter updated).
    // ElementMoveTool.onMouseButtonDown uses the return value to gate
    // the auto-drag fallback when the click landed off the gizmo.
    bool tryPickElement(int mx, int my) {
        FalloffStage stage = activeFalloffStage();
        if (stage is null) return false;
        if (stage.type != FalloffType.Element) return false;

        enum float PICK_R_PX = 16.0f;
        enum float PICK_R2   = PICK_R_PX * PICK_R_PX;

        // Pick-type restriction per Stage 14.8 ElementMode:
        //   Auto / AutoCent  → all three (priority vert → edge → face)
        //   Vertex           → verts only
        //   Edge / EdgeCent  → edges only
        //   Polygon/PolyCent → polygons only
        ElementMode em = stage.elementMode;
        bool wantV = (em == ElementMode.Auto)     || (em == ElementMode.AutoCent)
                  || (em == ElementMode.Vertex);
        bool wantE = (em == ElementMode.Auto)     || (em == ElementMode.AutoCent)
                  || (em == ElementMode.Edge)     || (em == ElementMode.EdgeCent);
        bool wantF = (em == ElementMode.Auto)     || (em == ElementMode.AutoCent)
                  || (em == ElementMode.Polygon)  || (em == ElementMode.PolyCent);

        // Vertex priority.
        if (wantV) {
            int   bestVi = -1;
            float bestD2 = PICK_R2;
            foreach (vi; 0 .. mesh.vertices.length) {
                float sx, sy, ndcZ;
                if (!projectToWindowFull(mesh.vertices[vi], cachedVp,
                                         sx, sy, ndcZ))
                    continue;
                float dx = sx - mx, dy = sy - my;
                float d2 = dx*dx + dy*dy;
                if (d2 < bestD2) { bestD2 = d2; bestVi = cast(int)vi; }
            }
            if (bestVi >= 0) {
                stage.pickedCenter = mesh.vertices[bestVi];
                stage.pickedVerts  = [cast(uint)bestVi];
                updateConnectMask(stage, bestVi);
                return true;
            }
        }
        // Edge priority: pick the edge whose projected SEGMENT is
        // closest to the cursor. Using the segment (not the midpoint)
        // matters for long edges — clicking near an endpoint can be
        // well outside 16 px of the midpoint and still be on the
        // edge visually. MODO's Auto-Center mode lands the picked
        // centre on the edge midpoint regardless of where on the
        // edge the user clicked; we mirror that by setting
        // `pickedCenter` to the midpoint after the pick decision.
        if (wantE) {
            int   bestEi = -1;
            float bestD2 = PICK_R2;
            foreach (ei, edge; mesh.edges) {
                float ax, ay, az, bx, by, bz;
                if (!projectToWindowFull(mesh.vertices[edge[0]], cachedVp,
                                         ax, ay, az))
                    continue;
                if (!projectToWindowFull(mesh.vertices[edge[1]], cachedVp,
                                         bx, by, bz))
                    continue;
                float t;
                float d2 = closestOnSegment2DSquared(
                    cast(float)mx, cast(float)my, ax, ay, bx, by, t);
                if (d2 < bestD2) { bestD2 = d2; bestEi = cast(int)ei; }
            }
            if (bestEi >= 0) {
                auto e = mesh.edges[bestEi];
                stage.pickedCenter = (mesh.vertices[e[0]]
                                    + mesh.vertices[e[1]]) * 0.5f;
                stage.pickedVerts  = [cast(uint)e[0], cast(uint)e[1]];
                updateConnectMask(stage, cast(int)e[0]);
                return true;
            }
        }
        // Face priority: cursor inside the projected face polygon
        // counts as a hit regardless of how far it is from the
        // centroid. Same MODO Auto-Center semantic as edges:
        // `pickedCenter` lands on the face centroid even when the
        // user clicked an off-centre point on the face. For
        // overlapping faces (e.g. cube back face under front),
        // pick the one whose centroid has the closest screen depth
        // (smallest ndcZ — nearest to camera) as a frontmost
        // tiebreaker.
        if (wantF) {
            int   bestFi = -1;
            float bestZ  = float.infinity;
            float[] xs;
            float[] ys;
            foreach (fi; 0 .. mesh.faces.length) {
                const(uint)[] face = mesh.faces[fi];
                xs.length = face.length;
                ys.length = face.length;
                bool projectedAll = true;
                float zSum = 0;
                int   zCount = 0;
                foreach (i, vi; face) {
                    float sx, sy, ndcZ;
                    if (!projectToWindowFull(mesh.vertices[vi], cachedVp,
                                             sx, sy, ndcZ))
                    {
                        projectedAll = false;
                        break;
                    }
                    xs[i] = sx; ys[i] = sy;
                    zSum += ndcZ; ++zCount;
                }
                if (!projectedAll || zCount == 0) continue;
                if (!pointInPolygon2D(cast(float)mx, cast(float)my, xs, ys))
                    continue;
                float zAvg = zSum / cast(float)zCount;
                if (zAvg < bestZ) { bestZ = zAvg; bestFi = cast(int)fi; }
            }
            if (bestFi >= 0) {
                stage.pickedCenter = mesh.faceCentroid(cast(uint)bestFi);
                stage.pickedVerts.length = mesh.faces[bestFi].length;
                foreach (i, vi; mesh.faces[bestFi])
                    stage.pickedVerts[i] = vi;
                // Seed the BFS from any vert of the picked face.
                if (mesh.faces[bestFi].length > 0)
                    updateConnectMask(stage, cast(int)mesh.faces[bestFi][0]);
                return true;
            }
        }
        return false;
    }

    // Compute the connected component containing `seedVi` and write
    // it into the FalloffStage's `connectMask`. BFS over mesh.edges.
    // Only runs when `connect != Off` — if the gate is disabled we
    // leave the mask alone (consumers see length 0 and skip the gate).
    void updateConnectMask(FalloffStage stage, int seedVi) {
        import toolpipe.packets : ElementConnect;
        if (stage.connect == ElementConnect.Off) {
            stage.connectMask = null;
            return;
        }
        size_t n = mesh.vertices.length;
        if (seedVi < 0 || seedVi >= cast(int)n) {
            stage.connectMask = null;
            return;
        }
        // Adjacency: edge endpoints both flag each other. Rebuilt per
        // pick — small mesh sizes today don't justify caching. For
        // large meshes the natural follow-up is invalidating on
        // mutationVersion and reusing across picks.
        size_t[][] adj = new size_t[][](n);
        foreach (e; mesh.edges) {
            adj[e[0]] ~= e[1];
            adj[e[1]] ~= e[0];
        }
        bool[] visited = new bool[](n);
        size_t[] queue;
        queue ~= cast(size_t)seedVi;
        visited[seedVi] = true;
        while (queue.length > 0) {
            size_t v = queue[$ - 1];
            queue.length -= 1;
            foreach (nb; adj[v]) {
                if (!visited[nb]) { visited[nb] = true; queue ~= nb; }
            }
        }
        stage.connectMask = visited;
    }

    // Returns the active FalloffStage (null if no pipeline registered
    // or no WGHT stage; the latter shouldn't happen in normal app
    // setup but tests bypass app's init and can hit this branch).
    FalloffStage activeFalloffStage() {
        if (g_pipeCtx is null) return null;
        return cast(FalloffStage)
               g_pipeCtx.pipeline.findByTask(TaskCode.Wght);
    }
}
