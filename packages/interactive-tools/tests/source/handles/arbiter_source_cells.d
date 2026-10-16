module handles.arbiter_source_cells;

import handles.shapes;
import std.conv : to;
import std.format : format;
import vibe3d.util.profiling.perf_probe : g_fc;
import vibe3d.editing.interaction.data.ai.advisor : AiAdvisor;
import vibe3d.editing.interaction.data.ai.debug_trace : publishHandleDebugTrace;
import vibe3d.editing.interaction.data.ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiInteractionContext, AiInteractionPhase, AiIntent;
import math;
import vibe3d.util.spatial.spatial : Viewport;
import std.json : JSONValue;
import handles.arbiter;

version (unittest) {
    private class EngageProbeHandle : Handler {
        bool hits;
        this(bool hits) { this.hits = hits; }
        override protected bool hitTest(int mx, int my, const ref Viewport vp) {
            return hits;
        }
    }
}

unittest {
    Viewport vp;
    auto pool = new ToolHandles();
    auto hovered = new EngageProbeHandle(true);
    auto missed  = new EngageProbeHandle(false);

    pool.begin();
    pool.add(hovered, 7);
    pool.add(missed,  8);
    pool.update(0, 0, vp);

    // It won the hit test — the arbiter's hot part, and so Rollover...
    assert(pool.hot == 7);
    assert(hovered.getState() == HandleState.Rollover);
    // ...but nothing has grabbed it, so it keeps its own colour.
    assert(!hovered.isEngaged(), "hover must not engage a handle");
    assert(!missed.isEngaged());
}

unittest {
    Viewport vp;
    auto pool = new ToolHandles();
    auto grabbed = new EngageProbeHandle(false);   // pointer has moved off it
    auto other   = new EngageProbeHandle(true);    // and is now over this one

    pool.begin();
    pool.add(grabbed, 7);
    pool.add(other,   8);
    pool.setHaul(7);
    pool.update(0, 0, vp);

    // Capture sticks: the hauled handle stays hot even though the pointer has
    // wandered onto another one, and it is the handle that recolours.
    assert(pool.hot == 7);
    assert(grabbed.isEngaged(), "the captured handle must be engaged");
    assert(!other.isEngaged(),  "a handle under the pointer during someone "
                              ~ "else's haul must not engage");

    // Release clears it.
    pool.clearHaul();
    pool.update(0, 0, vp);
    assert(!grabbed.isEngaged());
    assert(!other.isEngaged());
}

unittest {
    Viewport vp;
    auto pool = new ToolHandles();
    auto h = new EngageProbeHandle(true);

    pool.begin();
    pool.add(h, 7);
    pool.setHaul(7);
    pool.suppress();
    pool.update(0, 0, vp);

    assert(h.getState() == HandleState.Normal);
    assert(!h.isEngaged(), "suppress() must clear the engaged bit");
}
