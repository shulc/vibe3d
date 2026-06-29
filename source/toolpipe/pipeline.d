module toolpipe.pipeline;

import std.algorithm : sort, remove, SwapStrategy;
import std.array     : array;
import std.conv      : to;

import math : Viewport;
import toolpipe.stage   : Stage, TaskCode;
import toolpipe.packets : SubjectPacket, ActionCenterPacket, AxisPacket,
                          WorkplanePacket, FalloffPacket, SymmetryPacket,
                          SnapPacket, ConstrainPacket;
import operator : Operator, Task, VectorStack, PacketKind;
import perf_probe : g_perf, Cat;

// ---------------------------------------------------------------------------
// Pipeline — ordered list of Stages with dispatch.
//
// Stages are registered with `add()`, which inserts in ordinal order.
// `evaluate()` walks enabled stages low → high, threading a single
// ToolState through every one. `findByTask()` lets callers swap the
// active stage in a task slot ("single stage per task": replacing the
// active Action Center, Falloff, etc. swaps it in the same slot).
//
// Stage ownership: the Pipeline holds references; classes/structs
// elsewhere in the program may also keep references for property-panel
// editing. Lifetime: the pipeline outlives all stages registered to it
// (constructed once at app init, torn down on exit).
// ---------------------------------------------------------------------------
struct Pipeline {
private:
    Stage[] stages_;

    // VectorStack-side dispatch storage. Slot-as-list: most slots hold
    // 0 or 1 operators today, but WGHT can stack (Phase 8 Mix Mode).
    // Lives in parallel with `stages_` until Phase 6 cleanup; Phase 1
    // wires Stages into both lists via adapter methods.
    Operator[][Task.max + 1] operators_;

public:
    /// Insert `s` at the position determined by its ordinal. If a stage
    /// with the same TaskCode already exists, it is REPLACED — single-
    /// slot-per-task constraint (swap, not stack).
    ///
    /// Phase 1 of doc/operator_refactor_plan.md: when `s` also implements
    /// the Operator interface (every Stage subclass post-Phase-1 does),
    /// auto-plug it into the slot-list so the new `evaluate(VectorStack)`
    /// path stays in sync with the legacy `evaluate(SubjectPacket, Viewport)`
    /// path. No-op for the legacy NopStage / future Stages that don't
    /// implement Operator.
    void add(Stage s) {
        // Replace same-task slot if present.
        foreach (i, ref existing; stages_) {
            if (existing.taskCode() == s.taskCode()) {
                // Unplug the previous Operator side too if it had one.
                if (auto prevOp = cast(Operator)existing) unplug(prevOp);
                stages_[i] = s;
                stages_.sort!((a, b) => a.ordinal() < b.ordinal());
                if (auto op = cast(Operator)s) plug(op, /*replace=*/true);
                return;
            }
        }
        stages_ ~= s;
        stages_.sort!((a, b) => a.ordinal() < b.ordinal());
        if (auto op = cast(Operator)s) plug(op, /*replace=*/true);
    }

