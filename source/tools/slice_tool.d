module tools.slice_tool;

import bindbc.sdl;
import bindbc.opengl;
import std.json : JSONValue;
import std.math : sqrt;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import operator : VectorStack;
import display_sync : refreshDisplay;
import eventlog : queryMouse;
import handler : BoxHandler, ToolHandles, gizmoSize, drawWorldSegment;
import tools.create_common : currentWorkplaneFrame, pickWorkplaneFrame, WorkplaneFrame;

// The interactive Slice commit reuses the generic before/after snapshot edit
// command (the same MeshBevelEdit the mirror / tack / primitive tools reuse for
// their one-shot snapshot undo), labelled "Slice".
alias SliceEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// sliceFromBaseline — the shared cut kernel wrapper (the single point that
// turns a Start→End line into a plane cut). RESTORES `baseline` onto `mesh`
// FIRST, then cuts with the plane through the line perpendicular to
// `wpNormal`, returning the number of faces split (0 = the line missed every
// face). The mandatory restore is what makes the live preview NON-CUMULATIVE:
// dragging the line through many positions never stacks cut upon cut — every
// call reproduces exactly the single cut that the final line would make from
// the pristine pre-gesture mesh. The interactive preview (onMouseMotion), the
// commit (onMouseButtonUp), and the `fast`-deferred commit all funnel through
// here, so they can never diverge in result. Pure data (no GPU / GL) so it is
// unit-testable under `dub test`.
size_t sliceFromBaseline(ref Mesh mesh, const ref MeshSnapshot baseline,
                         Vec3 start, Vec3 end, Vec3 wpNormal)
{
    if (baseline.filled) baseline.restore(mesh);
    Vec3 p, n;
    if (!planeFromLineAndWorkplane(start, end, wpNormal, p, n))
        return 0;
    return mesh.cutByPlane(p, n);
}

