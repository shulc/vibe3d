module tools.edit.drag_weld;

import bindbc.sdl;

import tool;
import mesh;
import math;
import params : Param;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;
import editmode : EditMode;
import operator : VectorStack;

alias VertexEditFactory = MeshSessionEdit delegate();

// Pixel pick radius for DragWeldTool source/target vertex selection.
// A vertex must project within this many pixels of the mouse to be
// considered a candidate. vibe3d-divergence: reference snap radius not
// captured (deferred).
private enum float PICK_RADIUS_PX = 12.0f;

// ---------------------------------------------------------------------------
// DragWeldTool — drag a source vertex onto a target vertex to weld them.
//
// Gesture:
//   LMB-down  → pick nearest vertex within PICK_RADIUS_PX as the source.
//               If no vertex is near, the event is NOT consumed (lets camera
//               and other handlers see it).
//   LMB-motion → track (no geometry mutation; drag is non-destructive until
//               release). Consumes motion events while dragging_ is true.
//   LMB-up    → pick nearest OTHER vertex as the target; call
//               mesh.weldVertexPair(target, source). If no target or kernel
//               returns 0 (shared-face / faceless / guard), no-op (no undo
//               entry). Otherwise record one snapshot-undo entry.
//
// Selection after weld: the survivor vertex is re-located by its LAYER-LOCAL
// position (keepPos captured before the weld) because compactUnreferenced
// reindexes all surviving vertices and the pre-weld index is stale. Local vs
// local — `keepPos` and the rescan both read `mesh.vertices`, so the item
// transform cancels and must NOT be applied here (task 0619: three comments
// in this file used to say "world" of these local values).
//
// Gated to Vertices edit mode via supportedModes().
// ---------------------------------------------------------------------------
class DragWeldTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu_;
    LitShader        litShader_;

    VertexCache*     vc_;
    EdgeCache*       ec_;
    FaceBoundsCache* fc_;

    CommandHistory    history_;
    VertexEditFactory factory_;

    // The WORLD-space viewport `draw()` was handed. Named `vpWorld_` (task
    // 0619) so a use that needs the AIMING space — layer-local geometry
    // projected through the item transform — cannot pick this up by
    // accident: it has to go through `aimSpace(vpWorld_, ms)`, whose
    // `AimViewport` result is a distinct type (math.d §2.0).
    Viewport vpWorld_;

    bool dragging_ = false;
    int  source_   = -1;   // vertex index picked on button-down

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc)
    {
        this.meshSrc_   = meshSrc;
        this.gpu_       = gpu;
        this.litShader_ = litShader;
        this.vc_        = vc;
        this.ec_        = ec;
        this.fc_        = fc;
    }

    void setUndoBindings(CommandHistory h, VertexEditFactory f) {
        history_ = h;
        factory_ = f;
    }

    override string name() const { return "Drag Weld"; }

    override Param[] params() { return []; }

    // Restrict to Vertices mode — mirrors EdgeExtrudeTool.supportedModes().
    override EditMode[] supportedModes() const { return [EditMode.Vertices]; }

    // Cache the viewport each frame so pick helpers have current camera.
    override void draw(const ref Shader shader, const ref Viewport vp,
                       ref VectorStack vts, bool visualOnly = false)
    {
        vpWorld_ = vp;
    }

    override void drawProperties() {
        import ImGui = d_imgui;
        ImGui.TextDisabled("Drag a vertex onto another to weld them.");
    }

    // A drag is in progress between button-down and button-up.
    override bool hasUncommittedEdit() const { return dragging_; }

    override void cancelUncommittedEdit() {
        dragging_ = false;
        source_   = -1;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e,
                                    ref VectorStack vts)
    {
        if (e.button != SDL_BUTTON_LEFT) return false;
        // Alt is reserved for camera orbit/pan/zoom.
        if (SDL_GetModState() & KMOD_ALT) return false;

        int vi = pickNearestVertex_(e.x, e.y, -1);
        if (vi < 0) return false;  // no vertex nearby — let camera handle it

        source_   = vi;
        dragging_ = true;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e,
                                ref VectorStack vts)
    {
        // Consume motion events while dragging so camera doesn't orbit.
        // No geometry mutation during the drag — picking is done on release.
        return dragging_;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e,
                                  ref VectorStack vts)
    {
        if (!dragging_) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;

        scope(exit) { dragging_ = false; source_ = -1; }

        // Pick the target vertex, excluding the source from consideration.
        int target = pickNearestVertex_(e.x, e.y, source_);
        if (target < 0 || target == source_) return true;   // no-op release

        // Capture the survivor's LAYER-LOCAL position BEFORE the weld.
        // compactUnreferenced (called inside weldVertexPair → weldVerticesByMask)
        // reindexes surviving vertices, making the pre-weld index stale.
        // We re-locate the survivor by position afterwards.
        Vec3 keepPos = mesh.vertices[cast(uint)target];

        MeshSnapshot pre = MeshSnapshot.capture(*mesh);

        size_t welded = mesh.weldVertexPair(cast(uint)target, cast(uint)source_);
        if (welded == 0) return true;  // shared-face / faceless / guard: no-op

        // Re-locate the survivor by its layer-local position and select it.
        // resizeVertexSelection is already called inside compactUnreferenced
        // (inside `Mesh.compactUnreferenced`) — do NOT call it again here.
        mesh.clearVertexSelection();
        {
            float bestDist2 = 1e-9f * 1e-9f;   // 1 nm tolerance (well inside float eps)
            int   bestIdx   = -1;
            foreach (i, v; mesh.vertices) {
                Vec3 d = v - keepPos;
                float dist2 = d.x*d.x + d.y*d.y + d.z*d.z;
                if (dist2 < bestDist2) { bestDist2 = dist2; bestIdx = cast(int)i; }
            }
            // Use a relaxed tolerance for the linear scan: the survivor vertex
            // is AT keepPos (we snapped drop→keep before welding), so dist2 ≈ 0.
            // If the mesh has moved since capture (shouldn't happen mid-gesture),
            // fall back to the closest vertex within 1e-5 world units.
            if (bestIdx < 0) {
                float relaxed = 1e-5f * 1e-5f;
                foreach (i, v; mesh.vertices) {
                    Vec3 d = v - keepPos;
                    float dist2 = d.x*d.x + d.y*d.y + d.z*d.z;
                    if (dist2 < relaxed) { relaxed = dist2; bestIdx = cast(int)i; }
                }
            }
            if (bestIdx >= 0) mesh.selectVertex(bestIdx);
        }

        gpu_.upload(*mesh);

        // Record one snapshot-undo entry per completed gesture.
        if (history_ !is null && factory_ !is null && pre.filled) {
            auto cmd  = factory_();
            auto post = MeshSnapshot.capture(*mesh);
            cmd.setSnapshots(pre, post, "Weld Vertices");
            history_.record(cmd);
        }

        // Refresh selection / picking caches (mirrors vertex_place.d:174-187).
        mesh.syncSelection();
        refreshDisplay(mesh, gpu_, vc_, ec_, fc_);
        return true;
    }

