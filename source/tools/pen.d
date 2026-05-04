module tools.pen;

import bindbc.opengl;
import bindbc.sdl;

import tool;
import mesh;
import math;
import params : Param;
import handler : BoxHandler, gizmoSize;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import tools.create_common : pickMostFacingPlane, BuildPlane;

import std.math : abs;

alias PenEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// PenParams — vibe3d's pen tool wire schema.
//
// pen is a plugin tool in MODO 902 (no entry in cmdhelptools.cfg, not
// loadable in modo_cl). Schema follows MODO's panel option names so wire
// format compatibility is reasonable should that path ever open up.
//
// For phase 6.9.0 only `polygons` mode is implemented; later subphases
// add `lines` / `vertices` / `subdiv`. `spline` and `polyline` modes
// stay reserved (no vibe3d spline / curve geometry) — see doc/pen_plan.md.
// ---------------------------------------------------------------------------
struct PenParams {
    int  type = 0;       // 0=polygons (only mode in 6.9.0)
    bool flip = false;   // reverse vertex order on commit
}

// ---------------------------------------------------------------------------
// PenTool — interactive polygon-by-vertex creation.
//
// Phase 6.9.0 (skeleton + polygons mode):
//   Idle ── LMB-click ─→ Drawing (first vertex placed; construction plane
//                                  locked from the camera-most-facing world
//                                  plane via pickMostFacingPlane)
//   Drawing ── LMB-click ─→ Drawing (append vertex on the locked plane)
//   Drawing ── double-click / Enter ─→ commit n-gon (n ≥ 3); back to Idle
//   Drawing ── Backspace ─→ pop last vertex; ─→ Idle if buffer empties
//   Drawing ── Esc / RMB ─→ cancel (drop buffer); back to Idle
//
// In-progress vertex markers render in cyan (Vec3(0, 0.9, 0.9)); BoxHandler's
// built-in hover paint flips the cursor-over vertex to yellow ("they'll
// turn yellow when the mouse is directly over them" from MODO's pen.html).
// Edges between consecutive in-progress vertices preview as the standard
// wireframe (open polyline — closing happens at commit).
//
// On commit, the in-progress vertex sequence is appended to the scene
// mesh and a face is added (winding reversed when params_.flip = true).
// A snapshot pair is captured around the commit for undo.
//
// Unlike Box / Sphere / Cylinder / etc., Pen does NOT auto-deactivate
// after a single commit — the user can keep drawing more polygons until
// they switch tools or hit a different shortcut. Cache refresh is called
// from inside commitPolygonWithUndo (the commit fires on key / mouse
// events, not just deactivate, so the setActiveTool path can't cover it).
// ---------------------------------------------------------------------------

private enum PenState { Idle, Drawing }

class PenTool : Tool {
private:
    Mesh*            mesh;
    GpuMesh*         gpu;
    LitShader        litShader;

    // Cache refs — refreshed after each commit since Pen mutates mesh
    // mid-session (commits don't go through setActiveTool's bulk refresh).
    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    PenParams        params_;
    CommandHistory   history;
    PenEditFactory   factory;

    PenState         state;
    Vec3[]           vertices_;     // world positions of the in-progress sequence
    BoxHandler[]     vertHandlers;  // one cyan marker per in-progress vertex

    Mesh             previewMesh;
    GpuMesh          previewGpu;

    Vec3 planeNormal;
    Vec3 planeAxis1;
    Vec3 planeAxis2;

    Viewport cachedVp;
    bool     meshChanged;

public:
    this(Mesh* mesh, GpuMesh* gpu, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.mesh      = mesh;
        this.gpu       = gpu;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
    }

    void destroy() {
        clearVertHandlers();
    }

