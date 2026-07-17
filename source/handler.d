module handler;

import std.conv : to;

import ai.advisor : AiAdvisor;
import ai.debug_trace : publishHandleDebugTrace;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiInteractionContext, AiInteractionPhase, AiIntent;
import math;
import std.json : JSONValue;

private AiAdvisor g_handleAiAdvisor;

void setHandleAiAdvisor(AiAdvisor advisor) {
    g_handleAiAdvisor = advisor;
}

private AiAdvisor handleAiAdvisor() {
    if (g_handleAiAdvisor is null)
        g_handleAiAdvisor = new AiAdvisor();
    return g_handleAiAdvisor;
}

// Optional sink for live interaction-log capture (task 0027). Module-level so a
// single app.d-owned writer reaches every per-tool ToolHandles instance, mirror
// of g_handleAiAdvisor above. Passes only POD (context + candidates + decision +
// applied index) so handler.d stays ignorant of the writer type. Fired from
// publishHandleTrace on a genuine handle apply only.
alias HandleApplyCaptureSink = void delegate(const ref AiInteractionContext ctx,
                                             const(AiCandidate)[] candidates,
                                             AiAdvisorDecision decision,
                                             int appliedIndex);
private HandleApplyCaptureSink g_handleApplyCaptureSink;

void setHandleApplyCaptureSink(HandleApplyCaptureSink sink) {
    g_handleApplyCaptureSink = sink;
}

// Optional pluggable decision provider for the handle path (task 0028). When
// set it REPLACES the default advisor call as the source of the handle
// decision; when unset the path is byte-identical to before (the default
// advisor). Module-level so a single app.d-owned provider reaches every
// per-tool ToolHandles instance, mirror of g_handleAiAdvisor /
// g_handleApplyCaptureSink above. Passes only POD (context + candidates) and
// returns a POD decision, so handler.d stays ignorant of whatever produces the
// decision — the provider is an opaque closure (app.d injects one that consults
// an optional model first and falls through to the default advisor). The
// produced decision is still re-gated by canApplyAdvisorDecision unchanged.
alias HandleDecisionProvider = AiAdvisorDecision delegate(
    const ref AiInteractionContext ctx, const(AiCandidate)[] candidates);
private HandleDecisionProvider g_handleDecisionProvider;

void setHandleDecisionProvider(HandleDecisionProvider p) {
    g_handleDecisionProvider = p;
}

// Optional ε-exploration override hook (task 0033).  When set, called from
// publishHandleTrace on a genuine mouseDown with ≥2 candidates and no active
// haul.  The hook draws the PRNG and may return a non-default candidate index;
// -1 means "no override" (use the default).  Module-level so a single
// app.d-owned controller reaches every ToolHandles instance, mirroring the
// other module-level hooks above.  Default null ⇒ byte-identical to before.
alias HandleExploreHook = int delegate(const(AiCandidate)[] candidates,
                                       int defaultCandidateIdx);
private HandleExploreHook g_handleExploreHook;

void setHandleExploreHook(HandleExploreHook hook) {
    g_handleExploreHook = hook;
}

public import handles.gl_util;
public import handles.shapes;

// ---------------------------------------------------------------------------
// ToolHandles — central hover/capture arbiter, one per active tool. Mirrors
// the tool-model test/draw pass: a single hot (ROLLOVER) part and a single
// captured (hauled) part across ALL registered handles, so highlight and
// click can never disagree. ToolHandles drives each registered handle's
// `state` every frame via setState; handles never self-compute hover.
// Unregistered handles are draw-only and stay at HandleState.Normal.
//
// ToolHandles.test / update call Handler.hitTest / setState — legal from the
// same module regardless of `protected`.
// ---------------------------------------------------------------------------

