module tools.create.vertex_place;

import bindbc.sdl;

import tool;
import mesh;
import math;
import params : Param;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import tools.create.create_common : pickWorkplaneFrame, WorkplaneFrame,
                              mostFacingAxis,
                              transformPoint, transformDir, snapLocalHit,
                              workplaneCursorPlaneHit;
import toolpipe.packets : SnapType;
import editmode : EditMode;
import snap : SnapResult;
import snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;
import operator : VectorStack;
import prepared_tool_effect : PreparedActivateEffect, PreparedActivateKind;

private struct ValidatedVertexActivate {
    @disable this(this);
    bool consumable;
}
static assert(!__traits(compiles, {
    ValidatedVertexActivate first;
    auto copied = first;
}));

// ---------------------------------------------------------------------------
// VertexTool — interactive single-vertex placement.
//
// Each LMB click in the viewport:
//   1. Picks the construction plane via choosePlane_ — the workplane axis
//      most aligned with the camera back vector (identical to PenTool's
//      choosePlane, pen.d:564-583).  The plane passes through the frame
//      origin (LOCAL 0), mirroring pen.d:267-268.
//   2. Unprojects the click to local workplane coordinates via
//      rayPlaneIntersect.
//   3. Applies discrete snap (pen guide bits excluded).
//   4. Converts to world and appends one isolated vertex (mesh.addVertex).
//   5. Records a snapshot-undo entry immediately — one entry per click.
//
// Tool stays active across clicks (no in-progress sequence to commit or
// cancel).  Vertices are isolated: no auto-edge, no auto-face.
//
// Interactive-only; no headless command path.  The headless geometry contract
// for vertex creation is mesh.addVertex (task 0131).
// ---------------------------------------------------------------------------
class VertexTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*          gpu_;
    LitShader         litShader_;



    // Construction-plane state — refreshed on each click by choosePlane_.
    // planeNormal_ is in LOCAL workplane coordinates (one of ±X/Y/Z).
    Vec3           planeNormal_;
    WorkplaneFrame frame_;

    Viewport   cachedVp_;
    SnapResult lastSnap_;

    // Snap-type bits not handled by VertexTool.  Excluded from snapLocalHit
    // so only discrete mesh-element snap fires (no pen guide constraints).
    enum uint guideBits_ =
        SnapType.WorldAxis | SnapType.StraightLine | SnapType.RightAngle;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader)
    {
        this.meshSrc_   = meshSrc;
        this.gpu_       = gpu;
        this.litShader_ = litShader;
    }

    override string name() const { return "Vertex"; }

    override Param[] params() { return []; }

    override void activate() {
        lastSnap_ = SnapResult.init;
    }

    final PreparedActivateEffect prepareActivate() const nothrow @nogc {
        return PreparedActivateEffect(preparedToolStateOwner,
                                      PreparedActivateKind.Vertex);
    }

    final bool validatePreparedActivate(ref PreparedActivateEffect prepared,
            out ValidatedVertexActivate validated) const nothrow @nogc {
        if (prepared.owner != preparedToolStateOwner ||
            prepared.kind != PreparedActivateKind.Vertex) return false;
        validated.consumable = true;
        return true;
    }

    final void installPreparedActivate(ref ValidatedVertexActivate validated)
            nothrow @nogc {
        if (!validated.consumable) return;
        validated.consumable = false;
        lastSnap_ = SnapResult.init;
    }

    override void deactivate() {
        clearLastSnap();
        lastSnap_ = SnapResult.init;
    }

    final void installPreparedPrivateDeactivate() nothrow @nogc {
        lastSnap_ = SnapResult.init;
    }
    version(unittest) void seedPreparedSnapForTest(int index) nothrow @nogc {
        lastSnap_.snapped = true; lastSnap_.targetIndex = index;
    }
    version(unittest) int preparedSnapIndexForTest() const nothrow @nogc {
        return lastSnap_.targetIndex;
    }

    // Cache the viewport each frame so onMouseButtonDown has current camera.
    override void draw(const ref Shader shader, const ref Viewport vp,
                       ref VectorStack vts, bool visualOnly = false)
    {
        cachedVp_ = vp;
        drawSnapOverlay(lastSnap_, vp, *mesh);
    }

    override void drawProperties() {
        import ImGui = d_imgui;
        ImGui.TextDisabled("Click in viewport to place a vertex.");
    }

    // Every click is committed immediately — nothing is ever pending.
    override bool hasUncommittedEdit() const { return false; }
    override void cancelUncommittedEdit() {}

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e,
                                    ref VectorStack vts)
    {
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        // Alt is reserved for camera orbit / pan / zoom.
        if (mods & KMOD_ALT) return false;
        if (mods & (KMOD_CTRL | KMOD_SHIFT)) return false;

        // Select the construction plane: the workplane axis most aligned with
        // the camera back vector (mirrors PenTool.choosePlane, pen.d:564-583).
        choosePlane_(cachedVp_);

        // Unproject click to local workplane coords.  The plane passes through
        // the frame origin (LOCAL 0) — same anchor as pen.d:267-268.
        Vec3 hit;
        if (!localCursorPlane(e.x, e.y, Vec3(0, 0, 0), planeNormal_, hit))
            return true;   // ray parallel to plane — ignore

        // Discrete snap (pen guide bits excluded so only mesh-element targets
        // fire here).
        lastSnap_ = snapLocalHit(hit, frame_, e.x, e.y, cachedVp_,
                                  *mesh, EditMode.Vertices, [], guideBits_);
        publishLastSnap(lastSnap_);

        // Convert local workplane hit → world position.
        Vec3 world = transformPoint(frame_.toWorld, hit);

        // Capture mesh state before modification.
        MeshSnapshot pre = MeshSnapshot.capture(*mesh);

        // Append isolated vertex and fix up selection arrays.
        // CRITICAL: addVertex grows vertices[] only; resizeVertexSelection()
        // must precede selectVertex to prevent an out-of-bounds RangeError
        // (mirrors vertex_new.d:57-66 and pen.d:910-913).
        uint vi = mesh.addVertex(world);
        mesh.resizeVertexSelection();
        mesh.clearVertexSelection();    // only the NEWEST vertex selected
        mesh.selectVertex(cast(int)vi);

        // Upload geometry to GPU.  buildLoops() is intentionally omitted:
        // an isolated vertex has no edges / faces, so loop rebuild is a
        // no-op here — omitting it mirrors vertex_new.d (task 0131).
        gpu_.upload(*mesh);

        // Record one undo entry per click (not per session). The record sits
        // in the RAW EVENT HANDLER, not in a commit method — this tool has no
        // commit method at all and reports `hasUncommittedEdit() == false`
        // unconditionally. The seam moves the record; it does NOT move that
        // trigger (task 1905 §2).
        if (history !is null && gestureFactory !is null && pre.filled) {
            auto cmd = cast(MeshSessionEdit) gestureFactory();
            if (cmd is null) noteGestureCarrierMismatch();
            else {
                auto post = MeshSnapshot.capture(*mesh);
                cmd.setSnapshots(pre, post, "Add Vertex");
                recordGestureEdit(cmd, GestureRecordMode.Plain);
            }
        }

        // Refresh selection / picking caches (same pattern as pen.d:910-913).
        mesh.syncSelection();
        refreshDisplay(mesh, gpu_);

        return true;
    }

    // Live snap preview — show where the next click would land.
    override bool onMouseMotion(ref const SDL_MouseMotionEvent e,
                                ref VectorStack vts)
    {
        WorkplaneFrame f = pickWorkplaneFrame(cachedVp_);

        // Approximate plane normal for preview: most-facing local axis,
        // same logic as choosePlane_ but using the live camera without
        // locking to a frame.
        Vec3 camBack = Vec3(cachedVp_.view[2], cachedVp_.view[6],
                            cachedVp_.view[10]);
        Vec3 pn;
        {
            final switch (mostFacingAxis(camBack, f.axis1, f.normal, f.axis2)) {
                case 0: pn = Vec3(1, 0, 0); break;
                case 1: pn = Vec3(0, 1, 0); break;
                case 2: pn = Vec3(0, 0, 1); break;
            }
        }
        Vec3 hit;
        if (workplaneCursorPlaneHit(f, cachedVp_, cast(float)e.x, cast(float)e.y,
                                    Vec3(0, 0, 0), pn, hit)) {
            lastSnap_ = snapLocalHit(hit, f, e.x, e.y, cachedVp_,
                                      *mesh, EditMode.Vertices, [], guideBits_);
            publishLastSnap(lastSnap_);
        } else {
            lastSnap_ = SnapResult.init;
            clearLastSnap();
        }
        return false;
    }

