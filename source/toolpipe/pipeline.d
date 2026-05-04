module toolpipe.pipeline;

import std.algorithm : sort, remove;
import std.array     : array;

import math : Viewport;
import toolpipe.stage   : Stage, TaskCode;
import toolpipe.packets : SubjectPacket, ActionCenterPacket, AxisPacket,
                          WorkplanePacket, FalloffPacket, SymmetryPacket,
                          SnapPacket;

// ---------------------------------------------------------------------------
// ToolState — the in-flight value passed between Pipeline stages.
//
// Each stage may read upstream packets (filled by lower-ordinal stages
// already processed) and write its own packet. Final state is consumed
// by the actor stage at the end of the pipe (LXs_ORD_ACTR = 0xF0).
//
// Default-initialised values give an "identity pipe" — actor sees:
//   subject     : provided by pipeline.evaluate's caller
//   workplane   : world XZ plane (normal=+Y)
//   actionCenter: world origin
//   axis        : world axes
//   falloff     : weight = 1.0 for every vertex
//   symmetry    : disabled on every axis
//   snap        : applied = false (cursor passes through)
//
// Phase 7.0 populates `subject` only; later subphases register stages
// that fill the remaining packets.
// ---------------------------------------------------------------------------
struct ToolState {
    SubjectPacket      subject;
    Viewport           view;        // active 3D viewport at evaluation time
    WorkplanePacket    workplane;
    ActionCenterPacket actionCenter;
    AxisPacket         axis;
    FalloffPacket      falloff;
    SymmetryPacket     symmetry;
    SnapPacket         snap;
}

// ---------------------------------------------------------------------------
// Pipeline — ordered list of Stages with dispatch.
//
// Stages are registered with `add()`, which inserts in ordinal order.
// `evaluate()` walks enabled stages low → high, threading a single
// ToolState through every one. `findByTask()` lets callers swap the
// active stage in a task slot (matches MODO's "single stage per task"
// constraint described in tool_pipe.html: replacing the active Action
// Center, Falloff, etc. swaps it in the same slot).
//
// Stage ownership: the Pipeline holds references; classes/structs
// elsewhere in the program may also keep references for property-panel
// editing. Lifetime: the pipeline outlives all stages registered to it
// (constructed once at app init, torn down on exit).
// ---------------------------------------------------------------------------
struct Pipeline {
private:
    Stage[] stages_;

public:
    /// Insert `s` at the position determined by its ordinal. If a stage
    /// with the same TaskCode already exists, it is REPLACED — single-
    /// slot-per-task constraint matches MODO's UX (swap, not stack).
    void add(Stage s) {
        // Replace same-task slot if present.
        foreach (i, ref existing; stages_) {
            if (existing.taskCode() == s.taskCode()) {
                stages_[i] = s;
                stages_.sort!((a, b) => a.ordinal() < b.ordinal());
                return;
            }
        }
        stages_ ~= s;
        stages_.sort!((a, b) => a.ordinal() < b.ordinal());
    }

    /// Remove a stage (matched by reference identity). Returns true if
    /// found and removed.
    bool removeStage(Stage s) {
        foreach (i, existing; stages_) {
            if (existing is s) {
                stages_ = stages_.remove(i);
                return true;
            }
        }
        return false;
    }

    /// Remove the stage occupying `task`'s slot (if any).
    bool removeByTask(TaskCode task) {
        foreach (i, existing; stages_) {
            if (existing.taskCode() == task) {
                stages_ = stages_.remove(i);
                return true;
            }
        }
        return false;
    }

    /// Return the stage currently in `task`'s slot, or null.
    Stage findByTask(TaskCode task) {
        foreach (s; stages_)
            if (s.taskCode() == task)
                return s;
        return null;
    }

    /// Read-only view of the registered stages, in pipeline order.
    const(Stage)[] all() const {
        return stages_;
    }

    /// Walk enabled stages low → high and return the populated ToolState.
    /// Caller seeds `state.subject` (the pipeline's input) plus the active
    /// viewport (needed by stages that depend on the camera frame, e.g.
    /// the auto-mode workplane that runs `pickMostFacingPlane`); each
    /// stage then enriches the rest of the packet fields.
    ToolState evaluate(SubjectPacket subject, const ref Viewport view) {
        ToolState state;
        state.subject = subject;
        state.view    = view;
        foreach (s; stages_) {
            if (!s.enabled) continue;
            s.evaluate(state);
        }
        return state;
    }

    /// Number of stages registered (regardless of enabled state).
    size_t length() const { return stages_.length; }
}

// ---------------------------------------------------------------------------
// ToolPipeContext — per-app singleton holding the active Pipeline.
//
// Tools access the pipe via the global `g_pipeCtx` pointer, set at app
// startup. Phase 7.0 lays the type and global only; existing tools keep
// their hard-coded center / axis / plane logic until the relevant
// subphases (7.1 Workplane, 7.2 Action Center, etc.) wire them through
// the pipe.
// ---------------------------------------------------------------------------
final class ToolPipeContext {
    Pipeline pipeline;

    /// Convenience: run pipeline.evaluate. Cheap because most stages are
    /// no-ops at default settings.
    ToolState run(SubjectPacket subject, const ref Viewport view) {
        return pipeline.evaluate(subject, view);
    }
}

__gshared ToolPipeContext g_pipeCtx;
