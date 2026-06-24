// Pure tests for handle candidate collection in the shared handle arbiter.

import ai.interaction : AiCandidateKind;
import handler : Handler, ToolHandles;
import math : Viewport;

void main() {}

private class TestHandle : Handler {
    bool shouldHit;
    int hitCalls;

    this(bool shouldHit) {
        this.shouldHit = shouldHit;
    }

    override protected bool hitTest(int mx, int my, const ref Viewport vp) {
        ++hitCalls;
        return shouldHit;
    }
}

unittest { // first-hit winner is preserved while all hit candidates are exposed
    auto first = new TestHandle(true);
    auto miss = new TestHandle(false);
    auto later = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(first, 10);
    handles.add(miss, 20);
    handles.add(later, 30);
    handles.hot = 7;
    handles.captured = 8;

    int winner = handles.test(123, 456, vp);
    assert(winner == 10);
    assert(handles.hot == 7);
    assert(handles.captured == 8);
    assert(first.hitCalls == 1);
    assert(miss.hitCalls == 1);
    assert(later.hitCalls == 1);

    auto candidates = handles.handleCandidates();
    assert(candidates.length == 2);
    assert(candidates[0].id == "handle:10");
    assert(candidates[0].kind == AiCandidateKind.handle);
    assert(candidates[0].priorityFromCurrentRules == 0.0f);
    assert(candidates[0].isDefaultWinner);
    assert(candidates[0].hasScreenPosition);
    assert(candidates[0].screenPosition == [123.0f, 456.0f]);

    assert(candidates[1].id == "handle:30");
    assert(candidates[1].kind == AiCandidateKind.handle);
    assert(candidates[1].priorityFromCurrentRules == 2.0f);
    assert(!candidates[1].isDefaultWinner);
    assert(candidates[1].screenPosition == [123.0f, 456.0f]);
}

unittest { // invisible hits are skipped exactly like default arbitration
    auto hidden = new TestHandle(true);
    auto visible = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    hidden.setVisible(false);
    handles.begin();
    handles.add(hidden, 1);
    handles.add(visible, 2);

    assert(handles.test(10, 20, vp) == 2);
    assert(hidden.hitCalls == 0);
    assert(visible.hitCalls == 1);

    auto candidates = handles.handleCandidates();
    assert(candidates.length == 1);
    assert(candidates[0].id == "handle:2");
    assert(candidates[0].isDefaultWinner);
}
