module tools.edge_extrude;

import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, BoxHandler, ToolHandles, HandleState, gizmoSize;
import drag : screenAxisDelta;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.edge_extrude_edit : MeshEdgeExtrudeEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;

import std.math : abs, sqrt;

/// The interactive tool reuses the dedicated MeshEdgeExtrudeEdit record
/// command (a before/after MeshSnapshot pair) — analogous to how BoxTool
/// reuses MeshBevelEdit via `alias BoxEditFactory = MeshBevelEdit delegate();`.
/// A dedicated class (rather than reusing the bevel edit) keeps the undo label
/// reading "Edge Extrude".
alias EdgeExtrudeEditFactory = MeshEdgeExtrudeEdit delegate();

// ---------------------------------------------------------------------------
// EdgeExtrudeTool — interactive Edge Extrude (factory id `edge.extrude`).
//
// Modelled on BoxTool / PenTool (NOT TransformTool): topology-creating tools
// own their undo plumbing and commit ONE before/after MeshSnapshot record
// command at deactivate. TransformTool's vertex-position-delta MeshVertexEdit
// cannot undo added verts/faces, so it is unusable here.
//
// Session model (the BoxTool commit pattern):
//   activate()  — capture `before` = MeshSnapshot.capture(mesh) (geometry +
//                 selection); reset extrude/width to 0 (identity ⇒ no-op).
//                 ALSO compute the gizmo anchor (selection centroid) + the two
//                 handle axes (extrude = averaged neighbour-polygon normal;
//                 width = in-plane inset direction) from the ORIGINAL
//                 pre-extrude selection, so the gizmo doesn't jump as the mesh
//                 changes during the drag.
//   drag        — restore `before` (re-establishes the original cage AND the
//                 original edge selection), recompute the (extrude,width) pair
//                 from the accumulated screen-space mouse delta, re-run
//                 Mesh.extrudeEdgesByMask on the restored selection, then
//                 gpu.upload + cache refresh.
//   deactivate() — if any geometry was built (extrude or width nonzero),
//                 capture `after`, build a MeshEdgeExtrudeEdit via the injected
//                 factory, setSnapshots(before, after, "Edge Extrude"), and push
//                 it onto history as ONE undo step.
//
// Interaction (two REAL clickable gizmo handles, matching the reference
// modeler's edge-extrude tool, registered in a `ToolHandles` arbiter):
//   - Handle EXTRUDE = a BLUE Arrow anchored at the selection centroid,
//     pointing along the averaged extrude direction. Dragging it changes
//     `extrude` only (mouse delta projected onto the arrow's screen-space
//     direction → world distance → param delta).
//   - Handle WIDTH = a RED BoxHandler offset from the centroid along the
//     in-plane inset direction. Dragging it changes `width` only.
// Both handles get their highlight (Rollover) state ONLY from the
// ToolHandles arbiter's update→setState pass (the handle-arbiter model), so
// they highlight on hover and the dragged handle stays highlighted while
// hauling. No more blind whole-screen 2-axis drag.
//
// The headless path (`tool.set edge.extrude on; tool.attr edge.extrude
// extrude <v>; tool.attr edge.extrude width <v>; tool.doApply`) drives the
// SAME kernel through applyHeadless(); ToolDoApplyCommand wraps it with a
// snapshot pair for undo (so applyHeadless MUST NOT snapshot itself).
// ---------------------------------------------------------------------------
class EdgeExtrudeTool : Tool {
private:
    Mesh*            mesh;
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    // Caches refreshed after the per-drag revert+reapply (drag mutates the
    // mesh outside setActiveTool's bulk refresh).
    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory         history;
    EdgeExtrudeEditFactory factory;

    // Parameters — exposed via params() so both the Tool Properties panel
    // and the headless tool.attr path write into them.
    float extrude_ = 0.0f;
    float width_   = 0.0f;

    // Interactive session state.
    bool          active;          // between activate() and deactivate()
    bool          built;           // true once a nonzero extrude/width built topology
    MeshSnapshot  before;          // captured at activate() (geometry + selection)
    Viewport      cachedVp;        // last frame's viewport (for the gizmo handles)

    // Gizmo frame, computed at activate() from the ORIGINAL (pre-extrude)
    // selection. `gizmoValid` is false when there is no extrudable selection
    // (empty mesh) — the handles are then not drawn / not registered.
    bool gizmoValid;
    Vec3 anchor;        // selection centroid
    Vec3 extrudeAxis;   // unit: averaged neighbour-polygon normal (ridge lift dir)
    Vec3 widthAxis;     // unit: in-plane inset direction (perpendicular to edge tangent)
    uint gizmoSelHash;  // selection signature the gizmo frame was built for