// ---------------------------------------------------------------------------
// SliceTool — interactive plane/line slice (factory id `mesh.sliceTool`).
//
// Draws a Start→End line and cuts the mesh with the plane through that line
// that is PERPENDICULAR TO THE WORK PLANE (owner decision — see
// math.planeFromLineAndWorkplane). This is deliberately NOT the camera-eye
// plane that the one-shot `mesh.screenSlice` command builds
// (source/commands/mesh/screen_slice.d, untouched): a horizontal drag in a
// front view makes a clean axis-aligned cut regardless of camera pitch. The
// cut itself reuses the existing `Mesh.cutByPlane` kernel (index-shared
// crossing verts, chord-split faces, all-quad on a cube — 8v/6f → 12v/10f for
// a mid-plane cut); this tool does not reimplement it.
//
// S1 scope (this class), on top of S0's activation + line-draw + plane + cut
// + one-`MeshSnapshot`-per-commit undo + `applyHeadless()`:
//   • DRAW: the Start→End line + two draggable endpoint handles (BoxHandler),
//     rendered through the shared gizmo palette + hover arbiter (ToolHandles).
//   • GESTURES: drag an endpoint to move it; drag the line body to translate
//     the whole line; middle-click to relocate the line to the cursor;
//     Shift+drag to reset/redraw a fresh line; RMB to cancel a gesture.
//   • LIVE PREVIEW: while dragging, the resulting cut is previewed on the real
//     mesh WITHOUT committing — non-cumulative (each update restores the
//     pre-gesture baseline then re-cuts, via `sliceFromBaseline`), mirroring
//     LoopSliceTool's mutate/revert armed preview. Commit happens on drop.
//   • `fast` (bool, default off): the preview gate. OFF ⇒ the cut recomputes
//     live on every motion. ON ⇒ the cut is DEFERRED to mouse-up (only the
//     line/handles move during the drag — no live cut on dense meshes). Both
//     paths commit the identical final geometry (`sliceFromBaseline` is the
//     one commit kernel).
//
// Deferred to later tasks: post-tool selection (S2), axis/vector (S3),
// infinite (S4), angle snap (S5), split/caps/gap reusing the Loop Slice
// machinery (S7–S9). NONE of those options are implemented here. Params:
// `startX/Y/Z`, `endX/Y/Z`, `fast`.
//
// Undo model: `before_` is captured at gesture start (the pre-cut baseline).
// The live preview mutates the mesh but always reverts to `before_` before the
// next update and before the commit, so the commit is a single clean cut and
// records ONE MeshBevelEdit(before, after) history entry per committed slice.
// A gesture that touches no face reverts to baseline and records nothing.
// ---------------------------------------------------------------------------
final class SliceTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory   history;
    SliceEditFactory factory;

    // The slice line, in world space. Bound to the startX..endZ params. The
    // defaults are neutral round numbers (a unit line on X through the origin);
    // headless tests always set them explicitly, so the exact idle defaults are
    // not load-bearing.
    Vec3 start_ = Vec3(-1, 0, 0);
    Vec3 end_   = Vec3( 1, 0, 0);

    // Fast Slice (S6, introduced here as the preview gate): OFF ⇒ recompute the
    // cut live during the drag; ON ⇒ defer the cut to mouse-up. Sticky param
    // (not reset on activate) — matches the reference's sticky tool options.
    bool fast_ = false;

    // Which part of the gizmo this gesture drags.
    enum DragNone  = -1;
    enum DragStart = 0;    // the Start endpoint handle
    enum DragEnd   = 1;    // the End endpoint handle
    enum DragLine  = 2;    // the whole line body (translate)

    // Session state.
    bool     active;
    int      dragPart_ = DragNone;
    bool     previewLive_;       // a preview cut currently sits on the mesh
    MeshSnapshot before_;        // pre-cut baseline captured at gesture start
    bool     haveBefore_;
    Viewport cachedVp;

    // Line-body translate bookkeeping: the endpoints + the work-plane anchor at
    // the moment the drag began, so motion translates by (hit - anchor).
    Vec3 dragStart0_, dragEnd0_, dragAnchor_;

    // Endpoint handle visuals (lazily built inside a live GL context, since
    // BoxHandler uploads a VAO). Purely for drawing + hover highlight; the
    // actual grab hit-test is the projection-based `pickHandle` (no GL needed,
    // so the event path works even before the first draw).
    BoxHandler  startH_, endH_;
    ToolHandles toolHandles_;

    // Screen-pixel radius within which a click grabs an endpoint handle, and
    // the band within which a click on the line body grabs the whole line.
    enum float HANDLE_PICK_PX = 14.0f;
    enum float LINE_PICK_PX   = 8.0f;

    // Gizmo palette (codebase handle colours — NOT reference colours): endpoint
    // handles in the blue used by Create-tool handles, the line in a light
    // neutral. Rollover/selected tints come from handler.handleStateColor.
    enum Vec3 HANDLE_COLOR = Vec3(0.30f, 0.60f, 1.00f);
    enum Vec3 LINE_COLOR   = Vec3(0.90f, 0.92f, 0.98f);

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
    }

    void setUndoBindings(CommandHistory h, SliceEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Slice"; }

    // A mesh op — offered in every geometry mode (like the screen/axis slice
    // commands, which are mode-agnostic).
    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    override Param[] params() {
        return [
            Param.float_("startX", "Start X", &start_.x, -1.0f),
            Param.float_("startY", "Start Y", &start_.y,  0.0f),
            Param.float_("startZ", "Start Z", &start_.z,  0.0f),
            Param.float_("endX",   "End X",   &end_.x,    1.0f),
            Param.float_("endY",   "End Y",   &end_.y,    0.0f),
            Param.float_("endZ",   "End Z",   &end_.z,    0.0f),
            Param.bool_( "fast",   "Fast Slice", &fast_,  false),
        ];
    }

    // Test-introspection (GET /api/tool/state): echo the line + `fast` + a
    // neutral tool tag so a headless test can assert the driven start/end and
    // preview gate without a screenshot. Mirrors LoopSliceTool.toolStateJson
    // (data, not pixels).
    override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]   = JSONValue("slice");
        root["startX"] = JSONValue(start_.x);
        root["startY"] = JSONValue(start_.y);
        root["startZ"] = JSONValue(start_.z);
        root["endX"]   = JSONValue(end_.x);
        root["endY"]   = JSONValue(end_.y);
        root["endZ"]   = JSONValue(end_.z);
        root["fast"]   = JSONValue(fast_);
        return root;
    }

    override void activate()   { active = true;  resetSession(); }
    override void deactivate() {
        // Drop any uncommitted live preview back to the baseline on tool-drop
        // (a gesture is normally down..up within a frame window, so this is
        // defence-in-depth for an interrupted drag).
        if (active && previewLive_ && before_.filled) {
            before_.restore(*mesh);
            refreshDisplay(mesh, gpu, vc, ec, fc);
        }
        active = false;
        resetSession();
    }

    private void resetSession() {
        dragPart_    = DragNone;
        previewLive_ = false;
        haveBefore_  = false;
    }

    // No standing preview persists across frames outside a drag, so there is
    // never an uncommitted edit to coordinate with history navigation.
    override void evaluate() {}
    override void onParamChanged(string pname) {}   // no live rebuild from panel edits

    // -------------------------------------------------------------------
    // Headless apply (tool.doApply / HTTP). Builds the plane from the current
    // start/end + the DEFAULT construction plane's normal (world XZ ⇒ +Y in
    // `--test`, deterministic — the camera-facing auto pick has no headless
    // equivalent, see create_common.currentWorkplaneFrame) and cuts. Must NOT
    // snapshot itself — ToolDoApplyCommand wraps this with its own snapshot
    // pair and IS the undo entry. A single clean cut (no baseline restore —
    // headless never leaves a preview on the mesh), byte-for-byte the S0 path.
    // -------------------------------------------------------------------
    override bool applyHeadless() {
        Vec3 p, n;
        if (!planeFromLineAndWorkplane(start_, end_, currentWorkplaneFrame().normal, p, n))
            return false;
        if (mesh.cutByPlane(p, n) == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;

        // RMB cancels an in-flight gesture (revert to baseline, no undo entry).
        if (e.button == SDL_BUTTON_RIGHT) {
            if (dragPart_ != DragNone) { cancelGesture(); return true; }
            return false;
        }

        SDL_Keymod mods = SDL_GetModState();
        if (mods & KMOD_ALT) return false;   // reserved for camera nav (orbit/pan/zoom)
        bool shift = (mods & KMOD_SHIFT) != 0;

        // Middle-click relocates the whole line to the cursor: translate so the
        // line midpoint lands on the work-plane hit, then drag it as a line
        // translate.
        if (e.button == SDL_BUTTON_MIDDLE) {
            Vec3 hit;
            if (!workplaneHit(cast(float)e.x, cast(float)e.y, hit)) return false;
            Vec3 mid   = (start_ + end_) * 0.5f;
            Vec3 delta = hit - mid;
            start_ = start_ + delta;
            end_   = end_   + delta;
            beginLineDrag(hit);
            beginGesture();
            return true;
        }

        if (e.button != SDL_BUTTON_LEFT) return false;

        if (shift) {
            // Shift+drag resets/redraws: start a fresh line from the cursor
            // regardless of what the click landed near.
            Vec3 hit;
            if (!workplaneHit(cast(float)e.x, cast(float)e.y, hit)) return false;
            start_ = hit;
            end_   = hit;
            dragPart_ = DragEnd;
            beginGesture();
            return true;
        }

        // Plain LMB: grab an endpoint handle if the click is near its
        // projection; else grab the line body if the click is on it; else
        // begin a fresh line from the work-plane hit under the cursor.
        int grabbed = pickHandle(cast(float)e.x, cast(float)e.y);
        if (grabbed >= 0) {
            dragPart_ = grabbed;
        } else if (pickLineBody(cast(float)e.x, cast(float)e.y)) {
            Vec3 hit;
            if (!workplaneHit(cast(float)e.x, cast(float)e.y, hit)) return false;
            beginLineDrag(hit);
        } else {
            Vec3 hit;
            if (!workplaneHit(cast(float)e.x, cast(float)e.y, hit)) return false;
            start_ = hit;
            end_   = hit;
            dragPart_ = DragEnd;   // drag the End of the new line
        }
        beginGesture();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || dragPart_ == DragNone) return false;
        Vec3 hit;
        if (!workplaneHit(cast(float)e.x, cast(float)e.y, hit)) return true;

        final switch (dragPart_) {
            case DragStart: start_ = hit; break;
            case DragEnd:   end_   = hit; break;
            case DragLine:
                Vec3 delta = hit - dragAnchor_;
                start_ = dragStart0_ + delta;
                end_   = dragEnd0_   + delta;
                break;
        }

        // Live preview unless `fast` defers the cut to mouse-up.
        if (!fast_) updatePreview();
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || dragPart_ == DragNone) return false;
        if (e.button != SDL_BUTTON_LEFT && e.button != SDL_BUTTON_MIDDLE) return false;
        dragPart_ = DragNone;
        commitSlice();
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        // Cache the viewport for the endpoint ray casts / handle picks in the
        // event handlers.
        if (!visualOnly) cachedVp = vp;
        if (!active) return;

        // Lazily build the endpoint handle geometry (needs a live GL context).
        if (startH_ is null) {
            startH_      = new BoxHandler(start_, HANDLE_COLOR);
            endH_        = new BoxHandler(end_,   HANDLE_COLOR);
            toolHandles_ = new ToolHandles();
        }
        // Screen-constant handle size, re-positioned on the live endpoints.
        startH_.pos = start_; startH_.size = gizmoSize(start_, vp) * 0.5f;
        endH_.pos   = end_;   endH_.size   = gizmoSize(end_,   vp) * 0.5f;

        // The Start→End line, drawn over the mesh (depth-test off, like the
        // other gizmos) so it stays visible against the surface being cut.
        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);
        glDisable(GL_DEPTH_TEST);
        drawWorldSegment(start_, end_, vp, LINE_COLOR, 2.5f, shader.program);
        glEnable(GL_DEPTH_TEST);

        // Hover / capture highlight through the single-source arbiter: the
        // dragged endpoint stays hot for the whole gesture; otherwise the
        // hovered endpoint lights up.
        toolHandles_.begin();
        toolHandles_.add(startH_, DragStart);
        toolHandles_.add(endH_,   DragEnd);
        if      (dragPart_ == DragStart) toolHandles_.setHaul(DragStart);
        else if (dragPart_ == DragEnd)   toolHandles_.setHaul(DragEnd);
        else                             toolHandles_.setHaul(-1);
        int mx, my;
        queryMouse(mx, my);
        toolHandles_.update(mx, my, vp);

        startH_.draw(shader, vp);
        endH_.draw(shader, vp);
    }

