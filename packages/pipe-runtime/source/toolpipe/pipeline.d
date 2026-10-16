module toolpipe.pipeline;

import std.algorithm : sort, remove, SwapStrategy;
import std.array     : array;
import std.conv      : to;

import vibe3d.util.spatial.spatial : Viewport;
import toolpipe.stage   : Stage, TaskCode;
import vibe3d.editing.contracts.editmode : EditMode;
static import tool_policy_values = vibe3d.editing.contracts.tool_policy_values;
import toolpipe.packets : SubjectPacket, ActionCenterPacket, AxisPacket,
                          WorkplanePacket, FalloffPacket, SymmetryPacket,
                          SnapPacket, ConstrainPacket;
import operator : Operator, Task, VectorStack, PacketKind;
import vibe3d.util.profiling.perf_probe : g_perf, Cat, g_fc;

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
    // The single index over registered stages, sorted by ordinal (stable —
    // same-ordinal, same-task stacked instances keep insertion order). This
    // used to be ONE OF TWO parallel structures: `stages_` here plus a
    // Task-slot-indexed `Operator[][Task.max+1] operators_` that
    // `evaluate(VectorStack)` walked instead, in Task-enum DECLARATION
    // order rather than ordinal order (fast O(1)-by-slot dispatch, at the
    // cost of a second index every mutator had to keep in sync).
    //
    // Task 0980 (audit-4 P7) collapsed the two. The measured reason it was
    // SAFE: ordinal order and Task-declaration order agreed for every
    // registered stage except one pair — PathStage (ordinal 0x80) and
    // FalloffStage/WGHT (ordinal 0x90) — because PathStage's Task slot
    // (Task.Path = 8) was appended to the Task enum after AXIS/WGHT/ACTR,
    // while its ordinal was deliberately chosen to sit BETWEEN Axis (0x70)
    // and Wght (0x90) — see toolpipe/stages/path.d's own doc comment
    // ("Ordinal 0x80; evaluates between AXIS and WGHT"), which the old
    // Task-order walk silently contradicted (Path actually ran LAST, after
    // WGHT, not between AXIS and WGHT). Neither stage's evaluate() reads a
    // packet the other publishes (FalloffStage never calls
    // `vts.get!PathPacket`; PathStage's only declared required packet is
    // Subject, and it reads nothing else off `vts`), and neither mutates
    // shared state the other reads (both touch `Mesh` read-only), so the
    // two possible orders are provably indistinguishable for every input —
    // proven with the real production Operator bodies, not stand-ins, in
    // `tests/unit/toolpipe/pipeline_order_test.d`. `evaluate()` below now
    // walks `stages_` directly, in ordinal order — the order the field's
    // own name always claimed to mean, and the order path.d's comment
    // already assumed.
    Stage[] stages_;