class ToolHandles {
    private struct Entry { Handler h; int part; }
    alias AiHoverPreviewPredicate = bool delegate(int part) const;
    private Entry[] entries;     // registration order = test priority
    private AiCandidate[] aiCandidates; // last observational hit-candidate pass
    private int[] aiCandidateParts;      // candidate index -> registered part id
    int hot      = -1;           // ROLLOVER part, -1 = none
    int secondaryDefault = -1;   // deterministic default hint when AI changes hover
    int captured = -1;           // hauled part during a drag, -1 = none
    private bool suppressed;     // when set, update() forces every handle Normal
    private int lastDefaultPart = -1;
    private bool aiHoverPreviewEnabled;
    private AiHoverPreviewPredicate aiHoverPreviewPredicate;

    // ε-exploration silent-hover flag (task 0033, Phase 3).  When true,
    // update() still calls test() (so aiCandidates / handleCandidates() fill
    // for trace capture) but forces every handle's nextState to Normal — the
    // random grab is not telegraphed to the user.  Default FALSE; flag-off ⇒
    // the update() loop is byte-identical to the pre-exploration code.
    // NOTE: explicitly NOT routed through suppress() which zeroes aiCandidates.
    private bool aiExploreSilent = false;

    void setAiExploreSilentHover(bool silent) {
        aiExploreSilent = silent;
    }

    // Clear the per-frame registration list. Call at the start of each draw.
    void begin() {
        entries.length = 0;
        aiCandidates.length = 0;
        aiCandidateParts.length = 0;
        secondaryDefault = -1;
        lastDefaultPart = -1;
        suppressed = false;
    }

    // Force every registered handle to Normal for this frame, ignoring hover
    // and capture. Used by ScaleTool, whose drag feedback is the animated
    // scale arrow — no gizmo handle should highlight while a scale drag runs.
    void suppress() { suppressed = true; }

    void setAiHoverPreviewEnabled(bool enabled) {
        aiHoverPreviewEnabled = enabled;
    }

    void setAiHoverPreviewPredicate(AiHoverPreviewPredicate predicate) {
        aiHoverPreviewPredicate = predicate;
    }

    // Register a handle with a stable part id, in priority order (first wins
    // on overlap).
    void add(Handler h, int part) {
        entries ~= Entry(h, part);
    }

    // Hit-test pass: first registered handle (by priority) whose hitTest passes.
    // Skips invisible handles. Returns its part id, or -1 on miss. Also records
    // the full ordered list of hit handle candidates for future advisory/debug
    // paths; this cache is observational and does not drive the winner.
    int test(int mx, int my, const ref Viewport vp,
             AiInteractionPhase phase = AiInteractionPhase.unknown) {
        aiCandidates.length = 0;
        aiCandidateParts.length = 0;
        int firstPart = -1;
        size_t defaultCandidate = size_t.max;

        foreach (priority, ref e; entries) {
            if (!e.h.isVisible()) continue;
            if (!e.h.hitTest(mx, my, vp)) continue;

            AiCandidate c;
            c.id = "handle:" ~ e.part.to!string;
            c.kind = AiCandidateKind.handle;
            c.intent = e.h.aiIntentForPart(e.part);
            c.screenDist = e.h.aiScreenDistance(mx, my, vp);
            c.priorityFromCurrentRules = cast(float)priority;
            c.hasScreenPosition = true;
            c.screenPosition = [cast(float)mx, cast(float)my];
            if (firstPart < 0) {
                firstPart = e.part;
                defaultCandidate = aiCandidates.length;
            }
            aiCandidates ~= c;
            aiCandidateParts ~= e.part;
        }
        if (defaultCandidate != size_t.max)
            aiCandidates[defaultCandidate].isDefaultWinner = true;
        return publishHandleTrace(mx, my, phase, firstPart, defaultCandidate);
    }

    const(AiCandidate)[] handleCandidates() const {
        return aiCandidates;
    }

