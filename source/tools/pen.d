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
    int   type         = 0;        // 0=polygons (only mode in 6.9.0; later subphases extend)
    bool  flip         = false;    // reverse vertex order on commit

    // 6.9.1 numeric edit fields. currentPoint = -1 means "no vertex selected";
    // posX/Y/Z mirror the position of vertices_[currentPoint] when valid, and
    // are written back into the buffer through onParamChanged.
    int   currentPoint = -1;
    float posX = 0.0f, posY = 0.0f, posZ = 0.0f;

    // 6.9.5: Make Quads. After the first two clicks anchor a starting edge,
    // each subsequent click appends a pair of vertices forming one quad of
    // a strip — the user-placed vertex at the cursor plus an auto-corner
    // computed by the parallelogram rule (verified MODO behaviour: no, but
    // the most intuitive convention for ribbon-style strips, and the one
    // the docs imply by "polygon strips"). Only meaningful in `polygons`
    // mode.
    bool  makeQuads    = false;
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

    // 6.9.1 vertex-edit state. dragArmed = true between LMB-down on a
    // vertex and the matching LMB-up; flips dragInitiated once the cursor
    // moves more than DRAG_THRESHOLD_PX pixels (so a press-and-release on a
    // vertex *selects* it rather than moving anything).
    bool dragArmed;
    bool dragInitiated;
    int  dragVertIdx = -1;
    int  dragStartMX, dragStartMY;

    enum int DRAG_THRESHOLD_PX = 4;

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
            Param.int_("currentPoint", "Current Point", &params_.currentPoint, -1)
                .min(-1).max(1024),
            Param.float_("posX", "Position X", &params_.posX, 0.0f),
            Param.float_("posY", "Position Y", &params_.posY, 0.0f),
            Param.float_("posZ", "Position Z", &params_.posZ, 0.0f),
            Param.bool_("flip", "Flip Polygon", &params_.flip, false),
            Param.bool_("makeQuads", "Make Quads", &params_.makeQuads, false),
        ];
    }

    override bool paramEnabled(string name) const {
        if (name == "currentPoint" || name == "posX" || name == "posY" || name == "posZ")
            return state == PenState.Drawing && vertices_.length > 0;
        return true;
    }

    override void onParamChanged(string name) {
        // Numeric edit via the property panel — write back into the buffer
        // and re-render. The panel writes through the typed pointer first,
        // so params_.* already holds the new value when this fires.
        if (state != PenState.Drawing) return;

        if (name == "currentPoint") {
            // Clamp to a valid index range and refresh posX/Y/Z to mirror the
            // newly selected vertex. -1 is the legitimate "nothing current"
            // sentinel.
            int n = cast(int)vertices_.length;
            if (params_.currentPoint < -1) params_.currentPoint = -1;
            if (params_.currentPoint >= n) params_.currentPoint = n - 1;
            syncPosFromCurrent();
            return;
        }
        if (name == "posX" || name == "posY" || name == "posZ") {
            int idx = params_.currentPoint;
            if (idx < 0 || idx >= cast(int)vertices_.length) return;
            vertices_[idx] = Vec3(params_.posX, params_.posY, params_.posZ);
            uploadPreview();
            return;
        }
    }

    override void activate() {
        state = PenState.Idle;
        vertices_.length = 0;
        params_.currentPoint = -1;
        params_.posX = params_.posY = params_.posZ = 0.0f;
        dragArmed     = false;
        dragInitiated = false;
        dragVertIdx   = -1;
        previewGpu.init();
    }

    override void deactivate() {
        // If a valid sequence is pending, commit it on deactivate.
        if (state == PenState.Drawing && vertices_.length >= minCommitVerts()) {
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

        // Double-click semantics (vibe3d convention from doc/pen_plan.md):
        // every LMB-down adds a vertex, then on the SECOND click of a
        // double-click the polygon also commits if it now has ≥3 verts.
        // We can't rely on `clicks==2` to mean "no vertex added" — SDL may
        // auto-promote clicks=1 events that arrive within the double-click
        // window (default 500 ms) to clicks=2, which would silently swallow
        // rapid normal clicks. Instead the behaviour is "always add, also
        // commit on double-click".

        if (state == PenState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                   Vec3(0, 0, 0), planeNormal, hit))
                return true;
            appendVertex(hit);
            params_.currentPoint = cast(int)vertices_.length - 1;
            syncPosFromCurrent();
            state = PenState.Drawing;
            uploadPreview();
            armDragOnFresh(e.x, e.y);
            return true;
        }

        // 6.9.1: hit-test against existing in-progress vertices first. Press
        // on a vertex selects it as currentPoint and arms a potential drag —
        // the drag only "initiates" once the cursor moves > DRAG_THRESHOLD_PX
        // pixels (a release without motion just leaves the vertex selected).
        int hitIdx = findHoveredVert(e.x, e.y);
        if (hitIdx >= 0) {
            params_.currentPoint = hitIdx;
            syncPosFromCurrent();
            dragArmed     = true;
            dragInitiated = false;
            dragVertIdx   = hitIdx;
            dragStartMX   = e.x;
            dragStartMY   = e.y;
            return true;
        }

        // Click on empty plane.
        Vec3 hit;
        if (!rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                               Vec3(0, 0, 0), planeNormal, hit))
            return true;

        // Make Quads strip extension: after 2 anchor verts, each click adds
        // user (cursor) + auto (parallelogram extension). Skips the insert
        // path and the current-point preservation since strip ordering is
        // a positional sequence rather than a polygon's free boundary.
        if (params_.makeQuads && vertices_.length >= 2) {
            appendQuadStripPair(hit);
            // Current point follows the user-placed vertex (the second-to-
            // last in the buffer; the very-last is the auto-corner). Lets
            // the user's intent — placing a top-row vert at the cursor —
            // remain selectable for numeric edits.
            params_.currentPoint = cast(int)vertices_.length - 2;
            syncPosFromCurrent();
            uploadPreview();
            return true;
        }

        // Default polygon mode: append at end OR insert after currentPoint
        // (the doc's "to insert a vertex between two existing ones, highlight
        // a previously created vertex and click away from it").
        int n   = cast(int)vertices_.length;
        int cur = params_.currentPoint;
        if (cur >= 0 && cur < n - 1) {
            insertVertexAfter(cur, hit);
            params_.currentPoint = cur + 1;
        } else {
            appendVertex(hit);
            params_.currentPoint = cast(int)vertices_.length - 1;
        }
        syncPosFromCurrent();
        uploadPreview();
        armDragOnFresh(e.x, e.y);
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (!dragArmed) return false;

        if (!dragInitiated) {
            int dx = e.x - dragStartMX;
            int dy = e.y - dragStartMY;
            if (dx * dx + dy * dy < DRAG_THRESHOLD_PX * DRAG_THRESHOLD_PX)
                return true;     // still under threshold — consume but no-op
            dragInitiated = true;
        }

        // Relocate the dragged vertex to the cursor's projected plane hit.
        if (dragVertIdx < 0 || dragVertIdx >= cast(int)vertices_.length)
            return true;
        Vec3 hit;
        if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                              Vec3(0, 0, 0), planeNormal, hit))
        {
            vertices_[dragVertIdx] = hit;
            if (params_.currentPoint == dragVertIdx) syncPosFromCurrent();
            uploadPreview();
        }
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (!dragArmed) return false;
        scope(exit) {
            dragArmed     = false;
            dragInitiated = false;
            dragVertIdx   = -1;
        }

        if (!dragInitiated) {
            // Press-without-drag: vertex stays selected (currentPoint already
            // updated in onMouseButtonDown). Nothing more to do.
            return true;
        }

        // Drag completed — check if the dragged vertex was dropped onto
        // *another* in-progress vertex; if so, weld (drop the dragged one
        // from the boundary list, the target stays put).
        int target = findHoveredVertExcept(e.x, e.y, dragVertIdx);
        if (target >= 0) {
            weldVertex(dragVertIdx, target);
            // After weld, currentPoint should refer to the target (post-shift).
            int newCur = (target > dragVertIdx) ? (target - 1) : target;
            params_.currentPoint = newCur;
            syncPosFromCurrent();
            uploadPreview();
        }
        return true;
    }

    override bool onKeyDown(ref const SDL_KeyboardEvent e) {
        switch (e.keysym.sym) {
            case SDLK_RETURN:
            case SDLK_KP_ENTER:
                if (state == PenState.Drawing && vertices_.length >= minCommitVerts()) {
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

        // Filled face preview (shaded). Visible whenever the in-progress
        // sequence has enough vertices to form at least one face — ≥3 in
        // default polygon mode, ≥4 for the first quad in Make Quads. Faces
        // are rebuilt into previewMesh by uploadPreview.
        if (vertices_.length >= minCommitVerts()) {
            Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));
            glUseProgram(litShader.program);
            glUniformMatrix4fv(litShader.locModel, 1, GL_FALSE, identity.ptr);
            glUniformMatrix4fv(litShader.locView,  1, GL_FALSE, vp.view.ptr);
            glUniformMatrix4fv(litShader.locProj,  1, GL_FALSE, vp.proj.ptr);
            glUniform3f(litShader.locLightDir, lightDir.x, lightDir.y, lightDir.z);
            glUniform3f(litShader.locEyePos,   vp.eye.x, vp.eye.y, vp.eye.z);
            glUniform1f(litShader.locAmbient,  0.20f);
            glUniform1f(litShader.locSpecStr,  0.25f);
            glUniform1f(litShader.locSpecPow,  32.0f);
            previewGpu.drawFaces(litShader);
        }

        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);

        // Wireframe preview — shows the open polyline before the first
        // face is closed, and the boundary edges of the in-progress face(s)
        // afterwards (drawn on top of the lit fill).
        if (vertices_.length >= 2)
            previewGpu.drawEdges(shader.locColor, -1, []);

        // Vertex markers — three-state colour, by BoxHandler.draw precedence:
        //   hovered  → yellow (BoxHandler base, set by updateHover in draw)
        //   selected (not hovered) → orange — used for the current point
        //   default → cyan
        foreach (i, h; vertHandlers) {
            h.size     = gizmoSize(h.pos, vp, 0.04f);
            h.selected = (cast(int)i == params_.currentPoint);
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
        // Size is initialised here (not just in draw()) so the very next
        // hit-test inside the SAME event-processing pass sees a sensibly
        // sized hit volume — the BoxHandler default of 0.5 in world units
        // would otherwise project to most of the screen at typical camera
        // distances and cause spurious hover matches.
        auto h = new BoxHandler(pos, Vec3(0.0f, 0.9f, 0.9f));
        h.size = gizmoSize(pos, cachedVp, 0.04f);
        vertHandlers ~= h;
    }

    // 6.9.5: Make Quads — append the two vertices that complete the next
    // strip quad. The user-placed `cursorPos` becomes the new "top" vertex;
    // the auto-corner is computed by the parallelogram rule
    //
    //   newBottom = prevBottom + (cursorPos − prevTop)
    //
    // where prevTop / prevBottom are the LAST two vertices in the buffer
    // (the leading edge of the strip so far). After the call the buffer
    // grows by 2 and the new pair is the next leading edge.
    //
    // Caller must have already ensured vertices_.length >= 2 (the two
    // anchor clicks); for fewer than 2 verts the regular append path is
    // used so the strip can be seeded.
    void appendQuadStripPair(Vec3 cursorPos) {
        Vec3 prevTop = vertices_[$ - 2];
        Vec3 prevBot = vertices_[$ - 1];
        Vec3 newTop  = cursorPos;
        Vec3 newBot  = prevBot + (newTop - prevTop);
        appendVertex(newTop);
        appendVertex(newBot);
    }

    // Insert a new vertex (and matching handler) at position insertIdx in the
    // boundary list, shifting later elements right. Used by the "click-away
    // while a vertex is current" path to splice into the polygon.
    void insertVertexAfter(int afterIdx, Vec3 pos) {
        int insertIdx = afterIdx + 1;
        if (insertIdx < 0) insertIdx = 0;
        if (insertIdx > cast(int)vertices_.length) insertIdx = cast(int)vertices_.length;
        vertices_ = vertices_[0 .. insertIdx] ~ pos ~ vertices_[insertIdx .. $];
        auto h = new BoxHandler(pos, Vec3(0.0f, 0.9f, 0.9f));
        h.size = gizmoSize(pos, cachedVp, 0.04f);
        vertHandlers = vertHandlers[0 .. insertIdx] ~ h ~ vertHandlers[insertIdx .. $];
    }

    void popVertex() {
        if (vertices_.length == 0) return;
        vertices_.length -= 1;
        if (vertHandlers.length > 0) {
            vertHandlers[$ - 1].destroy();
            vertHandlers.length -= 1;
        }
        // currentPoint may now be out of range — clamp.
        int n = cast(int)vertices_.length;
        if (params_.currentPoint >= n) params_.currentPoint = n - 1;
        syncPosFromCurrent();
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
        params_.currentPoint = -1;
        params_.posX = params_.posY = params_.posZ = 0.0f;
    }

    // Mirror vertices_[currentPoint] into the params_.posX/Y/Z fields so the
    // property panel reflects the live vertex position. Called whenever
    // currentPoint changes or the buffered vertex is moved.
    void syncPosFromCurrent() {
        int idx = params_.currentPoint;
        if (idx < 0 || idx >= cast(int)vertices_.length) {
            params_.posX = params_.posY = params_.posZ = 0.0f;
            return;
        }
        Vec3 p = vertices_[idx];
        params_.posX = p.x;
        params_.posY = p.y;
        params_.posZ = p.z;
    }

    // Hit-test in-progress vertex markers; returns the index of the first
    // marker whose screen-space bounding cube contains (mx, my), or -1.
    // Arm a drag on the just-appended / just-inserted vertex (currentPoint)
    // so motion-while-LMB-held relocates it and LMB-up finalises (with
    // optional weld). Lets the user place a vertex with a single click-
    // and-drag motion — pure click (LMB-up without motion past
    // DRAG_THRESHOLD_PX) leaves the vertex at the click point unchanged.
    void armDragOnFresh(int mx, int my) {
        dragArmed     = true;
        dragInitiated = false;
        dragVertIdx   = params_.currentPoint;
        dragStartMX   = mx;
        dragStartMY   = my;
    }

    int findHoveredVert(int mx, int my) {
        foreach (i, h; vertHandlers) {
            if (h.hitTest(mx, my, cachedVp)) return cast(int)i;
        }
        return -1;
    }

    int findHoveredVertExcept(int mx, int my, int exclude) {
        foreach (i, h; vertHandlers) {
            if (cast(int)i == exclude) continue;
            if (h.hitTest(mx, my, cachedVp)) return cast(int)i;
        }
        return -1;
    }

    // Weld the dragged vertex (dragIdx) onto target. The dragged vertex
    // drops out of the boundary list entirely; the target's position stays
    // put (the user might have positioned it earlier and the weld shouldn't
    // teleport it). Boundary indices after dragIdx shift left by one.
    void weldVertex(int dragIdx, int targetIdx) {
        if (dragIdx < 0 || dragIdx >= cast(int)vertices_.length) return;
        if (targetIdx == dragIdx) return;
        vertHandlers[dragIdx].destroy();
        vertices_    = vertices_[0 .. dragIdx]    ~ vertices_[dragIdx + 1 .. $];
        vertHandlers = vertHandlers[0 .. dragIdx] ~ vertHandlers[dragIdx + 1 .. $];
    }

    void uploadPreview() {
        previewMesh.clear();
        foreach (v; vertices_) previewMesh.addVertex(v);

        // Filled face preview. Mirrors commitPolygon's index pattern so the
        // shape the user sees while drawing matches what they get on Enter.
        // flip is intentionally NOT applied here — the preview always shows
        // the un-flipped winding so the face stays visible from the user's
        // viewing angle. (Backface culling on a flipped preview would hide
        // the entire shape.)
        if (vertices_.length >= minCommitVerts()) {
            if (params_.makeQuads) {
                int N = cast(int)(vertices_.length / 2 * 2);
                int nQuads = (N - 2) / 2;
                foreach (k; 0 .. nQuads) {
                    uint a = cast(uint)(2 * k);
                    uint b = cast(uint)(2 * k + 2);
                    uint c = cast(uint)(2 * k + 3);
                    uint d = cast(uint)(2 * k + 1);
                    previewMesh.addFace([a, b, c, d]);
                }
            } else {
                uint[] face;
                face.length = vertices_.length;
                foreach (i, _; vertices_) face[i] = cast(uint)i;
                previewMesh.addFace(face);
            }
        } else if (vertices_.length >= 2) {
            // Pre-face: open polyline only (no faces yet, so addFace would
            // form none — register edges directly so the wireframe pass can
            // render them).
            foreach (i; 0 .. cast(int)vertices_.length - 1)
                previewMesh.addEdge(cast(uint)i, cast(uint)(i + 1));
        }

        previewGpu.upload(previewMesh);
        // Keep marker positions in sync (vertices_ may have been mutated by
        // popVertex / future numeric edits).
        foreach (i, ref h; vertHandlers) h.pos = vertices_[i];
    }

    // Minimum vertex count for a commit. Default polygon mode needs ≥3
    // (a triangle); Make Quads needs ≥4 (one full quad in the strip; the
    // first two anchor verts alone don't yet form a face).
    size_t minCommitVerts() const {
        return params_.makeQuads ? 4 : 3;
    }

    void commitPolygonWithUndo() {
        if (state != PenState.Drawing || vertices_.length < minCommitVerts()) return;
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
        params_.currentPoint = -1;
        params_.posX = params_.posY = params_.posZ = 0.0f;
        meshChanged = true;
    }

    void commitPolygon() {
        uint base = cast(uint)mesh.vertices.length;
        foreach (v; vertices_) mesh.addVertex(v);

        if (params_.makeQuads) {
            // Strip: vertices laid out [v0_top, v1_bot, v2_top, v3_bot, ...].
            // Quad k uses indices [2k, 2k+2, 2k+3, 2k+1] — top→top→bot→bot
            // forms a CCW boundary that yields the same outward normal as
            // the regular polygon mode would for the corresponding edge
            // sequence. flip swaps to [2k+1, 2k+3, 2k+2, 2k]. Round the
            // vertex count down to even since an odd buffer leaves a half-
            // quad that can't be closed.
            int N = cast(int)(vertices_.length / 2 * 2);
            int nQuads = (N - 2) / 2;
            foreach (k; 0 .. nQuads) {
                uint a = base + cast(uint)(2 * k);
                uint b = base + cast(uint)(2 * k + 2);
                uint c = base + cast(uint)(2 * k + 3);
                uint d = base + cast(uint)(2 * k + 1);
                if (params_.flip) mesh.addFace([d, c, b, a]);
                else              mesh.addFace([a, b, c, d]);
            }
        } else {
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
        }

        mesh.buildLoops();
        gpu.upload(*mesh);
    }
}
