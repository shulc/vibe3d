module toolpipe.stages.snap;

import std.format    : format;
import std.conv      : to;
import std.string    : split, strip;
import std.algorithm : canFind;

import toolpipe.stage    : Stage, TaskCode, ordSnap;
// pipeline imports moved to packet-only — Phase 6 cleanup
import toolpipe.packets  : SnapPacket, SnapConfig, SnapHitPacket, SnapType, SnapMode;
import toolpipe.guide    : SnapGuide, GuideDrawState;
import operator          : Operator, Task, VectorStack, PacketKind;
import popup_state       : setStatePath;
import params            : Param, IntEnumEntry;

// ---------------------------------------------------------------------------
// The snap TYPE table — one row per candidate class, single-sourced.
//
// Read by `params()` (one checkbox per row, in this order), by `setAttr`
// (the per-type wire keys), and by `knownAttrs()`. Order and labels follow
// the reference's own snap-type list, which is what a user who knows the
// other editor will be looking for; `workplane` has no counterpart there and
// is ours, so it sits at the end rather than pretending to a position.
private struct SnapTypeRow {
    SnapType bit;
    string   attr;    // wire key: `tool.pipe.attr snap <attr> true|false`
    string   token;   // token in the `types` CSV / `typeToggle`
    string   label;   // UI
}

private static immutable SnapTypeRow[] snapTypeRows = [
    SnapTypeRow(SnapType.Grid,         "typeGrid",         "grid",         "Grid"),
    SnapTypeRow(SnapType.Vertex,       "typeVertex",       "vertex",       "Vertex"),
    SnapTypeRow(SnapType.Edge,         "typeEdge",         "edge",         "Edge"),
    SnapTypeRow(SnapType.EdgeCenter,   "typeEdgeCenter",   "edgeCenter",   "Edge Center"),
    SnapTypeRow(SnapType.Polygon,      "typePolygon",      "polygon",      "Polygon"),
    SnapTypeRow(SnapType.PolyCenter,   "typePolyCenter",   "polyCenter",   "Polygon Center"),
    SnapTypeRow(SnapType.Pivot,        "typePivot",        "pivot",        "Pivot"),
    SnapTypeRow(SnapType.WorldAxis,    "typeWorldAxis",    "worldAxis",    "World Axis"),
    SnapTypeRow(SnapType.StraightLine, "typeStraightLine", "straightLine", "Straight Line"),
    SnapTypeRow(SnapType.RightAngle,   "typeRightAngle",   "rightAngle",   "Right Angle"),
    SnapTypeRow(SnapType.Intersection, "typeIntersection", "intersection", "Intersection"),
    SnapTypeRow(SnapType.Box,          "typeBox",          "box",          "Box"),
    SnapTypeRow(SnapType.Workplane,    "typeWorkplane",    "workplane",    "Workplane"),
];

private static immutable IntEnumEntry[] snapModeEntries = [
    IntEnumEntry(cast(int)SnapMode.Global,    "global",    "Global"),
    IntEnumEntry(cast(int)SnapMode.Component, "component", "Component"),
    IntEnumEntry(cast(int)SnapMode.Item,      "item",      "Item"),
];

/// The ONE place the word that titles the snapping surface is written
/// (task 0638). `displayName()` returns it — so it titles the collapsing
/// section — and the Tool Properties tab strip in app.d reads it too, so
/// the tab entry and the section header can never say different things and
/// can never drift apart from what a test pins.
///
/// It was once load-bearing for an ImGui id collision: the panel pushed no id
/// scope, so a row label and the title above it shared one namespace and any
/// row labelled with this string became the same widget as the title. Task
/// 0640 gave every section and every row a scope of its own, so that is no
/// longer true — what the unittest at the bottom of this module still pins is
/// legibility (one name must not stand for two controls a user has to tell
/// apart), plus the fact that the tab entry and the section header cannot
/// drift, which is what single-sourcing the word buys.
enum kSnapDisplayName = "Snapping";

// ---------------------------------------------------------------------------
// SnapStage — Phase 7.3 of doc/phase7_plan.md / doc/snap_plan.md.
// Sits at ordinal 0x40 (between WORK 0x30 and ACEN 0x60).
//
// Publishes a SnapPacket with the master enable flag, the
// candidate-type bitmask and the inner / outer pixel ranges. The
// actual snap math runs on demand in source/snap.d's `snapCursor`,
// since snap candidates depend on the live cursor position and can't
// be precomputed once per pipeline.evaluate.
//
// HTTP setAttr keys:
//   `enabled`       : "true" / "false"
//   `types`         : CSV — "vertex,edgeCenter,polyCenter,grid"
//                     (recognised tokens: vertex, edge, edgeCenter,
//                      polygon, polyCenter, grid, workplane)
//   `innerRange`    : float, screen pixels
//   `outerRange`    : float, screen pixels
//   `fixedGrid`     : "true" / "false"
//   `fixedGridSize` : float, world units
// ---------------------------------------------------------------------------
class SnapStage : Stage, Operator {
    // Phase 1 of doc/operator_refactor_plan.md.
    private SnapPacket _publishedPacket;
    // The per-cursor RESULT (S2 of doc/toolpipe_architecture_plan.md).
    // Storage lives on the stage for the same reason `_publishedPacket` does:
    // the VectorStack holds POINTERS into the publisher, valid for the one
    // `pipeline.evaluate` call.
    private SnapHitPacket _hitPkt;
    // The guide registry (S4(a) of doc/toolpipe_architecture_plan.md). Empty
    // in this phase and in every existing code path: nothing registers.
    private SnapGuide[] _guides;
    // How many live consumers have asked for the per-cursor RESULT. Zero here
    // and everywhere in this tree — see `demandHit` for what that buys.
    private int _hitDemand;

    Task task() const { return Task.Snap; }
    PacketKind[] requiredPackets() const { return [PacketKind.Subject]; }

    bool evaluate(ref VectorStack vts) {
        // NB: SnapStage shadows Stage.enabled with its own field
        // (default false). `this.enabled` resolves to the SnapStage one.
        if (!this.enabled) return false;
        import toolpipe.packets : WorkplanePacket;
        SnapPacket pkt;
        pkt.config = config;
        if (auto wp = vts.get!WorkplanePacket()) {
            pkt.workplaneCenter = wp.center;
            pkt.workplaneNormal = wp.normal;
            pkt.workplaneAxis1  = wp.axis1;
            pkt.workplaneAxis2  = wp.axis2;
        }
        pkt.gridStep = fixedGrid ? fixedGridSize : 1.0f;
        _publishedPacket = pkt;
        vts.put(&_publishedPacket);

        // The ranges go to the guides before the query that will consult them,
        // so a range changed mid-gesture reaches a guide that is already
        // registered. Zero iterations while the registry is empty.
        pushLimitsToGuides();
        publishSnapHit(vts, pkt);
        return true;
    }

    // ---- the guide registry (S4(a) of doc/toolpipe_architecture_plan.md) ---
    //
    // A guide is a gesture-scoped snapping CLIENT: the tool that owns the
    // gesture registers one when the gesture starts and removes it when the
    // gesture ends. That LIFECYCLE is MEASURED (an observed add/remove pair
    // around a drag); the interface's method set and its `priority` return are
    // header-derived and unmeasured — see `toolpipe.guide` for which is which.
    //
    // Phase (a) lands the registry EMPTY. No tool in this tree calls
    // `addGuide`, so `_guides.length` is 0 at every `snapCursor` this stage
    // makes, the arbitration branch inside `snapCursor` is unreachable, and
    // the ranking is the historical "nearest wins". Changing that is phase
    // (b), and it is named behaviour-changing.

    /// Register a gesture-scoped guide, and push the current ranges into it.
    ///
    /// Idempotent: registering the same guide twice is a no-op rather than a
    /// second vote in the arbitration. Ignores null.
    void addGuide(SnapGuide g) {
        if (g is null) return;
        foreach (e; _guides) if (e is g) return;
        _guides ~= g;
        // MEASURED direction — the environment's ranges are pushed IN at
        // registration; a guide never sources the pair for itself.
        g.limits(innerRangePx, outerRangePx);
    }

    /// Remove a previously registered guide. Returns true if it was there.
    bool removeGuide(SnapGuide g) {
        foreach (i, e; _guides) {
            if (e !is g) continue;
            _guides = _guides[0 .. i] ~ _guides[i + 1 .. $];
            return true;
        }
        return false;
    }

    /// The registered guides, in registration order — which is also the order
    /// the arbitration settles equal priorities by.
    SnapGuide[] guides() { return _guides; }

    /// How many guides are registered. 0 in phase (a), always.
    size_t guideCount() const { return _guides.length; }

    private void pushLimitsToGuides() {
        foreach (g; _guides) g.limits(innerRangePx, outerRangePx);
    }

    // ---- the DEMAND gate on the per-cursor RESULT --------------------------
    //
    // MEASURED COST, and it is why this gate exists. The publication below is
    // one full `snapCursor` per cursor-valid pipeline evaluation, and
    // `SubjectPacket.cursorValid` is stamped on every mouse-motion event that
    // reaches an armed tool — there is no button-down term in it. So with
    // snapping switched on and FOUR element classes enabled (which was this
    // stage's default when the number below was measured, tasks 0526/0531 — the
    // default is one class now, so a default run walks roughly a quarter of
    // this), a plain hover over a 100k-vertex mesh paid an extra element-class
    // candidate walk per motion event: the pipeline evaluation went from
    // 0.09 ms to 4.6 ms per
    // event, 28 % of a 60 fps frame added to moving the mouse. The numbers and
    // the driver are in task 0526; task 0531 re-ran them with this gate in.
    //
    // NOBODY READS THE PACKET. Outside this stage, its own unittests and the
    // `PacketKind` registration in `operator.d`, `SnapHitPacket` does not
    // appear in the tree — so 100 % of that work was speculative. The gate is
    // therefore behaviour-neutral by construction: the only observable
    // difference is the absence of a packet no code path consults.
    //
    // A COUNTER, not a bool, and the reason is in S2's own phase (b): six
    // consumers migrate onto this packet ONE COMMIT AT A TIME, so two of them
    // are live at once for most of that phase. A bool would let the first one
    // to release starve the rest. An unpaired release is reported rather than
    // wrapped, because a demand stuck ON costs time while a demand wrongly
    // OFF is a consumer reading nothing.
    //
    // NOT CLEARED BY `reset()`, deliberately, and unlike the guide registry
    // above: a guide is scoped to a GESTURE and a scene reset ends every
    // gesture there was, but a demand is scoped to a CONSUMER, and
    // `/api/reset` resets the scene, not the wiring. Clearing it would
    // silently starve a consumer that is still alive and still reading —
    // failure in the direction that changes behaviour rather than the one
    // that only costs time.