    // Drag state — which handle (part id) is being hauled, and the per-handle
    // base param + last mouse position for the axis-projected delta.
    enum int PART_EXTRUDE = 0;
    enum int PART_WIDTH    = 1;
    int   dragPart = -1;           // -1 = none, PART_EXTRUDE / PART_WIDTH
    int   dragLastMX, dragLastMY;
    float dragBaseExtrude, dragBaseWidth;

    // Two registered, clickable gizmo handles + their arbiter.
    Arrow       extrudeArrow;      // BLUE — extrude
    BoxHandler  widthBox;          // RED  — width
    ToolHandles toolHandles;

    enum Vec3 EXTRUDE_COLOR = Vec3(0.2f, 0.45f, 1.0f);   // blue
    enum Vec3 WIDTH_COLOR   = Vec3(0.9f, 0.2f, 0.2f);    // red

public:
    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.mesh      = mesh;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
        // Geometry placeholders; the real anchor/axes are written each frame
        // in draw() from the activate()-computed gizmo frame.
        extrudeArrow = new Arrow(Vec3(0, 0, 0), Vec3(0, 0, 1), EXTRUDE_COLOR);
        widthBox     = new BoxHandler(Vec3(0, 0, 0), WIDTH_COLOR);
        toolHandles  = new ToolHandles();
    }

    void destroy() {
        if (extrudeArrow !is null) extrudeArrow.destroy();
        if (widthBox     !is null) widthBox.destroy();
    }

    /// Inject undo plumbing — called by app.d after construction.
    /// commitEdit() is a no-op when these aren't bound.
    void setUndoBindings(CommandHistory h, EdgeExtrudeEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Edge Extrude"; }

    // Edge Extrude only makes sense on an edge selection.
    override EditMode[] supportedModes() const { return [EditMode.Edges]; }

    override Param[] params() {
        return [
            Param.float_("extrude", "Extrude", &extrude_, 0.0f),
            Param.float_("width",   "Width",   &width_,   0.0f),
        ];
    }

    override void activate() {
        active   = true;
        built    = false;
        dragPart = -1;
        extrude_ = 0.0f;
        width_   = 0.0f;
        // Snapshot the cage + selection at the start of the session. The
        // per-drag revert+reapply restores from here; the commit pairs it
        // with the final `after`.
        before = MeshSnapshot.capture(*mesh);
        // Build the gizmo anchor + axes from the original pre-extrude
        // selection so the handles stay put across the drag.
        computeGizmoFrame();
    }

    override void deactivate() {
        // Commit one undo step iff a nonzero param actually built topology.
        if (active && built && (extrude_ != 0.0f || width_ != 0.0f))
            commitEdit();
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        toolHandles.clearHaul();
    }

    // A parameter changed. Two callers, distinguished by `interactiveParamEdit`
    // (set by PropertyPanel only):
    //   - Interactive Tool Properties edit → rebuild the live preview from the
    //     clean cage (the same revert+reapply the drag path uses), so the
    //     panel's Extrude/Width sliders update the mesh immediately.
    //   - Headless `tool.attr ...; tool.doApply` → leave the mesh untouched.
    //     applyHeadless() runs the kernel once from the clean cage; mutating
    //     the mesh on every attr write would double-apply AND poison
    //     ToolDoApplyCommand's pre-snapshot (captured AFTER the attr writes).
    override void onParamChanged(string name) {
        if (interactiveParamEdit) rebuildPreview();
    }
    override void evaluate() {}

    // -----------------------------------------------------------------------
    // Headless apply (tool.doApply). Runs the kernel on the current edge
    // selection. MUST NOT snapshot — ToolDoApplyCommand wraps with undo.
    // -----------------------------------------------------------------------
    override bool applyHeadless() {
        if (*editMode != EditMode.Edges) return false;
        // If a live drag previously built preview topology, restore the clean
        // cage first so the kernel applies exactly once (idempotent). In the
        // pure headless flow (no drag) `before` == the current mesh, so this
        // is a no-op and ToolDoApplyCommand's pre-snapshot stays clean.
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.edges.length == 0) return false;
        if (extrude_ == 0.0f && width_ == 0.0f) return true;   // no-op success
        auto mask = currentMask();
        size_t n = mesh.extrudeEdgesByMask(mask, extrude_, width_);
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    // -----------------------------------------------------------------------
    // Interactive drag — driven by the two registered handles, NOT a blind
    // whole-screen 2-axis drag.
    //
    // LMB-down: hit-test the arbiter. The arrow part begins an extrude drag
    // (records the base extrude); the box part begins a width drag (records
    // the base width). A click that hits neither handle does nothing (no
    // blind drag starts).
    // -----------------------------------------------------------------------
    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) {
            // Cancel: drop any built topology, restore the original cage.
            before.restore(*mesh);
            refreshCaches();
            extrude_ = 0.0f;
            width_   = 0.0f;
            built    = false;
            dragPart = -1;
            toolHandles.clearHaul();
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera
        if (*editMode != EditMode.Edges) return false;
        if (mesh.edges.length == 0 || !gizmoValid) return false;

        // Ask the arbiter which handle (if any) the click landed on.
        int part = toolHandles.test(e.x, e.y, cachedVp);
        if (part != PART_EXTRUDE && part != PART_WIDTH) return false;

        dragPart        = part;
        dragLastMX      = e.x;
        dragLastMY      = e.y;
        dragBaseExtrude = extrude_;
        dragBaseWidth   = width_;
        toolHandles.setHaul(part);
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0 || !gizmoValid) return false;

        // Project the per-event mouse delta onto the screen-space direction of
        // the dragged handle's WORLD axis to get a world-space distance, then
        // map that distance directly to the param (1 world unit = 1 param unit,
        // since both extrude and width are world-space offsets the kernel adds
        // along these very axes). screenAxisDelta returns `axis * d`; the
        // signed magnitude `d` along the unit axis IS the param delta.
        Vec3 axis = (dragPart == PART_EXTRUDE) ? extrudeAxis : widthAxis;
        bool skip;
        Vec3 delta = screenAxisDelta(e.x, e.y, dragLastMX, dragLastMY,
                                     anchor, axis, cachedVp, skip);
        if (!skip) {
            float d = dot(delta, axis);   // axis is unit ⇒ signed world distance
            if (dragPart == PART_EXTRUDE) extrude_ += d;
            else                          width_   += d;
            // Width is a shrink amount: the kernel no-ops for width < ~0 and
            // treats tiny widths as a no-op. Clamp to >= 0 so a backward drag
            // can't drive it negative.
            if (width_ < 0.0f) width_ = 0.0f;
            rebuildPreview();
        }
        dragLastMX = e.x;
        dragLastMY = e.y;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragPart = -1;
        toolHandles.clearHaul();
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts) {
        cachedVp = vp;
        // Selection may have changed since activate() (e.g. the user picked a
        // different edge in the viewport before grabbing a handle). Recompute
        // the gizmo frame when it does — but never mid-drag (the moving set is
        // frozen for the whole haul).
        if (dragPart < 0 && mesh.selectionHashEdges() != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        // Position the two handles. Screen-stable sizing via gizmoSize().
        float armLen = gizmoSize(anchor, vp, 1.0f);          // arrow length
        float boxOff = gizmoSize(anchor, vp, 0.75f);         // box offset from anchor
        extrudeArrow.start = anchor + extrudeAxis * (armLen / 6.0f);
        extrudeArrow.end   = anchor + extrudeAxis * armLen;
        extrudeArrow.color = EXTRUDE_COLOR;
        widthBox.pos       = anchor + widthAxis * boxOff;
        widthBox.size      = gizmoSize(anchor, vp, 0.05f);
        widthBox.color     = WIDTH_COLOR;

        // Single test+update pass: register both handles (arrow priority over
        // box on overlap — arrow is the primary action), keep the hauled
        // handle highlighted, then hand each handle its HandleState.
        toolHandles.begin();
        toolHandles.add(extrudeArrow, PART_EXTRUDE);
        toolHandles.add(widthBox,     PART_WIDTH);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        extrudeArrow.draw(shader, vp);
        widthBox.draw(shader, vp);
    }

private:
    // The mask the kernel runs on: empty selection ⇒ whole mesh (matching the
    // mesh.delete / mesh.edge_extrude convention).
    bool[] currentMask() {
        if (mesh.nothingSelected(EditMode.Edges)) {
            auto m = new bool[](mesh.edges.length);
            m[] = true;
            return m;
        }
        return mesh.selectedEdges;
    }

    // Revert to the pre-extrude cage + selection, then rebuild from the
    // current extrude/width. Identity params leave the mesh restored (no-op).
    void rebuildPreview() {
        if (!active) return;
        before.restore(*mesh);
        if (extrude_ == 0.0f && width_ == 0.0f) {
            built = false;
            refreshCaches();
            return;
        }
        auto mask = currentMask();
        size_t n = mesh.extrudeEdgesByMask(mask, extrude_, width_);
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Edge Extrude");
        history.record(cmd);
    }

    void refreshCaches() {
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
    }

    // -----------------------------------------------------------------------
    // computeGizmoFrame — anchor + extrude/width axes from the CURRENT edge
    // selection (empty ⇒ whole mesh). Computed at activate() and whenever the
    // selection changes while idle, so the gizmo doesn't jump during a drag.
    //
    //   anchor      = centroid of the selected edges' endpoints.
    //   extrudeAxis = normalized average of `faceNormal` over the faces
    //                 adjacent to the selected edges (the same ridge-lift
    //                 notion the kernel uses).
    //   widthAxis   = a representative in-plane inset direction: the averaged
    //                 per-edge inward dir, each perpendicular to the edge
    //                 tangent and to the extrude axis. Falls back to any axis
    //                 perpendicular to extrudeAxis when degenerate.
    // -----------------------------------------------------------------------
    void computeGizmoFrame() {
        gizmoValid   = false;
        gizmoSelHash = mesh.selectionHashEdges();
        if (mesh.edges.length == 0) return;

        bool wholeMesh = mesh.nothingSelected(EditMode.Edges);
        auto sel = mesh.selectedEdges;

        Vec3 centSum  = Vec3(0, 0, 0);
        size_t centN  = 0;
        Vec3 normSum  = Vec3(0, 0, 0);
        Vec3 insetSum = Vec3(0, 0, 0);

        foreach (i; 0 .. mesh.edges.length) {
            bool selected = wholeMesh || (i < sel.length && sel[i]);
            if (!selected) continue;
            uint va = mesh.edges[i][0];
            uint vb = mesh.edges[i][1];
            Vec3 pa = mesh.vertices[va];
            Vec3 pb = mesh.vertices[vb];
            centSum = centSum + pa + pb;
            centN  += 2;

            // Averaged neighbour-polygon normal for this edge (ridge dir).
            Vec3 ne = edgeAveragedNormal(cast(uint)i);
            normSum = normSum + ne;

            // In-plane inset direction for this edge: perpendicular to the
            // edge tangent and lying in the surface (perpendicular to ne).
            //   tangent t = normalize(pb - pa)
            //   inward    = normalize(cross(ne, t))   (in-surface, ⟂ to edge)
            Vec3 t = pb - pa;
            float tl = sqrt(t.x*t.x + t.y*t.y + t.z*t.z);
            if (tl > 1e-6f) {
                t = t / tl;
                Vec3 inward = cross(ne, t);
                float il = sqrt(inward.x*inward.x + inward.y*inward.y + inward.z*inward.z);
                if (il > 1e-6f) insetSum = insetSum + (inward / il);
            }
        }

        if (centN == 0) return;
        anchor = Vec3(centSum.x / centN, centSum.y / centN, centSum.z / centN);

        // Extrude axis = averaged normal; fall back to world +Y if degenerate.
        float nl = sqrt(normSum.x*normSum.x + normSum.y*normSum.y + normSum.z*normSum.z);
        extrudeAxis = (nl > 1e-6f) ? (normSum / nl) : Vec3(0, 1, 0);

        // Width axis = averaged in-plane inset; orthogonalize against the
        // extrude axis and fall back to any perpendicular if degenerate (e.g.
        // per-edge inward dirs cancelled out on a closed loop).
        Vec3 w = insetSum - extrudeAxis * dot(insetSum, extrudeAxis);
        float wl = sqrt(w.x*w.x + w.y*w.y + w.z*w.z);
        if (wl > 1e-6f) {
            widthAxis = w / wl;
        } else {
            // Any vector perpendicular to extrudeAxis.
            Vec3 tmp = (abs(extrudeAxis.x) < 0.9f) ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
            Vec3 perp = cross(extrudeAxis, tmp);
            float pl = sqrt(perp.x*perp.x + perp.y*perp.y + perp.z*perp.z);
            widthAxis = (pl > 1e-6f) ? (perp / pl) : Vec3(1, 0, 0);
        }
        gizmoValid = true;
    }

    // Averaged normal of the 1–2 faces adjacent to edge `ei` — the same notion
    // the kernel's per-edge `ne` uses for the ridge-lift direction.
    Vec3 edgeAveragedNormal(uint ei) {
        Vec3 sum = Vec3(0, 0, 0);
        size_t n = 0;
        foreach (fi; mesh.facesAroundEdge(ei)) {
            sum = sum + mesh.faceNormal(fi);
            ++n;
        }
        if (n == 0) return Vec3(0, 1, 0);
        float l = sqrt(sum.x*sum.x + sum.y*sum.y + sum.z*sum.z);
        return (l > 1e-6f) ? (sum / l) : Vec3(0, 1, 0);
    }
}
