// Module unittests for `toolpipe.stages.constrain`, moved verbatim out of source/toolpipe/stages/constrain.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.toolpipe.stages.constrain_test;

import toolpipe.stage   : Stage, TaskCode, ordCons;
import toolpipe.packets : ConstrainPacket, ConstrainGeom, ConstrainHitPacket,
                          SubjectPacket;
import operator         : Operator, Task, VectorStack, PacketKind;
import popup_state      : setStatePath;
import params           : Param, IntEnumEntry, wireTagForValue;
import bvh_pick         : BvhPick, SurfaceHit;
import constraint        : BackgroundSource;
import toolpipe.stages.constrain;

// ---------------------------------------------------------------------------
// params() snapshot — module-level so `dub test --config=tests` runs it.
// A unittest in tests/ would be silently skipped (sourcePaths is "source/").
// ---------------------------------------------------------------------------
unittest {
    auto cs = new ConstrainStage();
    // Default: disabled → only the 'enabled' toggle is exposed.
    auto ps = cs.params();
    assert(ps.length == 1, "disabled: expected 1 param");
    assert(ps[0].name == "enabled", "disabled: first param must be 'enabled'");
    // Enabled → full 5 params visible.
    cs.enabled = true;
    ps = cs.params();
    assert(ps.length == 5, "enabled: expected 5 params");
    assert(ps[0].name == "enabled");
    assert(ps[1].name == "geometry");
    assert(ps[2].name == "offset");
    assert(ps[3].name == "handle");
    assert(ps[4].name == "dblSided");
}

// ---------------------------------------------------------------------------
// OBJ-4 (MANDATORY): knownAttrs() == fullParams() names. Constrain's derived
// knownAttrs() has ZERO coverage elsewhere — no `constrain` form exercises
// the forms-engine startup validator that reads it — so a future edit that
// silently un-derives it (reintroducing a hand literal, or forgetting to
// promote `fullParams()` back to `public override` after some refactor)
// would go undetected without this. It ALSO guards OBJ-5 directly: had
// `fullParams()` been left `private` (non-virtual), the base's `knownAttrs()`
// would dispatch to the BASE `fullParams()` (== `params()`, 1 attr while
// disabled) and this assert would fail with length 1 instead of 5.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;
    auto cs = new ConstrainStage();
    // Even while disabled (params() under-reports 1), knownAttrs() must
    // report the FULL 5-attr universe.
    auto known = cs.knownAttrs();
    auto full  = cs.fullParams();
    assert(known.length == full.length,
        "knownAttrs()/fullParams() length drift — OBJ-5 non-virtual trap?");
    foreach (i, n; known)
        assert(n == full[i].name, "knownAttrs()[" ~ i.to!string ~ "] != fullParams() name");
    assert(known == ["enabled", "geometry", "offset", "handle", "dblSided"]);
}