    /// Ask for the per-cursor RESULT packet to be published. Pair with
    /// `releaseHit` for the consumer's own lifetime — for a permanent
    /// consumer (an overlay renderer, say) that pairing is app start / app
    /// exit, and for a gesture-scoped one it is press / release.
    void demandHit() { ++_hitDemand; }

    /// Withdraw one demand. Returns false — WITHOUT going negative — when
    /// there was none to withdraw, which is an unpaired release in the caller.
    bool releaseHit() {
        if (_hitDemand <= 0) return false;
        --_hitDemand;
        return true;
    }

    /// Whether any consumer currently wants the result packet.
    bool hitDemanded() const { return _hitDemand > 0; }

    /// How many demands are outstanding. 0 in this tree, always.
    int hitDemandCount() const { return _hitDemand; }

    // ---- the per-cursor RESULT (S2 of doc/toolpipe_architecture_plan.md) ---
    //
    // The snap query is the one thing this stage never published: it shipped
    // the CONFIG and left every consumer to run the query itself. This runs it
    // once, here, and puts the answer on the stack the CONS stage already puts
    // its own per-cursor result on.
    //
    // The gate is `subj.cursorValid`, copied from CONS (`stages/constrain.d`)
    // rather than invented: that flag is stamped true ONLY by the main-thread
    // mouse-event dispatch (app.d's buildToolVts) and the main-thread-bridged
    // raycast provider. Every per-frame render-loop evaluate() and every
    // HTTP-thread subject builder (/api/toolpipe, /api/snap, /api/constrain,
    // /api/path) leaves it false, so the query runs once per real input event,
    // on the main thread, never off it — which matters because the candidate
    // grids snapCursor builds are process-global.
    //
    // No packet is published when the gate fails: an absent SnapHitPacket
    // means "no cursor-valid query this evaluation", exactly as an absent
    // ConstrainHitPacket does. A published packet with `snapped == false`
    // means the query ran and found nothing.
    private void publishSnapHit(ref VectorStack vts, const ref SnapPacket cfg) {
        // DEMAND first, before the cursor gate and before the query — this is
        // the whole of the fix for the cost measured in task 0526. A query
        // whose answer nobody asked for is not run at all.
        if (_hitDemand <= 0) return;
        import toolpipe.packets : SubjectPacket;
        import snap             : snapCursor, SnapResult,
                                  backgroundSourceLayerIndices;
        import math             : Vec3, projectToWindowFull;
        import std.math         : sqrt;
        // Task 0617 Stage 4: `subj.mesh` is the active/primary layer's mesh
        // (the toolpipe addresses the foreground mesh transparently, per
        // CLAUDE.md), so its ModelSpace is the SAME resolver every other
        // cross-module picking call site uses.
        import document         : primaryModelSpace;

        auto subj = vts.get!SubjectPacket();
        if (subj is null || !subj.cursorValid) return;
        if (subj.mesh is null || subj.viewport.width <= 0) return;

        // The query seed. `snapCursor` ranks candidates by their distance from
        // the cursor PIXEL alone — the seed is never compared against anything;
        // it only reappears as the pass-through `worldPos` on a miss. So the
        // stage, which has no tool and therefore no desired position, passes
        // the origin and publishes no position at all unless something snapped
        // (see SnapHitPacket's contract). Were the seed to acquire meaning,
        // this line would have to become a real derivation, and the packet's
        // "meaningful only when `snapped`" clause is what keeps that honest.
        // `_guides` is the S4(a) registry, and it is empty: nothing in this
        // tree registers a guide, so this argument is `null` in effect and the
        // query takes the historical ranking. It is passed anyway because the
        // registry has to reach the arbitration through SOMETHING, and this is
        // the one query the stage owns.
        //
        // NOTE for phase (b): the four tool-side `snapCursor` call sites
        // (`app.d`, `tools/create/create_common.d`, `tools/transform/move.d`,
        // `tools/transform/transform.d`) do NOT consult the registry. The
        // moment a real guide registers, they and this query would rank
        // differently — so migrating them is part of registering the first
        // guide, not a follow-up.
        SnapResult sr = snapCursor(Vec3(0, 0, 0), subj.cursorX, subj.cursorY,
                                   subj.viewport, *subj.mesh, primaryModelSpace(), cfg,
                                   null, null, _guides);

        SnapHitPacket hit;   // every field at its documented default
        hit.snapped        = sr.snapped;
        hit.highlighted    = sr.highlighted;
        hit.targetType     = sr.targetType;
        hit.targetIndex    = sr.targetIndex;
        hit.targetSource   = sr.targetSource;
        hit.constraintType = sr.constraintType;
        // PROVENANCE, not a result: how many guides re-ranked the walk above.
        // A consumer migrating off its own `snapCursor` (which passes no
        // registry) must refuse this packet when it is non-zero — see the
        // packet's own contract, and the note further up about the four
        // tool-side call sites that do not consult the registry.
        hit.guideCount     = cast(int)_guides.length;

        // Paired with `highlighted` exactly as `worldPos` is paired with
        // `snapped`: on a miss the query's `highlightPos` is the pass-through
        // seed, and this stage has no seed worth publishing.
        if (sr.highlighted) hit.highlightPos = sr.highlightPos;

        if (sr.snapped) {
            hit.worldPos = sr.worldPos;
            // The screen point + pixel distance are a RE-projection of the
            // winner, not a second opinion about it: `consider` picked the
            // winner by projecting this same world point through this same
            // viewport, so this reproduces the winning distance bit for bit.
            float pxs, pys, ndcZ;
            if (projectToWindowFull(sr.worldPos, subj.viewport, pxs, pys, ndcZ)) {
                hit.screenX = pxs;
                hit.screenY = pys;
                immutable float dx = pxs - cast(float)subj.cursorX;
                immutable float dy = pys - cast(float)subj.cursorY;
                hit.distPx = sqrt(dx * dx + dy * dy);
            }
        }

        // `targetSource` is the snap service's source SLOT (0 = active mesh,
        // 1..N = the (slot-1)-th background source). Resolve the background
        // ones back to a Document-layer index the same way the CONS stage
        // resolves its own hit, with the same fallback to the slot order when
        // the installer supplied no mapping. Slot 0 stays -1: the active
        // layer's index is the Document's business and snap.d does not hold it.
        if (sr.targetSource >= 1) {
            auto bgSrcLayer = backgroundSourceLayerIndices();
            immutable int srcIdx = sr.targetSource - 1;
            hit.layer = (srcIdx < cast(int)bgSrcLayer.length)
                        ? bgSrcLayer[srcIdx] : srcIdx;
        }

        _hitPkt = hit;
        vts.put(&_hitPkt);
    }

    // Panel-side mirror of `enabledTypes`, one slot per `snapTypeRows` entry.
    // Written by `params()` (re-synced from the bitmask every call) and read
    // back by `onParamChanged`. NOT state: `enabledTypes` is.
    private bool[snapTypeRows.length] _typeMirror;

    /// The stage's user-facing config — the SAME seven fields `SnapPacket`
    /// carries, because it is literally the same struct (task 0705, P8). The
    /// stage used to redeclare all seven with its own initialisers, and the
    /// two sets had already drifted once (see `SnapConfig`'s own note). There
    /// is nothing left to keep in step: `alias this` means every existing
    /// `enabled` / `innerRangePx` reference inside this class still resolves.
    SnapConfig config;
    alias config this;

    /// The one obstacle this split hit, and why `Stage.enabled` is now
    /// `Stage.pipeEnabled`: an `alias this` LOSES to an inherited member of
    /// the same name. While the base still spelled its pipe-registration flag
    /// `enabled`, aliasing the config in would have silently redirected every
    /// `enabled` in and around this stage to that flag — which defaults to
    /// TRUE, i.e. a stage in the pipe reading "snapping on" with the user's
    /// toggle off. The pin unittest at the bottom of this file is what caught
    /// it; nothing else would have.

    // ---- startup arming: the tool-activation save/restore pair -------------
    //
    // A tool activation may ARM the master enable for the life of that tool and
    // hand it back untouched when the tool is dropped. That is the reference's
    // own mechanism, and it is measured rather than inferred: its
    // tool-activation command carries a fourth argument meaning "snap state at
    // startup", and supplying it PUSHES the previous value under the activating
    // preset's NAME before writing the new one. The matching pop, keyed on that
    // same name, restores it. Dropping a tool restores the value rather than
    // leaking it because the drop path is a re-invocation of the same
    // activation command.
    //
    // OWNED HERE, NOT BY THE ARMING TOOL, and that placement is load-bearing
    // rather than tidiness: `reset()` — the `/api/reset` / scene-reset clean
    // slate — runs BEFORE the tool drop that same reset triggers, so a saved
    // value living on the tool would be written back ON TOP of the clean slate
    // and re-arm snapping across a reset. Clearing the outstanding push inside
    // `reset()` closes that, and it can only be cleared where it is stored.
    // (The reference stores it framework-side for its own reasons; we land in
    // the same place from ours.)
    //
    // ONE SLOT, name-keyed, mirroring the reference: a push while another is
    // outstanding re-keys the slot to the new owner, so the older owner's pop
    // becomes a no-op and its value is forgotten. Only one tool is active at a
    // time here and `deactivate()` always precedes the next `activate()`, so
    // no live path nests. What the key buys is that an UNBALANCED pop — a tool
    // that never pushed, or a pop arriving after a reset cleared the slot — is
    // harmless instead of a silent write of a stale value.
    private bool   _pushedEnabled;
    private string _pushedOwner;      // null / empty == nothing outstanding