    // Resolve the hot part (captured sticks; else test) and hand each
    // registered handle its HandleState for this frame.
    void update(int mx, int my, const ref Viewport vp) {
        if (suppressed) {
            hot = -1;
            secondaryDefault = -1;
            lastDefaultPart = -1;
            aiCandidates.length = 0;
            aiCandidateParts.length = 0;
            publishHandleDebugTrace(aiCandidates);
            foreach (ref e; entries) e.h.setState(HandleState.Normal);
            return;
        }
        if (captured >= 0) {
            hot = captured;
            secondaryDefault = -1;
        } else {
            hot = test(mx, my, vp,
                       aiHoverPreviewEnabled
                           ? AiInteractionPhase.hover
                           : AiInteractionPhase.unknown);
            secondaryDefault = lastDefaultPart >= 0 && lastDefaultPart != hot
                ? lastDefaultPart
                : -1;
        }
        // In exploration silent-hover mode: test() already ran (candidates
        // filled), but every handle is forced to Normal so the random grab is
        // not telegraphed.  At flag-off this if-block is absent and the loop
        // below is byte-identical to the pre-exploration code.
        if (aiExploreSilent) {
            foreach (ref e; entries) e.h.setState(HandleState.Normal);
            return;
        }
        foreach (ref e; entries) {
            auto nextState = HandleState.Normal;
            if (e.part == hot)
                nextState = HandleState.Rollover;
            else if (e.part == secondaryDefault)
                nextState = HandleState.SecondaryDefault;
            e.h.setState(nextState);
        }
    }

    void setHaul(int part) { captured = part; }
    void clearHaul()       { captured = -1;  }

    // Serialize the registered handles for test introspection (task 0234,
    // /api/tool/handles). `entries` stays private to this module; this is the
    // only exported view of it. Thread-safety: called from the HTTP
    // background thread with no lock, same quiescence contract as
    // /api/selection — the caller (Tool.toolHandlesJson override) is read-only
    // over data that only the main thread's draw()/update() ever writes, and
    // tests only probe between play-events settles, never mid-drag. This is
    // NOT the marshal-to-main-thread pattern used by /api/toolpipe/eval or
    // /api/snap: those mutate shared g_pipeCtx caches on evaluation, so they
    // must run on the main thread. Do not extend this "read on the HTTP
    // thread" shortcut to any state this method would have to MUTATE to read.
    //
    // Shape: {"parts":[{part,state,visible,screen:[sx,sy]|null}, ...],
    //         "hot":N, "captured":N, "secondaryDefault":N}
    // `screen` is null when the handle has no `screenAnchor` override or its
    // anchor point is off-camera. Draw-only (unregistered) handles never
    // appear here — matches the arbiter's own contract (only `add()`-ed
    // handles are ever hit-tested / highlighted).
    JSONValue toJson(const ref Viewport vp) const {
        JSONValue[] parts;
        foreach (e; entries) {
            auto obj = JSONValue.emptyObject;
            obj["part"]    = JSONValue(e.part);
            obj["state"]   = JSONValue(handleStateToString(e.h.getState()));
            obj["visible"] = JSONValue(e.h.isVisible());
            float sx, sy;
            obj["screen"] = e.h.screenAnchor(vp, sx, sy)
                ? JSONValue([JSONValue(sx), JSONValue(sy)])
                : JSONValue(null);
            parts ~= obj;
        }
        auto root = JSONValue.emptyObject;
        root["parts"]            = JSONValue(parts);
        root["hot"]              = JSONValue(hot);
        root["captured"]         = JSONValue(captured);
        root["secondaryDefault"] = JSONValue(secondaryDefault);
        return root;
    }