private:
    /// Pick the nearest vertex within PICK_RADIUS_PX of screen position (sx,sy).
    /// Skips vertex index `exclude` (-1 = no exclusion). Returns the vertex
    /// index or -1 if none is close enough.
    ///
    /// AIMING KIND: **Pixel** (task 0619, §1.1 of
    /// doc/tool_aiming_item_transform_plan.md). `mesh.vertices` holds
    /// LAYER-LOCAL coordinates; the geometry is DRAWN through the primary
    /// layer's item matrix `M`. The correct space for this kind is therefore
    /// "keep the geometry local, compose the viewport": `aimSpace` folds `M`
    /// into the view matrix, and `proj*(view*M)*v == proj*view*(M*v)` holds
    /// exactly, so the pixel compared against the cursor here is the pixel
    /// the vertex is drawn at. Projecting `v` through `vpWorld_` instead
    /// aims at where the layer would sit at identity.
    ///
    /// The `AimViewport` is built ONCE, before the loop (§3): `aimSpace` is
    /// a stack copy plus one `matMul4`, which is cheap per query and
    /// unacceptable per vertex.
    int pickNearestVertex_(int sx, int sy, int exclude) {
        import document : primaryModelSpace;
        const AimViewport vpAim = aimSpace(vpWorld_, primaryModelSpace());
        float bestDist2 = PICK_RADIUS_PX * PICK_RADIUS_PX;
        int   bestIdx   = -1;
        foreach (i, v; mesh.vertices) {
            if (cast(int)i == exclude) continue;
            float px, py, ndcZ;
            if (!projectToWindowFull(v, vpAim.vp, px, py, ndcZ)) continue;
            float dx = px - cast(float)sx;
            float dy = py - cast(float)sy;
            float d2 = dx*dx + dy*dy;
            if (d2 < bestDist2) {
                bestDist2 = d2;
                bestIdx   = cast(int)i;
            }
        }
        return bestIdx;
    }
}

// ---------------------------------------------------------------------------
// The AimViewport compile gate, asserted from a CONSUMER module (task 0619
// §2.0). `private` in D is module-scoped, so math.d itself cannot prove that
// `AimViewport`'s constructor is out of reach — inside math.d it is not. This
// file is a real consumer of `aimSpace`, so the asserts below measure exactly
// what the gate promises every call site in the tree: an `AimViewport` cannot
// be conjured from a world `Viewport`; the only way to obtain one is to hand
// `aimSpace` a `ModelSpace`.
//
// If any of these ever starts compiling, the type gate is gone and every
// aiming site silently falls back to being policed by review alone.
// ---------------------------------------------------------------------------
version (unittest) {
    private void aimViewportGateChecks() {
        static assert(!__traits(compiles, { AimViewport a; }),
            "AimViewport must not be default-constructible outside math.d");
        static assert(!__traits(compiles, { Viewport w; AimViewport a = AimViewport(w); }),
            "AimViewport's constructor must be unreachable outside math.d");
        static assert(!__traits(compiles, { Viewport w; AimViewport a = w; }),
            "a world Viewport must not become an AimViewport outside math.d");
        // The positive control: the ONE sanctioned producer does compile, so
        // the three refusals above are about accessibility, not about the
        // type being unusable.
        static assert(__traits(compiles, {
            Viewport w; ModelSpace ms; auto a = aimSpace(w, ms); cast(void)a.vp.width;
        }), "aimSpace(vp, ms) must be the way an AimViewport is produced");
    }
}
