module tests.unit.falloff_screen_default_test;

// The Screen falloff's default radius, and the fact that its TWO declarations
// agree (task 5514).
//
// 20 is not a number of ours: the reference's Screen-falloff reset writes
// `size = 20` as the instruction's own immediate, read from the stream rather
// than inferred from a read-back (`doc/measured_laws.md` §18). Both sides count
// WINDOW PIXELS — ours says so at `toolpipe/stages/falloff.d`'s units note, and
// the reference's drag arm advances one unit per pixel — so the two numbers are
// comparable and this one matches. Our previous default was 64, recorded as gap
// registry row 105 before it was closed.
//
// THE HALF THAT IS WORTH MORE THAN THE NUMBER. The default is declared TWICE —
// once as the struct field `FalloffConfig.screenSize` (which `reset()` restores
// through `config = FalloffConfig.init`) and once as the `Param.float_` default
// in the Screen arm of `params()` (which a form reset reads). Nothing else in
// the tree compares them, so they can drift apart and the two reset paths then
// disagree silently: a scene reset would give one radius and a panel reset
// another. That is what the second assertion is for; the literal below is only
// the anchor it needs.
//
// Mutation that must redden it: change either declaration alone. Changing both
// to the same wrong value reddens the first assertion instead, which is why
// both are here.

import toolpipe.packets       : FalloffConfig, FalloffType;
import toolpipe.stages.falloff : FalloffStage;
import params                 : Param;

import std.conv : to;

unittest {
    // The reset path: `reset()` assigns `FalloffConfig.init` wholesale.
    assert(FalloffConfig.init.screenSize == 20.0f,
        "falloff screen default: FalloffConfig.init.screenSize must be 20 " ~
        "(measured_laws §18, the reference's reset immediate), got " ~
        FalloffConfig.init.screenSize.to!string);

    // The schema path, and the drift guard between the two.
    auto stage = new FalloffStage();
    stage.config.type = FalloffType.Screen;
    auto ps = stage.params();

    size_t seen;
    float declared = float.nan;
    foreach (ref p; ps) {
        if (p.name != "screenSize") continue;
        ++seen;
        declared = p.default_.f;
    }

    // POPULATION FLOOR. Without this the loop above is satisfied by a param
    // list that never mentions `screenSize` at all — renamed, moved to another
    // arm, or dropped — and the comparison below would never run while the
    // block still passed honestly.
    assert(seen == 1,
        "falloff screen default: the Screen param schema must declare exactly " ~
        "one `screenSize` entry for this test to mean anything");

    assert(declared == FalloffConfig.init.screenSize,
        "falloff screen default: the schema default and the struct default " ~
        "must agree — a scene reset and a panel reset would otherwise hand " ~
        "the user two different radii");
}