private:
    // Snapshot the pre-cut baseline for this gesture's single undo entry.
    void beginGesture() {
        before_      = MeshSnapshot.capture(*mesh);
        haveBefore_  = true;
        previewLive_ = false;
        if (!fast_) updatePreview();   // show the cut immediately (unless deferred)
    }

    // Latch the line-translate reference state from the current endpoints.
    void beginLineDrag(Vec3 anchor) {
        dragPart_   = DragLine;
        dragStart0_ = start_;
        dragEnd0_   = end_;
        dragAnchor_ = anchor;
    }

    // Refresh the non-cumulative preview: restore the baseline, re-cut with the
    // current line, and push to the GPU. Leaves the mesh AT the baseline (no
    // preview flag) when the line misses every face, so an off-mesh drag never
    // shows a stale cut.
    void updatePreview() {
        if (!haveBefore_) return;
        size_t nSplit = sliceFromBaseline(*mesh, before_, start_, end_, cachedWorkplaneNormal());
        previewLive_ = nSplit > 0;
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }

    // Cancel: revert any preview to the baseline and end the gesture with no
    // history entry.
    void cancelGesture() {
        if (haveBefore_ && before_.filled) {
            before_.restore(*mesh);
            refreshDisplay(mesh, gpu, vc, ec, fc);
        }
        resetSession();
    }

    // Commit the current line as one cut: revert any live preview to the
    // baseline, re-cut once from that clean state (so `fast` on/off commit the
    // identical geometry), and record a single MeshBevelEdit(before, after) —
    // but only if the cut actually split a face (an off-mesh line reverts to
    // baseline and records nothing).
    void commitSlice() {
        if (!haveBefore_) return;
        scope(exit) resetSession();

        size_t nSplit = sliceFromBaseline(*mesh, before_, start_, end_, cachedWorkplaneNormal());
        refreshDisplay(mesh, gpu, vc, ec, fc);
        if (nSplit == 0) return;   // missed every face — mesh reverted, no entry

        if (history !is null && factory !is null && before_.filled) {
            auto cmd  = factory();
            auto post = MeshSnapshot.capture(*mesh);
            cmd.setSnapshots(before_, post, "Slice");
            history.record(cmd);
        }
    }

    // The work-plane normal the interactive path builds the cut plane from.
    // Uses the live workplane frame (respects a user-set non-auto workplane);
    // pickWorkplaneFrame needs a viewport, so fall back to the pipe default
    // (currentWorkplaneFrame) when none was cached yet.
    Vec3 cachedWorkplaneNormal() {
        if (cachedVp.width > 0) return pickWorkplaneFrame(cachedVp).normal;
        return currentWorkplaneFrame().normal;
    }

    // Intersect the cursor ray with the current work plane; the dragged
    // endpoint slides on that plane so the whole line stays in the work plane
    // (which keeps the perpendicular cut plane well-defined).
    bool workplaneHit(float sx, float sy, out Vec3 hit) {
        if (cachedVp.width <= 0) return false;
        WorkplaneFrame wp = pickWorkplaneFrame(cachedVp);
        Vec3 origin, dir;
        screenPointToRay(sx, sy, cachedVp, origin, dir);
        return rayPlaneIntersect(origin, dir, wp.origin, wp.normal, hit);
    }

    // Return DragStart if the cursor is within HANDLE_PICK_PX of the Start
    // projection, DragEnd if within range of End (nearest wins), else -1.
    int pickHandle(float sx, float sy) {
        if (cachedVp.width <= 0) return -1;
        float bestD2 = HANDLE_PICK_PX * HANDLE_PICK_PX;
        int best = -1;
        foreach (i, pt; [start_, end_]) {
            float px, py, z;
            if (!projectToWindowFull(pt, cachedVp, px, py, z)) continue;
            float d2 = (px - sx) * (px - sx) + (py - sy) * (py - sy);
            if (d2 <= bestD2) { bestD2 = d2; best = cast(int)i; }
        }
        return best;
    }

    // True if the cursor is within LINE_PICK_PX of the Start→End line's screen
    // projection (endpoints already handled by pickHandle, which is tried
    // first). A degenerate (zero-length) line has no body.
    bool pickLineBody(float sx, float sy) {
        if (cachedVp.width <= 0) return false;
        float ax, ay, az, bx, by, bz;
        if (!projectToWindowFull(start_, cachedVp, ax, ay, az)) return false;
        if (!projectToWindowFull(end_,   cachedVp, bx, by, bz)) return false;
        float dx = bx - ax, dy = by - ay;
        if (dx * dx + dy * dy < 1.0f) return false;   // no visible body
        float t;
        float d = closestOnSegment2D(sx, sy, ax, ay, bx, by, t);
        return d <= LINE_PICK_PX;
    }
}