    /// Register an ADDITIONAL stage of an existing task WITHOUT replacing
    /// the same-task stage already present — the stacking counterpart to
    /// `add()`'s single-slot-per-task replace semantics. Use this for the
    /// second-and-beyond instances of a stackable task (today only Wght /
    /// falloff stacks); `add()` stays the single/primary path that callers
    /// like the pulldown and `*.<type>` commands target.
    ///
    /// Each stacked instance MUST carry a UNIQUE `id()` so `findById` can
    /// resolve it — `findByTask` keeps returning the FIRST (primary) for
    /// backward compat, while `findAllByTask` yields every instance.
    ///
    /// `s` is appended to `stages_` and the list re-sorted by ordinal.
    /// The sort is STABLE, so same-ordinal same-task instances keep their
    /// insertion order (deterministic pipeline order). When `s` also
    /// implements Operator it is APPENDED to its task slot (`plug` with
    /// `replace=false`) — the slot-list keeps every plugged operator so
    /// `evaluate(VectorStack)` walks all stacked instances in order.
    void addStacked(Stage s) {
        stages_ ~= s;
        // STABLE so same-ordinal same-task instances keep insertion order
        // (the primary, added first, stays ahead of later-stacked extras).
        stages_.sort!((a, b) => a.ordinal() < b.ordinal(), SwapStrategy.stable);
        if (auto op = cast(Operator)s) plug(op, /*replace=*/false);
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

    /// Return EVERY registered stage with the given task, in pipeline
    /// (ordinal) order. The stacking counterpart to `findByTask` (which
    /// returns only the first / primary): callers that must iterate all
    /// stacked instances of a task (e.g. a future weight combiner walking
    /// every falloff contributor) use this. With the single/primary path
    /// only one stage per task is registered, so this yields a 1-element
    /// slice equivalent to `[findByTask(task)]`.
    Stage[] findAllByTask(TaskCode task) {
        Stage[] hits;
        foreach (s; stages_)
            if (s.taskCode() == task)
                hits ~= s;
        return hits;
    }

    /// Return the stage with the given `id()` (e.g. "falloff",
    /// "actionCenter", "snap", "symmetry"), or null. Used by the
    /// tool-preset loader to apply attrs by stage name, mirroring
    /// the `tool.pipe.attr <stageId> ...` HTTP wire format.
    ///
    /// Returns the FIRST id match. Stacked same-task instances (added via
    /// `addStacked`) must therefore each carry a UNIQUE `id()` to be
    /// addressable here (the primary keeps the bare id, e.g. "falloff").
    Stage findById(string id) {
        foreach (s; stages_)
            if (s.id() == id)
                return s;
        return null;
    }

    /// Read-only view of the registered stages, in pipeline order.
    const(Stage)[] all() const {
        return stages_;
    }

    /// Mutable view of the registered stages — used by SceneReset to
    /// call `reset()` on every stage in one pass without going through
    /// per-TaskCode lookups.
    Stage[] allMut() {
        return stages_;
    }

    /// VectorStack-based evaluation. Slot-chain dispatch: for every
    /// Task slot in declaration order, walk the operators
    /// plugged into that slot and call `Operator.evaluate(vts)`. Operators
    /// publish their packets into `vts.put()`; downstream operators read
    /// them via `vts.get()`.
    ///
    /// Slot-as-list: each slot holds a `[]` of operators, so WGHT can
    /// stack multiple FalloffStages with Mix Mode (Phase 8 of
    /// doc/operator_refactor_plan.md). Other slots typically hold one
    /// operator but the list shape is uniform.
    void evaluate(ref VectorStack vts) {
        // Perf: time the whole pipeline pass, then each stage by its slot.
        // No-op in the default build (g_perf.scope_ → empty struct).
        auto zTotal = g_perf.scope_(Cat.pipeTotal);
        // Iterate slots in declared Task order: Work → Symm → Snap →
        // Acen → Axis → Wght → Actr. static foreach so the dispatch
        // unrolls to seven straight-line array walks; no runtime
        // overhead beyond the array bounds check.
        static foreach (member; __traits(allMembers, Task)) {{
            enum Task slot = __traits(getMember, Task, member);
            auto slotOps = operators_[slot];
            // Map the slot to a perf category. Slots without a dedicated
            // bucket (Work, Actr) don't open a timer — Actr's mesh mutation
            // is timed separately in the kernels as Cat.kernelApply.
            enum hasCat = perfCatFor(slot) != -1;
            static if (hasCat)
                auto zStage = g_perf.scope_(cast(Cat)perfCatFor(slot));
            foreach (op; slotOps) {
                checkRequiredPackets(op, vts);
                op.evaluate(vts);
            }
        }}
    }

    // Compile-time Task → perf Cat map. Returns -1 for slots with no
    // dedicated timer category (Work, Wght-as-actor, Actr).
    private static int perfCatFor(Task slot) pure nothrow @nogc @safe {
        final switch (slot) {
            case Task.Work: return -1;
            case Task.Symm: return cast(int)Cat.pipeSymmetry;
            case Task.Snap: return cast(int)Cat.pipeSnap;
            case Task.Cons: return -1;
            case Task.Acen: return cast(int)Cat.pipeAcen;
            case Task.Axis: return cast(int)Cat.pipeAxis;
            case Task.Wght: return cast(int)Cat.pipeFalloff;
            case Task.Actr: return -1;
            case Task.Path: return -1;
        }
    }

    /// Diagnostic: confirm every PacketKind the operator declares in
    /// `requiredPackets()` is actually present in the VectorStack at the
    /// moment it runs — i.e. published by an earlier-order operator or
    /// supplied up front by the caller (the SubjectPacket is always
    /// caller-provided). A missing packet is NOT fatal: the operator is
    /// expected to null-check and degrade gracefully, so we warn and let
    /// it run. The check exists to surface ordering gaps and over-declared
    /// dependencies early.
    ///
    /// De-spam: the pipeline re-evaluates every drag frame, so an
    /// uncorrected gap would flood stderr. We fire at most once per
    /// (operator type, missing kind) pair via a process-wide warned set.
    /// A correctly-configured pipeline produces zero warnings, so the set
    /// stays empty in the steady state.
    private static void checkRequiredPackets(Operator op, ref const VectorStack vts) {
        import log : logWarnOnce;
        import std.format : format;
        foreach (kind; op.requiredPackets()) {
            if (vts.has(kind)) continue;
            const opName = typeid(op).name;
            const key = opName ~ "|" ~ kind.to!string;
            logWarnOnce("toolpipe", key, format(
                "WARNING: operator %s requires packet %s but " ~
                "no earlier operator produced it (and the caller did not " ~
                "supply it). Running anyway; operator must degrade gracefully.",
                opName, kind.to!string));
        }
    }

    /// Insert an Operator into its `task()` slot. When `replace=true`
    /// the slot is cleared first (single-operator semantics). When
    /// `replace=false` the operator is appended (Phase 8 Mix Mode
    /// stacking). `op.reset()` is called immediately after plug.
    void plug(Operator op, bool replace = false) {
        auto slot = op.task();
        if (replace) operators_[slot].length = 0;
        operators_[slot] ~= op;
        op.reset();
    }

    /// Remove an operator by reference identity. Returns true on hit.
    bool unplug(Operator op) {
        auto slot = op.task();
        foreach (i, existing; operators_[slot]) {
            if (existing is op) {
                operators_[slot] = operators_[slot].remove(i);
                return true;
            }
        }
        return false;
    }

    /// Read-only view of operators in a slot (in registration order).
    const(Operator)[] operatorsInSlot(Task slot) const {
        return operators_[slot];
    }

    /// Number of stages registered (regardless of enabled state).
    size_t length() const { return stages_.length; }
}

// ---------------------------------------------------------------------------
// ToolPipeContext — per-app singleton holding the active Pipeline.
// Tools access the pipe via the global `g_pipeCtx` pointer, set at app
// startup. Callers build a VectorStack with a SubjectPacket, call
// `g_pipeCtx.pipeline.evaluate(vts)`, then read upstream packets via
// `vts.get!T()`.
// ---------------------------------------------------------------------------
final class ToolPipeContext {
    Pipeline pipeline;
}

__gshared ToolPipeContext g_pipeCtx;
