module tools.slice_tool;

import bindbc.sdl;
import std.json : JSONValue;

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
import tools.create_common : currentWorkplaneFrame, pickWorkplaneFrame, WorkplaneFrame;

// The interactive Slice commit reuses the generic before/after snapshot edit
// command (the same MeshBevelEdit the mirror / tack / primitive tools reuse for
// their one-shot snapshot undo), labelled "Slice".
alias SliceEditFactory = MeshBevelEdit delegate();

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
// S0 scope (this class): activation, two draggable Start/End handles, a
// line-draw gesture (down = place Start, drag = End, up = commit the cut),
// plane build + `Mesh.cutByPlane`, one `MeshSnapshot` undo entry per committed
// slice, and `applyHeadless()` so `--test` / HTTP can drive a slice with
// explicit start/end coordinates. Params: `startX/Y/Z`, `endX/Y/Z`.
//
// Deferred to later tasks (structure left so they slot in): live preview +
// handle polish (S1), post-tool selection (S2), axis/vector (S3), infinite
// (S4), angle snap (S5), fast (S6), split/caps/gap reusing the Loop Slice
// machinery (S7–S9). NONE of those options are implemented here.
//
// Undo model (S0): NO live mutation during the drag (the live preview is S1).
// The mesh is cut ONCE at mouse-up. `before_` is captured at mouse-down (the
// pre-cut baseline); at mouse-up the plane is built, `cutByPlane` runs, and if
// it split anything a MeshBevelEdit(before, after) is recorded — one history
// entry per committed slice. A gesture that touches no face records nothing.
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

    // Session state.
    bool     active;
    int      dragHandle_ = -1;   // -1 none, 0 = Start, 1 = End (dragged this gesture)
    MeshSnapshot before_;        // pre-cut baseline captured at mouse-down
    bool     haveBefore_;
    Viewport cachedVp;

    // Screen-pixel radius within which a click grabs an endpoint handle
    // (instead of starting a fresh line). Polish (a real ToolHandles hit-test
    // + visuals) is S1.
    enum float HANDLE_PICK_PX = 14.0f;

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
        ];
    }

    // Test-introspection (GET /api/tool/state): echo the line + a neutral tool
    // tag so a headless test can assert the driven start/end without a
    // screenshot. Mirrors LoopSliceTool.toolStateJson (data, not pixels).
    override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]   = JSONValue("slice");
        root["startX"] = JSONValue(start_.x);
        root["startY"] = JSONValue(start_.y);
        root["startZ"] = JSONValue(start_.z);
        root["endX"]   = JSONValue(end_.x);
        root["endY"]   = JSONValue(end_.y);
        root["endZ"]   = JSONValue(end_.z);
        return root;
    }

    override void activate() { active = true; dragHandle_ = -1; haveBefore_ = false; }
    override void deactivate() { active = false; dragHandle_ = -1; haveBefore_ = false; }

    // S0 has no standing preview (no live mutation), so there is never an
    // uncommitted edit to coordinate with history navigation.
    override void evaluate() {}
    override void onParamChanged(string pname) {}   // no live rebuild in S0

    // -------------------------------------------------------------------
    // Headless apply (tool.doApply / HTTP). Builds the plane from the current
    // start/end + the DEFAULT construction plane's normal (world XZ ⇒ +Y in
    // `--test`, deterministic — the camera-facing auto pick has no headless
    // equivalent, see create_common.currentWorkplaneFrame) and cuts. Must NOT
    // snapshot itself — ToolDoApplyCommand wraps this with its own snapshot
    // pair and IS the undo entry.
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
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera nav

        // Grab an endpoint handle if the click landed near its projection;
        // otherwise begin a fresh line from the work-plane hit under the cursor.
        int grabbed = pickHandle(cast(float)e.x, cast(float)e.y);
        if (grabbed >= 0) {
            dragHandle_ = grabbed;
        } else {
            Vec3 hit;
            if (!workplaneHit(cast(float)e.x, cast(float)e.y, hit)) return false;
            start_ = hit;
            end_   = hit;
            dragHandle_ = 1;   // drag the End of the new line
        }

        // Snapshot the pre-cut baseline for this gesture's single undo entry.
        before_     = MeshSnapshot.capture(*mesh);
        haveBefore_ = true;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || dragHandle_ < 0) return false;
        Vec3 hit;
        if (!workplaneHit(cast(float)e.x, cast(float)e.y, hit)) return true;
        if (dragHandle_ == 0) start_ = hit;
        else                  end_   = hit;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || dragHandle_ < 0) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragHandle_ = -1;
        commitSlice();
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        // Cache the viewport for the endpoint ray casts / handle picks in the
        // event handlers. The pink line + endpoint handle VISUALS are S1; S0
        // draws no overlay (the committed cut is already visible in the mesh).
        if (!visualOnly) cachedVp = vp;
    }

private:
    // Commit the current line as one cut: build the plane, cut, and record a
    // single MeshBevelEdit(before, after) entry — but only if the cut actually
    // split a face (an off-mesh line records nothing).
    void commitSlice() {
        if (!haveBefore_) return;
        scope(exit) haveBefore_ = false;

        Vec3 p, n;
        if (!planeFromLineAndWorkplane(start_, end_, cachedWorkplaneNormal(), p, n))
            return;
        if (mesh.cutByPlane(p, n) == 0) return;   // missed every face — no entry
        refreshDisplay(mesh, gpu, vc, ec, fc);

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

    // Return 0 if the cursor is within HANDLE_PICK_PX of the Start projection,
    // 1 if within range of End (nearest wins), else -1.
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
}
