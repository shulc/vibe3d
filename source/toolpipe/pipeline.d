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
import perf_probe : g_perf, Cat, g_fc;

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

// ---------------------------------------------------------------------------
// Pipeline unit tests — registration invariant.
//
// Historically this section pinned "stages_ / operators_ must never
// diverge" — two parallel indexes (evaluate() walked one, every other query
// walked the other) that a removeStage/removeByTask bug could desync,
// leaving a zombie Operator plugged in and evaluated after its Stage was
// supposedly gone. `source/commands/falloff.d` used to work around exactly
// that by hand-calling `unplug()` before every `removeStage()` call.
//
// Task 0980 removed the second index outright (see `stages_`'s field doc):
// there is only one registration list now, so the two-structure divergence
// this block used to guard against cannot recur BY CONSTRUCTION. The tests
// below are kept as-is (they exercise the public add/addStacked/
// removeStage/removeByTask/operatorsInSlot contract, which is unchanged)
// and still pass — they now assert an invariant that holds trivially
// instead of one two structures had to be kept in sync to satisfy, which is
// the point: nothing here can drift again the way it did before.
// ---------------------------------------------------------------------------
version (unittest) {
    import toolpipe.stage : ordAcen, ordAxis, ordSnap, ordWght, ToolSwitchTransient;

    // Minimal Stage+Operator double, shaped like every concrete Stage
    // subclass (falloff/actcenter/axis/snap/symmetry/workplane/constrain/
    // path all implement `: Stage, Operator`), stripped to bare identity —
    // no real evaluate() behaviour is needed to exercise registration.
    private final class TestOpStage : Stage, Operator {
        TaskCode code_;
        Task     slot_;
        string   id_;
        ubyte    ord_;

        this(TaskCode code, Task slot, string id, ubyte ord) {
            code_ = code; slot_ = slot; id_ = id; ord_ = ord;
        }

        override TaskCode taskCode() const pure nothrow @nogc @safe { return code_; }
        override string   id()       const                          { return id_; }
        override ubyte    ordinal()  const pure nothrow @nogc @safe { return ord_; }

        Task         task()            const { return slot_; }
        PacketKind[] requiredPackets() const { return []; }
        bool         evaluate(ref VectorStack vts) { return true; }
        override void reset() {}
    }

    // How many times `op` appears in its own task-slot of `p`.
    private size_t slotCount(ref Pipeline p, Operator op) {
        size_t n;
        foreach (o; p.operatorsInSlot(op.task()))
            if (o is op) n++;
        return n;
    }
}

unittest {
    // add() plugs a fresh stage into its task slot.
    Pipeline p;
    auto a = new TestOpStage(TaskCode.Acen, Task.Acen, "a", ordAcen);
    p.add(a);
    assert(p.findByTask(TaskCode.Acen) is a);
    assert(slotCount(p, a) == 1);
}

unittest {
    // add() replacing a same-task stage unplugs the old Operator and
    // plugs the new one — no duplicate, no leak (this direction already
    // worked before the fix; verified here as the baseline the
    // removeStage/removeByTask tests below are held to).
    Pipeline p;
    auto a1 = new TestOpStage(TaskCode.Acen, Task.Acen, "a1", ordAcen);
    auto a2 = new TestOpStage(TaskCode.Acen, Task.Acen, "a2", ordAcen);
    p.add(a1);
    p.add(a2);
    assert(p.findByTask(TaskCode.Acen) is a2);
    assert(slotCount(p, a2) == 1);
    assert(slotCount(p, a1) == 0);
    assert(p.operatorsInSlot(Task.Acen).length == 1);
}

unittest {
    // removeStage() unplugs the Operator side. Regression test for the
    // bug this task fixes: it used to drop only the stages_ entry,
    // leaving a zombie Operator plugged into operators_.
    Pipeline p;
    auto a = new TestOpStage(TaskCode.Acen, Task.Acen, "a", ordAcen);
    p.add(a);
    assert(slotCount(p, a) == 1);
    assert(p.removeStage(a));
    assert(p.findByTask(TaskCode.Acen) is null);
    assert(slotCount(p, a) == 0);
    assert(p.operatorsInSlot(Task.Acen).length == 0);
}

unittest {
    // removeByTask() unplugs the Operator side — same class of bug as
    // removeStage, verified independently since it re-finds by TaskCode
    // rather than reference identity.
    Pipeline p;
    auto a = new TestOpStage(TaskCode.Axis, Task.Axis, "a", ordAxis);
    p.add(a);
    assert(slotCount(p, a) == 1);
    assert(p.removeByTask(TaskCode.Axis));
    assert(p.findByTask(TaskCode.Axis) is null);
    assert(slotCount(p, a) == 0);
    assert(p.operatorsInSlot(Task.Axis).length == 0);
}