    /// Save the current master enable under `owner`, then set it to `value`.
    /// Balanced by `popEnabled(owner)`; see the block comment above.
    void pushEnabled(string owner, bool value) {
        if (owner.length == 0) return;
        _pushedEnabled = enabled;
        _pushedOwner   = owner;
        enabled        = value;
        publishState();
    }

    /// Restore the master enable `owner` saved. A pop whose owner does not
    /// match the outstanding push does nothing — the reference's own name
    /// comparison, and our guard against restoring across a reset.
    void popEnabled(string owner) {
        if (owner.length == 0 || _pushedOwner != owner) return;
        enabled      = _pushedEnabled;
        _pushedOwner = null;
        publishState();
    }

    /// Is `owner`'s startup arming still outstanding? Test-facing only — no
    /// product path reads it; the push/pop pair is self-balancing.
    bool hasPushedEnabled(string owner) const {
        return owner.length != 0 && _pushedOwner == owner;
    }

    this() { publishState(); }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Snap; }
    override string   id()       const                          { return "snap"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordSnap; }
    override string   displayName() const                       { return kSnapDisplayName; }

    // ------------------------------------------------------------------
    // Tool Properties schema.
    //
    // This stage shipped without one. Every other pipe stage — action
    // centre, falloff, symmetry, path, constrain — overrides `params()`,
    // and the panel loop skips any stage whose schema is empty, so snapping
    // had NO Tool Properties surface at all: the master toggle and the type
    // set were reachable only from the status line, and the two pixel ranges
    // that decide whether anything sticks were reachable only over HTTP.
    //
    // The rows and their order follow the reference's own snapping form
    // (master toggle, mode, the type set, the fixed-grid pair, then the two
    // ranges). Two honesty notes that belong in the source and not just in a
    // task file:
    //
    //   * PLACEMENT IS OURS for the ranges. In the reference the inner /
    //     outer pixel ranges are a USER PREFERENCE ("Inner Range (pixels)" /
    //     "Outer Range (pixels)"), not a tool attribute. Putting them on a
    //     tool-side panel is our choice, made because they are the two
    //     numbers that decide whether a drag sticks and they had no UI at
    //     all. The LABELS are the reference's; the location is not.
    //   * THE VALUES 24 / 40 ARE THE SERVICE'S. They live on this stage and
    //     nowhere else — no tool keeps a private copy — and these rows read
    //     and write those very fields rather than a per-tool shadow.
    //
    // The per-type rows are backed by `_typeMirror`, re-synced from
    // `enabledTypes` on every `params()` call (which the panel makes once a
    // frame) and folded back by `onParamChanged`. The bitmask stays the one
    // source of truth; the mirror is never authoritative for longer than the
    // frame it is drawn in.
    // ------------------------------------------------------------------
    override Param[] params() {
        foreach (i, ref row; snapTypeRows)
            _typeMirror[i] = (enabledTypes & row.bit) != 0;

        Param[] ps;
        // MASTER TOGGLE. The wire name stays `enabled` — it is on the HTTP
        // surface and in tests, and renaming it would be a breaking change
        // for zero gain. The LABEL moved for task 0638: it used to read
        // "Snapping", the same text as this section's own title, and back then
        // the panel pushed no id scope anywhere, so title and row hashed to one
        // ImGui id and the widget the user clicked was decided by draw order.
        //
        // THAT CONSTRAINT IS GONE (task 0640): the panel now opens an id scope
        // per section and per row, so a repeated label is legal — it costs
        // nothing but the reader's ability to tell two controls apart. The
        // label stays "Enable Snapping" because it reads better under a title
        // that already says "Snapping", not because anything would break.
        ps ~= Param.bool_("enabled", "Enable Snapping", &enabled, false);
        ps ~= Param.intEnum_("snapMode", "Mode", cast(int*)&snapScope,
                             snapModeEntries, cast(int)SnapMode.Global);
        foreach (i, ref row; snapTypeRows)
            ps ~= Param.bool_(row.attr, row.label, &_typeMirror[i],
                              (SnapPacket.init.enabledTypes & row.bit) != 0);
        ps ~= Param.bool_ ("fixedGrid",     "Use Fixed Grid",       &fixedGrid,     false);
        ps ~= Param.float_("fixedGridSize", "Grid Size",            &fixedGridSize, 1.0f);
        ps ~= Param.float_("innerRange",    "Inner Range (pixels)", &innerRangePx,  24.0f);
        ps ~= Param.float_("outerRange",    "Outer Range (pixels)", &outerRangePx,  40.0f);
        return ps;
    }

    /// The panel writes straight through a Param's pointer, so a per-type row
    /// lands in `_typeMirror` and has to be folded back into the bitmask that
    /// every reader consults. Only the named bit is folded — reconstructing
    /// the whole mask from the mirror would let a stale slot (one written by
    /// HTTP since the last `params()`) overwrite a bit nobody touched.
    override void onParamChanged(string name) {
        foreach (i, ref row; snapTypeRows) {
            if (row.attr != name) continue;
            if (_typeMirror[i]) enabledTypes |=  row.bit;
            else                enabledTypes &= ~row.bit;
            break;
        }
        publishState();
    }

    /// The authoritative wire universe. `params()` cannot supply it: the
    /// `types` CSV, `typeToggle` and `fixedGridToggle` have no Param row (they
    /// are set-shaped and action-shaped, not value-shaped), while the per-type
    /// rows are Params that `params()` DOES expose. Same reason ACEN and
    /// falloff override this — see Stage.knownAttrs().
    override string[] knownAttrs() {
        string[] names = ["enabled", "types", "snapMode", "innerRange",
                          "outerRange", "fixedGrid", "fixedGridSize",
                          "fixedGridToggle", "typeToggle"];
        foreach (ref row; snapTypeRows) names ~= row.attr;
        return names;
    }

    /// Match every default field initialiser at declaration time —
    /// invoked via Stage.reset() by SceneReset / `/api/reset`.
    override void reset() {
        // One assignment, and it CANNOT fall behind the declaration: the
        // initialisers it restores are the struct's own (task 0705). This used
        // to restate all seven by hand and was the third copy of the set.
        config = SnapConfig.init;
        // Drop the last per-cursor result too, so a scene reset cannot leave a
        // stale hit behind the stage's pointer (mirrors the CONS stage).
        _hitPkt       = SnapHitPacket.init;
        // And drop the guide registry: a guide is scoped to a gesture, and a
        // scene reset ends every gesture there was. Leaving one registered
        // would outlive the tool that owns it — the one lifecycle error the
        // measured add/remove pair rules out.
        _guides       = null;
        // And drop any outstanding startup-arming push (see `pushEnabled`).
        // ORDER, not hygiene: a scene reset resets every stage BEFORE it drops
        // the active tool, so an armed tool's `popEnabled` arrives AFTER this
        // and would otherwise write its pre-reset value back over the clean
        // slate — snapping left on across a reset, and bleeding into whatever
        // runs next in the same process.
        _pushedOwner   = null;
        _pushedEnabled = false;
        publishState();
    }

    override bool setAttr(string name, string value) {
        bool ok = applySetAttr(name, value);
        if (ok) publishState();
        return ok;
    }

    /// Snapshot the stage's LIVE user-facing CONFIG fields into a SnapPacket —
    /// the inverse of `restoreConfigFromPacket`. Used by the wrapper's
    /// transform-session undo/redo hooks (P-C) so a mid-run snap toggle reverts
    /// the snap CONFIG together with the geometry. Mirrors
    /// FalloffStage.snapshotConfigToPacket: captures only the STAGE-owned config
    /// fields (the ones a round-trip restores); the workplane cache + gridStep
    /// are re-derived by evaluate() from the upstream WORK stage.
    SnapPacket snapshotConfigToPacket() const {
        SnapPacket p;
        p.config = config;
        return p;
    }

    /// Restore the user-facing CONFIG fields from a previously-snapshotted
    /// SnapPacket and re-publish so the status-bar pulldown follows. Used by the
    /// wrapper's in-session snap-refire undo/redo hooks (P-C): an in-session
    /// Ctrl+Z of a transform-session snap change restores the snap config to its
    /// PRE-tweak value (revert hook); redo restores the POST-tweak config (apply
    /// hook). Mirrors FalloffStage.restoreConfigFromPacket — assign + publish, no
    /// session. Does NOT restore the workplane cache / gridStep (evaluate()
    /// re-derives those from the upstream WORK stage).
    void restoreConfigFromPacket(const ref SnapPacket p) {
        config = p.config;
        publishState();
    }

    override string[2][] listAttrs() const {
        return [
            ["enabled",       enabled ? "true" : "false"],
            ["types",         typesLabel()],
            ["snapMode",      snapModeLabel()],
            ["innerRange",    format("%g", innerRangePx)],
            ["outerRange",    format("%g", outerRangePx)],
            ["fixedGrid",     fixedGrid ? "true" : "false"],
            ["fixedGridSize", format("%g", fixedGridSize)],
        ];
    }

