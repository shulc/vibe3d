module tools.element_move;

import bindbc.sdl;

import tools.move;
import mesh;
import editmode;
import math : Vec3, Vec4, projectToWindowFull, pivotRotationMatrix,
              pivotScaleMatrix, mulMV;
import shader;
import params : Param;

import std.math : PI;

import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage    : TaskCode;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.packets  : FalloffType;

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
    enum Mode : ubyte { Automatic = 0, Manual = 1 }
    Mode mode = Mode.Automatic;

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

    override void activate() {
        super.activate();
        mode = Mode.Automatic;
        headlessRotate = Vec3(0, 0, 0);
        headlessScale  = Vec3(1, 1, 1);
    }

    // `mode` is an int enum; expose via Param.int_ for simplicity (the
    // values are Automatic=0, Manual=1). User sets via
    // `tool.attr xfrm.elementMove mode 1` for Manual.
    override Param[] params() {
        auto base = super.params();
        base ~= Param.int_("mode", "Mode", cast(int*)&mode, 0).min(0).max(1);
        // Numeric rotate / scale attrs. TX/TY/TZ come from
        // MoveTool's params() (base above).
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
        // before any drag starts.
        //
        // Skip element pick when:
        //   - Not LMB (right-click owns lasso / camera modes elsewhere).
        //   - Any modifier held (Alt = camera, Ctrl/Shift = selection
        //     modifiers handled by app.d, not us).
        if (e.button == SDL_BUTTON_LEFT) {
            SDL_Keymod mods = SDL_GetModState();
            bool plain = (mods & (KMOD_ALT | KMOD_CTRL | KMOD_SHIFT)) == 0;
            if (plain) tryPickElement(e.x, e.y);
        }
        return super.onMouseButtonDown(e);
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
    void tryPickElement(int mx, int my) {
        FalloffStage stage = activeFalloffStage();
        if (stage is null) return;
        if (stage.type != FalloffType.Element) return;

        enum float PICK_R_PX = 16.0f;
        enum float PICK_R2   = PICK_R_PX * PICK_R_PX;

        bool wantV = (mode == Mode.Automatic) || (*editMode == EditMode.Vertices);
        bool wantE = (mode == Mode.Automatic) || (*editMode == EditMode.Edges);
        bool wantF = (mode == Mode.Automatic) || (*editMode == EditMode.Polygons);

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
                updateConnectMask(stage, bestVi);
                return;
            }
        }
        // Edge priority: pick the edge whose midpoint is closest.
        if (wantE) {
            int   bestEi = -1;
            float bestD2 = PICK_R2;
            foreach (ei, edge; mesh.edges) {
                Vec3 mid = (mesh.vertices[edge[0]] + mesh.vertices[edge[1]])
                           * 0.5f;
                float sx, sy, ndcZ;
                if (!projectToWindowFull(mid, cachedVp, sx, sy, ndcZ))
                    continue;
                float dx = sx - mx, dy = sy - my;
                float d2 = dx*dx + dy*dy;
                if (d2 < bestD2) { bestD2 = d2; bestEi = cast(int)ei; }
            }
            if (bestEi >= 0) {
                auto e = mesh.edges[bestEi];
                stage.pickedCenter = (mesh.vertices[e[0]]
                                    + mesh.vertices[e[1]]) * 0.5f;
                updateConnectMask(stage, cast(int)e[0]);
                return;
            }
        }
        // Face priority: pick the face whose centroid is closest.
        if (wantF) {
            int   bestFi = -1;
            float bestD2 = PICK_R2;
            foreach (fi; 0 .. mesh.faces.length) {
                Vec3 c = mesh.faceCentroid(cast(uint)fi);
                float sx, sy, ndcZ;
                if (!projectToWindowFull(c, cachedVp, sx, sy, ndcZ))
                    continue;
                float dx = sx - mx, dy = sy - my;
                float d2 = dx*dx + dy*dy;
                if (d2 < bestD2) { bestD2 = d2; bestFi = cast(int)fi; }
            }
            if (bestFi >= 0) {
                stage.pickedCenter = mesh.faceCentroid(cast(uint)bestFi);
                // Seed the BFS from any vert of the picked face.
                if (mesh.faces[bestFi].length > 0)
                    updateConnectMask(stage, cast(int)mesh.faces[bestFi][0]);
            }
        }
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