unittest {
    // Full invariant over a mixed add/addStacked/removeStage/removeByTask
    // sequence across multiple task slots, including WGHT stacking (the
    // only slot that legitimately holds >1 operator today): every stage
    // still in stages_ that implements Operator is present in
    // operators_[its slot] exactly once; every removed one, nowhere.
    Pipeline p;

    auto acen  = new TestOpStage(TaskCode.Acen, Task.Acen, "acen",  ordAcen);
    auto axis  = new TestOpStage(TaskCode.Axis, Task.Axis, "axis",  ordAxis);
    auto wght0 = new TestOpStage(TaskCode.Wght, Task.Wght, "wght0", ordWght);
    auto wght1 = new TestOpStage(TaskCode.Wght, Task.Wght, "wght1", ordWght);
    auto wght2 = new TestOpStage(TaskCode.Wght, Task.Wght, "wght2", ordWght);
    auto snap  = new TestOpStage(TaskCode.Snap, Task.Snap, "snap",  ordSnap);

    p.add(acen);
    p.add(axis);
    p.add(wght0);          // primary falloff slot
    p.addStacked(wght1);   // stacked extra #1
    p.addStacked(wght2);   // stacked extra #2
    p.add(snap);

    // Retire one stage through each of the three removal paths.
    assert(p.removeStage(wght1));          // by-reference, mid-stack
    assert(p.removeByTask(TaskCode.Snap)); // by-task, single-occupant slot
    auto axisReplacement = new TestOpStage(TaskCode.Axis, Task.Axis, "axis2", ordAxis);
    p.add(axisReplacement);                // add()'s own replace path

    // ---- Invariant: every stage still in stages_ that implements
    // Operator is in operators_[its slot] exactly once. ----
    foreach (s; p.allMut()) {
        auto op = cast(Operator)s;
        if (op is null) continue; // no non-Operator Stage in this test
        assert(slotCount(p, op) == 1,
            "live stage " ~ s.id() ~ " must appear exactly once");
    }

    // ---- Invariant: every removed stage is nowhere in operators_. ----
    assert(slotCount(p, wght1) == 0);
    assert(slotCount(p, snap)  == 0);
    assert(slotCount(p, axis)  == 0); // superseded by axisReplacement via add()

    // ---- Shape sanity: Wght slot still stacks the two survivors in
    // insertion order; Acen/Axis stay single-occupant. ----
    assert(p.operatorsInSlot(Task.Wght).length == 2);
    assert(p.operatorsInSlot(Task.Wght)[0] is wght0);
    assert(p.operatorsInSlot(Task.Wght)[1] is wght2);
    assert(p.operatorsInSlot(Task.Acen).length == 1);
    assert(p.operatorsInSlot(Task.Axis).length == 1);
    assert(p.operatorsInSlot(Task.Axis)[0] is axisReplacement);
    assert(p.operatorsInSlot(Task.Snap).length == 0);

    // stages_ agrees: 4 live stages (acen, axisReplacement, wght0, wght2).
    assert(p.length() == 4);
}

// ---------------------------------------------------------------------------
// resetToolSwitchTransientStages — task 0980 / audit-4 P7 reset-switch fix.
//
// app.d's resetTransientPipeStages() used to be a hand-written
// `switch (s.id())` naming exactly three literals ("actionCenter" / "axis" /
// "constrain") plus a separate `s.taskCode() == TaskCode.Wght` branch for
// falloff — four special cases for four stages, with no way to tell "no
// case matches because this stage genuinely persists across tool switches
// (Snap/Symmetry/Workplane/Path)" apart from "no case matches because this
// is a NEW tool-driven stage nobody wired a case for yet". Both looked
// identical: silence.
//
// The test below proves the replacement fixes exactly that gap, with both
// halves of the comparison live: a stage that implements
// `ToolSwitchTransient` under an id/taskCode NONE of the four old special
// cases would have matched is (a) reached by the new
// `resetToolSwitchTransientStages` and (b) NOT reached by the old switch,
// reproduced verbatim as a negative control.
// ---------------------------------------------------------------------------
unittest {
    final class NewToolDrivenStage : Stage, Operator, ToolSwitchTransient {
        bool userLocked;
        bool resetTransientCalled;
        bool fullResetCalled;

        override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Cont; }
        override string   id()       const                          { return "somethingNew"; }
        override ubyte    ordinal()  const pure nothrow @nogc @safe { return 0x50; }

        Task         task()            const { return Task.Symm; } // any non-Wght slot
        PacketKind[] requiredPackets() const { return []; }
        bool         evaluate(ref VectorStack vts) { return true; }
        override void reset() { fullResetCalled = true; }

        // Same contract every real implementor (ActionCenter/Axis/
        // Constrain/Falloff) uses: skip when explicitly locked, else defer
        // to the ordinary reset().
        void resetTransient() {
            resetTransientCalled = true;
            if (userLocked) return;
            reset();
        }
    }

    Pipeline p;
    auto s = new NewToolDrivenStage();
    p.add(s);

    // ---- Positive: the NEW generic walk reaches it. ----
    resetToolSwitchTransientStages(p);
    assert(s.resetTransientCalled,
        "resetToolSwitchTransientStages must reach every ToolSwitchTransient "
        ~ "stage regardless of id()/taskCode(), not just the ones an old "
        ~ "hand-written switch happened to name");
    assert(s.fullResetCalled, "userLocked is false, so resetTransient() "
        ~ "must fall through to the ordinary reset()");

    // ---- Negative control: the OLD id()-keyed switch, reproduced exactly
    // (app.d's shape before this task, minus the separate Wght-taskCode
    // branch this stage doesn't use), does NOT recognise this stage. This
    // is the silent-skip defect task 0980 replaced.
    bool oldSwitchWouldHaveReset;
    switch (s.id()) {
        case "actionCenter": case "axis": case "constrain":
            oldSwitchWouldHaveReset = true;
            break;
        default: break;
    }
    assert(!oldSwitchWouldHaveReset,
        "negative control failed: the id()-keyed switch this task replaced "
        ~ "was NOT supposed to recognise an id it never named — if this "
        ~ "assert fires, the reproduction above no longer matches the bug");
}
