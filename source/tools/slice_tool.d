module tools.slice_tool;

import bindbc.sdl;
import bindbc.opengl;
import std.json : JSONValue;
import std.math : sqrt;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param, IntEnumEntry, wireTagForValue;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import operator : VectorStack;
import display_sync : refreshDisplay;
import eventlog : queryMouse;
import handler : BoxHandler, ToolHandles, gizmoSize, getGizmoPixels, drawWorldSegment;
import tools.create_common : currentWorkplaneFrame, pickWorkplaneFrame, WorkplaneFrame;

// The interactive Slice commit reuses the generic before/after snapshot edit
// command (the same MeshBevelEdit the mirror / tack / primitive tools reuse for
// their one-shot snapshot undo), labelled "Slice".
alias SliceEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// SliceAxis (task 0269, S3) — the plane-orientation constraint. `Free` is the
// factory default: the plane is built from the drawn line ⟂ the work plane
// (the S0 base behavior). `X`/`Y`/`Z` lock the plane normal to a WORLD axis
// (the drawn line then only fixes the through-point); `Custom` uses the
// user-supplied `vector` direction as the normal.
//
// DEFAULT DECISION: the reference live-capture reads `axis = y`, but its own
// spec flags that value as "likely sticky/prefs-seeded, NOT a guaranteed fresh
// factory default", and the tool plan states the base behavior is the free
// drawn-line plane. A `Y` factory default would lock every cut to a world-Y
// (horizontal) normal, contradicting the drawn-line semantics AND the S0
// golden (a Z-line must give an X-normal cut, not a Y-normal one). The
// reference-faithful, self-consistent reading is therefore `Free` as the
// factory default (drawn line ⟂ work plane), with `X`/`Y`/`Z`/`Custom` as the
// explicit locked overrides. This keeps the S0 `slice.json` golden green with
// no axis change while `axis=x/y/z` lock the normal to the world axis exactly
// as the reference's Axis control does.
enum SliceAxis : int { Free = 0, X = 1, Y = 2, Z = 3, Custom = 4 }