    void setUndoBindings(CommandHistory h, PenEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Pen"; }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.intEnum_("type", "Type", &params_.type,
                [IntEnumEntry(0, "polygons", "Polygons")],
                0),
            Param.bool_("flip", "Flip Polygon", &params_.flip, false),
        ];
    }

    override void activate() {
        state = PenState.Idle;
        vertices_.length = 0;
        previewGpu.init();
    }

    override void deactivate() {
        // If a valid sequence is pending, commit it on deactivate.
        if (state == PenState.Drawing && vertices_.length >= 3) {
            commitPolygonWithUndo();
        } else {
            cancelPolygon();
        }
        previewGpu.destroy();
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button == SDL_BUTTON_RIGHT) {
            if (state == PenState.Drawing) cancelPolygon();
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        // Alt is reserved for camera. Ctrl / Shift slated for later
        // subphases (Shift+click new polygon, Ctrl in Make Quads).
        if (mods & KMOD_ALT) return false;
        if (mods & (KMOD_CTRL | KMOD_SHIFT)) return false;

        // Double-click commits the current sequence (vibe3d convention,
        // see doc/pen_plan.md). The first physical click of the double
        // will have fired with clicks=1 already, adding a vertex; the
        // clicks=2 event then commits without adding another.
        if (e.clicks == 2) {
            if (state == PenState.Drawing && vertices_.length >= 3)
                commitPolygonWithUndo();
            return true;
        }

        if (state == PenState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                   Vec3(0, 0, 0), planeNormal, hit))
                return true;
            appendVertex(hit);
            state = PenState.Drawing;
            uploadPreview();
            return true;
        }

        // Drawing — append vertex on the locked plane.
        Vec3 hit;
        if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                              Vec3(0, 0, 0), planeNormal, hit))
        {
            appendVertex(hit);
            uploadPreview();
        }
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        // BoxHandler.draw() updates its own hover state per frame, so we
        // don't need explicit per-motion bookkeeping here. Returning false
        // lets app.d's other motion handlers (camera drag, etc.) run.
        return false;
    }

    override bool onKeyDown(ref const SDL_KeyboardEvent e) {
        switch (e.keysym.sym) {
            case SDLK_RETURN:
            case SDLK_KP_ENTER:
                if (state == PenState.Drawing && vertices_.length >= 3) {
                    commitPolygonWithUndo();
                    return true;
                }
                // Consume Enter while pen is active even if not committable
                // (no point letting it leak to other handlers).
                return true;

            case SDLK_BACKSPACE:
                if (state == PenState.Drawing && vertices_.length > 0) {
                    popVertex();
                    if (vertices_.length == 0) state = PenState.Idle;
                    uploadPreview();
                    return true;
                }
                return false;

            case SDLK_ESCAPE:
                // Always consume Esc while pen is active so the app's
                // SDLK_ESCAPE → quit fallback doesn't fire mid-edit.
                if (state == PenState.Drawing) cancelPolygon();
                return true;

            default:
                return false;
        }
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        cachedVp = vp;
        if (state == PenState.Idle) return;

        immutable float[16] identity = identityMatrix;

        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);

        // Open polyline preview (edges between consecutive verts).
        if (vertices_.length >= 2)
            previewGpu.drawEdges(shader.locColor, -1, []);

        // Vertex markers — cyan default; BoxHandler.draw paints yellow on hover.
        foreach (i, h; vertHandlers) {
            h.size = gizmoSize(h.pos, vp, 0.04f);
            h.draw(shader, vp);
        }
    }

    override bool drawImGui() { return false; }

    override void drawProperties() {
        import ImGui = d_imgui;
        if (state == PenState.Idle)
            ImGui.TextDisabled("Click in viewport to start a polygon.");
        else
            ImGui.TextDisabled("Click to add vertices • Enter / dbl-click to close • Backspace to undo • Esc / RMB to cancel");
    }

private:
    void choosePlane(const ref Viewport vp) {
        auto bp = pickMostFacingPlane(vp);
        planeNormal = bp.normal;
        planeAxis1  = bp.axis1;
        planeAxis2  = bp.axis2;
    }

    void appendVertex(Vec3 pos) {
        vertices_ ~= pos;
        // Cyan marker per architectural decision C.1 in doc/pen_plan.md;
        // BoxHandler tinted yellow on cursor hover via the base class.
        auto h = new BoxHandler(pos, Vec3(0.0f, 0.9f, 0.9f));
        vertHandlers ~= h;
    }

    void popVertex() {
        if (vertices_.length == 0) return;
        vertices_.length -= 1;
        if (vertHandlers.length > 0) {
            vertHandlers[$ - 1].destroy();
            vertHandlers.length -= 1;
        }
    }

    void clearVertHandlers() {
        foreach (h; vertHandlers) h.destroy();
        vertHandlers.length = 0;
    }

    void cancelPolygon() {
        clearVertHandlers();
        vertices_.length = 0;
        previewMesh.clear();
        // No upload needed: draw() short-circuits when state == Idle, so the
        // stale GPU buffers are simply not rendered until the next Drawing
        // session re-uploads.
        state = PenState.Idle;
    }

    void uploadPreview() {
        previewMesh.clear();
        foreach (v; vertices_) previewMesh.addVertex(v);
        if (vertices_.length >= 2) {
            foreach (i; 0 .. cast(int)vertices_.length - 1)
                previewMesh.addEdge(cast(uint)i, cast(uint)(i + 1));
        }
        previewGpu.upload(previewMesh);
        // Keep marker positions in sync (vertices_ may have been mutated by
        // popVertex / future numeric edits).
        foreach (i, ref h; vertHandlers) h.pos = vertices_[i];
    }

    void commitPolygonWithUndo() {
        if (state != PenState.Drawing || vertices_.length < 3) return;
        MeshSnapshot pre = MeshSnapshot.capture(*mesh);
        commitPolygon();
        if (history !is null && factory !is null && pre.filled) {
            auto cmd  = factory();
            auto post = MeshSnapshot.capture(*mesh);
            cmd.setSnapshots(pre, post, "Pen Polygon");
            history.record(cmd);
        }
        // Refresh selection/picking caches so the new face is hover-pickable
        // and selection arrays match the grown geometry.
        mesh.syncSelection();
        if (vc !is null) { vc.resize(mesh.vertices.length); vc.invalidate(); }
        if (fc !is null) { fc.resize(mesh.vertices.length, mesh.faces.length); fc.invalidate(); }
        if (ec !is null) { ec.resize(mesh.edges.length); ec.invalidate(); }
        // Drop in-progress state — tool stays active for the next polygon.
        state = PenState.Idle;
        clearVertHandlers();
        vertices_.length = 0;
        previewMesh.clear();
        previewGpu.upload(previewMesh);
        meshChanged = true;
    }

    void commitPolygon() {
        uint base = cast(uint)mesh.vertices.length;
        foreach (v; vertices_) mesh.addVertex(v);
        uint[] face;
        face.length = vertices_.length;
        if (params_.flip) {
            foreach (i, _; vertices_)
                face[i] = base + cast(uint)(vertices_.length - 1 - i);
        } else {
            foreach (i, _; vertices_)
                face[i] = base + cast(uint)i;
        }
        mesh.addFace(face);
        mesh.buildLoops();
        gpu.upload(*mesh);
    }
}
