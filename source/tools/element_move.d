module tools.element_move;

import bindbc.sdl;

import tools.move;
import mesh;
import editmode;
import math : Vec3, projectToWindowFull;
import shader;
import params : Param;

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

    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        super(mesh, gpu, editMode);
    }

    override string name() const { return "Element Move"; }

    override void activate() {
        super.activate();
        mode = Mode.Automatic;
    }

    // `mode` is an int enum; expose via Param.int_ for simplicity (the
    // values are Automatic=0, Manual=1). User sets via
    // `tool.attr xfrm.elementMove mode 1` for Manual.
    override Param[] params() {
        auto base = super.params();
        base ~= Param.int_("mode", "Mode", cast(int*)&mode, 0).min(0).max(1);
        return base;
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
            }
        }
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