static immutable IntEnumEntry[5] sliceAxisTable = [
    IntEnumEntry(cast(int)SliceAxis.Free,   "free",   "Free (drawn line)"),
    IntEnumEntry(cast(int)SliceAxis.X,      "x",      "X"),
    IntEnumEntry(cast(int)SliceAxis.Y,      "y",      "Y"),
    IntEnumEntry(cast(int)SliceAxis.Z,      "z",      "Z"),
    IntEnumEntry(cast(int)SliceAxis.Custom, "custom", "Custom"),
];

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
                         Vec3 start, Vec3 end, Vec3 wpNormal,
                         int axisMode = cast(int)SliceAxis.Free,
                         Vec3 vector = Vec3(0, 1, 0),
                         bool infinite = false)
{
    if (baseline.filled) baseline.restore(mesh);
    Vec3 p, n;
    if (!planeForSlice(start, end, wpNormal, axisMode, vector, p, n))
        return 0;
    // `infinite` (task 0270): ON extends the line indefinitely, so the plane
    // slices the WHOLE mesh (Mesh.cutByPlane — the S0 behavior). OFF (the
    // reference factory default) CLIPS the cut to the drawn Start→End span, so
    // only faces under the drawn line are cut (Mesh.cutByPlaneClipped). On a
    // mesh whose cross-section fits within the line the two agree.
    if (infinite) return mesh.cutByPlane(p, n);
    return mesh.cutByPlaneClipped(p, n, start, end);
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
//     ACTIVATION baseline then re-cuts, via `sliceFromBaseline`), mirroring
//     LoopSliceTool's mutate/revert armed preview. The slice stays LIVE for the
//     whole tool session; nothing is baked on mouse-up.
//   • `fast` (bool, default off): the preview gate. OFF ⇒ the cut recomputes
//     live on every motion. ON ⇒ the cut is DEFERRED to mouse-up (only the
//     line/handles move during the drag — no live cut on dense meshes). Both
//     paths materialise the identical final geometry (`sliceFromBaseline` is
//     the one cut kernel).
//
// S3 (task 0269) adds the `axis` (Free/X/Y/Z/Custom) + `vectorX/Y/Z` plane
// constraint: Free = the drawn-line ⟂ work-plane plane (default); X/Y/Z lock
// the normal to a world axis; Custom uses the `vector` normal. The plane law
// lives in the unit-tested math.planeForSlice helper; the Vector gang is greyed
// unless axis == Custom (paramEnabled).
//
// S4 (task 0270) adds `infinite` (bool): OFF (the reference factory default)
// CLIPS the cut to the drawn Start→End span — only faces under the line get
// cut (Mesh.cutByPlaneClipped); ON extends the line indefinitely so the plane
// slices the whole mesh (Mesh.cutByPlane, the S0 behavior). It threads through
// the preview + commit (sliceFromBaseline) and applyHeadless.
//
// Deferred to later tasks: angle snap (S5), split/caps/gap reusing the Loop
// Slice machinery (S7–S9). Params: `startX/Y/Z`, `endX/Y/Z`, `fast`,
// `infinite`, `axis`, `vectorX/Y/Z`.
//
// Undo model (task 0278 — mirrors LoopSliceTool's arm-then-commit lifecycle):
// `before_` is the ACTIVATION baseline, snapshotted ONCE in `activate()` — NOT
// per gesture. Every endpoint/line drag re-cuts NON-CUMULATIVELY from that one
// baseline (restore baseline → `cutByPlane` once), so the mesh always shows
// EXACTLY ONE slice at the current line — dragging endpoints refines the SAME
// slice, it never spawns another. The cut is baked into ONE
// MeshBevelEdit(before, after) history entry when the tool is DEACTIVATED /
// dropped (see `deactivate` → `commitCurrentSlice`), never on mouse-up. A
// session whose final line touches no face (or was never drawn) commits
// nothing. `armedKey_` guards the deferred commit against a mesh swapped out
// from under us (scene reset / layer switch) between the last preview and the
// drop — a mismatch drops the preview instead of baking a bogus entry.
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

    // Slice axis constraint (S3). `axis_` selects how the cut-plane normal is
    // built (see SliceAxis); `vector_` is the Custom normal, meaningful only
    // when axis_ == Custom (the panel greys it otherwise — see paramEnabled).
    // Default Free = the S0 drawn-line ⟂ work-plane plane (see SliceAxis doc).
    SliceAxis axis_   = SliceAxis.Free;
    Vec3      vector_ = Vec3(0, 1, 0);

    // Infinite (S4, task 0270). OFF (the reference factory default) CLIPS the
    // cut to the drawn Start→End span — only faces under the line get cut. ON
    // extends the line indefinitely so the plane slices the whole mesh (the S0
    // behavior). Threaded into sliceFromBaseline (preview + commit) and
    // applyHeadless. Sticky (not reset on activate), like the other tool
    // options. DEFAULT DECISION: the reference live-capture reads infinite=off
    // as a GUARANTEED factory default (spec.json "default": false, authoritative
    // from cmdhelptools.cfg — unlike the sticky-flagged axis/snap values). The
    // S0/S3/session goldens all draw lines that span the cube's cross-section,
    // so every crossing stays in-band and the clipped default reproduces them
    // unchanged; the infinite/clipped divergence only shows on a line shorter
    // than the mesh (see test_fixture_slice_infinite).
    bool infinite_ = false;

    // Which part of the gizmo this gesture drags.
    enum DragNone  = -1;
    enum DragStart = 0;    // the Start endpoint handle
    enum DragEnd   = 1;    // the End endpoint handle
    enum DragLine  = 2;    // the whole line body (translate)

    // Session state. `before_` is the session baseline captured ONCE at
    // activation (task 0278); `previewLive_` is true whenever a real cut sits
    // on the mesh (the thing `deactivate` commits). `armedKey_` stamps the
    // mesh identity+version we last left the preview at, so the deferred
    // commit can detect an external mesh swap and drop rather than corrupt it.
    bool     active;
    int      dragPart_ = DragNone;
    bool     previewLive_;       // a preview cut currently sits on the mesh
    MeshSnapshot before_;        // session baseline captured at activation
    bool     haveBefore_;
    MeshCacheKey armedKey_;      // mesh identity+version guard for the deferred commit
    Viewport cachedVp;

    // Line-body translate bookkeeping: the endpoints + the work-plane anchor at
    // the moment the drag began, so motion translates by (hit - anchor).
    Vec3 dragStart0_, dragEnd0_, dragAnchor_;

    // The line endpoints as they stood at the START of the current gesture, so
    // RMB-cancel can revert this drag (only) and re-preview, leaving the
    // session baseline untouched.
    Vec3 gStart0_, gEnd0_;

    // Endpoint handle visuals (lazily built inside a live GL context, since
    // BoxHandler uploads a VAO). Purely for drawing + hover highlight; the
    // actual grab hit-test is the projection-based `pickHandle` (no GL needed,
    // so the event path works even before the first draw).
    BoxHandler  startH_, endH_;
    ToolHandles toolHandles_;

    // Endpoint handle visual size + grab radius (task 0278). The reference
    // Slice draws small cyan endpoint squares ~10 px across (0277 handler
    // capture), so the visible half-extent is HANDLE_HALF_PX ≈ 5 px (the old
    // `gizmoSize()*0.5` was ~45 px half — a ~90 px square, far too big). The
    // grab radius is tied to the visual: HANDLE_PICK_PX covers the whole
    // square (its 5·√2 ≈ 7 px corner) plus a small margin, so a click on the
    // visible square reliably grabs the endpoint. A hit-test SMALLER than the
    // visual was part of why endpoint drags "missed" and fell through to
    // drawing a fresh line.
    enum float HANDLE_HALF_PX = 5.0f;    // visible endpoint square half-extent (~10 px square)
    enum float HANDLE_PICK_PX = 9.0f;    // grab radius — matched to (slightly > ) the visual
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
            // Infinite (S4): OFF clips the cut to the drawn line's span (the
            // reference factory default); ON slices the whole mesh (S0).
            Param.bool_( "infinite", "Infinite", &infinite_, false),
            // Axis (S3): Free (drawn line ⟂ work plane) / X / Y / Z (world-axis
            // normal) / Custom (vector normal). Default Free — see SliceAxis.
            Param.intEnum_("axis", "Axis", cast(int*)&axis_, sliceAxisTable[],
                           cast(int)SliceAxis.Free),
            // Custom normal — greyed unless Axis == Custom (paramEnabled).
            Param.float_("vectorX", "Vector X", &vector_.x, 0.0f),
            Param.float_("vectorY", "Vector Y", &vector_.y, 1.0f),
            Param.float_("vectorZ", "Vector Z", &vector_.z, 0.0f),
        ];
    }

    // Grey the Vector gang unless a Custom axis is active — the custom normal is
    // only consulted when axis_ == Custom (reference: the Vector X/Y/Z rows are
    // enabled only for Axis = Custom).
    override bool paramEnabled(string name) const {
        if (name == "vectorX" || name == "vectorY" || name == "vectorZ")
            return axis_ == SliceAxis.Custom;
        return true;
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
        root["infinite"] = JSONValue(infinite_);
        root["axis"]    = JSONValue(wireTagForValue(sliceAxisTable[], cast(int)axis_));
        root["vectorX"] = JSONValue(vector_.x);
        root["vectorY"] = JSONValue(vector_.y);
        root["vectorZ"] = JSONValue(vector_.z);
        return root;
    }

    override void activate() {
        active = true;
        dropPreview();
        // Snapshot the SESSION baseline once, now, at tool activation. Every
        // drag re-cuts non-cumulatively from this (never per-gesture), and the
        // deferred commit records before_ → the final cut as ONE undo entry.
        before_     = MeshSnapshot.capture(*mesh);
        haveBefore_ = true;
        armedKey_.stamp(*mesh);
    }

    override void deactivate() {
        // Bake the live slice into ONE undo entry on tool-drop (task 0278) —
        // this is the ONLY commit point (never mouse-up). If no cut is live
        // (off-mesh / never-drawn line, or a headless applyHeadless already
        // ran its own ToolDoApplyCommand-wrapped cut), leave the mesh exactly
        // as it is and record nothing.
        if (active) commitCurrentSlice();
        active = false;
        dropPreview();
    }

    // Clear per-session preview/drag state WITHOUT touching the mesh or
    // history — the safe teardown for a mesh swapped out from under us.
    private void dropPreview() {
        dragPart_    = DragNone;
        previewLive_ = false;
        haveBefore_  = false;
        armedKey_.invalidate();
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
        if (!planeForSlice(start_, end_, currentWorkplaneFrame().normal,
                           cast(int)axis_, vector_, p, n))
            return false;
        // infinite ⇒ whole-mesh plane cut; else clip to the drawn Start→End span.
        size_t nSplit = infinite_ ? mesh.cutByPlane(p, n)
                                   : mesh.cutByPlaneClipped(p, n, start_, end_);
        if (nSplit == 0) return false;
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

        // Latch the line as it stands NOW so RMB can cancel just this gesture
        // (the session baseline is never per-gesture — see the class comment).
        gStart0_ = start_;
        gEnd0_   = end_;

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
            kickPreview();
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
            kickPreview();
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
        kickPreview();
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
        // Mouse-up does NOT commit (task 0278) — the slice stays LIVE for the
        // rest of the session; the single undo entry is baked at tool-drop.
        // Materialise the final cut here so `fast` mode (which suppresses the
        // live cut during the drag) shows/holds the result, and so the
        // non-fast path lands exactly on the release line.
        updatePreview();
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
        // Screen-constant handle size (~10 px cyan square, reference-matched),
        // re-positioned on the live endpoints. gizmoSize()'s half-extent maps
        // to getGizmoPixels() px, so scale it to HANDLE_HALF_PX px.
        immutable float handleScale = HANDLE_HALF_PX / getGizmoPixels();
        startH_.pos = start_; startH_.size = gizmoSize(start_, vp, handleScale);
        endH_.pos   = end_;   endH_.size   = gizmoSize(end_,   vp, handleScale);

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
    // Kick the live preview at the start of a gesture (unless `fast` defers the
    // cut to mouse-up). Does NOT snapshot — the session baseline was captured
    // once at activation.
    void kickPreview() {
        if (!fast_) updatePreview();
    }

    // Latch the line-translate reference state from the current endpoints.
    void beginLineDrag(Vec3 anchor) {
        dragPart_   = DragLine;
        dragStart0_ = start_;
        dragEnd0_   = end_;
        dragAnchor_ = anchor;
    }

    // Refresh the non-cumulative preview: restore the SESSION baseline, re-cut
    // with the current line, stamp the mesh guard, and push to the GPU. Leaves
    // the mesh AT the baseline (previewLive_ = false) when the line misses
    // every face, so an off-mesh drag never shows a stale cut — and the
    // deferred commit then records nothing.
    void updatePreview() {
        if (!haveBefore_) return;
        size_t nSplit = sliceFromBaseline(*mesh, before_, start_, end_,
                                          cachedWorkplaneNormal(), cast(int)axis_, vector_,
                                          infinite_);
        previewLive_ = nSplit > 0;
        // Stamp AFTER the cut, BEFORE refreshDisplay (which does not bump
        // mutationVersion): the guard now reflects the mesh state WE produced,
        // so deactivate() can tell whether anything external has since touched
        // it (mirrors LoopSliceTool.rebuildCut).
        armedKey_.stamp(*mesh);
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }

    // RMB cancel: revert ONLY the current gesture (restore the line to where it
    // stood when this drag began) and re-preview from the session baseline. The
    // session stays alive — the baseline is not dropped.
    void cancelGesture() {
        dragPart_ = DragNone;
        start_    = gStart0_;
        end_      = gEnd0_;
        updatePreview();
    }

    // Bake the live slice into ONE undo entry (called from deactivate). The
    // mesh already holds the non-cumulative preview cut for the current line
    // (mutate/revert keeps exactly one cut on it), so this just records
    // before_ → the current mesh. No-ops when nothing is live to commit
    // (off-mesh / never-drawn line, or a headless applyHeadless path), and
    // drops silently if the mesh was swapped out from under us since the last
    // preview (armedKey_ mismatch) rather than baking a bogus entry.
    void commitCurrentSlice() {
        if (!previewLive_ || !haveBefore_ || !before_.filled) return;
        if (!armedKey_.matches(*mesh)) return;   // mesh swapped since last preview — drop
        if (history is null || factory is null) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before_, post, "Slice");
        history.record(cmd);
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
// Runs on the `infinite` path (infinite=true): these positions vary the line
// LENGTH, and the point here is length-INDEPENDENT non-accumulation, so the
// whole-mesh plane cut is the right invariant. The clipped-default divergence
// (line length changes what is cut) is covered by cutByPlaneClipped's mesh.d
// unittests + test_fixture_slice_infinite.
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
    enum bool INF = true;         // whole-mesh plane — length-independent cut

    // --- Path A: live preview drag, then commit at the final line ---
    Mesh live = makeCube();
    auto baseline = MeshSnapshot.capture(live);
    assert(live.vertices.length == 8 && live.faces.length == 6);

    foreach (ep; endPositions) {
        size_t n = sliceFromBaseline(live, baseline, start, ep, wpN,
                                     cast(int)SliceAxis.Free, Vec3(0, 1, 0), INF);
        assert(n > 0, "each mid-plane preview must split faces");
        // NON-CUMULATIVE: always the single-cut topology, never accumulated.
        assert(live.vertices.length == 12, "preview must not accumulate verts");
        assert(live.faces.length == 10,    "preview must not accumulate faces");
    }
    // Commit at the final line (revert baseline + cut once — the same
    // non-cumulative kernel the deferred deactivate-commit records).
    size_t nCommit = sliceFromBaseline(live, baseline, start, endPositions[$-1], wpN,
                                       cast(int)SliceAxis.Free, Vec3(0, 1, 0), INF);
    assert(nCommit > 0);
    assert(live.vertices.length == 12 && live.faces.length == 10);

    // --- Path B: fast — no live preview, a single deferred commit ---
    Mesh fast = makeCube();
    auto fastBaseline = MeshSnapshot.capture(fast);
    size_t nFast = sliceFromBaseline(fast, fastBaseline, start, endPositions[$-1], wpN,
                                     cast(int)SliceAxis.Free, Vec3(0, 1, 0), INF);
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

    // --- Clip default: the SAME short line (end z=0.4) cuts LESS than infinite.
    // Its far crossing (z=+0.5) projects past the drawn span, so only the near
    // (z=−0.5) side splits — a countable proof the default clips.
    Mesh clip = makeCube();
    auto clipBase = MeshSnapshot.capture(clip);
    size_t nClip = sliceFromBaseline(clip, clipBase, start, Vec3(0, 0, 0.4f), wpN);
    assert(nClip < 4, "clipped short line must split fewer faces than infinite (4)");
    assert(clip.vertices.length < 12,
           "clipped short line adds fewer crossing verts than the full belt");
}
