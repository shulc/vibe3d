module tools.edit.topology_pen;

import bindbc.sdl;
import std.json : JSONValue;

import tool;
import mesh                : Mesh, GpuMesh;
import math               : Vec3, Viewport, projectToWindowFull;
import shader              : Shader;
import operator            : VectorStack;
import toolpipe.packets    : ConstrainHitPacket, HoverTarget, HoverTargetKind,
                             SubjectPacket;
import toolpipe.pipeline   : g_pipeCtx;
import toolpipe.stage      : TaskCode;
import toolpipe.stages.constrain : ConstrainStage;
import constraint           : resolveHoverTarget, kTopoPenSnapPx;
import viewcache            : VertexCache, EdgeCache, FaceBoundsCache;
import command_history      : CommandHistory;
import commands.mesh.vertex_new : MeshVertexNew;
import display_sync         : refreshDisplay;

import ImGui = d_imgui;
import d_imgui.imgui_h;

/// Factory the tool calls PER CLICK to obtain a fresh, primary-bound
/// `MeshVertexNew` (P2, doc/topopen_p2_plan.md REV-1) — mirrors
/// `tools.create.vertex_place`'s `VertexEditFactory` alias shape. Binding
/// happens at CALL time (`() => new MeshVertexNew(&mesh(), ...)` at the
/// registration.d wiring site), so each click's command targets whichever
/// layer is primary AT THAT MOMENT.
alias VertexNewFactory = MeshVertexNew delegate();

// ---------------------------------------------------------------------------
// TopologyPenTool — Phases P0 + P1 + P2 of the topology-pen port (factory id
// `mesh.topoPen`, doc/topopen_p0_plan.md, doc/topopen_p1_plan.md,
// doc/topopen_p2_plan.md).
//
// LAYERED like the reference editor (owner hard rule #1): the background-
// surface constraint (Point-mode nearest-foot magnet, Screen-mode
// camera-ray) lives ENTIRELY in the mesh-CONSTRAINT toolpipe stage
// (ConstrainStage's mode-dispatched branches, source/toolpipe/stages/
// constrain.d, reusing the existing BvhPick — source/bvh_pick.d — for
// Screen mode and `constraint.closestPointOnMeshes` for Point mode), and
// the hover snap-target RESOLUTION lives ENTIRELY in the constraint
// (pure-math) layer (`resolveHoverTarget`, source/constraint.d — P1,
// review REV-A). This tool is a THIN CONSUMER of both: it does NOT
// raycast, does NOT touch BvhPick or `closestPointOnMeshes` directly, does
// NOT resolve a snap target inline (it only CALLS `resolveHoverTarget`),
// and mutates the mesh ONLY through the `mesh.addVertex` command
// (`MeshVertexNew`, P2) — never a direct `mesh.addVertex` call of its own.
// P0 shipped the raycast plumbing; P1 added hover-preview rendering + the
// resolved target exposed over `toolStateJson()`; P2 adds the actual
// placement: a click with a hit creates ONE vertex in the PRIMARY layer at
// `ConstrainHitPacket.point` (now the corrected nearest-foot point under
// Point mode). Polygon/strip building from a chain of placed verts is a
// later phase (P3, doc/topopen_p2_plan.md §Extension).
//
// Lifecycle:
//   activate()   — composes CONS (enabled + geometry=Point) via the
//                  stage's own setAttr, mirroring how a preset composes an
//                  ancillary pipe stage. Since ConstrainStage.onParamChanged
//                  no longer locks on every write (review fix SF), this
//                  setAttr call is ALREADY transient by construction — no
//                  unlock dance needed. Critically (review fix SF-1), this
//                  means activate() must NOT blindly clobber a pre-existing
//                  `userLocked`: when the user already explicitly enabled
//                  CONS (`constrain.toggle` or `tool.pipe.attr constrain
//                  enabled true`), that lock — and the user's own
//                  enabled/geometry choice — MUST survive this tool
//                  activating. So activate() only composes when CONS is
//                  NOT already user-locked; a locked CONS is left
//                  completely untouched (the tool still reads whatever hit
//                  packet the user's own config produces).
//                  `resetTransientPipeStages()` (app.d, called on every
//                  tool switch BEFORE the outgoing tool's deactivate())
//                  cleanly reverts the tool's OWN unlocked composition —
//                  mirroring ActionCenterStage / AxisStage's userLocked
//                  pattern — while a genuine user lock passes straight
//                  through both this activate() and that reset. No
//                  bespoke tool-local save/restore.
//   deactivate() — clears the tool's own cached hit/target only; CONS
//                  itself is already reverted by the funnel above by the
//                  time this runs (or immediately after, on the "toggle
//                  same tool off" path) — either way this tool never
//                  hand-rolls a CONS restore, and a user's prior lock was
//                  never touched in the first place.
//   onMouseMotion()/update() — read `vts.get!ConstrainHitPacket()` (the
//                  packet CONS published earlier in the SAME
//                  pipeline.evaluate() pass the dispatcher already ran)
//                  and cache it as `lastHit_`. The packet is present only
//                  when the dispatching `vts` carried a valid cursor
//                  (mouse-event dispatch — see SubjectPacket's doc
//                  comment); the per-frame render-loop's `update()` call
//                  always sees no packet, so a present→absent transition
//                  must NOT stomp the last real reading. When the packet
//                  IS present, also resolve `lastTarget_` from the SAME
//                  vts's `SubjectPacket.viewport` (P1) — CONS only
//                  publishes a hit when a SubjectPacket was present (its
//                  `evaluate()` requires it), so the viewport read here is
//                  exactly the one the hit was raycast against.
//   draw()       — P1: renders a hover-preview marker at `lastHit_.point`
//                  (orange dot + ring + short normal pin) and, when the
//                  hover resolves to a vertex/edge, a cyan highlight of
//                  that element — mirrors `snap_render.drawSnapOverlay`'s
//                  conventions. Re-resolves the target against THIS
//                  cell's `vp` (a multi-viewport draw may run once per
//                  eligible cell, each with its own camera) rather than
//                  reusing the motion-time `lastTarget_`, which stays the
//                  cached value `toolStateJson()` reports. No raycast, no
//                  mesh access, no mutation — every input comes from
//                  `lastHit_` (the packet) and the passed-in `vp`.
// ---------------------------------------------------------------------------
class TopologyPenTool : Tool {
private:
    ConstrainHitPacket lastHit_;
    HoverTarget         lastTarget_;