private:
    bool applySetAttr(string name, string value) {
        switch (name) {
            case "enabled":
                if      (value == "true"  || value == "1") { enabled = true;  return true; }
                else if (value == "false" || value == "0") { enabled = false; return true; }
                return false;
            case "types": {
                uint mask = 0;
                foreach (tok; value.split(",")) {
                    auto t = tok.strip;
                    if      (t.length == 0)          continue;
                    else if (t == "vertex")          mask |= SnapType.Vertex;
                    else if (t == "edge")            mask |= SnapType.Edge;
                    else if (t == "edgeCenter")      mask |= SnapType.EdgeCenter;
                    else if (t == "polygon")         mask |= SnapType.Polygon;
                    else if (t == "polyCenter")      mask |= SnapType.PolyCenter;
                    else if (t == "grid")            mask |= SnapType.Grid;
                    else if (t == "workplane")       mask |= SnapType.Workplane;
                    else if (t == "pivot")           mask |= SnapType.Pivot;
                    else if (t == "intersection")    mask |= SnapType.Intersection;
                    else if (t == "worldAxis")       mask |= SnapType.WorldAxis;
                    else if (t == "straightLine")    mask |= SnapType.StraightLine;
                    else if (t == "rightAngle")      mask |= SnapType.RightAngle;
                    else if (t == "box")             mask |= SnapType.Box;
                    else                             return false;
                }
                enabledTypes = mask;
                return true;
            }
            case "snapMode": {
                if      (value == "global")    { snapScope = SnapMode.Global;    return true; }
                else if (value == "component") { snapScope = SnapMode.Component; return true; }
                else if (value == "item")      { snapScope = SnapMode.Item;      return true; }
                return false;
            }
            case "innerRange": innerRangePx  = parseFloat(value); return true;
            case "outerRange": outerRangePx  = parseFloat(value); return true;
            case "fixedGrid":
                if      (value == "true"  || value == "1") { fixedGrid = true;  return true; }
                else if (value == "false" || value == "0") { fixedGrid = false; return true; }
                return false;
            case "fixedGridSize": fixedGridSize = parseFloat(value); return true;
            case "fixedGridToggle":
                fixedGrid = !fixedGrid;
                return true;
            // typeToggle <name> — flip a single type bit. Powers the
            // Snap popup's per-type checkboxes via snap.toggleType.
            case "typeToggle": {
                uint bit = typeBit(value);
                if (bit == 0) return false;
                enabledTypes ^= bit;
                return true;
            }
            // Per-type wire keys — the same rows `params()` renders as
            // checkboxes. The panel writes them through the Param pointer, so
            // this leg exists for the HTTP / script surface: a test that
            // drives the panel's row must be able to drive it by name, and
            // `knownAttrs()` promises these names anyway.
            default: {
                foreach (i, ref row; snapTypeRows) {
                    if (row.attr != name) continue;
                    if      (value == "true"  || value == "1")
                        { enabledTypes |=  row.bit; return true; }
                    else if (value == "false" || value == "0")
                        { enabledTypes &= ~row.bit; return true; }
                    return false;
                }
                return false;
            }
        }
    }

    // Token -> bit, off the one table `params()` / `setAttr` / `knownAttrs`
    // all read, so a type added there cannot be missing here.
    static uint typeBit(string name) {
        foreach (ref row; snapTypeRows)
            if (row.token == name) return row.bit;
        return 0;
    }

    string typesLabel() const {
        // Stable, human-readable serialisation — matches the input
        // format of `setAttr("types", ...)` so round-trip is exact.
        string[] tokens;
        if (enabledTypes & SnapType.Vertex)       tokens ~= "vertex";
        if (enabledTypes & SnapType.Edge)         tokens ~= "edge";
        if (enabledTypes & SnapType.EdgeCenter)   tokens ~= "edgeCenter";
        if (enabledTypes & SnapType.Polygon)      tokens ~= "polygon";
        if (enabledTypes & SnapType.PolyCenter)   tokens ~= "polyCenter";
        if (enabledTypes & SnapType.Grid)         tokens ~= "grid";
        if (enabledTypes & SnapType.Workplane)    tokens ~= "workplane";
        if (enabledTypes & SnapType.Pivot)        tokens ~= "pivot";
        if (enabledTypes & SnapType.Intersection) tokens ~= "intersection";
        if (enabledTypes & SnapType.WorldAxis)    tokens ~= "worldAxis";
        if (enabledTypes & SnapType.StraightLine) tokens ~= "straightLine";
        if (enabledTypes & SnapType.RightAngle)   tokens ~= "rightAngle";
        if (enabledTypes & SnapType.Box)          tokens ~= "box";
        if (tokens.length == 0) return "";
        string s = tokens[0];
        foreach (t; tokens[1 .. $]) s ~= "," ~ t;
        return s;
    }

    string snapModeLabel() const {
        final switch (snapScope) {
            case SnapMode.Global:    return "global";
            case SnapMode.Component: return "component";
            case SnapMode.Item:      return "item";
        }
    }

    void publishState() {
        setStatePath("snap/enabled",   enabled   ? "true" : "false");
        setStatePath("snap/types",     typesLabel());
        setStatePath("snap/snapMode",  snapModeLabel());
        setStatePath("snap/fixedGrid", fixedGrid ? "true" : "false");
        // Per-type bits — drives the popup's checked-state on each
        // type entry. Mirrors `enabledTypes & SnapType.<X>` truthiness.
        setStatePath("snap/types/vertex",
                     (enabledTypes & SnapType.Vertex)       ? "true" : "false");
        setStatePath("snap/types/edge",
                     (enabledTypes & SnapType.Edge)         ? "true" : "false");
        setStatePath("snap/types/edgeCenter",
                     (enabledTypes & SnapType.EdgeCenter)   ? "true" : "false");
        setStatePath("snap/types/polygon",
                     (enabledTypes & SnapType.Polygon)      ? "true" : "false");
        setStatePath("snap/types/polyCenter",
                     (enabledTypes & SnapType.PolyCenter)   ? "true" : "false");
        setStatePath("snap/types/grid",
                     (enabledTypes & SnapType.Grid)         ? "true" : "false");
        setStatePath("snap/types/workplane",
                     (enabledTypes & SnapType.Workplane)    ? "true" : "false");
        setStatePath("snap/types/pivot",
                     (enabledTypes & SnapType.Pivot)        ? "true" : "false");
        setStatePath("snap/types/intersection",
                     (enabledTypes & SnapType.Intersection) ? "true" : "false");
        setStatePath("snap/types/worldAxis",
                     (enabledTypes & SnapType.WorldAxis)    ? "true" : "false");
        setStatePath("snap/types/straightLine",
                     (enabledTypes & SnapType.StraightLine) ? "true" : "false");
        setStatePath("snap/types/rightAngle",
                     (enabledTypes & SnapType.RightAngle)   ? "true" : "false");
        setStatePath("snap/types/box",
                     (enabledTypes & SnapType.Box)          ? "true" : "false");
    }

    static float parseFloat(string s) {
        return s.length == 0 ? 0.0f : s.to!float;
    }
}

unittest { // The snap config is ONE declaration — and `enabled` is the
    // USER toggle, not the pipe flag.
    //
    // The previous version of this block compared the stage's seven defaults
    // to `SnapPacket.init`'s seven, field by field, because the two sets were
    // written out twice and had drifted (the packet carried inner 8 against
    // the stage's 24, so the four call sites that serve `SnapPacket.init` as a
    // fallback snapped with a 3x narrower acceptance, silently). Since task
    // 0705 both sides ARE `SnapConfig`, so that comparison would be a
    // tautology — an assertion that can no longer fail is not a guard, it is
    // decoration. What it is replaced with is the one thing the split made
    // fragile, and it is not hypothetical: this test is what caught it.
    auto st = new SnapStage();

    // TWO booleans, and a fresh stage must disagree about them. `pipeEnabled`
    // is `Stage`'s registration flag (default TRUE — the stage is in the pipe);
    // `enabled` is the user's master snap toggle (default FALSE — snapping
    // ships off). They were BOTH spelled `enabled` until task 0705, the
    // derived one shadowing the base one. Embedding the config as a sub-struct
    // then broke it: an `alias this` loses to an inherited member, so every
    // `enabled` in and around this stage silently became the pipe flag, and a
    // fresh stage read as "snapping ON".
    assert(st.pipeEnabled,
        "a freshly constructed stage is registered-and-live in the pipe");
    assert(!st.enabled,
        "...and its USER snap toggle is off. If this fires and pipeEnabled "
        ~ "above passed, `enabled` has stopped resolving to SnapConfig's field "
        ~ "and is reading Stage's pipe flag instead");
    assert(&st.enabled is &st.config.enabled,
        "SnapStage.enabled must BE the config's storage — the panel checkbox "
        ~ "binds to its address");

    // Writing one must not move the other.
    st.enabled = true;
    assert(st.config.enabled && st.pipeEnabled,
        "toggling snapping must not touch the pipe registration flag");
    st.enabled = false;

    // The config round-trip, which is now a property of one struct rather than
    // an agreement between two. Still worth asserting: `snapshotConfigToPacket`
    // and `reset` are the undo/redo and scene-reset paths, and a future edit
    // could reintroduce a hand-written field list in either.
    st.innerRangePx = 1.0f;
    st.outerRangePx = 2.0f;
    st.enabled      = true;
    assert(st.snapshotConfigToPacket() != SnapPacket.init,
        "the rig must actually change the config, or the reset below proves "
        ~ "nothing");
    st.reset();
    assert(st.snapshotConfigToPacket() == SnapPacket.init,
        "SnapStage.reset() must restore exactly the declaration initialisers");
    assert(st.pipeEnabled,
        "and reset() must NOT switch the stage out of the pipe");
}

