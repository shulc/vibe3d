module tools.edit.topology_pen;

import bindbc.sdl;
import std.json : JSONValue;

import tool;
import operator          : VectorStack;
import toolpipe.packets  : ConstrainHitPacket;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage    : TaskCode;
import toolpipe.stages.constrain : ConstrainStage;

// ---------------------------------------------------------------------------
// TopologyPenTool — Phase P0 of the topology-pen port (factory id
// `mesh.topoPen`, doc/topopen_p0_plan.md).
//
// LAYERED like the reference editor (owner hard rule #1): the background-
// surface raycast lives ENTIRELY in the mesh-CONSTRAINT toolpipe stage
// (ConstrainStage's raycast branch, source/toolpipe/stages/constrain.d,
// reusing the existing BvhPick — source/bvh_pick.d, no new module). This
// tool is a THIN CONSUMER of the packet CONS publishes — it does NOT
// raycast, does NOT touch BvhPick directly, and does NOT mutate the mesh.
// P0 ships the plumbing only; the actual pen/topology-drawing behaviour
// (placing verts/edges/faces from the hit) is a later phase.
//
// Lifecycle:
//   activate()   — enables CONS (geometry=Point) via the stage's own
//                  setAttr, mirroring how a preset composes an ancillary
//                  pipe stage. Leaves `ConstrainStage.userLocked` false
//                  (REV-2 of the plan): this is the TOOL's own transient
//                  composition, not an explicit user
//                  `tool.pipe.attr constrain ...` lock, so
//                  `resetTransientPipeStages()` (app.d, called on every
//                  tool switch BEFORE the outgoing tool's deactivate())
//                  cleanly reverts CONS to its pre-activation state —
//                  mirroring ActionCenterStage / AxisStage's userLocked
//                  pattern. No bespoke tool-local save/restore.
//   deactivate() — clears the tool's own cached hit only; CONS itself is
//                  already reverted by the funnel above by the time this
//                  runs (or immediately after, on the "toggle same tool
//                  off" path) — either way this tool never hand-rolls a
//                  CONS restore.
//   onMouseMotion()/update() — read `vts.get!ConstrainHitPacket()` (the
//                  packet CONS published earlier in the SAME
//                  pipeline.evaluate() pass the dispatcher already ran)
//                  and cache it as `lastHit_`. The packet is present only
//                  when the dispatching `vts` carried a valid cursor
//                  (mouse-event dispatch — see SubjectPacket's doc
//                  comment); the per-frame render-loop's `update()` call
//                  always sees no packet, so a present→absent transition
//                  must NOT stomp the last real reading.
// ---------------------------------------------------------------------------
class TopologyPenTool : Tool {
private:
    ConstrainHitPacket lastHit_;

    void readHit(ref VectorStack vts) {
        if (auto p = vts.get!ConstrainHitPacket())
            lastHit_ = *p;
        // else: leave lastHit_ unchanged — see class doc (the per-frame
        // render-loop's vts never carries the packet; only a real mouse
        // event does).
    }

public:
    override string name() const { return "Topology Pen"; }

    override void activate() {
        lastHit_ = ConstrainHitPacket.init;
        if (g_pipeCtx is null) return;
        auto cs = cast(ConstrainStage) g_pipeCtx.pipeline.findByTask(TaskCode.Cons);
        if (cs is null) return;
        cs.setAttr("enabled", "true");
        cs.setAttr("geometry", "point");
        // ORDER MATTERS: ConstrainStage.onParamChanged sets userLocked=true
        // on EVERY setAttr call (completing the field's pre-existing
        // "explicit user tool.pipe.attr" contract — the same public entry
        // point an HTTP `tool.pipe.attr constrain ...` call uses, so the
        // stage cannot tell the two apart AT setAttr time). This tool's
        // own composition is NOT that explicit user lock, so it must
        // un-lock AFTER its own setAttr calls, not before (setting it
        // false first would just get immediately overwritten back to true
        // by the first setAttr's onParamChanged) — this is what lets
        // resetTransientPipeStages() (REV-2) cleanly revert CONS when this
        // tool deactivates, while a genuine external
        // `tool.pipe.attr constrain ...` call still survives a tool switch.
        cs.userLocked = false;
    }

    override void deactivate() {
        lastHit_ = ConstrainHitPacket.init;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        readHit(vts);
        return false;   // never consumes the event — P0 places nothing yet
    }

    override void update(ref VectorStack vts) {
        readHit(vts);
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
        return root;
    }
}
