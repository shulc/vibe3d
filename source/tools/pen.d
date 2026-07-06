module tools.pen;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;

import tool;
import mesh;
import math;
import params : Param;
import handler : BoxHandler, gizmoSize, ToolHandles;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;
import tools.create_common : pickWorkplane, BuildPlane,
                              pickWorkplaneFrame, WorkplaneFrame,
                              mostFacingAxis,
                              transformPoint, transformDir, snapLocalHit,
                              currentSnapPacket;
import toolpipe.packets : SnapType;
import editmode : EditMode;
import snap : SnapResult;
import snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;

import std.math : abs;

// Snap-type bits that PenTool handles via applyPenGuide (Pen-local guide
// constraints). These bits are excluded from snapLocalHit at all Pen call
// sites so the shared snap pipeline never applies the transform-scoped
// WorldAxis-through-origin on top of the Pen-scoped prior-vertex variants.
private enum uint guideBits =
    SnapType.WorldAxis | SnapType.StraightLine | SnapType.RightAngle;

alias PenEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// PenParams — vibe3d's pen tool wire schema.
//
// Schema follows conventional pen-tool panel option names.
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
    // computed by the parallelogram rule (the most intuitive convention
    // for ribbon-style strips, and the one
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
// In-progress vertex markers render in cyan (Vec3(0, 0.9, 0.9)); the central
// ToolHandles arbiter (Test pass) flips the single cursor-over vertex to
// yellow ("they'll turn yellow when the mouse is directly over them").
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
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
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
    Vec3[]           vertices_;     // LOCAL workplane positions of the in-progress sequence
    BoxHandler[]     vertHandlers;  // one cyan marker per in-progress vertex (handler.pos in WORLD)
    ToolHandles      toolHandles;   // single-source hover arbiter (Test pass)

    Mesh             previewMesh;
    GpuMesh          previewGpu;

    // After workplane refactor — LOCAL canonical axes; world basis is in
    // `frame`.
    Vec3 planeNormal;
    Vec3 planeAxis1;
    Vec3 planeAxis2;
    /// Workplane local↔world transform captured at choosePlane(). All
    /// in-progress vertices live in this frame's local space.
    WorkplaneFrame frame;

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

    // Last snap query — drives the cyan/yellow overlay. Refreshed on
    // every motion event when the cursor is over the construction
    // plane; consumed by clicks (which snap the placed vertex to the
    // target's world position).
    SnapResult lastSnap;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_ = meshSrc;
        this.gpu       = gpu;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
        toolHandles    = new ToolHandles();
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
            // currentPoint/posX/Y/Z: per-gesture point-edit proxies
            // (onParamChanged mutates vertices_[currentPoint] while
            // Drawing) — not a remembered setting. Excluded from
            // sticky-tool-defaults capture via .transient().
            Param.int_("currentPoint", "Current Point", &params_.currentPoint, -1)
                .min(-1).max(1024).transient(),
            Param.float_("posX", "Position X", &params_.posX, 0.0f).transient(),
            Param.float_("posY", "Position Y", &params_.posY, 0.0f).transient(),
            Param.float_("posZ", "Position Z", &params_.posZ, 0.0f).transient(),
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

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
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
            if (!rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                   Vec3(0, 0, 0), planeNormal, hit))
                return true;
            // Snap the click position to the closest pipeline-enabled
            // snap target (vertex / edge / face / grid). guideBits are
            // excluded from snapLocalHit so the transform-scoped
            // WorldAxis-through-origin never fires here. applyPenGuide
            // is a no-op on the first click (vertices_ is empty), but
            // the guideBits mask is still needed to prevent double-apply
            // in future calls before the first vertex is appended.
            lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                    *mesh, EditMode.Vertices, [], guideBits);
            if (!(lastSnap.snapped && lastSnap.constraintType == SnapType.None))
                applyPenGuide(hit, e.x, e.y);
            publishLastSnap(lastSnap);
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
        if (!rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                               Vec3(0, 0, 0), planeNormal, hit))
            return true;

        // Snap the placed vertex: discrete targets first (guideBits excluded
        // from snapLocalHit); then Pen guide if no discrete snap won.
        // Merge rule: discrete > guide > free. Box face-planes from snap.d
        // survive snapLocalHit (not in guideBits) but lose to the guide when
        // constraintType != None — a deliberate discrete>guide>free choice.
        lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                *mesh, EditMode.Vertices, [], guideBits);
        if (!(lastSnap.snapped && lastSnap.constraintType == SnapType.None))
            applyPenGuide(hit, e.x, e.y);
        publishLastSnap(lastSnap);

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

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        // Live snap preview — runs whenever a click would place / move
        // a vertex, so the user sees the cyan target before committing.
        // Skipped only when the user is hovering an existing in-progress
        // vertex (next click selects it, doesn't place a new one).
        bool overExisting = state == PenState.Drawing
                            && findHoveredVert(e.x, e.y) >= 0;
        if (!overExisting) {
            // Frame is captured at first click; before that we still
            // need one to convert local↔world. pickWorkplaneFrame gives
            // the live frame the first click would lock onto.
            WorkplaneFrame f = state == PenState.Drawing
                ? frame
                : pickWorkplaneFrame(cachedVp);
            // Local plane normal varies per state too. choosePlane() in
            // PenTool uses the camera-most-facing axis of the LIVE frame,
            // which collapses to (0,1,0) in identity-frame auto-mode.
            Vec3 pn = state == PenState.Drawing ? planeNormal : Vec3(0, 1, 0);
            Vec3 lEye = transformPoint(f.toLocal, cachedVp.eye);
            Vec3 lRay = transformDir  (f.toLocal, screenRay(e.x, e.y, cachedVp));
            Vec3 hit;
            if (rayPlaneIntersect(lEye, lRay, Vec3(0, 0, 0), pn, hit)) {
                lastSnap = snapLocalHit(hit, f, e.x, e.y, cachedVp,
                                         *mesh, EditMode.Vertices, [], guideBits);
                // Guide follows same discrete>guide merge rule. When Drawing,
                // f==frame so applyPenGuide uses the same coordinate basis.
                // Idle: applyPenGuide returns false (vertices_ empty) — no-op.
                if (!(lastSnap.snapped && lastSnap.constraintType == SnapType.None))
                    applyPenGuide(hit, e.x, e.y);
                publishLastSnap(lastSnap);
            } else {
                lastSnap = SnapResult.init;
                clearLastSnap();
            }
        } else {
            lastSnap = SnapResult.init;
            clearLastSnap();
        }

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
        if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                              Vec3(0, 0, 0), planeNormal, hit))
        {
            // Snap the dragged vertex's new position — same discrete>guide
            // merge rule as the click paths. guideBits excluded from
            // snapLocalHit; applyPenGuide applied when no discrete snap won.
            lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                    *mesh, EditMode.Vertices, [], guideBits);
            if (!(lastSnap.snapped && lastSnap.constraintType == SnapType.None))
                applyPenGuide(hit, e.x, e.y);
            publishLastSnap(lastSnap);
            vertices_[dragVertIdx] = hit;
            if (params_.currentPoint == dragVertIdx) syncPosFromCurrent();
            uploadPreview();
        }
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
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

    override bool onKeyDown(ref const SDL_KeyboardEvent e, ref VectorStack vts) {
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

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        // Snap overlay (cyan element + yellow cursor marker) renders
        // even in Idle so the user sees where the FIRST vertex would
        // land if they clicked. Populated by onMouseMotion.
        drawSnapOverlay(lastSnap, vp, *mesh);
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

        // Vertex markers — three-state colour, by BoxHandler.draw precedence
        // from the arbiter-assigned HandleState:
        //   Rollover  → yellow (single hot part, set by ToolHandles.update)
        //   selected (not hot) → orange — used for the current point
        //   default → cyan
        // Single-source hover (Test pass): register every vertex
        // marker, resolve ONE hot part so overlapping markers can't both
        // highlight. A live vertex drag (dragArmed) keeps its marker hot.
        toolHandles.begin();
        foreach (i, h; vertHandlers) {
            h.size = gizmoSize(h.pos, vp, 0.04f);
            toolHandles.add(h, cast(int)i);
        }
        toolHandles.setHaul(dragArmed ? dragVertIdx : -1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);
        foreach (i, h; vertHandlers) {
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
        frame = pickWorkplaneFrame(vp);
        Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
        final switch (mostFacingAxis(camBack, frame.axis1, frame.normal, frame.axis2)) {
            case 0:
                planeNormal = Vec3(1, 0, 0);
                planeAxis1  = Vec3(0, 1, 0);
                planeAxis2  = Vec3(0, 0, 1);
                break;
            case 1:
                planeNormal = Vec3(0, 1, 0);
                planeAxis1  = Vec3(1, 0, 0);
                planeAxis2  = Vec3(0, 0, 1);
                break;
            case 2:
                planeNormal = Vec3(0, 0, 1);
                planeAxis1  = Vec3(1, 0, 0);
                planeAxis2  = Vec3(0, 1, 0);
                break;
        }
    }

    // ---- Local ↔ world helpers (workplane refactor) ---------------------
    Vec3 localEye() const { return transformPoint(frame.toLocal, cachedVp.eye); }
    Vec3 localRay(int x, int y) const {
        return transformDir(frame.toLocal, screenRay(x, y, cachedVp));
    }
    Vec3 toWorldP(Vec3 p) const { return transformPoint(frame.toWorld, p); }
    Vec3 toLocalP(Vec3 p) const { return transformPoint(frame.toLocal, p); }

    void appendVertex(Vec3 pos) {
        // pos is in LOCAL workplane coords; the vertex handler renders in
        // world, so hit-testing needs the world image of `pos`.
        vertices_ ~= pos;
        Vec3 worldPos = toWorldP(pos);
        auto h = new BoxHandler(worldPos, Vec3(0.0f, 0.9f, 0.9f));
        h.size = gizmoSize(worldPos, cachedVp, 0.04f);
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
        // pos in LOCAL; handler in WORLD.
        int insertIdx = afterIdx + 1;
        if (insertIdx < 0) insertIdx = 0;
        if (insertIdx > cast(int)vertices_.length) insertIdx = cast(int)vertices_.length;
        vertices_ = vertices_[0 .. insertIdx] ~ pos ~ vertices_[insertIdx .. $];
        Vec3 worldPos = toWorldP(pos);
        auto h = new BoxHandler(worldPos, Vec3(0.0f, 0.9f, 0.9f));
        h.size = gizmoSize(worldPos, cachedVp, 0.04f);
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

    // ----- History-coordination hooks (undo/redo migration P0) -------------
    // Commit guard mirror (deactivate() :225): a pending polygon commits only
    // while Drawing with enough verts to close (>= minCommitVerts). A short
    // in-progress stroke would be discarded, not committed, so it reports false.
    public override bool hasUncommittedEdit() const {
        return state == PenState.Drawing && vertices_.length >= minCommitVerts();
    }
    // Cancel: drop the in-progress sequence (cancelPolygon resets state + clears
    // the preview / vert handlers, records nothing).
    public override void cancelUncommittedEdit() { cancelPolygon(); }

    // resyncSession() (undo/redo P1) is intentionally a JUSTIFIED NO-OP here:
    // PenTool caches no scene-mesh baseline. Its only session state is the
    // in-progress `vertices_` buffer, which holds LOCAL workplane positions
    // (world coords, not mesh vertex/edge indices). A committed undo/redo that
    // moves geometry beneath the active tool changes neither those world points
    // nor anything Pen would re-derive from the mesh, so the default base no-op
    // leaves the tool coherent for the next click. No override needed.

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
        // Drop the snap overlay so it doesn't linger.
        lastSnap = SnapResult.init;
        clearLastSnap();
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
        // vertices_ are in LOCAL; transform each through frame.toWorld so
        // the preview renders in world position.
        foreach (v; vertices_) previewMesh.addVertex(toWorldP(v));

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
        // popVertex / future numeric edits). Handlers render in WORLD.
        foreach (i, ref h; vertHandlers) h.pos = toWorldP(vertices_[i]);
    }

    // Minimum vertex count for a commit. Default polygon mode needs ≥3
    // (a triangle); Make Quads needs ≥4 (one full quad in the strip; the
    // first two anchor verts alone don't yet form a face).
    size_t minCommitVerts() const {
        return params_.makeQuads ? 4 : 3;
    }

    // Apply Pen-local guide constraints: straightLine / worldAxis / rightAngle.
    //
    // Anchor = prior vertex (vertices_[$-1]), direction from the prior segment
    // for straightLine/rightAngle, world X/Y/Z through the prior vertex for
    // worldAxis (Pen-scoped, differs from snap.d's origin-based WorldAxis).
    //
    // All arithmetic in LOCAL workplane coordinates. Candidates are projected
    // to screen pixels to gate against cfg.innerRangePx. The nearest in-range
    // candidate wins; ties between guide types resolved by screen distance.
    //
    // Returns true and writes hitLocal to the guide point when a candidate is
    // within tolerance; returns false (hitLocal unchanged) otherwise.
    // Stateless beyond vertices_ / frame / cachedVp — no new persistent fields.
    private bool applyPenGuide(ref Vec3 hitLocal, int sx, int sy) {
        if (vertices_.length < 1) return false;

        auto cfg = currentSnapPacket(*mesh, EditMode.Vertices, cachedVp);
        if (!cfg.enabled) return false;

        Vec3  anchorL  = vertices_[$-1];
        float bestDist = cfg.innerRangePx;
        bool  found    = false;
        Vec3  bestP;

        // Project a LOCAL candidate point to screen; return pixel distance to
        // (sx,sy). Returns float.infinity for behind-camera points.
        float screenDist(Vec3 pL) {
            Vec3  pW = toWorldP(pL);
            float px_, py_, ndcZ;
            if (!projectToWindowFull(pW, cachedVp, px_, py_, ndcZ))
                return float.infinity;
            float dx = px_ - cast(float)sx;
            float dy = py_ - cast(float)sy;
            return Vec3(dx, dy, 0).length;   // Vec3.length uses std.math.sqrt
        }

        void consider(Vec3 candL) {
            float d = screenDist(candL);
            if (d < bestDist) { bestDist = d; bestP = candL; found = true; }
        }

        // Segment direction in LOCAL (shared by straightLine + rightAngle).
        // Computed only when needed and guarded against degenerate segments
        // (nit 1: normalize has no zero-guard, a zero-length segment poisons
        // both candidate directions via NaN).
        Vec3 segL;
        bool segValid = false;
        if ((cfg.enabledTypes & (SnapType.StraightLine | SnapType.RightAngle))
                && vertices_.length >= 2)
        {
            Vec3 segVec = vertices_[$-1] - vertices_[$-2];
            if (segVec.length > 1e-6f) {
                segL     = normalize(segVec);
                segValid = true;
            }
        }

        // straightLine: lock new point to the infinite extension of the prior
        // segment (anchor = prior vertex, dir = prior-segment direction).
        // Requires ≥2 prior vertices.
        if ((cfg.enabledTypes & SnapType.StraightLine) && segValid)
            consider(closestPointOnLineToRay(anchorL, segL,
                                              localEye(), localRay(sx, sy)));

        // worldAxis (Pen-scoped): X/Y/Z axes through the PRIOR vertex.
        // Requires only ≥1 prior vertex (anchorL already set).
        // The in-plane filter drops any world axis nearly parallel to the
        // construction-plane normal (planeNormal, in LOCAL frame coords):
        // snapping to it would move the vertex off the plane, which is never
        // useful in Pen mode.  planeNormal is (1,0,0)/(0,1,0)/(0,0,1) in
        // local space depending on which frame axis choosePlane found most
        // face-on to the camera — it is NOT always local-Y.
        if (cfg.enabledTypes & SnapType.WorldAxis) {
            immutable Vec3[3] worldAxes = [Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1)];
            foreach (ax; worldAxes) {
                Vec3 axL = transformDir(frame.toLocal, ax);
                if (abs(dot(axL, planeNormal)) > 0.9f) continue;   // skip the plane-normal axis
                consider(closestPointOnLineToRay(anchorL, axL,
                                                  localEye(), localRay(sx, sy)));
            }
        }

        // rightAngle: perpendicular to the prior segment, in the construction
        // plane. Direction = cross(planeNormal, segL) — both in LOCAL, result
        // also in LOCAL. A single infinite LINE covers both ±90° senses.
        // Requires ≥2 prior vertices.
        if ((cfg.enabledTypes & SnapType.RightAngle) && segValid) {
            Vec3 perpL = cross(planeNormal, segL);
            if (perpL.length > 1e-6f) {
                perpL = normalize(perpL);
                consider(closestPointOnLineToRay(anchorL, perpL,
                                                  localEye(), localRay(sx, sy)));
            }
        }

        if (found) { hitLocal = bestP; return true; }
        return false;
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
        refreshDisplay(mesh, gpu, vc, ec, fc);
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
        // Append committed vertices in WORLD; vertices_ are stored in
        // LOCAL workplane coords for the duration of the in-progress
        // session, so transform through frame.toWorld at commit.
        foreach (v; vertices_) mesh.addVertex(toWorldP(v));

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

// Pure guide-geometry unit tests — no HTTP harness, no app loop.
// Covers the core math used by applyPenGuide so dub test catches regressions
// independently of the interactive test suite.
unittest {
    import tools.create_common : transformDir, frameFromBasis;

    // Helper: verify two floats agree to < 1e-5.
    static bool near(float a, float b) { return abs(a - b) < 1e-5f; }

    // --- straightLine candidate ---
    // Closest point on infinite line (anchor=(0.2,0,0), dir=(1,0,0)) to a
    // vertical ray at x=0.7, y=1, z=0 pointing straight down.
    // Expected: (0.7, 0, 0).
    {
        import math : closestPointOnLineToRay;
        Vec3 anchor = Vec3(0.2f, 0, 0);
        Vec3 dir    = Vec3(1, 0, 0);
        Vec3 p = closestPointOnLineToRay(anchor, dir,
                                         Vec3(0.7f, 1, 0), Vec3(0, -1, 0));
        assert(near(p.x, 0.7f) && near(p.y, 0) && near(p.z, 0));
    }

    // --- rightAngle direction: cross(planeNormal, segL) ---
    // planeNormal = (0,1,0), segL = (1,0,0) → perp = (0,0,-1).
    // Verify perp ⊥ segL AND perp ⊥ planeNormal (stays in-plane).
    {
        Vec3 pn   = Vec3(0, 1, 0);
        Vec3 segL = Vec3(1, 0, 0);
        Vec3 perp = cross(pn, segL);
        assert(perp.length > 1e-6f);                      // non-degenerate
        Vec3 perpN = normalize(perp);
        assert(abs(dot(perpN, segL)) < 1e-6f);            // ⊥ segment
        assert(abs(dot(perpN, pn))   < 1e-6f);            // stays in-plane
        assert(near(perpN.x, 0) && near(perpN.z, -1.0f)); // specific direction
    }

    // --- worldAxis in-plane filter (aN case: planeNormal = local-Y) ---
    // For the Z-workplane frame (normal=+Z, axis1=+X, axis2=+Y, origin=0):
    // world +X and +Y land in the plane (local y≈0), world +Z maps to the
    // plane normal (local y=1) and should be skipped.
    // choosePlane gives planeNormal=(0,1,0) when aN wins (camBack ≈ frame.normal).
    {
        auto f = frameFromBasis(Vec3(0,0,1), Vec3(1,0,0), Vec3(0,1,0),
                                Vec3(0,0,0));
        Vec3 pn  = Vec3(0,1,0); // planeNormal in local coords (aN case)
        Vec3 axX = transformDir(f.toLocal, Vec3(1,0,0)); // world +X
        Vec3 axY = transformDir(f.toLocal, Vec3(0,1,0)); // world +Y
        Vec3 axZ = transformDir(f.toLocal, Vec3(0,0,1)); // world +Z (plane normal)
        assert(abs(dot(axX, pn)) < 0.1f);  // in-plane — should NOT be filtered
        assert(abs(dot(axY, pn)) < 0.1f);  // in-plane — should NOT be filtered
        assert(abs(dot(axZ, pn)) > 0.9f);  // plane-normal — SHOULD be filtered
    }

    // --- worldAxis in-plane filter: non-Y planeNormal (view-dependent regression) ---
    // Default Y-up frame (normal=Y, axis1=X, axis2=Z) has identity toLocal,
    // so axL == ax for every world axis.  choosePlane sets planeNormal=(0,0,1)
    // in local space when aZ wins — i.e. when camBack is most aligned with
    // frame.axis2 (world Z in the default frame).  In that case:
    //   construction plane  = XY plane (normal = world Z = local (0,0,1))
    //   in-plane axes       = world X (local (1,0,0)) and world Y (local (0,1,0))
    //   plane-normal axis   = world Z (local (0,0,1))   ← must be filtered
    //
    // OLD code abs(axL.y) — wrong for this case:
    //   world Z → axL=(0,0,1) → abs(axL.y)=0 → NOT filtered  ← misses the normal
    //   world Y → axL=(0,1,0) → abs(axL.y)=1 → filtered       ← drops in-plane axis
    //
    // NEW code abs(dot(axL, planeNormal)):
    //   world X → dot((1,0,0),(0,0,1))=0 → NOT filtered ✓
    //   world Y → dot((0,1,0),(0,0,1))=0 → NOT filtered ✓
    //   world Z → dot((0,0,1),(0,0,1))=1 → filtered     ✓
    {
        auto f  = frameFromBasis(Vec3(0,1,0), Vec3(1,0,0), Vec3(0,0,1), Vec3(0,0,0));
        Vec3 pn = Vec3(0,0,1); // planeNormal in local coords (aZ case, world Z is normal)

        immutable Vec3[3] worldAxes = [Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1)];
        // world Z (index 2) is the plane normal and must be filtered; X and Y must not.
        foreach (size_t i, ax; worldAxes) {
            Vec3 axL     = transformDir(f.toLocal, ax);
            bool newPass = abs(dot(axL, pn)) > 0.9f;
            assert(newPass == (i == 2),
                   "worldAxis non-Y planeNormal: wrong filter result for axis index " ~
                   cast(char)('0' + i));
        }
        // Red→green witness: confirm old abs(axL.y) was wrong.
        Vec3 axZL = transformDir(f.toLocal, Vec3(0,0,1)); // world Z, the plane normal
        Vec3 axYL = transformDir(f.toLocal, Vec3(0,1,0)); // world Y, an in-plane axis
        // Old code: abs(axZL.y)=0 → did NOT filter world Z (missed the plane normal).
        assert(abs(axZL.y) < 0.1f,
               "RED witness: old abs(axL.y) must fail to filter world-Z plane-normal");
        // Old code: abs(axYL.y)=1 → DID filter world Y (wrongly dropped in-plane axis).
        assert(abs(axYL.y) > 0.9f,
               "RED witness: old abs(axL.y) must wrongly filter in-plane world-Y axis");
    }

    // --- degenerate segment guard ---
    // Two coincident prior vertices produce a zero-length segVec. Guard:
    // segVec.length < 1e-6f, so normalize is never called (would yield NaN).
    {
        Vec3 v0 = Vec3(1, 0, 0);
        Vec3 v1 = Vec3(1, 0, 0);  // same as v0
        Vec3 segVec = v1 - v0;
        assert(segVec.length < 1e-6f);  // guard triggers: guide inert
    }
}