private:
    // Choose the construction plane: the workplane local axis most aligned
    // with the camera back vector.  Mirrors PenTool.choosePlane (pen.d:564-583).
    // planeNormal_ is set in LOCAL workplane space (one of ±X/Y/Z unit axes).
    void choosePlane_(const ref Viewport vp) {
        frame_ = pickWorkplaneFrame(vp);
        Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
        final switch (mostFacingAxis(camBack, frame_.axis1, frame_.normal, frame_.axis2)) {
            case 0: planeNormal_ = Vec3(1, 0, 0); break;
            case 1: planeNormal_ = Vec3(0, 1, 0); break;
            case 2: planeNormal_ = Vec3(0, 0, 1); break;
        }
    }

    /// The cursor ray at pixel (x, y) against a plane in LOCAL coords.
    /// Ortho-aware — see `create_common.workplaneCursorPlaneHit`. The
    /// `localEye_()`/`localRay_()` pair this replaces was the perspective law
    /// and put the placed vertex at the camera distance times the intended
    /// offset in every ortho cell (task 0661).
    bool localCursorPlane(int x, int y, Vec3 planeOrigin, Vec3 planeNormal,
                          out Vec3 hitLocal) const
    {
        return workplaneCursorPlaneHit(frame_, cachedVp_,
                                       cast(float)x, cast(float)y,
                                       planeOrigin, planeNormal, hitLocal);
    }
}