// ---------------------------------------------------------------------------
// S2 (a) of doc/toolpipe_architecture_plan.md — the SNAP stage publishes the
// snap RESULT, not only the snap CONFIG.
//
// Phase (a) is an UNREAD publication: the packet goes onto the stack and
// nothing in the tree reads it, so the neutrality argument is a grep, not a
// test. What a test can prove — and what this block proves — is that the
// thing published is the thing the query already returns, and that it is
// published under exactly the gate that keeps it off the HTTP threads:
//
//   1. GATE. No packet without `SubjectPacket.cursorValid`, and none while the
//      stage is disabled. This is the property that keeps the process-global
//      candidate grids a main-thread affair; a publication that ignored the
//      flag would be a thread-safety change dressed as a packet.
//   2. EQUIVALENCE. Field for field, the published packet is what a direct
//      `snapCursor` at the same pixel with the same config returns. A packet
//      that dropped or crossed a field would pass a "packet exists" test and
//      fails this one.
//   3. DERIVATION. `screenX`/`screenY`/`distPx` are the WINNER's own pixel and
//      its distance from the cursor — checked against an independently
//      computed projection, so projecting the wrong point is caught.
//   4. CONTRACT. On a highlight-without-snap, and on an outright miss, the
//      position-shaped fields stay at their documented defaults. The stage
//      supplies no meaningful query seed, and this is what stops that seed
//      from being published as if it were a measurement.
//
// The fixture is three collinear vertices with NO faces (so `needVis` is false
// and ranking is pure screen distance) and a single enabled type, so the whole
// packet is decided by one candidate walk with no grid / workplane traffic.
// ---------------------------------------------------------------------------
unittest {
    import math             : Vec3, Viewport, ModelSpace, lookAt, perspectiveMatrix,
                              projectToWindowFull;
    import mesh             : Mesh;
    import toolpipe.packets : SubjectPacket;
    import snap             : snapCursor, SnapResult, invalidateSnapGrids;
    import editmode         : EditMode;
    import std.math         : PI, round, sqrt;

    // snap.d's global candidate grids are keyed by (mesh address, mutation
    // version, viewport); a fresh stack Mesh can land on a recycled address
    // with the same zero version, so drop them rather than trust the key.
    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    Mesh m;
    // Deliberately OFF the world origin. A fixture whose winning vertex sits
    // at (0,0,0) makes every "the packet published no position" assertion
    // agree with every "the packet published the winner's position" one, and
    // a producer that dropped a position field would pass both. The offset is
    // in Y only, so the collinear X spacing — and every distance below — is
    // unchanged.
    m.vertices = [
        Vec3(0.00f, 0.25f, 0),   // 0 — directly under the cursor pixel
        Vec3(0.50f, 0.25f, 0),   // 1 — inside the gather range, outside acceptance
        Vec3(3.00f, 0.25f, 0),   // 2 — outside the gather range entirely
    ];

    float pixDist(Vec3 w, int sx, int sy) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every candidate must project on-screen");
        immutable float dx = qx - cast(float)sx;
        immutable float dy = qy - cast(float)sy;
        return sqrt(dx * dx + dy * dy);
    }

    // Cursor A: vertex 0's own pixel — a snap. Cursor B: 50 px to its LEFT,
    // away from the other two — inside the gather range, outside acceptance,
    // i.e. a highlight without a snap.
    float p0x, p0y, p0z;
    assert(projectToWindowFull(m.vertices[0], vp, p0x, p0y, p0z));
    immutable int ax = cast(int)round(p0x), ay = cast(int)round(p0y);
    immutable int bx = ax - 50,             by = ay;

    auto st = new SnapStage();
    st.enabled      = true;
    st.enabledTypes = SnapType.Vertex;   // one type: no grid / workplane traffic
    st.innerRangePx = 20.0f;
    st.outerRangePx = 120.0f;
    // This block is the stage's own consumer, so it says so. Everything below
    // describes what a DEMANDED publication does; the undemanded case has its
    // own block (0, further down) and its own assertion.
    st.demandHit();

    // Fixture premises, stated rather than assumed.
    assert(pixDist(m.vertices[0], ax, ay) < st.innerRangePx,
        "fixture: vertex 0 must be inside acceptance at cursor A");
    assert(pixDist(m.vertices[1], ax, ay) > st.innerRangePx,
        "fixture: vertex 1 must not be able to snap at cursor A");
    assert(pixDist(m.vertices[2], ax, ay) > st.outerRangePx,
        "fixture: vertex 2 must be out of the gather range");
    assert(pixDist(m.vertices[0], bx, by) > st.innerRangePx
        && pixDist(m.vertices[0], bx, by) < st.outerRangePx,
        "fixture: at cursor B vertex 0 must highlight but not snap");
    assert(pixDist(m.vertices[1], bx, by) > pixDist(m.vertices[0], bx, by),
        "fixture: cursor B must leave vertex 0 the winner");

    // Build the stack the mouse-event dispatch builds, minus the cursor flag.
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.editMode = EditMode.Vertices;
    subj.viewport = vp;

    // --- 1. GATE: no cursor, no packet --------------------------------------
    {
        VectorStack vts;
        vts.put(&subj);              // cursorValid stays false
        assert(st.evaluate(vts), "the stage is enabled, so it must publish its config");
        assert(vts.get!SnapPacket() !is null, "the CONFIG packet is unconditional");
        assert(vts.get!SnapHitPacket() is null,
            "S2 gate: without `cursorValid` the stage must not run the query — "
            ~ "that flag is what keeps the process-global candidate grids on "
            ~ "the main thread");
    }

    subj.cursorX     = ax;
    subj.cursorY     = ay;
    subj.cursorValid = true;

    // --- 0. DEMAND: a cursor-valid evaluation with no consumer runs nothing --
    // The cursor gate above bounds WHEN the query may run; this one bounds
    // WHETHER it runs at all. Without it the stage spent a full element-class
    // candidate walk on every mouse-motion event that reached an armed tool,
    // for a packet with no reader (task 0526's measurement, task 0531's fix).
    {
        assert(st.releaseHit(), "the block raised a demand above, so it holds one");
        assert(!st.hitDemanded && st.hitDemandCount == 0);
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts), "the stage is enabled: the CONFIG still ships");
        assert(vts.get!SnapPacket() !is null,
            "the demand gate is on the RESULT only — the config packet is what "
            ~ "the six existing snap consumers read, and it is unconditional");
        assert(vts.get!SnapHitPacket() is null,
            "S2 demand gate: with no consumer asking, the stage must publish no "
            ~ "result — and, the point of the gate, must not run the query to "
            ~ "produce one");
        st.demandHit();
        assert(st.hitDemanded && st.hitDemandCount == 1);
    }

    // --- ...and no packet at all while the stage is disabled ----------------
    {
        st.enabled = false;
        VectorStack vts;
        vts.put(&subj);
        assert(!st.evaluate(vts), "a disabled stage publishes nothing");
        assert(vts.get!SnapHitPacket() is null,
            "S2 gate: a disabled SNAP stage must not publish a result either");
        st.enabled = true;
    }

    // --- 2. EQUIVALENCE: the packet IS the query's own answer ---------------
    invalidateSnapGrids();
    SnapHitPacket hit;
    SnapPacket    cfg;
    {
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts));
        auto p = vts.get!SnapHitPacket();
        assert(p !is null, "S2: a cursor-valid evaluation must publish the result");
        hit = *p;
        cfg = *vts.get!SnapPacket();
    }

    // The reference: the same query every existing consumer runs for itself,
    // with the config the stage just published. The seed is deliberately a
    // position no candidate sits at — if the packet ever started reporting the
    // seed, the assertions below would see it.
    invalidateSnapGrids();
    immutable Vec3 probeSeed = Vec3(7.5f, -3.25f, 1.125f);
    SnapResult ref_ = snapCursor(probeSeed, ax, ay, vp, m, ModelSpace.world(), cfg);
    assert(ref_.snapped && ref_.targetIndex == 0 && ref_.targetType == SnapType.Vertex,
        "fixture: the reference query must snap to vertex 0, else the "
        ~ "equivalence below is vacuous");

    assert(hit.snapped      == ref_.snapped,      "snapped diverged");
    assert(hit.highlighted  == ref_.highlighted,  "highlighted diverged");
    assert(hit.targetType   == ref_.targetType,   "targetType diverged");
    assert(hit.targetIndex  == ref_.targetIndex,  "targetIndex diverged");
    assert(hit.targetSource == ref_.targetSource, "targetSource diverged");
    assert(hit.constraintType == ref_.constraintType, "constraintType diverged");
    assert(hit.worldPos.x == ref_.worldPos.x
        && hit.worldPos.y == ref_.worldPos.y
        && hit.worldPos.z == ref_.worldPos.z,
        "S2 equivalence: the published position must be the query's own, "
        ~ "bit for bit — not a re-derivation of it");
    assert(hit.highlightPos.x == ref_.highlightPos.x
        && hit.highlightPos.y == ref_.highlightPos.y
        && hit.highlightPos.z == ref_.highlightPos.z,
        "S2 equivalence: `highlightPos` is the query's own too — it is a "
        ~ "SEPARATE point from `worldPos` whenever a constraint placed the "
        ~ "position, and the pre-snap ring is drawn at it");
    assert(hit.layer == -1,
        "the winner came from the active mesh (slot 0), whose Document-layer "
        ~ "index the snap service does not hold");
    assert(hit.guideCount == 0,
        "S2 provenance: no guide is registered on this stage, so the walk "
        ~ "ranked by nearest pixel — the same ranking a tool-side snapCursor "
        ~ "would have produced, which is what makes the packet substitutable "
        ~ "for it");

    // --- 3. DERIVATION: the screen point is the WINNER's own pixel ----------
    float wx, wy, wz;
    assert(projectToWindowFull(m.vertices[0], vp, wx, wy, wz));
    assert(hit.screenX == wx && hit.screenY == wy,
        "S2: screenX/screenY are the snapped point's projection, so they must "
        ~ "equal an independent projection of the winning vertex");
    assert(hit.distPx == pixDist(m.vertices[0], ax, ay),
        "S2: distPx is that projection's distance from the cursor pixel — the "
        ~ "very number the candidate walk ranked by");
    assert(hit.distPx <= cfg.innerRangePx,
        "a snap by definition landed inside acceptance");

    // --- 4. CONTRACT: highlight without snap publishes no position ----------
    // Cursor B is inside the gather range of vertex 0 and outside acceptance:
    // the element is still named, the position-shaped fields are not.
    subj.cursorX = bx;
    subj.cursorY = by;
    invalidateSnapGrids();
    {
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts));
        auto p = vts.get!SnapHitPacket();
        assert(p !is null,
            "S2: publication is gated on the CURSOR, not on the outcome — a "
            ~ "query that only highlighted still ran, and still publishes");
        assert(!p.snapped && p.highlighted,
            "fixture: cursor B must highlight vertex 0 without snapping to it");
        assert(p.targetIndex == 0 && p.targetType == SnapType.Vertex,
            "a highlight still names its element");
        assert(p.worldPos.x == 0 && p.worldPos.y == 0 && p.worldPos.z == 0,
            "S2 contract: nothing snapped, so no position is published — the "
            ~ "stage's query seed must never reach the wire");
        assert(p.distPx == float.infinity && p.screenX == 0 && p.screenY == 0,
            "S2 contract: the screen fields are paired with `snapped`");
        // ...but the HIGHLIGHT point is published, because it is paired with
        // `highlighted`, not with `snapped`. This is the one field that makes
        // the packet usable by the overlay renderer at all: the pre-snap ring
        // is drawn HERE, at the candidate, not at the cursor.
        assert(p.highlightPos.x == m.vertices[0].x
            && p.highlightPos.y == m.vertices[0].y
            && p.highlightPos.z == m.vertices[0].z,
            "S2 contract: a highlight publishes its own point — this is the "
            ~ "pixel `snap_render.drawCursorMarker` draws the pre-snap ring "
            ~ "at, and `worldPos` (still default here) is not it");
    }

    // --- ...and an outright miss is the packet's own `.init` -----------------
    subj.cursorX = 5;
    subj.cursorY = 5;      // a corner pixel: every candidate is far away
    invalidateSnapGrids();
    {
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts));
        auto p = vts.get!SnapHitPacket();
        assert(p !is null,
            "a miss still publishes: an ABSENT packet means the query did not "
            ~ "run, a published one with `snapped == false` means it found "
            ~ "nothing, and downstream must be able to tell those apart");
        assert(*p == SnapHitPacket.init,
            "S2 contract: a miss is the packet's own defaults, field for field");
    }

    invalidateSnapGrids();
}