// ---------------------------------------------------------------------------
// Non-cumulative preview + fast-gate parity (dub test). Proves the two S1
// invariants at the cut-kernel level without a GL context:
//   1. Dragging the line through many preview positions never accumulates —
//      each `sliceFromBaseline` reproduces a single clean cut of the pristine
//      baseline (a mid-plane cube cut is always 12v/10f, never 16v+).
//   2. The `fast`-deferred commit (one call at the final line) yields the
//      identical geometry to the live-preview path (N previews then a final
//      commit-position call).
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    // A drag of the End endpoint through several positions, all producing a
    // vertical (X-normal, through X=0) cut of the unit cube: the line lies
    // along Z (perpendicular to +Y work plane), start fixed at (0,0,-1).
    Vec3[] endPositions = [
        Vec3(0, 0, 0.4f), Vec3(0, 0, 0.7f), Vec3(0, 0, 1.0f), Vec3(0, 0, 1.3f),
    ];
    Vec3 start = Vec3(0, 0, -1);
    Vec3 wpN   = Vec3(0, 1, 0);   // default world-XZ work plane normal

    // --- Path A: live preview drag, then commit at the final line ---
    Mesh live = makeCube();
    auto baseline = MeshSnapshot.capture(live);
    assert(live.vertices.length == 8 && live.faces.length == 6);

    foreach (ep; endPositions) {
        size_t n = sliceFromBaseline(live, baseline, start, ep, wpN);
        assert(n > 0, "each mid-plane preview must split faces");
        // NON-CUMULATIVE: always the single-cut topology, never accumulated.
        assert(live.vertices.length == 12, "preview must not accumulate verts");
        assert(live.faces.length == 10,    "preview must not accumulate faces");
    }
    // Commit at the final line (revert baseline + cut once, as commitSlice does).
    size_t nCommit = sliceFromBaseline(live, baseline, start, endPositions[$-1], wpN);
    assert(nCommit > 0);
    assert(live.vertices.length == 12 && live.faces.length == 10);

    // --- Path B: fast — no live preview, a single deferred commit ---
    Mesh fast = makeCube();
    auto fastBaseline = MeshSnapshot.capture(fast);
    size_t nFast = sliceFromBaseline(fast, fastBaseline, start, endPositions[$-1], wpN);
    assert(nFast == nCommit);
    assert(fast.vertices.length == live.vertices.length);
    assert(fast.faces.length    == live.faces.length);

    // Byte-for-byte geometry parity between the fast-deferred and live-preview
    // commits (both are one cut of the pristine baseline at the same line).
    foreach (i; 0 .. live.vertices.length) {
        assert(abs(live.vertices[i].x - fast.vertices[i].x) < 1e-6f);
        assert(abs(live.vertices[i].y - fast.vertices[i].y) < 1e-6f);
        assert(abs(live.vertices[i].z - fast.vertices[i].z) < 1e-6f);
    }
}
