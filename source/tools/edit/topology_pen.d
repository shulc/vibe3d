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
//   deactivate() — clears the tool's own cached hit only; CONS itself is
//                  already reverted by the funnel above by the time this
//                  runs (or immediately after, on the "toggle same tool
//                  off" path) — either way this tool never hand-rolls a
//                  CONS restore, and a user's prior lock was never touched
//                  in the first place.
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