// ---------------------------------------------------------------------------
// The DEMAND gate on the per-cursor RESULT — task 0531, closing the cost that
// task 0526 measured.
//
// The block above pins WHAT is published. This one pins that the publication
// does not HAPPEN unasked, and it pins it the only way that is worth pinning:
// by counting candidate enumerations, not packets. "No packet" would still
// pass if the stage ran the whole query and then threw the answer away, and
// the whole point of the gate is the query — an element-class walk over every
// vertex, edge centre and polygon centre near the cursor, on every mouse-
// motion event that reaches an armed tool.
//
// The counter is a registered guide, used as an instrument rather than as a
// ranking policy: `RecordingGuide.proximity` is called once per candidate that
// survives the gather range, and it counts. It admits nothing, so it cannot
// influence what the block asserts about publication.
//
//   1. UNASKED. No demand — no candidate is enumerated, and no packet exists.
//   2. ASKED. One demand — candidates are enumerated and the packet appears.
//   3. COUNTER. Two consumers need two releases; one leaving does not starve
//      the other. This is S2 phase (b)'s shape: six consumers migrate one
//      commit at a time, so overlapping demands are the normal case.
//   4. UNPAIRED RELEASE. Reported, not wrapped past zero.
//   5. RESET. A scene reset does NOT withdraw a demand — see the contract at
//      `demandHit`. This assertion exists because the neighbouring registry
//      IS cleared there, and the difference has to be deliberate.
// ---------------------------------------------------------------------------
unittest {
    import math             : Vec3, Viewport, lookAt, perspectiveMatrix,
                              projectToWindowFull;
    import mesh             : Mesh;
    import toolpipe.packets : SubjectPacket;
    import snap             : invalidateSnapGrids;
    import editmode         : EditMode;
    import std.math         : PI, round;

    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    Mesh m;
    m.vertices = [Vec3(0, 0, 0)];      // one candidate, right under the cursor

    float p0x, p0y, p0z;
    assert(projectToWindowFull(m.vertices[0], vp, p0x, p0y, p0z));

    auto st = new SnapStage();
    st.enabled      = true;
    st.enabledTypes = SnapType.Vertex;   // one type: one candidate walk
    st.innerRangePx = 20.0f;
    st.outerRangePx = 120.0f;

    auto probe = new RecordingGuide();
    st.addGuide(probe);

    SubjectPacket subj;
    subj.mesh        = &m;
    subj.editMode    = EditMode.Vertices;
    subj.viewport    = vp;
    subj.cursorX     = cast(int)round(p0x);
    subj.cursorY     = cast(int)round(p0y);
    subj.cursorValid = true;            // the cursor gate is WIDE OPEN here

    size_t evaluateOnce() {
        invalidateSnapGrids();
        immutable size_t before = probe.queries;
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts), "an enabled stage always publishes its config");
        assert(vts.get!SnapPacket() !is null,
            "the demand gate governs the RESULT only; the CONFIG is what every "
            ~ "existing consumer reads and it must keep shipping");
        immutable bool published = vts.get!SnapHitPacket() !is null;
        immutable size_t walked  = probe.queries - before;
        assert(published == (walked > 0),
            "the packet and the walk are the same event: a published packet "
            ~ "means the query ran, an absent one means it did not");
        return walked;
    }

    // --- 1. UNASKED ---------------------------------------------------------
    assert(st.hitDemandCount == 0, "a fresh stage has no consumer");
    assert(evaluateOnce() == 0,
        "0531: with no consumer asking, a cursor-valid evaluation must not "
        ~ "enumerate a single candidate — that walk, once per mouse-motion "
        ~ "event, is the whole of the cost measured in task 0526");

    // --- 2. ASKED -----------------------------------------------------------
    st.demandHit();
    assert(st.hitDemanded && st.hitDemandCount == 1);
    assert(evaluateOnce() == 1,
        "one consumer, one candidate in range, one enumeration — the gate "
        ~ "withholds the query, it does not break it");

    // --- 3. COUNTER: two consumers, two releases ----------------------------
    st.demandHit();
    assert(st.hitDemandCount == 2);
    assert(st.releaseHit() && st.hitDemandCount == 1);
    assert(evaluateOnce() == 1,
        "one consumer leaving must not starve the one still reading — S2 "
        ~ "phase (b) migrates six of them one commit at a time, so two live "
        ~ "demands is the ordinary state, not an edge case");
    assert(st.releaseHit() && st.hitDemandCount == 0);
    assert(evaluateOnce() == 0, "the last consumer leaving closes the gate again");

    // --- 4. UNPAIRED RELEASE ------------------------------------------------
    assert(!st.releaseHit(),
        "a release with no matching demand is a caller bug and is reported as "
        ~ "one");
    assert(st.hitDemandCount == 0,
        "...and it must not go negative: a demand counter that wrapped would "
        ~ "wedge the gate open for the life of the process");

    // --- 5. RESET leaves the demand alone -----------------------------------
    st.demandHit();
    st.reset();
    assert(st.hitDemandCount == 1,
        "a demand is scoped to a CONSUMER, not to a gesture or a scene: "
        ~ "`/api/reset` resets the scene, and a consumer that is still alive "
        ~ "is still reading. The guide registry beside it IS cleared there, "
        ~ "for the opposite reason (a guide IS gesture-scoped), and this "
        ~ "assertion is what keeps the two from being confused for each other");
    assert(st.guideCount == 0, "...while the registry did clear, as it must");

    invalidateSnapGrids();
}

// ---------------------------------------------------------------------------
// S4(a) of doc/toolpipe_architecture_plan.md — the guide REGISTRY.
//
// The equivalence of the two ranking paths is pinned in `source/snap.d`. What
// belongs here is the registry's own contract, and the first clause of it is
// the neutrality claim itself:
//
//   1. EMPTY. A fresh stage holds no guide, and nothing in this tree registers
//      one. That is what makes the arbitration branch in `snapCursor`
//      unreachable, and it is the whole of phase (a)'s neutrality argument.
//      The assertion is cheap; its value is that a later commit which
//      registers a guide from inside the stage cannot do so silently.
//   2. LIFECYCLE (MEASURED). Add, remove, and add-is-idempotent — a guide
//      registered twice is one guide, not two votes in the arbitration.
//      `reset()` empties the registry, because a guide is scoped to a gesture
//      and a scene reset ends every gesture there was.
//   3. RANGES PUSHED IN (MEASURED direction). Registration hands the guide the
//      stage's current pair, and a later evaluation hands it the pair again,
//      so a range changed mid-gesture reaches a guide already registered. The
//      guide never sources the pair for itself.
// ---------------------------------------------------------------------------
version (unittest) {
    private class RecordingGuide : SnapGuide {
        import math : Vec3;
        float  innerPx = -1, outerPx = -1;
        int    pushes;
        size_t queries;

        void limits(float i, float o) { innerPx = i; outerPx = o; ++pushes; }
        bool proximity(Vec3 candWorld, SnapType type, int idx, int slot,
                       out float distPx, ref int priority)
        {
            ++queries;
            return false;   // admits nothing: this guide is here to be counted
        }
        void setDrawState(GuideDrawState s) {}
        uint flags() const { return 0; }
    }
}

