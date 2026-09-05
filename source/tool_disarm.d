module tool_disarm;

// ---------------------------------------------------------------------------
// TASK 3130 — the seam a DOCUMENT-REPLACING command crosses before it throws
// the mesh away.
//
// THE DEFECT THIS EXISTS FOR, measured 2026-08-28 on a live `--test` instance.
//
//   `SceneReset.applyImpl` writes the new primitive INTO the surviving layer
//   (`*mesh = makeCube()`), and only 24 lines later fires `onResetTool()` →
//   `dropActiveTool(sceneResetDrop)` → the tool's `deactivate()`. For a session
//   tool `deactivate()` IS the commit point (slice_tool.d: "this is the ONLY
//   commit point (never mouse-up)"), so the dying gesture runs its kernel
//   against a mesh that is no longer the one it was armed on. Witnessed:
//
//     /api/reset                        -> v=8  e=12 f=6     (fresh cube)
//     tool.set mesh.mirrorTool
//     tool.attr mesh.mirrorTool distance 0.05     (engages the tool)
//     /api/reset                        -> v=8  e=12 f=12    <-- MIRRORED
//     /api/history  undo: [... "Mirror", "Reset to cube"]    <-- and recorded
//
//   The fresh cube came out of the reset already mirrored, with an undo entry
//   for an edit the user never confirmed, buried UNDER the reset's own entry.
//
// WHY IT IS WORSE THAN A WRONG SHAPE. `run_test.d` shares one `vibe3d --test`
// per worker, so this is DIRECTIONAL cross-test contamination: a stand that
// dies mid-gesture (i.e. a RED one) hands its successor a scene that is not
// the scene the successor asked for, and the successor fails for a reason that
// has nothing to do with what it tests. The first red manufactures a second
// red with a different cause. That is a signal which does not distinguish its
// own cause — the defect class this project pays for most.
//
// THE SEAM, AND ITS TWO LAYERS. Each layer carries a different guarantee and
// they are deliberately not merged:
//
//   LAYER 1 (UNCONDITIONAL, depends on NO per-tool code): the tool is DROPPED
//   while the mesh it was armed on is still under it. After this returns
//   there is no active tool, so no `deactivate()` can reach the replacement —
//   for any of the 35 tools that override `deactivate()`, including ones
//   written tomorrow. A tool whose gesture cannot be cancelled therefore
//   commits into the mesh it was actually built against (in-range by
//   construction, and discarded a moment later), instead of into the fresh
//   document.
//
//   LAYER 2 (PER-TOOL, depends on the documented session contract): before
//   that drop, the live gesture is CANCELLED, so the drop is SILENT — no
//   kernel run, no history entry. This rides `Tool.hasUncommittedEdit()` /
//   `cancelUncommittedEdit()` and their stated invariant (tool.d):
//   "hasUncommittedEdit() <=> a commit would fire if the tool's session ended
//   *right now*". A tool whose pair is unfaithful loses layer 2 and keeps
//   layer 1 — it gets a stray undo entry, never foreign geometry.
//
// WHY A DELEGATE INSTALLED BY app.d, and not a direct call. `activeTool` is
// `main()`-local state in app.d; a command module reaching it directly would
// invert the dependency the whole command layer is built to avoid. This is
// the same shape (and the same "uninstalled means no-op" contract) as
// `command.g_editTargetResolver`, which is the precedent it copies.
//
// Related: `source/tools/common/session_mesh_key.d` (task 2880) is the same
// family seen from the TOOL side — a per-tool witness that the mesh under a
// frozen gesture is still the mesh it was frozen against. That guard is a last
// line of defence for paths this seam does not cover; this seam removes the
// need for it on the reset path by making the tool gone before the swap.
// ---------------------------------------------------------------------------

/// How many `cancelUncommittedEdit()` calls the disarm will make before it
/// gives up and falls through to the unconditional drop.
///
/// It is a LOOP because the contract on `Tool.cancelUncommittedEdit()` says so
/// verbatim: "this is NOT guaranteed one-shot — the primitive live-run family
/// pops ONE recorded live step per call (the interactive undo ladder) and may
/// legitimately still report hasUncommittedEdit()==true afterwards". A single
/// call would leave exactly that family armed.
///
/// It is CAPPED because the same contract forbids asserting the postcondition:
/// a tool that never clears would spin forever inside `/api/reset`, i.e. an
/// unbounded loop reachable from a wire request. 64 is far above the deepest
/// live-run ladder any tool records and small enough to be free.
enum int kMaxDisarmSteps = 64;

/// Which half of the seam a caller needs. Document replacement cancels a
/// pending edit before dropping the tool; a primary-layer move keeps the edit
/// and only drops, so the tool commits while its original mesh is current.
enum DisarmMode {
    cancelAndDrop,
    dropOnly,
}

/// What the seam did, for diagnostics and for the unit tests below.
struct DisarmOutcome {
    /// A tool was active when the document replace began.
    bool hadTool;
    /// `cancelUncommittedEdit()` calls made (0 = nothing was armed).
    int  cancelSteps;
    /// The tool STILL reported an uncommitted edit when the cap was reached,
    /// so layer 2 did not hold for it and its drop may have committed into the
    /// pre-replace mesh. Never means foreign geometry — see layer 1 above.
    bool stillArmed;
    /// The mode requested by this crossing.
    DisarmMode mode;
}

/// Installed once by `app.d`. Cancels the active tool's live gesture (bounded)
/// and then drops the tool, both while the pre-replace mesh is still current.
/// Null in headless / unit construction, where there is no app and no tool.
__gshared DisarmOutcome delegate(DisarmMode) g_disarmActiveTool;

/// The last outcome, for a test or a future diagnostic route to read. Written
/// on every crossing, including the no-tool one (so a stale `true` cannot be
/// mistaken for a fresh one).
__gshared DisarmOutcome g_lastDisarm;

/// Number of seam crossings, including crossings without an installed hook.
__gshared ulong g_disarmCrossings;

/// Cross the seam. Call this from a command's `applyImpl` BEFORE it captures
/// its undo snapshot and BEFORE it writes the new geometry — the whole point
/// is that the tool is gone while the old mesh is still the current one.
///
/// Uninstalled resolver means "there is no tool" (headless / unit), the same
/// convention `command.g_editTargetResolver` uses.
DisarmOutcome disarmActiveToolBeforeDocumentReplace(DisarmMode mode) {
    ++g_disarmCrossings;
    if (g_disarmActiveTool is null) {
        g_lastDisarm = DisarmOutcome.init;
        g_lastDisarm.mode = mode;
        return g_lastDisarm;
    }
    g_lastDisarm = g_disarmActiveTool(mode);
    g_lastDisarm.mode = mode;
    return g_lastDisarm;
}

/// Drop the active tool before a primary-layer move. The distinct name keeps
/// layer selection from pretending that it replaces the whole document.
DisarmOutcome dropActiveToolBeforePrimaryMove() {
    return disarmActiveToolBeforeDocumentReplace(DisarmMode.dropOnly);
}

// ---------------------------------------------------------------------------
// Unit tests. These pin the CONTRACT of the seam (bounded, records, no-op when
// uninstalled) against a fake tool; the product witness — that a reset with an
// armed tool leaves the fresh cube alone — is the suite test
// `tests/test_reset_disarms_tool.d`, which drives the real 35 tools' path.
// ---------------------------------------------------------------------------
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