    // --- P2 placement deps (doc/topopen_p2_plan.md) — wired by
    // registration.d, mirroring VertexTool's ctor/setUndoBindings shape
    // (tools/create/vertex_place.d). All may be left unset (test/no-app
    // construction); `placeVertexAt` degrades to a no-op rather than
    // crashing when `addVertexFactory_` is null.
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() { return meshSrc_(); }
    GpuMesh*         gpu_;
    VertexCache*     vc_;
    EdgeCache*       ec_;
    FaceBoundsCache* fc_;

    CommandHistory    history_;
    VertexNewFactory  addVertexFactory_;

    void readHit(ref VectorStack vts) {
        if (auto p = vts.get!ConstrainHitPacket()) {
            lastHit_ = *p;
            Viewport vp;
            if (auto s = vts.get!SubjectPacket())
                vp = s.viewport;
            lastTarget_ = resolveHoverTarget(lastHit_, vp, kTopoPenSnapPx);
        }
        // else: leave lastHit_/lastTarget_ unchanged — see class doc (the
        // per-frame render-loop's vts never carries the packet; only a
        // real mouse event does).
    }

    // Project a world point to a foreground-drawlist pixel; false when
    // behind the camera (mirrors snap_render.d's private `project`).
    static bool projectPt(Vec3 world, const ref Viewport vp, out ImVec2 pt) {
        float sx, sy, ndcZ;
        if (!projectToWindowFull(world, vp, sx, sy, ndcZ)) return false;
        pt = ImVec2(sx, sy);
        return true;
    }

public:
    // Deps default-unset (matches the pre-P2 `new TopologyPenTool()`
    // registration site — every existing P0/P1 caller/test keeps working
    // unchanged); `setUndoBindings` supplies the placement path.
    this() {}

    this(Mesh* delegate() meshSrc, GpuMesh* gpu,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_ = meshSrc;
        this.gpu_     = gpu;
        this.vc_      = vc;
        this.ec_      = ec;
        this.fc_      = fc;
    }

    void setUndoBindings(CommandHistory h, VertexNewFactory f) {
        history_          = h;
        addVertexFactory_ = f;
    }

    override string name() const { return "Topology Pen"; }