    private int publishHandleTrace(int mx, int my, AiInteractionPhase phase,
                                   int defaultPart,
                                   size_t defaultCandidate) {
        auto context = AiInteractionContext();
        context.phase = phase;
        context.defaultIntent = AiIntent.keepDefault;
        context.mouseX = mx;
        context.mouseY = my;
        context.isDragging = captured >= 0;

        AiAdvisorDecision decision;
        try {
            // The decision provider, when set, is the pluggable source of the
            // handle decision (task 0028); unset ⇒ exactly the prior advisor
            // call. The try/catch wraps BOTH branches so a throwing provider
            // (or advisor) cannot escape into the UI.
            decision = g_handleDecisionProvider !is null
                ? g_handleDecisionProvider(context, aiCandidates)
                : handleAiAdvisor().advise(context, aiCandidates);
        } catch (Exception) {
            decision = AiAdvisorDecision();
        }

        auto appliedCandidate = defaultCandidate;
        int appliedPart = defaultPart;
        if (canApplyAdvisorDecision(phase, decision, defaultCandidate)) {
            appliedCandidate = cast(size_t)decision.candidateIndex;
            appliedPart = aiCandidateParts[appliedCandidate];
        }
        // ε-exploration override (task 0033).  Applied AFTER the advisor
        // decision, BEFORE the capture-sink fire.  The hook draws the PRNG
        // and may return a non-default index; -1 = no override.  The guard
        // matches the capture-sink gate (mouseDown, not mid-drag, ≥2 hits).
        if (g_handleExploreHook !is null &&
            phase == AiInteractionPhase.mouseDown &&
            captured < 0 &&
            aiCandidates.length >= 2) {
            int overrideIdx = g_handleExploreHook(aiCandidates,
                                                   cast(int)appliedCandidate);
            if (overrideIdx >= 0 &&
                overrideIdx < cast(int)aiCandidates.length &&
                overrideIdx != cast(int)appliedCandidate) {
                appliedCandidate = cast(size_t)overrideIdx;
                appliedPart      = aiCandidateParts[appliedCandidate];
            }
        }

        lastDefaultPart = defaultPart;
        publishHandleDebugTrace(
            aiCandidates,
            decision,
            appliedCandidate == size_t.max ? -1 : cast(int)appliedCandidate);

        // Capture exactly one record per genuine handle apply. The gate
        // excludes the every-frame hover/unknown update() path, a mid-drag
        // re-test (captured>=0), and a click that hit no handle (defaultPart<0).
        // appliedCandidate is the index of the part actually applied (= default
        // unless an advisor decision overrode it, or ε-exploration overrode it);
        // it is a valid index here because defaultPart>=0 guarantees at least one
        // hit candidate.
        if (g_handleApplyCaptureSink !is null &&
            phase == AiInteractionPhase.mouseDown &&
            captured < 0 &&
            defaultPart >= 0)
            g_handleApplyCaptureSink(context, aiCandidates, decision,
                                     cast(int)appliedCandidate);
        return appliedPart;
    }

    private bool canApplyAdvisorDecision(AiInteractionPhase phase,
                                         const ref AiAdvisorDecision decision,
                                         size_t defaultCandidate) const {
        enum float minConfidence = 0.75f;
        if (phase != AiInteractionPhase.mouseDown &&
            phase != AiInteractionPhase.hover)
            return false;
        if (captured >= 0)
            return false;
        if (decision.keepDefault || decision.confidence < minConfidence)
            return false;
        if (decision.candidateIndex < 0)
            return false;
        auto index = cast(size_t)decision.candidateIndex;
        if (index >= aiCandidates.length || index >= aiCandidateParts.length)
            return false;
        if (index == defaultCandidate)
            return false;
        if (aiCandidates[index].kind != AiCandidateKind.handle)
            return false;
        if (phase == AiInteractionPhase.hover) {
            if (!aiHoverPreviewEnabled)
                return false;
            if (defaultCandidate >= aiCandidateParts.length)
                return false;
            if (aiHoverPreviewPredicate !is null &&
                (!aiHoverPreviewPredicate(aiCandidateParts[defaultCandidate]) ||
                 !aiHoverPreviewPredicate(aiCandidateParts[index])))
                return false;
        }
        if (decision.candidateId.length == 0 ||
            decision.candidateId != aiCandidates[index].id)
            return false;
        return true;
    }
}
