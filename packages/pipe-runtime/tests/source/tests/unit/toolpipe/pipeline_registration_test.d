module tests.unit.toolpipe.pipeline_registration_test;

import toolpipe.pipeline : Pipeline, resetToolSwitchTransientStages;
import toolpipe.stage : Stage, TaskCode;
import vibe3d.editing.pipeline.contracts.operator : Operator, Task, VectorStack, PacketKind;

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