    override void activate() {
        lastHit_    = ConstrainHitPacket.init;
        lastTarget_ = HoverTarget.init;
        if (g_pipeCtx is null) return;
        auto cs = cast(ConstrainStage) g_pipeCtx.pipeline.findByTask(TaskCode.Cons);
        if (cs is null) return;
        // SF-1: a pre-existing EXPLICIT user lock (constrain.toggle /
        // tool.pipe.attr constrain enabled true) must survive this tool
        // activating — do not touch CONS at all in that case, so neither
        // the user's enabled/geometry choice nor the lock itself is
        // clobbered. Only compose CONS+Point when it is NOT already
        // user-locked; that composition stays unlocked (CONS.onParamChanged
        // no longer locks — review fix SF), so resetTransientPipeStages()
        // cleanly reverts it on the next tool switch.
        if (cs.userLocked) return;
        cs.setAttr("enabled", "true");
        cs.setAttr("geometry", "point");
    }

    override void deactivate() {
        lastHit_    = ConstrainHitPacket.init;
        lastTarget_ = HoverTarget.init;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        readHit(vts);
        return false;   // never consumes — placement happens on button-down, not motion
    }

    override void update(ref VectorStack vts) {
        readHit(vts);
    }

    // P2 (doc/topopen_p2_plan.md): a plain LEFT click with a background hit
    // places ONE vertex in the primary layer at the (now nearest-foot-
    // corrected) hit point. Dispatched via app.d's general `if
    // (activeTool)` mouse-down block (app.d:6135-6136), which already ran
    // `buildToolVts(..., btn.x, btn.y, true)` -> `cursorValid=true` ->
    // pipeline.evaluate(vts) BEFORE calling here, so CONS has already
    // published this event's ConstrainHitPacket onto `vts` — `readHit`
    // below reads it fresh rather than trusting a possibly-stale
    // `lastHit_` from the last motion event.
    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e,
                                    ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & KMOD_ALT) return false;                  // camera orbit/pan/zoom
        // Reserved for later-phase pen gestures (Duplicate/Slide/Split —
        // behavior_from_docs.md §D); not handled yet, so don't consume.
        if (mods & (KMOD_CTRL | KMOD_SHIFT)) return false;

        readHit(vts);
        if (!lastHit_.hit) return true;   // claimed the click; no bg/degenerate seed -> place nothing

        placeVertexAt(lastHit_.point, vts);
        return true;
    }

    // Create one isolated vertex at `point` in the PRIMARY layer via the
    // `mesh.addVertex` command (P2 REV-1, doc/topopen_p2_plan.md): fires
    // the real `MeshVertexNew` through its Operator interface
    // (`cmd.evaluate(vts)`, using the TOOL's own vts so the command's
    // internal `SubjectPacket` guard is satisfied) and records it
    // POST-apply via `history_.record(cmd)` — no re-apply, one
    // non-coalescing undo entry per click (mirrors the precedent at
    // `tools/common/command_wrapper.d`'s `applyWithLivePipeline`, NOT
    // VertexTool's snapshot-diff path: `addVertexFactory_` binds `&mesh()`
    // = primary at CALL time, so the command targets whichever layer is
    // primary right now, and its own `MeshSnapshot`-based `revert()`
    // handles undo). Returns the new vertex's index (`-1` on a no-op —
    // missing factory or a rejected `evaluate`), for P3's chain-building to
    // reuse (doc/topopen_p2_plan.md §Extension); this tool itself does not
    // use the return value yet.
    private int placeVertexAt(Vec3 point, ref VectorStack vts) {
        if (addVertexFactory_ is null) return -1;

        auto cmd = addVertexFactory_();   // binds &mesh() = primary NOW
        cmd.setPos(point);
        if (!cmd.evaluate(vts)) return -1;

        // meshSrc_/gpu_/vc_/ec_/fc_ are wired together (registration.d) —
        // guard on meshSrc_ alone so a partially-constructed tool (e.g. the
        // no-arg ctor with only setUndoBindings called) never null-derefs.
        // Checked BEFORE history_.record (review NIT) — a partially-wired
        // tool that can't finish the view-side effects below (GPU upload,
        // selection sync, display refresh) shouldn't record an undo entry
        // either.
        if (meshSrc_ is null) return -1;

        if (history_ !is null) history_.record(cmd);   // non-coalescing -> one undo entry

        if (gpu_ !is null) gpu_.upload(*mesh);
        mesh.syncSelection();
        refreshDisplay(mesh, gpu_, vc_, ec_, fc_);

        return cast(int)(mesh.vertices.length - 1);
    }

    override void draw(const ref Shader shader, const ref Viewport vp,
                       ref VectorStack vts, bool visualOnly = false) {
        if (!lastHit_.hit) return;

        auto dl = ImGui.GetForegroundDrawList();

        // Re-resolve for THIS cell's camera — a multi-viewport draw may
        // run once per eligible cell, each with its own `vp`; the cached
        // `lastTarget_` (motion-time) stays what toolStateJson() reports.
        auto ht = resolveHoverTarget(lastHit_, vp, kTopoPenSnapPx);

        enum uint markerCol = IM_COL32(255, 150, 0, 230);   // pen orange
        enum uint cyan      = IM_COL32(0, 220, 255, 230);   // snap highlight

        ImVec2 hitPt;
        if (projectPt(lastHit_.point, vp, hitPt)) {
            // Hover marker: filled dot + ring ("free place-point" cursor).
            dl.AddCircleFilled(hitPt, 4.0f, markerCol, 16);
            dl.AddCircle(hitPt, 10.0f, markerCol, 24, 2.0f);

            // Normal pin — short line showing surface orientation.
            ImVec2 tip;
            if (projectPt(lastHit_.point + lastHit_.normal * 0.15f, vp, tip))
                dl.AddLine(hitPt, tip, markerCol, 2.0f);
        }

        final switch (ht.kind) {
            case HoverTargetKind.Vertex: {
                ImVec2 vpt;
                if (projectPt(lastHit_.nearestVertPos, vp, vpt))
                    dl.AddCircleFilled(vpt, 5.0f, cyan, 16);
                break;
            }
            case HoverTargetKind.Edge: {
                ImVec2 a, b;
                if (projectPt(lastHit_.nearestEdgeA, vp, a)
                 && projectPt(lastHit_.nearestEdgeB, vp, b))
                    dl.AddLine(a, b, cyan, 2.5f);
                break;
            }
            case HoverTargetKind.Face:
            case HoverTargetKind.None:
                break;   // marker only — no element to highlight
        }
    }

    // ----- Test-introspection (task 0234 pattern, GET /api/tool/state) ----
    override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]        = JSONValue("mesh.topoPen");
        root["hit"]         = JSONValue(lastHit_.hit);
        root["point"]       = JSONValue([cast(double)lastHit_.point.x,
                                          cast(double)lastHit_.point.y,
                                          cast(double)lastHit_.point.z]);
        root["normal"]      = JSONValue([cast(double)lastHit_.normal.x,
                                          cast(double)lastHit_.normal.y,
                                          cast(double)lastHit_.normal.z]);
        root["layer"]       = JSONValue(lastHit_.layer);
        root["face"]        = JSONValue(lastHit_.face);
        root["nearestVert"] = JSONValue(lastHit_.nearestVert);
        root["nearestEdge"] = JSONValue(lastHit_.nearestEdge);

        // P1 (doc/topopen_p1_plan.md): the resolved hover snap-target,
        // nested so the P0 root fields above stay intact for the existing
        // Tier-C test.
        auto hv = JSONValue.emptyObject;
        hv["hit"]    = JSONValue(lastHit_.hit);
        hv["point"]  = JSONValue([cast(double)lastHit_.point.x,
                                   cast(double)lastHit_.point.y,
                                   cast(double)lastHit_.point.z]);
        hv["normal"] = JSONValue([cast(double)lastHit_.normal.x,
                                   cast(double)lastHit_.normal.y,
                                   cast(double)lastHit_.normal.z]);
        string kindToken;
        final switch (lastTarget_.kind) {
            case HoverTargetKind.None:   kindToken = "none";   break;
            case HoverTargetKind.Vertex: kindToken = "vertex"; break;
            case HoverTargetKind.Edge:   kindToken = "edge";   break;
            case HoverTargetKind.Face:   kindToken = "face";   break;
        }
        hv["targetKind"] = JSONValue(kindToken);
        hv["targetVert"] = JSONValue(lastTarget_.vert);
        hv["targetEdge"] = JSONValue(lastTarget_.edge);
        root["hover"] = hv;

        return root;
    }
}
