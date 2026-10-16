module vibe3d.editing.tools.interactive.tool_disarm_source_cells;


import vibe3d.editing.tools.interactive.tool_disarm;

unittest {
    // Uninstalled: a no-op that reports nothing, and CLEARS a stale record.
    g_lastDisarm = DisarmOutcome(true, 3, true, DisarmMode.cancelAndDrop);
    g_disarmActiveTool = null;
    auto before = g_disarmCrossings;
    auto r = disarmActiveToolBeforeDocumentReplace(DisarmMode.cancelAndDrop);
    assert(!r.hadTool && r.cancelSteps == 0 && !r.stillArmed,
        "an uninstalled disarm hook must report the empty outcome");
    assert(!g_lastDisarm.hadTool && !g_lastDisarm.stillArmed,
        "an uninstalled crossing must overwrite the previous record, not keep "
        ~ "it — a stale `stillArmed:true` read as fresh is a false alarm and a "
        ~ "stale `false` hides a real one");
    assert(g_disarmCrossings == before + 1,
        "an uninstalled hook is still a seam crossing");
}

unittest {
    // A gesture that cancels in one step: recorded as one step, not armed.
    bool armed = true;
    g_disarmActiveTool = (DisarmMode) {
        DisarmOutcome o;
        o.hadTool = true;
        while (armed && o.cancelSteps < kMaxDisarmSteps) {
            armed = false;           // one-shot cancel
            ++o.cancelSteps;
        }
        o.stillArmed = armed;
        return o;
    };
    auto r = disarmActiveToolBeforeDocumentReplace(DisarmMode.cancelAndDrop);
    import std.conv : to;
    assert(r.hadTool, "hadTool must be reported");
    assert(r.cancelSteps == 1,
        "a one-shot cancel is one step, got " ~ r.cancelSteps.to!string);
    assert(!r.stillArmed, "a one-shot cancel must leave the tool disarmed");
    g_disarmActiveTool = null;
}

unittest {
    // THE CAP IS REAL, and this is the cell that shows it: a tool whose cancel
    // NEVER clears must not spin. Without the `< kMaxDisarmSteps` term this
    // loop does not terminate, which is why the assertion is on the exact cap
    // rather than on "some bound".
    g_disarmActiveTool = (DisarmMode) {
        DisarmOutcome o;
        o.hadTool = true;
        bool armed = true;
        while (armed && o.cancelSteps < kMaxDisarmSteps)
            ++o.cancelSteps;         // cancel that clears nothing
        o.stillArmed = armed;
        return o;
    };
    auto r = disarmActiveToolBeforeDocumentReplace(DisarmMode.cancelAndDrop);
    assert(r.cancelSteps == kMaxDisarmSteps,
        "a cancel that never clears must stop AT the cap");
    assert(r.stillArmed,
        "and must report stillArmed, so layer 2's failure is visible rather "
        ~ "than silently assumed to have held");
    g_disarmActiveTool = null;
}

unittest {
    // A live edit is the population floor: without it, zero cancel calls says
    // only that there was nothing for dropOnly to preserve.
    bool armed = true;
    int cancelSteps;
    g_disarmActiveTool = (DisarmMode mode) {
        DisarmOutcome o;
        o.hadTool = true;
        assert(armed, "the drop-only fixture must start with a live edit");
        if (mode == DisarmMode.cancelAndDrop) {
            armed = false;
            ++cancelSteps;
        }
        o.cancelSteps = cancelSteps;
        o.stillArmed = armed;
        return o;
    };
    assert(armed, "the drop-only fixture must arm a live edit");
    auto r = dropActiveToolBeforePrimaryMove();
    import std.conv : to;
    assert(r.hadTool, "a drop-only crossing must report the active tool");
    assert(r.cancelSteps == 0,
        "a drop-only crossing must make zero cancel calls, got "
        ~ r.cancelSteps.to!string);
    assert(r.mode == DisarmMode.dropOnly,
        "the recorded crossing must retain its requested mode");
    g_disarmActiveTool = null;
}
