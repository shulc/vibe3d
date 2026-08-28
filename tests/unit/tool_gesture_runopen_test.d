// tool_gesture_runopen_test — task 1905, lane G0-G1: the `runOpen` witness the
// HTTP plane fixture cannot be.
//
// WHAT IT PINS. `PrimitiveCreateTool.commitEdit` — the ONE record body nine
// create tools share — writes through `CommandHistory.record`, the primitive
// plan §3(B) calls `RecordMode.Plain`. `record` CONSOLIDATES an open run and
// leaves `_runOpen` false; `recordInSession` OPENS one and leaves it true. The
// two are one token apart at the call site, and swapping them changes the SHAPE
// of the history without changing anything a user or an HTTP client can see
// through the surfaces the G0-G1 fixture reads.
//
// WHY IT IS HERE AND NOT IN `tests/test_tool_gesture_g1.d`. Measured, not
// assumed: `grep -rn runOpen source/http_providers.d source/http_server.d` is
// EMPTY — `runOpen()` has no HTTP surface, so no fixture driven over the wire
// can read it. And the consequences that DO reach the wire do not separate the
// two branches: `record` and `recordInSession` both call `pushEntry` exactly
// once behind identical gates, so on a freshly-cleared stack the depth delta is
// +1 either way and every plane round-trips identically. Plan §5.4's row for
// this field says so in as many words, and it is why the row's "must stay
// green" column is `undoDelta` and every plane.
//
// THE MUTATION THIS CELL ANSWERS TO:
//     source/tools/create/primitive_create_tool.d, in `commitEdit`:
//         history.record(cmd);
//     ->  history.recordInSession(cmd, history.currentRunId);
// Expected: the `runOpen` assertion below reddens with its own message; the
// depth assertion beside it stays green; `tests/test_tool_gesture_g1.d` stays
// green on every plane and on `undoDelta`.
//
// THE POSITIVE CONTROL IS BLOCK 1 AND IT IS LOAD-BEARING. Block 2's assertion
// is `runOpen() == false`, and a `runOpen()` that could never answer `true` —
// an accessor over a field nobody sets, a `_runOpen` whose writers were removed
// — satisfies it for free, forever, under every mutation. So block 1 makes the
// SAME accessor answer `true` first, through the very primitive the mutation
// would substitute.
//
// THE PROBE CLASS EXISTS BECAUSE `commitEdit` IS `protected` AND EVERY LEAF IS
// `final`. `SphereTool`, `BoxTool` and the rest cannot be derived from, and
// `commitEdit` cannot be called from outside the hierarchy; a derived stub is
// the only way in. The stub supplies nothing but the abstract hooks —
// the body under test is production, untouched.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_gesture_runopen_test;

import command : Command;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import editmode : EditMode;
import math : Vec3;
import mesh : Mesh, GpuMesh;
import mesh_edit_delta : MeshEditScope;
import shader : LitShader;
import snapshot : MeshSnapshot;
import tools.create.primitive_create_tool : PrimitiveCreateTool;
import view : View;

/// The smallest concrete `PrimitiveCreateTool`: every abstract hook stubbed,
/// nothing overridden, and `commitEdit` — the production body — re-exposed so a
/// test can call it.
private final class ProbeCreateTool : PrimitiveCreateTool {
    private Vec3 c_;
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader lit) {
        super(meshSrc, gpu, lit);
    }
    protected override Vec3   center() const   { return c_; }
    protected override void   setCenter(Vec3 c){ c_ = c; }
    protected override bool   isIdle() const   { return false; }
    protected override bool   showHandles() const { return false; }
    protected override bool   willCommit() const  { return true; }
    protected override string commitLabel() const { return "Probe Create"; }
    protected override void   goIdle()            {}
    protected override void   buildInto(Mesh* dst){}
    override string name() const { return "probe.create"; }

    /// The single reason this class exists.
    void probeCommit(MeshSnapshot pre) { commitEdit(pre); }
}

private Mesh makeTri() {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(0, 0, 1));
    m.addFace([0u, 1u, 2u]);
    m.buildLoops();
    return m;
}

// ---------------------------------------------------------------------------
// 1. POSITIVE CONTROL — `runOpen()` can answer `true`.
//
//    Block 2 asserts it is `false` after a tool commit. A dead accessor pinned
//    at `false` satisfies that under every mutation, including the one this
//    file exists to catch. So drive the OTHER primitive first, on the same
//    history object, and require the same accessor to flip.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeTri();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();

    assert(!h.runOpen(),
        "control: a fresh CommandHistory reports an OPEN run — the accessor is "
      ~ "not reading the flag this file pins");

    auto run = h.nextRun();
    auto cmd = new MeshSessionEdit(&m, v, EditMode.Vertices,
                                   "probe.session_edit", "Probe",
                                   MeshEditScope.Geometry);
    auto pre = MeshSnapshot.capture(m);
    m.addVertex(Vec3(2, 0, 0));
    auto post = MeshSnapshot.capture(m);
    cmd.setSnapshots(pre, post, "Probe");
    h.recordInSession(cmd, run);

    assert(h.runOpen(),
        "CONTROL: `recordInSession` did NOT leave the run open. `runOpen()` "
      ~ "therefore cannot distinguish the two record primitives, and block 2's "
      ~ "`runOpen() == false` is satisfied by an accessor that can only ever "
      ~ "answer false — under the mutation as much as without it");
}

// ---------------------------------------------------------------------------
// 2. THE CELL. A create tool's commit goes through `record`, and `record`
//    leaves NO run open.
//
//    The depth assertion sits beside it deliberately: it is the field plan
//    §5.4's row predicts stays GREEN under the mutation, and having both in one
//    block is what lets a mutation run read the green half off the same output
//    as the red one. They are separate asserts, so the message names which.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeTri();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();

    auto t = new ProbeCreateTool(() => &m, null, null);
    t.setUndoBindings(h, () => new MeshSessionEdit(&m, v, EditMode.Vertices,
                                                  "probe.session_edit", "Probe",
                                                  MeshEditScope.Geometry));

    immutable size_t before = h.undoEntriesVisible().length;
    auto pre = MeshSnapshot.capture(m);
    assert(pre.filled,
        "the probe's pre-image is empty, so `commitEdit` takes its "
      ~ "`!pre.filled` early return and records NOTHING — every assertion "
      ~ "below would then be about a commit that did not happen");

    m.addVertex(Vec3(3, 0, 0));      // the "kernel": something to record
    m.buildLoops();
    t.probeCommit(pre);

    immutable size_t after = h.undoEntriesVisible().length;
    assert(after == before + 1,
        "the create funnel recorded " ~ (after - before).stringOf1
      ~ " entr(ies), expected exactly 1 — this is the field that must stay "
      ~ "GREEN when the record primitive is swapped, because `record` and "
      ~ "`recordInSession` both push exactly once");

    assert(!h.runOpen(),
        "after `PrimitiveCreateTool.commitEdit` the history still reports an "
      ~ "OPEN run. That is `recordInSession` (or `replaceInSessionTail`) at a "
      ~ "site whose contract is `record`: the next foreign record will be "
      ~ "CONSOLIDATED into this tool's run instead of standing as its own "
      ~ "entry, and nothing on the HTTP surface — not the stack depth, not the "
      ~ "wire names, not one plane of the mesh — says so");
}

/// `size_t` -> string without pulling `std.conv` into the assert expressions
/// above (the message is built even on the green path in a `-debug` build, so
/// keep it cheap and dependency-free).
private string stringOf1(size_t n) {
    import std.conv : to;
    return n.to!string;
}