public:
    /// Insert `s` at the position determined by its ordinal. If a stage
    /// with the same TaskCode already exists, it is REPLACED — single-
    /// slot-per-task constraint (swap, not stack).
    ///
    /// `op.reset()` is called on `s` when it implements Operator (every
    /// concrete Stage subclass does — only the test-only NopStage doesn't),
    /// mirroring the old plug-time reset (task 0980 folded `plug`/`unplug`
    /// away — `stages_` is the only registration index now, see this
    /// struct's field doc).
    void add(Stage s) {
        // Replace same-task slot if present.
        foreach (i, ref existing; stages_) {
            if (existing.taskCode() == s.taskCode()) {
                stages_[i] = s;
                stages_.sort!((a, b) => a.ordinal() < b.ordinal(), SwapStrategy.stable);
                if (auto op = cast(Operator)s) op.reset();
                return;
            }
        }
        stages_ ~= s;
        stages_.sort!((a, b) => a.ordinal() < b.ordinal(), SwapStrategy.stable);
        if (auto op = cast(Operator)s) op.reset();
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
    /// insertion order (deterministic pipeline order, and the order
    /// `evaluate(VectorStack)` walks them in).
    void addStacked(Stage s) {
        stages_ ~= s;
        // STABLE so same-ordinal same-task instances keep insertion order
        // (the primary, added first, stays ahead of later-stacked extras).
        stages_.sort!((a, b) => a.ordinal() < b.ordinal(), SwapStrategy.stable);
        if (auto op = cast(Operator)s) op.reset();
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

    /// H7 (tool session model, slice M6): whether some stage's rollover flag
    /// draws the hovered element of `type` (`Stage.rollovers`, OR-ed across
    /// the pipe as the flags of a tool's nodes are).
    bool rolloverDraws(EditMode type, bool dragging) const nothrow @nogc {
        foreach (s; stages_)
            if (tool_policy_values.rolloverDraws(s.rollovers(), type, dragging))
                return true;
        return false;
    }

    /// Return the stage currently in `task`'s slot, or null.
    Stage findByTask(TaskCode task) nothrow @nogc {
        foreach (s; stages_)
            if (s.taskCode() == task)
                return s;
        return null;
    }

    /// Allocation-free identity check used by prepared stage transitions.
    bool ownsTaskStage(TaskCode task, Stage expected) const nothrow @nogc {
        foreach (s; stages_)
            if (s.taskCode() == task)
                return s is expected;
        return expected is null;
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
    Stage[] allMut() nothrow @nogc {
        return stages_;
    }

    /// VectorStack-based evaluation. Walks `stages_` — ordinal order, low →
    /// high — and calls `Operator.evaluate(vts)` on every entry that
    /// implements Operator (skipping ones that don't, e.g. the test-only
    /// NopStage). Operators publish their packets into `vts.put()`;
    /// downstream operators (later in ordinal order) read them via
    /// `vts.get()`.
    ///
    /// Same-task stacking (WGHT can hold multiple FalloffStages for Mix
    /// Mode, Phase 8 of doc/operator_refactor_plan.md) falls out of
    /// `stages_` itself: `addStacked` appends and re-sorts with a STABLE
    /// sort, so same-ordinal stacked instances stay in insertion order and
    /// are walked in that order here — no separate per-slot list needed.
    void evaluate(ref VectorStack vts) {
        // Perf: time the whole pipeline pass, then each operator by its
        // Task's category. No-op in the default build (g_perf.scope_ →
        // empty struct).
        auto zTotal = g_perf.scope_(Cat.pipeTotal);
        // Perf (always-on): one pass, and the number of operators it actually
        // ran. `stageEvals` is the counter that would have caught a stage
        // evaluating every frame to publish a packet nobody reads — the
        // operator shows up in the count with no matching consumer-side work,
        // which a timer never surfaces because the stage itself is cheap.
        g_fc.bumpPipeEval();
        foreach (s; stages_) {
            auto op = cast(Operator)s;
            if (op is null) continue; // e.g. NopStage — registered, not an Operator
            // Map the operator's Task to a perf category. Slots without a
            // dedicated bucket (Work, Cons, Actr, Path) don't open a timer —
            // Actr's mesh mutation is timed separately in the kernels as
            // Cat.kernelApply.
            const cat = perfCatFor(op.task());
            if (cat != -1) {
                auto zStage = g_perf.scope_(cast(Cat)cat);
                checkRequiredPackets(op, vts);
                g_fc.bumpStageEval();
                op.evaluate(vts);
            } else {
                checkRequiredPackets(op, vts);
                g_fc.bumpStageEval();
                op.evaluate(vts);
            }
        }
    }

    // Task → perf Cat map. Returns -1 for slots with no dedicated timer
    // category (Work, Cons, Wght-as-actor, Actr, Path).
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
        import vibe3d.util.log.log : logWarnOnce;
        import std.format : format;
        foreach (kind; op.requiredPackets()) {
            if (vts.has(kind)) continue;
            // `typeid(op)` where `op`'s STATIC type is an interface
            // (`Operator`) returns the INTERFACE's own TypeInfo
            // ("operator.Operator") for every caller, not the concrete
            // stage's — a D trap distinct from the class case, where
            // `typeid` on a class-typed reference correctly dispatches to
            // the dynamic type (task 1904 Stage 6 measured this directly:
            // the de-spam key collapsed across ALL operator types sharing a
            // missing `kind`, so a second stage's warning silently rode the
            // first's already-consumed key, and the message never named the
            // real offender). Casting through `Object` first forces the
            // correct dynamic lookup.
            const opName = typeid(cast(Object) op).name;
            const key = opName ~ "|" ~ kind.to!string;
            logWarnOnce("toolpipe", key, format(
                "WARNING: operator %s requires packet %s but " ~
                "no earlier operator produced it (and the caller did not " ~
                "supply it). Running anyway; operator must degrade gracefully.",
                opName, kind.to!string));
        }
    }

    /// Read-only view of the operators registered in a Task slot, in
    /// pipeline (ordinal) order — derived from `stages_` by filtering on
    /// `op.task() == slot`, since task 0980 removed the separate
    /// Task-indexed `operators_` storage this used to read directly.
    const(Operator)[] operatorsInSlot(Task slot) const {
        Operator[] out_;
        foreach (s; stages_) {
            auto op = cast(Operator)s;
            if (op !is null && op.task() == slot) out_ ~= op;
        }
        return out_;
    }

    /// Number of stages registered (regardless of enabled state).
    size_t length() const { return stages_.length; }
}

/// Reset every stage in `p` that opts into "clear on tool switch unless the
/// user explicitly locked it" — i.e. implements `ToolSwitchTransient`
/// (toolpipe/stage.d; see that interface's doc for why this replaced a
/// hand-written switch on `s.id()`). Free function rather than a Pipeline
/// method so it is unit-testable without a running EditorApp — app.d's
/// `resetTransientPipeStages()` (tool.set / tool switch) is a one-line
/// caller (task 0980 / audit-4 P7).
void resetToolSwitchTransientStages(ref Pipeline p) {
    import toolpipe.stage : ToolSwitchTransient;
    foreach (s; p.allMut())
        if (auto r = cast(ToolSwitchTransient)s)
            r.resetTransient();
}

/// Record a user write against preset ownership. A locking displacement keeps
/// every other claimed stage as a user choice; a loose write only releases its
/// own claim (task 5911, witnessed by pipe_preset_claim_test U-c/U-f).
void noteUserStageChoice(ref Pipeline p, Stage target, bool locking) nothrow {
    import toolpipe.stage : PresetClaimable;
    auto chosen = cast(PresetClaimable)target;
    if (chosen is null) return;

    if (locking && chosen.presetClaimed()) {
        foreach (stage; p.allMut()) {
            if (stage is target) continue;
            if (auto sibling = cast(PresetClaimable)stage)
                if (sibling.presetClaimed())
                    sibling.promoteClaimToUserChoice();
        }
    }
    chosen.dropPresetClaim();
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