unittest {
    auto st = new SnapStage();

    // --- 1. EMPTY -----------------------------------------------------------
    assert(st.guideCount == 0,
        "S4(a): a fresh SNAP stage registers no guide, and neither does any "
        ~ "tool in this tree — that emptiness is what keeps the arbitration "
        ~ "path in snapCursor unreachable, which is the entire neutrality "
        ~ "argument for this stage");

    // --- 3. RANGES PUSHED IN, at registration -------------------------------
    auto g = new RecordingGuide();
    st.innerRangePx = 11.0f;
    st.outerRangePx = 22.0f;
    st.addGuide(g);
    assert(st.guideCount == 1);
    assert(g.pushes == 1 && g.innerPx == 11.0f && g.outerPx == 22.0f,
        "the environment's ranges are pushed IN when a guide registers — the "
        ~ "guide does not source the pair for itself");

    // --- 2. LIFECYCLE -------------------------------------------------------
    st.addGuide(g);
    assert(st.guideCount == 1,
        "registering the same guide twice must be a no-op, not a second vote "
        ~ "in the arbitration");
    st.addGuide(null);
    assert(st.guideCount == 1, "a null guide is not a guide");

    auto h = new RecordingGuide();
    st.addGuide(h);
    assert(st.guideCount == 2 && st.guides[0] is g && st.guides[1] is h,
        "the registry keeps registration order — the arbitration settles "
        ~ "equal priorities by it");

    assert(st.removeGuide(g) && st.guideCount == 1 && st.guides[0] is h,
        "remove takes out the named guide and leaves the rest in order");
    assert(!st.removeGuide(g),
        "removing a guide that is not registered reports so rather than "
        ~ "corrupting the registry");

    // --- 3. ...and again on every evaluation --------------------------------
    // A mid-gesture range change must reach a guide that is already
    // registered, so the push is not a registration-time courtesy.
    st.innerRangePx = 33.0f;
    st.outerRangePx = 44.0f;
    st.enabled      = true;
    {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;               // cursorValid stays false: no query
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts));
    }
    assert(h.innerPx == 33.0f && h.outerPx == 44.0f,
        "an evaluation re-pushes the current ranges, so a pair changed "
        ~ "mid-gesture reaches a guide that registered before the change");
    assert(h.queries == 0,
        "and it does so WITHOUT running the query — the cursor gate still "
        ~ "governs whether any candidate is enumerated at all");

    // --- 2. reset() empties the registry ------------------------------------
    st.reset();
    assert(st.guideCount == 0,
        "a scene reset ends every gesture there was, so it can leave no guide "
        ~ "registered — a guide outliving the tool that owns it is the one "
        ~ "lifecycle error the measured add/remove pair rules out");
}

// ---------------------------------------------------------------------------
// SNAPPING HAS A TOOL PROPERTIES SURFACE — `params()`.
//
// It had none. The panel's per-stage loop is literally
//
//     if (stage.params().length == 0) continue;
//
// and `SnapStage` was the one pipe stage that never overrode `params()` — the
// loop's own comment lists "Action Center, Falloff, Snap, ..." as the sections
// it expects, so the section was intended and simply never got a schema. The
// consequence was not cosmetic: the master toggle and the type set lived only
// in the status line, and `innerRangePx` / `outerRangePx` — the two numbers
// that decide whether a drag sticks to anything at all — were reachable ONLY
// over HTTP.
//
//   1. NON-EMPTY. The one condition the panel loop tests.
//   2. COVERAGE. Every field the brief named is a row: master enable, scope
//      mode, the whole type set, the two pixel ranges, the fixed-grid pair.
//   3. THE ROWS ARE THE STAGE'S OWN FIELDS. A panel row that wrote a private
//      copy of a range would be the very defect the campaign spent a task
//      naming (`constraint.d`'s duplicated 24/40). Checked by writing through
//      the Param pointer and reading the field.
//   4. DEFAULTS ARE THE MEASURED ONES. 24 / 40, and they are the SERVICE's.
//   5. TYPE MIRROR ROUND-TRIP. `enabledTypes` stays the single source of
//      truth: `params()` syncs the mirror from it, `onParamChanged` folds one
//      bit back, and nothing else is disturbed.
//   6. WIRE PARITY. Every per-type row is also a `setAttr` key, and
//      `knownAttrs()` names every key `setAttr` accepts — so a panel row and
//      a script can drive the same control by the same name.
// ---------------------------------------------------------------------------
unittest {
    import std.algorithm : canFind, map;
    import std.array     : array;

    auto st = new SnapStage();

    // --- 1. NON-EMPTY -------------------------------------------------------
    assert(st.params().length != 0,
        "the Tool Properties per-stage loop skips any stage whose params() is "
        ~ "empty, and SnapStage was that stage — snapping had no panel at all");

    auto names = st.params().map!(p => p.name).array;

    // --- 2. COVERAGE --------------------------------------------------------
    foreach (n; ["enabled", "snapMode", "fixedGrid", "fixedGridSize",
                 "innerRange", "outerRange"])
        assert(names.canFind(n),
            "the panel must expose `" ~ n ~ "`: the master enable, the scope "
            ~ "mode, the fixed-grid pair and the two ranges are the whole of "
            ~ "what this stage already has and already measured");
    foreach (ref row; snapTypeRows)
        assert(names.canFind(row.attr),
            "every snap TYPE must be a row (`" ~ row.attr ~ "` missing) — the "
            ~ "type set decides which candidates exist, and it was reachable "
            ~ "only from the status line");

    // --- 3 + 4. THE ROWS ARE THE STAGE'S FIELDS, at the measured defaults ---
    foreach (ref p; st.params()) {
        if (p.name == "innerRange") {
            assert(p.fptr is &st.innerRangePx,
                "the Inner Range row must write the SNAP SERVICE's own field. "
                ~ "A private per-tool copy of this number is the defect the "
                ~ "campaign already named once; the panel must not add a "
                ~ "second one");
            assert(*p.fptr == 24.0f && p.default_.f == 24.0f,
                "24 px is the measured acceptance and it belongs to the "
                ~ "service — the row reads it rather than restating it");
        }
        if (p.name == "outerRange") {
            assert(p.fptr is &st.outerRangePx, "same for the Outer Range row");
            assert(*p.fptr == 40.0f && p.default_.f == 40.0f,
                "40 px is the measured gather range");
        }
        if (p.name == "enabled")
            assert(p.bptr is &st.enabled,
                "the master toggle must be the stage's own `enabled`, the one "
                ~ "`evaluate` gates on — not a second boolean the panel keeps");
    }

    // --- 5. TYPE MIRROR ROUND-TRIP ------------------------------------------
    // Turning a type OFF from the panel must clear exactly its bit and leave
    // every other type alone.
    //
    // The fixture sets its OWN multi-bit mask rather than borrowing whatever
    // the factory default happens to be. Two reasons, and the second is why
    // this is not merely tidiness: the default is Vertex alone, so a test
    // riding on it would have no OTHER bits for "exactly one bit moved" to
    // protect and that assertion would pass vacuously. Owning the mask keeps
    // the round-trip claim at full strength and decouples it from a default
    // it does not test.
    {
        st.enabledTypes = SnapType.Vertex | SnapType.EdgeCenter
                        | SnapType.PolyCenter | SnapType.Grid;
        immutable uint before = st.enabledTypes;
        assert((before & SnapType.PolyCenter) != 0, "fixture: PolyCenter is on");
        assert((before & ~cast(uint)SnapType.PolyCenter) != 0,
            "fixture: at least one OTHER bit must be set, or the 'exactly one "
            ~ "bit moved' assertion below has nothing to protect");

        Param* row;
        foreach (ref p; st.params()) if (p.name == "typePolyCenter") row = &p;
        assert(row !is null && row.bptr !is null);
        assert(*row.bptr,
            "params() must SYNC the mirror from the bitmask on every call — a "
            ~ "row that showed a stale value would let the next click write "
            ~ "back a bit the user never saw");

        *row.bptr = false;                   // what the checkbox does
        st.onParamChanged("typePolyCenter");
        assert((st.enabledTypes & SnapType.PolyCenter) == 0,
            "...and onParamChanged must fold the row back into `enabledTypes`, "
            ~ "which stays the one thing every reader consults");
        assert((st.enabledTypes | SnapType.PolyCenter) == before,
            "exactly one bit moved: folding must not rebuild the whole mask "
            ~ "from a mirror that may hold slots written since the last sync");

        // ...and back on again, through the same path.
        foreach (ref p; st.params()) if (p.name == "typePolyCenter") row = &p;
        assert(!*row.bptr, "the re-sync must show the cleared bit");
        *row.bptr = true;
        st.onParamChanged("typePolyCenter");
        assert(st.enabledTypes == before, "round-trip is exact");
    }

    // --- 5b. THE STALE MIRROR, ACTUALLY MADE STALE --------------------------
    // The "exactly one bit moved" assertion above names the defect it guards:
    // folding must not rebuild the whole mask "from a mirror that may hold
    // slots written since the last sync". But nothing above ever makes a slot
    // stale — `params()` re-syncs the mirror from the bitmask on entry, so at
    // every point above the mirror already agrees with the mask and a
    // rebuild-the-world implementation computes the same answer and passes.
    // That assertion is therefore vacuous on its own; this block is what makes
    // the claim bite.
    //
    // The staleness is not hypothetical. `setAttr("types", ...)` — the HTTP /
    // script path — assigns `enabledTypes` directly and never touches
    // `_typeMirror`. So a script write followed by a panel click is a real
    // sequence in which the mirror holds values from before the write.
    {
        // Capture the checkbox's write target from a params() call made BEFORE
        // the script write, and deliberately do NOT call params() again: a
        // re-sync would repair the mirror and destroy the very staleness under
        // test. The pointer stays valid across calls because it addresses the
        // stage's own `_typeMirror` slot, not the returned array.
        bool* pcMirror;
        foreach (ref p; st.params())
            if (p.name == "typePolyCenter") pcMirror = p.bptr;
        assert(pcMirror !is null, "fixture: the PolyCenter row must exist");

        // The script write. `edge` is a bit the mirror has never seen set;
        // Grid / EdgeCenter are bits the mirror still believes are set.
        assert(st.setAttr("types", "vertex,edge,polyCenter"),
            "fixture: the script path must accept this type list");
        assert(st.enabledTypes ==
               (SnapType.Vertex | SnapType.Edge | SnapType.PolyCenter),
            "fixture: the script write lands whole");

        // Now the panel click, on the stale mirror.
        *pcMirror = false;
        st.onParamChanged("typePolyCenter");

        assert(st.enabledTypes == (SnapType.Vertex | SnapType.Edge),
            "a panel click must clear ONLY the bit it names, folding into the "
            ~ "mask as it stands NOW. Rebuilding the mask from the mirror "
            ~ "would resurrect Grid and EdgeCenter (which the stale mirror "
            ~ "still shows set) and would drop Edge (which the script set and "
            ~ "the mirror has never seen) — silently undoing a script write "
            ~ "because the user touched an unrelated checkbox");
    }

    // --- 6. WIRE PARITY -----------------------------------------------------
    {
        auto known = st.knownAttrs();
        foreach (n; ["enabled", "types", "snapMode", "innerRange", "outerRange",
                     "fixedGrid", "fixedGridSize", "fixedGridToggle",
                     "typeToggle"])
            assert(known.canFind(n),
                "knownAttrs() is the forms validator's universe and must name "
                ~ "every key setAttr accepts — `" ~ n ~ "` is missing");

        foreach (ref row; snapTypeRows) {
            assert(known.canFind(row.attr),
                "a per-type row that params() renders but knownAttrs() does "
                ~ "not name is a control the panel can drive and a script "
                ~ "cannot");
            assert(st.setAttr(row.attr, "false"),
                "`" ~ row.attr ~ "` must be settable by name");
            assert((st.enabledTypes & row.bit) == 0);
            assert(st.setAttr(row.attr, "true"));
            assert((st.enabledTypes & row.bit) != 0);
            assert(!st.setAttr(row.attr, "maybe"),
                "a non-boolean value is refused rather than silently taken");
        }
        assert(!st.setAttr("typeNoSuchThing", "true"),
            "an unknown per-type key must still be refused — the new default "
            ~ "leg in applySetAttr must not swallow every name");
    }

    // A fresh stage's schema must not have disturbed the config it reports.
    st.reset();
    assert(st.snapshotConfigToPacket() == SnapPacket.init,
        "reading params() / folding a row must leave `reset()` restoring the "
        ~ "same defaults it always did");
}