version (unittest) unittest {
    EditMode mode;
    Mesh mesh = makeCube();
    GpuMesh gpu;
    auto tool = new VertexTool(() => &mesh, &gpu, null);
    auto legacy = new VertexTool(() => &mesh, &gpu, null);
    tool.lastSnap_.snapped = true;
    tool.lastSnap_.targetIndex = 7;
    legacy.lastSnap_ = tool.lastSnap_;
    auto prepared = tool.prepareActivate();
    assert(tool.lastSnap_.snapped && tool.lastSnap_.targetIndex == 7);
    ValidatedVertexActivate validated;
    assert(tool.validatePreparedActivate(prepared, validated));
    tool.installPreparedActivate(validated);
    legacy.activate();
    assert(!tool.lastSnap_.snapped && tool.lastSnap_.targetIndex == -1);
    assert(tool.lastSnap_ == legacy.lastSnap_);
    tool.lastSnap_.snapped = true;
    tool.installPreparedActivate(validated);
    assert(tool.lastSnap_.snapped, "prepared activation was not one-shot");

    auto wrong = new VertexTool(() => &mesh, &gpu, null);
    auto foreign = wrong.prepareActivate();
    assert(!tool.validatePreparedActivate(foreign, validated));
    tool.lastSnap_.targetIndex = 9;
    tool.installPreparedActivate(validated);
    assert(tool.lastSnap_.targetIndex == 9,
           "refused foreign activation gained an install handle");
}