// ---------------------------------------------------------------------------
// STARTUP ARMING — `pushEnabled` / `popEnabled`.
//
// The reference's tool-activation command carries a "snap state at startup"
// argument; supplying it saves the previous master enable under the activating
// preset's NAME, writes the new one, and the drop restores it. This is that
// pair. The four properties that make it safe to arm a global from a tool:
//
//   1. SAVE AND RESTORE, both polarities. Arming from OFF hands back OFF;
//      arming from ON (a user who already had snapping on) hands back ON, not
//      the armed value. A restore that always wrote `false` would silently
//      switch snapping off for that user on every tool drop.
//   2. THE POP IS NAME-KEYED. A pop from something that never pushed is inert.
//      Without this an unbalanced drop writes a stale value into a global
//      nobody armed.
//   3. RESET CLEARS THE SLOT. `reset()` is the `/api/reset` clean slate and it
//      runs BEFORE the tool drop the same reset triggers, so the drop's pop
//      arrives afterwards; if the slot survived, it would write the pre-reset
//      value back over the clean slate. This is the cross-test-bleed shape.
//   4. RE-PUSH RE-KEYS. Two arms in a row leave exactly one outstanding, the
//      newer one — the reference's single slot, not a stack.
// ---------------------------------------------------------------------------
unittest {
    // --- 1. save/restore, both polarities ----------------------------------
    {
        auto st = new SnapStage();
        assert(!st.enabled, "setup: the stage still ships snapping OFF");
        st.pushEnabled("tool.a", true);
        assert(st.enabled, "arming must set the master enable");
        assert(st.hasPushedEnabled("tool.a"));
        st.popEnabled("tool.a");
        assert(!st.enabled, "the drop must hand back the OFF it was given");
        assert(!st.hasPushedEnabled("tool.a"), "a balanced pop empties the slot");
    }
    {
        auto st = new SnapStage();
        st.enabled = true;                       // the user turned snapping on
        st.pushEnabled("tool.a", true);
        assert(st.enabled);
        st.popEnabled("tool.a");
        assert(st.enabled,
            "a user who had snapping ON before the tool must still have it ON "
            ~ "after the drop — the restore writes the SAVED value, never a "
            ~ "constant");
    }

    // --- 2. the pop is name-keyed ------------------------------------------
    {
        auto st = new SnapStage();
        st.enabled = true;
        st.popEnabled("tool.a");
        assert(st.enabled,
            "a pop from something that never pushed must be inert — it must "
            ~ "not write the zero-initialised saved value into the global");
        st.pushEnabled("tool.a", true);
        st.enabled = false;                      // as if the user toggled it off
        st.popEnabled("tool.b");
        assert(!st.enabled,
            "a pop keyed to a different owner must leave the global alone");
        assert(st.hasPushedEnabled("tool.a"),
            "and must leave the real owner's push outstanding");
    }

    // --- 3. reset clears the slot ------------------------------------------
    {
        auto st = new SnapStage();
        st.enabled = true;                       // user had snapping on ...
        st.pushEnabled("tool.a", true);          // ... then armed a tool
        st.reset();                              // /api/reset: clean slate
        assert(!st.enabled, "reset() still lands on the shipped default");
        assert(!st.hasPushedEnabled("tool.a"),
            "reset() must drop the outstanding push");
        st.popEnabled("tool.a");                 // the tool drop reset triggers
        assert(!st.enabled,
            "the tool drop that follows a reset must NOT resurrect the "
            ~ "pre-reset value — that is snapping left armed across a reset "
            ~ "and bleeding into the next test in the same process");
    }

    // --- 4. re-push re-keys a single slot ----------------------------------
    {
        auto st = new SnapStage();
        st.pushEnabled("tool.a", true);
        st.pushEnabled("tool.b", true);
        assert(!st.hasPushedEnabled("tool.a") && st.hasPushedEnabled("tool.b"),
            "one slot, re-keyed — not a stack");
        st.popEnabled("tool.a");
        assert(st.enabled, "the displaced owner's pop is inert");
        st.popEnabled("tool.b");
        assert(st.enabled,
            "and tool.b saved the value tool.a had already armed, so the "
            ~ "restore is that armed value");
    }

    // An empty owner is never a key — it is the 'nothing outstanding' marker.
    {
        auto st = new SnapStage();
        st.pushEnabled("", true);
        assert(!st.enabled && !st.hasPushedEnabled(""),
            "an empty owner must not arm and must not claim the slot");
    }
}

// ---------------------------------------------------------------------------
// THIS SECTION'S LABELS ARE DISTINCT — FOR THE READER, NOT FOR ImGui
// (task 0638, re-founded by task 0640).
//
// The original reason was mechanical: the panel pushed no id scope anywhere,
// so this section's title and every one of its rows hashed against ONE seed
// and two equal strings were two widgets being one widget — the click landed
// on whichever drew first and the other was unreachable. The master toggle
// shipped labelled "Snapping", the same text as the title, and that was the
// owner-reported defect.
//
// That reason no longer holds. `PropertyPanel` now opens an id scope per
// section (around the header as well as the body) and per row, keyed on the
// stage id and the parameter's WIRE NAME — so identical labels are legal
// anywhere in the column, and proving that is what
// `tests/test_property_panel_id_scope.d` does against the live ids.
//
// What survives is a LEGIBILITY rule, and only for this one stage: a section
// titled "Snapping" holding a row also labelled "Snapping", or two type
// toggles both reading "Grid", is a control the user cannot name — a UI
// defect, not an identity one. Do NOT read this as a rule about the column:
// generalising it back is exactly the trap 0640 removed.
//
// The wire name is pinned in the same breath, in the opposite direction: the
// LABEL had to move and the NAME must not, because `enabled` is the HTTP key
// (`tool.pipe.attr snap enabled …`) and the status-line state path. A "fix"
// that renamed the param would break both while making this file look tidier.
// ---------------------------------------------------------------------------
unittest {
    auto st = new SnapStage();

    // The title is the shared constant — the section header and the tab entry
    // both read it, so pinning rows against it pins rows against both.
    assert(st.displayName() == kSnapDisplayName,
        format("the section title must be the single-sourced constant, got %s",
               st.displayName()));

    auto ps = st.params();
    assert(ps.length > 1, "setup: the stage must expose a schema to collide with");

    // --- 1. No row repeats the title it is drawn under. --------------------
    foreach (ref p; ps)
        assert(p.label != kSnapDisplayName,
            format("row '%s' is labelled \"%s\", the same text as the title "
                 ~ "above it — legal to ImGui since task 0640, but the user "
                 ~ "then has two controls with one name and no way to say "
                 ~ "which is which", p.name, p.label));

    // --- 2. No two rows repeat each other either. --------------------------
    foreach (i, ref a; ps)
        foreach (ref b; ps[i + 1 .. $])
            assert(a.label != b.label,
                format("rows '%s' and '%s' share the label \"%s\" — same "
                     ~ "unreadable pair, one row deeper", a.name, b.name,
                       a.label));

    // --- 3. The wire name did NOT move with the label. ---------------------
    bool sawEnabled = false;
    foreach (ref p; ps) {
        if (p.name != "enabled") continue;
        sawEnabled = true;
        assert(p.kind == Param.Kind.Bool,
            "the master toggle stays a bool on the wire");
        assert(p.label != "enabled" && p.label.length > 0,
            "and it keeps a human label, not its own wire key");
    }
    assert(sawEnabled,
        "the master toggle's wire key must still be `enabled` — it is the "
        ~ "HTTP surface and the status-line state path, and only the LABEL "
        ~ "was ever in question");
}
