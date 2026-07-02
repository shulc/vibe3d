module toolpipe.stages.actcenter;

import std.format : format;

import math    : Vec3, Pin, Viewport, screenRay, screenPointToRay, rayPlaneIntersect, applyAffine;
import mesh    : Mesh, MeshCacheKey;
import editmode : EditMode;
import toolpipe.stage    : Stage, TaskCode, ordAcen;
import params           : Param, IntEnumEntry, wireTagForValue, valueForWireTag;
// pipeline imports moved to packet-only — Phase 6 cleanup
import toolpipe.packets  : SymmetryPacket, ActionCenterPacket;
import operator          : Operator, Task, VectorStack, PacketKind;
import popup_state       : setStatePath;
import document          : Layer;

// ---------------------------------------------------------------------------
// ActionCenterStage — phase 7.2a. Sits at ordinal 0x60. Replaces
// hard-coded `selectionCentroid*` in Move / Rotate / Scale with a pluggable
// origin produced by one of the `actr.<mode>` modes.
//
// Modes (the `actr.<X>` presets):
//   - Auto       — selection centroid if anything selected, else
//                  geometry centroid. Click-outside-gizmo writes
//                  `userPlacedCenter` and `userPlaced=true` but mode
//                  STAYS Auto ("Auto NOT fixed; click away → new
//                  center"). Re-selecting "Auto" in the
//                  popup clears userPlaced. The same click-outside
//                  hook also applies to None and Screen — see those
//                  modes below.
//   - Select     — world-BBOX CENTER of the selection (not the per-vertex
//                  average). Implemented via centroidWithGeometryFallback()
//                  → mesh.selectionBBoxCenter* = (min+max)*0.5 over selected
//                  elements. On an EMPTY selection falls back to the whole-mesh
//                  bbox center (the "any" flag in selectionBBoxCenter* bboxes
//                  all geometry when nothing is selected — intentional, kept
//                  as-is). `selectSubMode` picks which side of the bbox
//                  (center / top / bottom / back / front / left / right in
//                  world XYZ); the non-Center paths compute the bbox extremes
//                  directly (actcenter.d selectionCentroid body) and return
//                  Vec3(0,0,0) on an empty set — a minor inconsistency vs the
//                  Center path's whole-mesh fallback, intentionally unchanged.
//   - SelectAuto — same bbox-center POSITION as Select (calls
//                  selectionCentroid(SelectSubMode.Center) directly,
//                  actcenter.d:737); AxisStage realigns the basis to the
//                  major world axis — the action-center POSITION is lockstep.
//   - Origin     — world (0,0,0).
//   - Screen     — selection centroid (the "screen" aspect is the
//                  AXIS orientation handled by AxisStage; the action-
//                  center POSITION just tracks the selection like
//                  Auto). Click-outside relocates the gizmo onto a
//                  camera-perpendicular plane through the selection
//                  center; userPlaced wins until mode is switched.
//   - Manual     — sticky `manualCenter`, ignores selection (7.2b).
//   - Element / Local / Border — see 7.2d / 7.2e.
//
// 7.2a implements Auto + Select + SelectAuto only — Origin is trivial
// (constant), the others land in subsequent subphases.
// ---------------------------------------------------------------------------
class ActionCenterStage : Stage, Operator {
    // Phase 1 of doc/operator_refactor_plan.md: persistent packet for
    // VectorStack publishing. Updated in evaluate(VectorStack) from the
    // ToolState result of the legacy evaluate path.
    private ActionCenterPacket _publishedPacket;

    Task task() const { return Task.Acen; }
    PacketKind[] requiredPackets() const { return [PacketKind.Subject]; }

    bool evaluate(ref VectorStack vts) {
        if (!enabled) return false;
        import toolpipe.packets : SubjectPacket, WorkplanePacket,
                                  SymmetryPacket;
        // Cache live viewport + upstream workplane so listAttrs
        // (called outside evaluation) and Screen mode can re-derive
        // the same value the pipeline just produced.
        if (auto subj = vts.get!SubjectPacket()) lastView_ = subj.viewport;
        if (auto wp = vts.get!WorkplanePacket()) {
            lastWpCenter_ = wp.center;
            lastWpNormal_ = wp.normal;
        }
        ActionCenterPacket pkt;
        // Local mode's per-frame center comes from the cached cluster
        // partition (see localCenterAndClustersCached) so the O(E·V) BFS is
        // not redone every drag frame. All other modes use the const
        // computeCenter() path (cheap centroid/bbox scans).
        Vec3[] localCenters;
        int[]  localClusterOf;
        if (mode == Mode.Local && mesh_ !is null) {
            pkt.center = localCenterAndClustersCached(localCenters, localClusterOf);
        } else {
            pkt.center = computeCenter();
        }

        // Phase 7.6 (BaseSide gizmo): when symmetry is on and the
        // selection contains BOTH sides of the plane (via 7.6c
        // auto-add or explicit multi-pick), the raw selection
        // centroid sits ON the symmetry plane — the gizmo lands at
        // the axis of symmetry instead of the user's clicked half.
        // Restrict the centroid to base-side verts so the gizmo
        // follows the side the user anchored on.
        if (auto sym = vts.get!SymmetryPacket()) {
            if (sym.enabled
             && sym.vertSign.length == sym.pairOf.length
             && sym.vertSign.length > 0
             && !userPin.placed
             && mode != Mode.Origin && mode != Mode.Manual
             && mode != Mode.Element && mode != Mode.Local
             && mode != Mode.Pivot  && mode != Mode.Parent)
            {
                Vec3 baseCen;
                if (baseSideCentroid(*sym, baseCen))
                    pkt.center = baseCen;
            }
        }

        pkt.isAuto = (mode == Mode.Auto && !userPin.placed);
        pkt.type   = cast(int)mode;

        // Phase 3 of the action-center parity plan: Local mode publishes
        // per-cluster pivots so transform tools can scale/rotate each
        // cluster around its own centroid (actr.local).
        if (mode == Mode.Local && mesh_ !is null) {
            if (localCenters.length >= 2) {
                pkt.clusterCenters = localCenters;
                pkt.clusterOf      = localClusterOf;
            }
        }
        _publishedPacket = pkt;
        vts.put(&_publishedPacket);
        return true;
    }

    enum Mode {
        Auto       = 0,
        Select     = 1,
        SelectAuto = 2,
        Element    = 3,    // 7.2d
        Local      = 4,    // 7.2e
        Origin     = 5,    // 7.2b
        Screen     = 6,    // 7.2b
        Border     = 7,    // 7.2e
        Manual     = 8,    // 7.2b
        // The "(none)" entry in the Action Center popup —
        // `tool.clearTask "axis" "center"` (drops both ACEN+AXIS from
        // the toolpipe). We keep the stage installed but publish a
        // fixed origin pivot and
        // mark the packet non-Auto, so transform tools can fall back to
        // world origin without a special-case.
        None       = 9,
        // Task 0082 — new item-hierarchy modes.
        Pivot      = 10,  // center = primary item's pivot world position
        Parent     = 11,  // center = parent item's world position
    }
    enum SelectSubMode {
        Center = 0,
        Top    = 1, Bottom = 2,
        Back   = 3, Front  = 4,
        Left   = 5, Right  = 6,
    }

    // ------------------------------------------------------------------
    // Single-sourced `mode` / `selectSubMode` token<->value tables (task
    // 0184 / audit-2 C2). `mode` needs TWO tables — this IS the
    // universe-vs-visibility split for an enum, not just a hoist:
    //   - `modeEntries`     (11, no `manual`) — the Tool Properties PANEL
    //     dropdown (params()). `manual` has no dedicated popup entry (it's
    //     reached via `cenX`/`cenY`/`cenZ` implicitly promoting the mode —
    //     see applySetAttr — not a direct panel pick).
    //   - `modeEntriesFull` (12, incl `manual`) — the WIRE universe read by
    //     `modeLabel()` (stringify) and `applySetAttr("mode", ...)` (parse).
    // Both tables are read-only lookups via wireTagForValue/valueForWireTag;
    // neither can drift from the other's ENTRIES since `modeEntries` is not
    // duplicated data — it is simply a strict subset chosen for panel
    // display. See the enforcement unittest at the bottom of this file
    // (replaces the retired "KEEP IN SYNC" comment on knownAttrs()).
    // ------------------------------------------------------------------
    private static immutable IntEnumEntry[] modeEntries = [
        IntEnumEntry(cast(int)Mode.None,       "none",       "(none)"),
        IntEnumEntry(cast(int)Mode.Auto,       "auto",       "Automatic"),
        IntEnumEntry(cast(int)Mode.Select,     "select",     "Selection"),
        IntEnumEntry(cast(int)Mode.Border,     "border",     "Selection Border"),
        IntEnumEntry(cast(int)Mode.SelectAuto, "selectauto", "Selection Center Auto Axis"),
        IntEnumEntry(cast(int)Mode.Element,    "element",    "Element"),
        IntEnumEntry(cast(int)Mode.Screen,     "screen",     "Screen"),
        IntEnumEntry(cast(int)Mode.Origin,     "origin",     "Origin"),
        IntEnumEntry(cast(int)Mode.Local,      "local",      "Local"),
        IntEnumEntry(cast(int)Mode.Pivot,      "pivot",      "Pivot"),
        IntEnumEntry(cast(int)Mode.Parent,     "parent",     "Parent"),
    ];

    private static immutable IntEnumEntry[] modeEntriesFull = [
        IntEnumEntry(cast(int)Mode.Auto,       "auto",       "Automatic"),
        IntEnumEntry(cast(int)Mode.Select,     "select",     "Selection"),
        IntEnumEntry(cast(int)Mode.SelectAuto, "selectauto", "Selection Center Auto Axis"),
        IntEnumEntry(cast(int)Mode.Element,    "element",    "Element"),
        IntEnumEntry(cast(int)Mode.Local,      "local",      "Local"),
        IntEnumEntry(cast(int)Mode.Origin,     "origin",     "Origin"),
        IntEnumEntry(cast(int)Mode.Screen,     "screen",     "Screen"),
        IntEnumEntry(cast(int)Mode.Border,     "border",     "Selection Border"),
        IntEnumEntry(cast(int)Mode.Manual,     "manual",     "Manual"),
        IntEnumEntry(cast(int)Mode.None,       "none",       "(none)"),
        IntEnumEntry(cast(int)Mode.Pivot,      "pivot",      "Pivot"),
        IntEnumEntry(cast(int)Mode.Parent,     "parent",     "Parent"),
    ];

    private static immutable IntEnumEntry[] selectSubModeEntries = [
        IntEnumEntry(cast(int)SelectSubMode.Center, "center", "Center"),
        IntEnumEntry(cast(int)SelectSubMode.Top,    "top",    "Top"),
        IntEnumEntry(cast(int)SelectSubMode.Bottom, "bottom", "Bottom"),
        IntEnumEntry(cast(int)SelectSubMode.Back,   "back",   "Back"),
        IntEnumEntry(cast(int)SelectSubMode.Front,  "front",  "Front"),
        IntEnumEntry(cast(int)SelectSubMode.Left,   "left",   "Left"),
        IntEnumEntry(cast(int)SelectSubMode.Right,  "right",  "Right"),
    ];

    // Default = None — a pristine pulldown state (no
    // center.* / axis.* tools registered until the user picks a
    // preset). Tests that rely on a specific mode set it explicitly.
    Mode mode = Mode.None;
    // R5 (typed Pin) — the explicit-relocate override (click-outside marker
    // for Auto / None / Screen / Pivot / Parent). `userPin.placed` /
    // `userPin.center` are the direct replacements for the former
    // `userPlaced` / `userPlacedCenter` fields.
    Pin  userPin;
    Vec3 manualCenter = Vec3(0, 0, 0);      // valid for Mode.Manual
    // Mode.Element: the picked element's vertex indices (single vert / edge
    // endpoints / face vert ring), set by the transform wrapper's click-pick
    // (XfrmTransformTool.tryPickElement). Unlike `userPlaced` (a FROZEN world
    // point owned by the Move-tool relocate machinery), this tracks the
    // element LIVE: computeCenter returns the current centroid of these verts,
    // so the gizmo follows the element as it moves under the drag and stays on
    // it after release — the gizmo pivot = element centroid (vertex pos /
    // edge midpoint / face centroid), click-independent.
    // Empty until a pick; cleared on reset / mode switch.
    uint[] elementVerts_;
    int  selectSubMode = SelectSubMode.Center;
    // Phase 7.2e (Local mode): cluster count + first-cluster centroid
    // are recomputed in evaluate() and exposed via listAttrs() so
    // tools or UI can iterate. The single-pivot
    // `state.actionCenter.center` always = clusters[0].
    int  clusterCount_ = 0;
    // userLocked: true when the mode was set explicitly by the user via
    // `actr.<preset>` (ActrPresetCommand.apply), not by a tool preset.
    // resetTransientPipeStages skips stages with userLocked=true so
    // an explicit `actr.local` (or any other actr.*) survives tool.set.
    bool userLocked = false;

private:
    // Stage holds direct refs to the live mesh + edit mode; re-evaluating
    // on each pipeline pass walks the current selection arrays. Cheap —
    // centroid is O(verts) and only runs when a tool actually consumes
    // state.actionCenter (typically Move/Rotate/Scale's per-frame update).
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh_() const { return meshSrc_ ? meshSrc_() : null; }
    EditMode* editMode_;
    // Task 0082: delegate supplying the primary Layer for Pivot/Parent modes.
    // Null in tests that don't need item-hierarchy modes.
    Layer delegate() primarySrc_;
    @property Layer primary_() const { return primarySrc_ ? primarySrc_() : null; }
    // Cached viewport from the last evaluate() — Screen mode needs it to
    // ray-cast the screen-center pixel onto the workplane. listAttrs()
    // doesn't run inside the pipeline, so it reads back the cache.
    Viewport  lastView_;
    // Cached upstream workplane state (origin + normal) for Screen mode.
    Vec3      lastWpCenter_  = Vec3(0, 0, 0);
    Vec3      lastWpNormal_  = Vec3(0, 1, 0);

    // --- Local-mode cluster cache -----------------------------------------
    // During a transform drag the connected-component partition is INVARIANT
    // (selection frozen, topology frozen — transform tools mutate vertex
    // POSITIONS directly without bumping mesh.mutationVersion, on purpose),
    // so only per-cluster centers need recomputing each frame. The membership
    // partition (`_cachedClusterOf` + count) and the vertex adjacency it was
    // built from are cached and reused while the key holds.
    //
    // Cache key: (address, mutationVersion, editMode, selectionSignature).
    // mutationVersion bumps on every topology/geometry-structure edit (always
    // paired with topologyVersion) and is NOT bumped by selection writes NOR
    // by drag-time vertex moves — so it alone cannot detect a selection
    // change. Selection lives in the Marks.Select bit of
    // vertexMarks/edgeMarks/faceMarks and has no version counter, so we fold
    // a cheap rolling hash of the relevant marks array's Select bits into the
    // key. Edit mode picks which cluster variant runs, so it is part of the
    // key too. `_clusterKey` (a MeshCacheKey) additionally folds in the
    // mesh's address: this cache lives on the STAGE, not on the Mesh, and
    // `mesh_` is a live delegate that can silently retarget to a different
    // primary layer — two distinct Mesh instances can share an equal
    // mutationVersion, so the address term is required to stop this cache
    // from serving one layer's stale partition back for another. See
    // mesh.d's MeshCacheKey doc comment.
    bool   _cacheValid       = false;
    MeshCacheKey _clusterKey;
    int    _cachedEditMode   = -1;
    ulong  _cachedSelSig     = 0;
    int    _cachedClusterCnt = 0;
    int[]  _cachedClusterOf;          // per-vertex cluster id (-1 = not in sel)
    int[]  _cachedFaceClusterOf;      // per-face cluster id (Polygons mode only)
    // Vertex→neighbor adjacency is now owned by Mesh itself
    // (mesh_.vertexAdjacencyCSR) — a Mesh-owned cache cannot alias across
    // layers the way this stage-owned cluster cache could, so no address key
    // is needed for it (the address IS the object). See mesh.d's
    // vertexAdjacencyCSR doc comment.

public:
    this(Mesh* delegate() meshSrc, EditMode* editMode,
         Layer delegate() primarySrc = null) {
        this.meshSrc_    = meshSrc;
        this.editMode_   = editMode;
        this.primarySrc_ = primarySrc;
        publishState();
    }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Acen; }
    override string   id()       const                          { return "actionCenter"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordAcen; }

    /// Restore declaration-time defaults. Triggered by SceneReset
    /// (= `/api/reset`) so an explicit reset wipes the ACEN mode +
    /// any sticky userPlaced / manualCenter pin alongside the mesh.
    /// Also clears userLocked — SceneReset is an unconditional full reset.
    override void reset() {
        mode             = Mode.None;
        userPin          = Pin.init;
        elementVerts_    = null;
        manualCenter     = Vec3(0, 0, 0);
        selectSubMode    = SelectSubMode.Center;
        clusterCount_    = 0;
        userLocked       = false;
        cancelFrozen     = false;
        cancelSnap       = Pin.init;
        softPin          = Pin.init;
        invalidateClusterCache();
        publishState();
    }

    /// Drop the Local-mode partition + adjacency cache. Called on reset and
    /// whenever the cache key is known to be stale. (The key check in
    /// computeLocalClustersFull also catches selection / topology changes
    /// mid-session, so this is a belt-and-braces hook for explicit resets.)
    private void invalidateClusterCache() {
        _cacheValid     = false;
        _clusterKey.invalidate();
        _cachedEditMode = -1;
        _cachedSelSig   = 0;
    }

    /// resetTransient: same as reset() but respects userLocked.
    /// Called by resetTransientPipeStages (tool.set / tool switch) so
    /// an explicit `actr.*` user setting survives switching tools.
    void resetTransient() {
        if (userLocked) return;
        reset();
    }

    /// Set the action-center mode explicitly (called by ActrPresetCommand).
    /// Sets userLocked=true so the mode survives the next tool activation.
    void setUserMode(string modeStr) {
        bool ok = applySetAttr("mode", modeStr);
        if (ok) {
            userLocked = true;
            publishState();
        }
    }

    override bool setAttr(string name, string value) {
        bool ok = applySetAttr(name, value);
        if (ok) publishState();
        return ok;
    }

    override string[2][] listAttrs() const {
        Vec3 c = currentCenter();
        // Local mode exposes cluster count alongside the first-cluster
        // pivot. Other modes report 0 (no per-cluster semantics).
        int clusters = 0;
        if (mode == Mode.Local) {
            // D5 dedup: same cached partition computeCenter's Local arm reads
            // (see the cast note there) — one BFS body for both consumers.
            Vec3[] cc;
            int[]  co;
            (cast(ActionCenterStage)this).computeLocalClustersFull(cc, co);
            clusters = _cachedClusterCnt;
        }
        return [
            ["mode",          modeLabel()],
            ["cenX",          format("%g", c.x)],
            ["cenY",          format("%g", c.y)],
            ["cenZ",          format("%g", c.z)],
            ["userPlaced",    userPin.placed ? "true" : "false"],
            ["userPlacedX",   format("%g", userPin.center.x)],
            ["userPlacedY",   format("%g", userPin.center.y)],
            ["userPlacedZ",   format("%g", userPin.center.z)],
            ["selectSubMode", selectSubModeLabel()],
            ["clusterCount",  format("%d", clusters)],
        ];
    }

    // ------------------------------------------------------------------
    // Tool Properties schema. Exposes the `mode` selector as an int-backed
    // enum Param so the config-driven Action Center form
    // (config/forms/actioncenter.yaml, whenStage: actionCenter) renders a
    // dropdown whose choices + current selection both fall out of THIS list
    // — the same pattern as FalloffStage.params(). The wire tags match
    // `applySetAttr("mode", ...)` exactly; user labels mirror the status-bar
    // Action Center pulldown (config/statusline.yaml) for consistency.
    //
    // When mode==None, params() returns [] so the Tool Properties section is
    // hidden entirely — mirroring FalloffStage.params() returning [] at
    // type==None. The user re-enables ACEN via the status-bar Action Center
    // pulldown (actr.auto / actr.select / actr.local / etc.), which calls
    // setUserMode() — the same re-enable path as falloff uses its own
    // status-bar pulldown. setAttr / listAttrs / knownAttrs are already
    // independent of params() so the HTTP surface is unaffected.
    //
    // The FORM write path fires `tool.pipe.attr actionCenter mode <tag>`,
    // routed through setAttr → applySetAttr (NOT this Param's typed pointer);
    // PropertyPanel's direct-pointer path is unused for this stage because
    // the form is the only consumer. Either way the int* below mirrors the
    // live mode so the dropdown previews the active mode.
    override Param[] params() {
        if (mode == Mode.None) return [];
        Param[] ps;
        ps ~= Param.intEnum_("mode", "Action Center",
                             cast(int*)&mode, modeEntries,
                             cast(int)Mode.None);
        return ps;
    }

    // Full STATIC attr universe for forms-engine startup validation. params()
    // reports only `mode`, but applySetAttr (and listAttrs) accept the wider
    // set below — so the base Stage.knownAttrs() default (params() names)
    // would reject perfectly valid attrs like cenX / userPlacedCenter /
    // selectSubMode at boot. Mirror FalloffStage.knownAttrs(): enumerate
    // everything applySetAttr accepts. This asymmetric attr set (read-only
    // `clusterCount` in listAttrs(), write-only `userPlacedCenter`, a
    // non-Param `mode` alias token `manual`) can't be base-derived from a
    // `fullParams()` the way ConstrainStage's symmetric fields could (task
    // 0184 / audit-2 C2) — enforced instead of hand-verified by the
    // enforcement unittest at the bottom of this file (replaces the retired
    // "KEEP IN SYNC" comment).
    override string[] knownAttrs() {
        return [
            "mode", "cenX", "cenY", "cenZ",
            "userPlacedCenter", "userPlacedX", "userPlacedY", "userPlacedZ",
            "selectSubMode",
        ];
    }

    /// Header label for the stage's Tool Properties section.
    override string displayName() const { return "Action Center"; }

    /// `tool.set actr.auto` semantics — reset Auto sub-state to "follow
    /// selection". Switching mode to Auto via setAttr also goes through
    /// here so the popup re-click clears any previous click-outside.
    void resetAuto() {
        mode = Mode.Auto;
        userPin.placed = false;   // preserves the pre-R5 shape: only the flag
                                   // clears, the stale center is left in place
                                   // (never read while placed==false)
        elementVerts_ = null;
        // Re-picking Auto re-follows the selection — drop any display settle.
        softPin = Pin.init;
        publishState();
    }

    /// Click-outside-gizmo entrypoint for transform tools. Move/Rotate
    /// /Scale call this when the user clicks on empty viewport while
    /// in a relocate-allowed mode (Auto / None / Screen). Sets a sticky
    /// center without leaving the current mode — `computeCenter` then
    /// returns this point until either the mode is switched or the
    /// click is repeated. In modes that don't allow click-relocate
    /// (Select / Element / Local / Origin / Manual / Border) the call
    /// is harmless but the userPlaced flag is never read by their
    /// `computeCenter` branches.
    void setUserPlaced(Vec3 worldHit) {
        // Stage the PRIOR pin state for the in-session cancel baseline, but
        // only while no session snapshot is frozen — this captures the
        // pre-relocate state on the mouse-down relocate that precedes the
        // session's beginEdit (which then freezes whatever was last staged).
        // Relocates during an open session leave the frozen baseline alone.
        if (!cancelFrozen) {
            cancelSnap = userPin;
        }
        userPin = Pin(true, worldHit);
        // An explicit click-relocate supersedes any display settle (userPlaced
        // wins in computeCenter anyway; clear so the soft pin can't resurface if
        // userPlaced is later cleared without a fresh settle).
        softPin = Pin.init;
        publishState();
    }

    /// True iff a sticky click-outside pin is active (set via
    /// `setUserPlaced`, cleared by `resetAuto` or a mode switch).
    bool isUserPlaced() const { return userPin.placed; }

    /// Mode.Element: record the picked element's vertex ring so computeCenter
    /// tracks the element LIVE (see the `elementVerts_` field doc). The gizmo
    /// pivot is always the live ring centroid (vertex pos / edge midpoint /
    /// face centroid) — click-independent. Pass an empty slice to clear.
    void setElementVerts(const(uint)[] verts) {
        elementVerts_ = verts.dup;
        publishState();
    }

    /// Live centroid of `verts` (mesh positions), false when none resolve.
    private bool ringCentroid(const(uint)[] verts, out Vec3 c) const {
        if (mesh_ is null || verts.length == 0) return false;
        Vec3 sum = Vec3(0, 0, 0);
        int  n   = 0;
        foreach (vi; verts) {
            if (vi >= mesh_.vertices.length) continue;   // stale index guard
            sum += mesh_.vertices[vi];
            n++;
        }
        if (n == 0) return false;
        c = sum * (1.0f / n);
        return true;
    }

    /// Live picked-element centroid = ring centroid, or false when no element
    /// is recorded / the mesh / indices are unusable.
    private bool liveElementCenter(out Vec3 c) const {
        return ringCentroid(elementVerts_, c);
    }

    // ----- In-session cancel snapshot (transform Ctrl+Z coordination) -------
    //
    // A click-away / element-pick relocate fires setUserPlaced() on mouse-DOWN,
    // BEFORE the transform tool opens its edit session (beginEdit at drag start
    // / first apply). An in-session Ctrl+Z (cancelUncommittedEdit) restores the
    // session-baseline vertices + attrs but must ALSO restore the action center
    // to its pre-gesture state — otherwise the gizmo sticks at the click point
    // while geometry snaps back. The pin lives here, so the pin baseline does
    // too, mirroring the wrapper's attrBase* snapshot.
    //
    // Lifecycle (driven by the transform wrapper):
    //   - Every relocate that happens while NO snapshot is frozen stashes the
    //     PRIOR pin state into `cancelSnap`. This catches the
    //     relocate-before-beginEdit ordering: the latest pre-relocate state is
    //     always staged, even though setUserPlaced runs first.
    //   - `freezeUserPlacedSnapshot()` (called on the closed->open session
    //     transition in beginEdit) freezes the staged state as the session
    //     baseline. Relocates DURING the open session no longer re-stash.
    //   - `restoreUserPlacedSnapshot()` (called from cancelUncommittedEdit)
    //     restores the frozen baseline and clears the freeze.
    //   - `discardUserPlacedSnapshot()` (called from a COMMIT path) clears the
    //     freeze WITHOUT restoring — committed relocates persist, as today.
    private bool cancelFrozen = false;   // was `snapFrozen`
    private Pin  cancelSnap;             // was `snapPlaced`/`snapPlacedCenter`

    // ----- Display soft-pin (BUG-1: Move gizmo settle) ------------------------
    //
    // A Move gizmo drag must leave the gizmo at the FULL-delta settled pivot on
    // mouse-up — matching the reference, where the pivot follows the whole drag
    // delta and STAYS there. On mouse-up the recompute modes (Auto / None /
    // Screen) recompute the pivot from `centroidWithGeometryFallback()`. WITHOUT
    // falloff every vert moved by the full delta so that centroid already equals
    // the settled gizmo position (no snap-back, soft pin unused — the wrapper
    // leaves the no-falloff path byte-identical by not setting one). WITH falloff
    // the fallback returns the WEIGHTED moving-set bbox-center, which snaps back
    // toward the original pivot — the bug.
    //
    // The soft-pin records the settled pivot so the recompute modes return it
    // instead of the weighted centroid. The MECHANISM is falloff-agnostic
    // (computeCenter knows nothing about falloff); the wrapper only sets a soft
    // pin in the falloff case, where the snap-back actually occurs. It is
    // DELIBERATELY distinct from `userPlaced` / `snapPlaced`: a soft pin is a
    // weaker, display-only sticky center that does NOT touch the relocate
    // machinery (setUserPlaced / freeze / restore / stageCurrentPinState) — so the
    // relocate boundary, cross-slot commit, and element-falloff pick behave
    // EXACTLY as before. It is computeCenter()-only.
    //
    // Precedence in computeCenter (Auto / None / Screen): userPlaced (explicit
    // click-relocate) wins over softPlaced (the settle), which wins over the
    // weighted centroid fallback. An explicit relocate (setUserPlaced) therefore
    // takes over from any soft pin.
    //
    // Lifetime: a soft pin from gesture-1's settle persists for gesture-2 of the
    // SAME run (sticky — matches the reference's gizmo follow), but is CLEARED
    // wherever the center should legitimately recompute: full reset(), resetAuto,
    // an explicit setUserPlaced (userPlaced supersedes), a mode switch
    // (applySetAttr "mode"), and — driven by the transform wrapper — a selection /
    // mutation boundary and an ACEN-mode boundary. It is NOT read by the relocate-
    // boundary detection, beginRunGesture / per-run baseline, or the falloff-
    // element pick (all of which use userPlaced).
    private Pin softPin;   // was `softPlaced`/`softPlacedCenter`

    /// Record the settled display pivot after a Move gizmo mouse-up so the
    /// recompute modes (Auto / None / Screen) return it instead of the weighted
    /// moving-set centroid (BUG-1). Display-only: does NOT touch userPlaced or any
    /// relocate snapshot. publishState so the live gizmo follows immediately.
    void setSoftPlaced(Vec3 settled) {
        softPin = Pin(true, settled);
        publishState();
    }

    /// Drop the display soft-pin so the center recomputes from the selection
    /// (the moving-set centroid). Called wherever a soft pin must be invalidated:
    /// reset / mode-switch / explicit relocate / selection or ACEN-mode boundary.
    /// No-op (besides a publish-free early return) when no soft pin is active.
    void clearSoftPlaced() {
        if (!softPin.placed) return;
        softPin = Pin.init;
        publishState();
    }

    /// True iff a display soft-pin is active. (Used by tests / introspection;
    /// computeCenter reads the field directly.)
    bool isSoftPlaced() const { return softPin.placed; }

    /// The current soft-pin center (meaningful only when isSoftPlaced()). Exposed
    /// so the transform wrapper can capture the gesture-START / gesture-END soft
    /// state for the Move undo/redo hooks, mirroring currentPinCenter() for the
    /// userPlaced pin.
    Vec3 currentSoftCenter() const { return softPin.center; }

    /// Restore the display soft-pin to an explicit (placed, center) endpoint and
    /// publish. Used by the wrapper's Move undo/redo hooks to carry the soft pin
    /// in lockstep with the geometry: revert restores the gesture-START soft state
    /// (typically cleared → the pivot recomputes to the reverted-geometry
    /// centroid), apply restores the gesture-END (settled) soft pin. Independent
    /// of restorePinState (userPlaced) — the two own disjoint state and compose in
    /// one hook closure without clobber.
    void restoreSoftPlaced(bool placed, Vec3 center) {
        softPin = Pin(placed, placed ? center : Vec3(0, 0, 0));
        publishState();
    }

    /// Freeze the currently-staged pre-relocate pin state as the cancel
    /// baseline for an opening edit session. Called once per session on the
    /// closed->open transition; subsequent relocates within the session do not
    /// disturb the frozen baseline.
    void freezeUserPlacedSnapshot() { cancelFrozen = true; }

    /// Restore the action-center pin to its frozen session-start state and
    /// clear the freeze. Called from the transform wrapper's
    /// cancelUncommittedEdit() alongside the vertex / attr restore.
    void restoreUserPlacedSnapshot() {
        if (!cancelFrozen) return;
        userPin      = cancelSnap;
        cancelFrozen = false;
        publishState();
    }

    /// Drop the frozen snapshot WITHOUT restoring. Called from the commit
    /// (tool-drop / guard-trip) path so a committed relocate stays put.
    void discardUserPlacedSnapshot() { cancelFrozen = false; }

    // ----- Per-gesture undo-hook pin accessors (record+consolidate, addendum-2)
    //
    // Under per-gesture commit each Move mouse-up records a tagged in-session
    // entry and DISCARDS the frozen snapshot (no open session at idle), so the
    // session-cancel restore path no longer covers a plain history.undo(). The
    // wrapper's Move commitEdit instead attaches PIN HOOKS to the recorded entry
    // (mirroring the R/S accumulator hooks): revert restores the gesture-START
    // pin, apply restores the gesture-END pin (the current pin at mouse-up).
    //
    // W1 fix: the gesture-START is NOT read from the frozen snapshot
    // (cancelSnap). That snapshot holds the PRE-relocate pin
    // staged at the last relocate — the right in-flight cancel baseline, but the
    // WRONG gesture-START for the 2nd+ plain gesture in a userPlaced run (no
    // boundary re-stages it, so the frozen value is stale, from a relocate
    // possibly a prior run). The wrapper instead captures the LIVE pin
    // (isUserPlaced()/currentPinCenter()) at each gesture's beginEdit. These two
    // accessors expose the live pin endpoints (placed flag + center) so the
    // wrapper can capture the gesture-START at beginEdit and the gesture-END at
    // commit, and restore either one from a hook.

    /// The current (live) pin endpoints — the gesture-START pin captured at
    /// beginEdit, and the gesture-END pin captured at mouse-up after any
    /// sticky-follow has settled. (isUserPlaced(), above, supplies the placed
    /// flag for the same endpoint.)
    Vec3 currentPinCenter() const { return userPin.center; }

    /// Restore the pin to an explicit (placed, center) endpoint and publish so
    /// the visible gizmo follows. Used by the wrapper's Move undo/redo hooks to
    /// snap the action center to the gesture-START (revert) or gesture-END
    /// (apply) pin in lockstep with the geometry. Does NOT touch the frozen
    /// snapshot — hooks run outside any open session.
    void restorePinState(bool placed, Vec3 center) {
        userPin = Pin(placed, center);
        publishState();
    }

    /// Re-stage the CURRENT pin state VERBATIM as the in-session-cancel
    /// baseline, WITHOUT mutating the pin or publishing. Phase 5 boundary
    /// helper.
    ///
    /// The Phase 5 boundary (an off-gizmo plain LMB-down in a relocate-
    /// DISALLOWED mode while a session is open) commits every open session to
    /// split the undo run, but it must NOT relocate anything — so it cannot
    /// use `notifyAcenUserPlaced(...)` / `restageActionCenterPin()` (those call
    /// `setUserPlaced`, which sets `userPlaced = true` and would force-place
    /// the pivot — wrong in Select mode, where the off-gizmo click is inert by
    /// rule). It still hits the SAME `setUserPlaced`/`commitEdit` staging trap
    /// as Phases 1a/1b, though:
    ///
    ///   [prior run open: cancelFrozen == true]
    ///   commitEdit (boundary) → discardUserPlacedSnapshot() → cancelFrozen = false
    ///                           (clears the freeze WITHOUT restoring cancelSnap)
    ///   stageCurrentPinState() → cancelSnap = userPin   (no publish)
    ///   beginEdit (next drag)  → freezeUserPlacedSnapshot() freezes THIS staged
    ///                            (current, un-mutated) pin as the new baseline
    ///
    /// Without this, the next `beginEdit` would freeze whatever STALE value
    /// `cancelSnap` last held (from a relocate two sessions ago — matters in
    /// Element mode, where `userPlaced` is genuinely set from a prior pick and
    /// an off-gizmo NON-element click there takes the Phase 5 path); a later
    /// in-session cancel would then restore the WRONG pin. Re-staging the
    /// current pin verbatim keeps the cancel baseline equal to the (unchanged)
    /// pin. Only stages while `!cancelFrozen` (the commit cleared it just above);
    /// a stray call mid-session is a no-op, mirroring `setUserPlaced`'s guard.
    void stageCurrentPinState() {
        if (cancelFrozen) return;
        cancelSnap = userPin;
    }

    /// Switch into Manual mode and pin the center. Mirror of
    /// `setAutoUserPlaced` for callers that want strict "stay here"
    /// semantics regardless of selection changes.
    void setManualCenter(Vec3 worldPos) {
        mode         = Mode.Manual;
        manualCenter = worldPos;
        publishState();
    }

public:
    // Returns the actual Vec3 the next pipeline.evaluate would publish.
    // Used by evaluate() / listAttrs() so the panel's cenX/Y/Z displays
    // the live computed center, and by external consumers
    // (falloff_handles.d's RMB-radius gesture) that need the canonical
    // pivot without walking the full pipeline.
    Vec3 currentCenter() const {
        return computeCenter();
    }

    /// BUG-1 / flex_border_handles_plan.md Phase 3 — the 2-entry "is a gesture
    /// settle (soft-pin) meaningful in this mode?" predicate. The wrapper's
    /// settleGestureCenter() consults it before pinning the drop center, and the
    /// undo-hook splice gates on it too. We EXCLUDE exactly the two modes that
    /// already own a HIGHER-precedence LIVE pivot source which computeCenter
    /// returns ahead of softPlaced — so a single drop-center either can't apply or
    /// can't represent the pivot:
    ///   - Element: liveElementCenter (the picked-element ring centroid) wins in
    ///     computeCenter; the gizmo must keep tracking the element, not freeze.
    ///   - Local:   per-cluster pivots (N centers) — one drop-center can't stand
    ///     in for N clusters.
    /// This is NOT a mode allow-list: every OTHER mode (Auto / None / Screen /
    /// Select / SelectAuto / Border / Origin / Manual) consults softPlaced, so the
    /// freeze generalizes with no `mode==border` branch.
    bool acenSettleAllowed() const {
        return mode != Mode.Element && mode != Mode.Local;
    }

    // Task 0187 (B3) — the pin-precedence hoist. `computeCenter` used to
    // repeat an `if (userPlaced) …; if (softPlaced) …;` ladder across every
    // mode arm; the two predicates below collapse that ladder into a single
    // pre-switch check (see `computeCenter`). The action center is one
    // published 3-vector; `userPlaced` / `softPlaced` are override
    // *lifetimes* of that one value, not separate outputs, so precedence
    // over them is a property of the ladder, not of any one mode's arm.
    //
    // Modes whose center is a plain relocatable point (no fixed origin, no
    // live per-element/per-item source, no per-cluster partition) — an
    // explicit relocate pin (userPlaced / notifyAcenUserPlaced click-away)
    // overrides them wholesale. Element is EXCLUDED: its live ring center
    // outranks userPlaced, so Element keeps its own in-arm userPlaced check
    // (below the live center). Pivot/Parent ARE included by task 0187: an
    // explicit relocation to a chosen point is defensible even for the live
    // item pivot — the settle pin is a different story, see
    // `settlePinHonored` below.
    private static bool relocateAllowed(Mode m) pure nothrow @nogc @safe {
        return m == Mode.Auto  || m == Mode.Screen || m == Mode.None
            || m == Mode.Pivot || m == Mode.Parent;
    }

    // Modes that honor an AUTO gesture SETTLE (soft pin) = `acenSettleAllowed()`
    // minus the four modes with either a FIXED center (Origin, Manual) or a
    // LIVE item-tracking center (Pivot, Parent) that a drop-point freeze would
    // defeat. Equivalently {Auto, Screen, None, Select, SelectAuto, Border}.
    //
    // Pivot/Parent join Origin/Manual in the "writes but never reads" class:
    // `settleGestureCenter` (xfrm_transform.d) still calls `setSoftPlaced` for
    // them whenever `acenSettleAllowed()` is true (unchanged — Pivot/Parent are
    // not Element/Local), but `computeCenter` must never read that write for
    // them, or a gesture settle would freeze the gizmo at the drop point
    // instead of continuing to track the live item pivot (same class as
    // Element's `liveElementCenter` / Local's per-cluster pivots, which
    // `acenSettleAllowed()` already excludes from the settle write itself).
    bool settlePinHonored() const {
        return acenSettleAllowed()
            && mode != Mode.Origin && mode != Mode.Manual
            && mode != Mode.Pivot  && mode != Mode.Parent;
    }

private:

    Vec3 computeCenter() const {
        if (relocateAllowed(mode) && userPin.placed) return userPin.center;
        if (settlePinHonored()    && softPin.placed) return softPin.center;
        final switch (mode) {
            case Mode.Auto:
                return centroidWithGeometryFallback();
            case Mode.Select:
                return selectionCentroid(/*sub*/ selectSubMode);
            case Mode.SelectAuto:
                // Same center as Select; AxisStage realigns the basis.
                return selectionCentroid(SelectSubMode.Center);
            case Mode.Origin:
                return Vec3(0, 0, 0);
            case Mode.Manual:
                return manualCenter;
            case Mode.Screen:
                // Selection centroid — Screen mode's distinguishing
                // feature is the AXIS orientation (camera-aligned),
                // handled by AxisStage. The action-center POSITION
                // tracks the selection like Auto does.
                return centroidWithGeometryFallback();
            case Mode.Element:
                // Click-pick (XfrmTransformTool.tryPickElement when
                // falloff.element is active) records the picked element's
                // vertex ring via setElementVerts. The pivot is the LIVE
                // ring centroid (vertex pos / edge midpoint / face centroid),
                // which becomes the gizmo pivot AND the falloff sphere anchor
                // (FalloffStage.evaluate reads state.actionCenter.center).
                // Click-position does not affect the pivot — all modes anchor
                // at the element centroid.
                // No pick yet → fall back to the selection-element centroid
                // (whole mesh per the universal "empty selection = all" rule).
                // userPlaced stays an IN-ARM check here (below the live
                // center) — Element is excluded from `relocateAllowed`.
                Vec3 elc;
                if (liveElementCenter(elc)) return elc;
                if (userPin.placed) return userPin.center;
                return elementCenter();
            case Mode.Local: {
                // D5 dedup: reuse the SAME cached BFS body `evaluate()` uses
                // (localCenterAndClustersCached), instead of a second
                // independent partition. computeCenter() is logically const
                // (the caller-visible RESULT never depends on cache state) but
                // the cached path fills cross-frame membership fields, so the
                // cast mirrors an ordinary memoization. Post Stage-U, the only
                // caller of this const path off the main thread (GET
                // /api/toolpipe) is marshaled, so this fill never races
                // evaluate()'s own use of the same cache.
                Vec3[] cc;
                int[]  co;
                return (cast(ActionCenterStage)this)
                           .localCenterAndClustersCached(cc, co);
            }
            case Mode.None:
                // No designated action center — for visual placement
                // (gizmo position) and translate-drag plane reference,
                // fall back to the same centroid Auto would give.
                // Click-outside-gizmo writes userPlaced (same hook as
                // Auto / Screen), so the gizmo + transform pivot stay
                // in sync after relocation.
                return centroidWithGeometryFallback();
            case Mode.Border:
                // Bbox center of selection-border verts — those on edges
                // with one selected and one unselected adjacent face.
                // For closed/symmetric selections the border == the full
                // selection (cube top face: every edge is bounded by
                // unselected faces below it), so the result equals
                // `centroidWithGeometryFallback`. For open/partial
                // selections (sphere top hemisphere: only the equator
                // ring is on a border edge) the result differs and
                // matches `actr.border`.
                if (mesh_ is null) return Vec3(0, 0, 0);
                final switch (*editMode_) {
                    case EditMode.Vertices: return centroidWithGeometryFallback();
                    case EditMode.Edges:    return centroidWithGeometryFallback();
                    case EditMode.Polygons: return mesh_.selectionBorderBBoxCenterFaces();
                }
            case Mode.Pivot: {
                // center = primary item's pivot world position.
                // applyAffine(M, pivot) == pos + rotation·pivot for the general
                // case; equals pos+pivot when unrotated. Capture-verified 3/3 exact.
                auto l = primary_();
                if (l is null) return Vec3(0, 0, 0);
                return applyAffine(l.xform.composedMatrix(), l.xform.pivot);
            }
            case Mode.Parent: {
                // center = parent item's world position (parent.pivot=0 → parent.pos).
                // Reads exactly ONE level (l.parent) — no ancestor-chain walk.
                // Capture-verified 3/3 exact. parent-pivot dimension is untested
                // in the capture (same caveat as Pivot basis).
                auto l = primary_();
                auto p = (l !is null) ? l.parent : null;
                if (p is null) return Vec3(0, 0, 0);
                return applyAffine(p.xform.composedMatrix(), p.xform.pivot);
            }
        }
    }

    // Phase 3 follow-up to the (now-removed, D5-deduped) single-pivot BFS:
    // enumerate ALL clusters and assign every selected vertex to its cluster
    // id. Used by
    // evaluate() to populate ActionCenterPacket.{clusterCenters,
    // clusterOf} so tools can apply per-cluster pivots. Cluster centers
    // are bounding-box midpoints (consistent with Phase 2's bbox-Select
    // choice). `clusterOf[vi] == -1` for verts not in the selection.
    void computeLocalClustersFull(out Vec3[] clusterCenters,
                                  out int[]  clusterOf) {
        if (mesh_ is null) return;

        // --- Cache key check --------------------------------------------------
        // Membership is invariant while (mutationVersion, editMode, selSig) all
        // hold; only centers (read from live mesh_.vertices) change per frame.
        const int   edMode  = cast(int)(*editMode_);
        const ulong selSig  = selectionSignature();
        const bool  hit = _cacheValid
                       && _clusterKey.matches(*mesh_)
                       && _cachedEditMode == edMode
                       && _cachedSelSig   == selSig
                       && _cachedClusterOf.length == mesh_.vertices.length;

        if (!hit) {
            // MISS: rebuild membership (O(V+E) via cached adjacency) and the
            // partition, then stamp the new key.
            _cachedClusterOf.length = mesh_.vertices.length;
            foreach (ref c; _cachedClusterOf) c = -1;
            _cachedClusterCnt = 0;
            _cachedFaceClusterOf.length = 0;
            final switch (*editMode_) {
                case EditMode.Polygons:
                    buildFaceClusterMembership(_cachedClusterOf, _cachedClusterCnt);
                    break;
                case EditMode.Edges:
                    buildEdgeClusterMembership(_cachedClusterOf, _cachedClusterCnt);
                    break;
                case EditMode.Vertices:
                    buildVertClusterMembership(_cachedClusterOf, _cachedClusterCnt);
                    break;
            }
            _clusterKey.stamp(*mesh_);
            _cachedEditMode = edMode;
            _cachedSelSig   = selSig;
            _cacheValid     = true;
        }

        if (_cachedClusterCnt <= 0) return;   // nothing selected
        // Always recompute centers from the live positions (cheap, O(sel verts))
        // so a drag's per-frame motion is reflected, EXACTLY as before.
        clusterOf = _cachedClusterOf;
        clusterCenters = new Vec3[](_cachedClusterCnt);
        foreach (i; 0 .. _cachedClusterCnt)
            clusterCenters[i] = clusterBBoxCenter(clusterOf, cast(int)i);
    }

    // Per-frame Local-mode entry for evaluate() — and, since D5, the ONLY
    // Local-mode BFS body (computeCenter()'s Local arm and listAttrs()'s
    // cluster-count branch both call in here too). Returns the single-pivot
    // center (cluster-0 AVERAGE centroid — NOT the bbox center), while also handing
    // back the per-cluster BBOX centers + partition for the published packet.
    // Both reuse the cross-frame membership cache so the O(E·V) BFS runs at
    // most once per (topology, selection, edit-mode) change instead of per
    // drag frame.
    Vec3 localCenterAndClustersCached(out Vec3[] clusterCenters,
                                      out int[]  clusterOf) {
        computeLocalClustersFull(clusterCenters, clusterOf);
        if (_cachedClusterCnt <= 0)
            return centroidWithGeometryFallback();
        // Average centroid of CLUSTER 0, replicating the per-mode single-pivot
        // formula exactly (face mode averages face centroids; vert/edge modes
        // average the cluster's verts).
        Vec3 sum = Vec3(0, 0, 0);
        int  n   = 0;
        final switch (*editMode_) {
            case EditMode.Polygons:
                // Average of the centroids of faces in cluster 0.
                foreach (fi, c; _cachedFaceClusterOf) {
                    if (c != 0) continue;
                    const(uint)[] face = mesh_.faces[fi];
                    sum += face.length > 0 ? mesh_.faceCentroid(cast(uint)fi) : Vec3(0, 0, 0);
                    n++;
                }
                break;
            case EditMode.Edges:
            case EditMode.Vertices:
                // Average of the verts assigned to cluster 0.
                foreach (vi, c; _cachedClusterOf) {
                    if (c != 0) continue;
                    sum += mesh_.vertices[vi];
                    n++;
                }
                break;
        }
        return n > 0 ? sum / cast(float)n : centroidWithGeometryFallback();
    }

    // Cheap rolling hash of the Select bit across the marks array relevant to
    // the active edit mode. Two different selections collide with vanishingly
    // small probability; a collision would only ever cause a stale partition,
    // and selection changes during an interactive drag don't happen (the drag
    // freezes the selection), so this is safe for the cache-key use. Thin
    // wrapper over the single canonical Mesh.selectionSignature (mirrors
    // FalloffStage.selectionSignature, which wraps the same call).
    ulong selectionSignature() const {
        if (mesh_ is null) return 0;
        return mesh_.selectionSignature(*editMode_);
    }

    // Helper: bbox center of vertices in a cluster (verts identified by
    // clusterOf == cid). Mirrors mesh.selectionBBoxCenterFaces() but
    // restricted to one cluster.
    Vec3 clusterBBoxCenter(const(int)[] clusterOf, int cid) const {
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool seen = false;
        foreach (vi, c; clusterOf) {
            if (c != cid) continue;
            Vec3 v = mesh_.vertices[vi];
            if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
            if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
            if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
            seen = true;
        }
        return seen ? (mn + mx) * 0.5f : Vec3(0, 0, 0);
    }

    // Membership-only builders (centers are computed by the caller from live
    // positions). They fill `clusterOf[vi]` with a cluster id per selected
    // vertex (-1 = not in selection) and set `cid` to the cluster count.
    // Topology adjacency is O(V+E) via the cached CSR / face-edge maps, NOT
    // O(E·V) per dequeued element as the old inline scans were.
    void buildFaceClusterMembership(ref int[] clusterOf, ref int cid) {
        if (!mesh_.hasAnySelectedFaces()) return;
        size_t nF = mesh_.faces.length;
        int[]  clusterOfFace = new int[](nF);
        foreach (ref c; clusterOfFace) c = -1;
        // Build face adjacency via a shared-edge map: each undirected vertex
        // pair (v0,v1) maps to the faces incident on it; two faces sharing a
        // key are edge-adjacent. O(total face corners) to build.
        uint[][ulong] facesByEdgeKey;
        ulong edgeKey(uint a, uint b) {
            return a < b ? (cast(ulong)a << 32) | b
                         : (cast(ulong)b << 32) | a;
        }
        foreach (fi; 0 .. nF) {
            const(uint)[] f = mesh_.faces[fi];
            foreach (i; 0 .. f.length) {
                ulong k = edgeKey(f[i], f[(i + 1) % f.length]);
                facesByEdgeKey[k] ~= cast(uint)fi;
            }
        }
        foreach (start; 0 .. nF) {
            if (!mesh_.isFaceSelected(start) || clusterOfFace[start] != -1) continue;
            uint[] queue; queue ~= cast(uint)start;
            clusterOfFace[start] = cid;
            while (queue.length > 0) {
                uint cur = queue[0]; queue = queue[1 .. $];
                const(uint)[] f = mesh_.faces[cur];
                foreach (i; 0 .. f.length) {
                    ulong k = edgeKey(f[i], f[(i + 1) % f.length]);
                    foreach (other; facesByEdgeKey[k]) {
                        if (other == cur) continue;
                        if (!mesh_.isFaceSelected(other) || clusterOfFace[other] != -1) continue;
                        clusterOfFace[other] = cid;
                        queue ~= other;
                    }
                }
            }
            cid++;
        }
        // Project face cluster ids onto verts. A vertex shared between
        // two disjoint clusters keeps the lowest cid (deterministic).
        foreach (fi; 0 .. nF) {
            int c = clusterOfFace[fi];
            if (c == -1) continue;
            foreach (vi; mesh_.faces[fi]) {
                if (clusterOf[vi] == -1 || c < clusterOf[vi])
                    clusterOf[vi] = c;
            }
        }
        // Stash the per-face partition so the single-pivot first-center
        // (average of face centroids in cluster 0) can be recomputed from
        // cache without redoing the BFS.
        _cachedFaceClusterOf = clusterOfFace;
    }

    void buildEdgeClusterMembership(ref int[] clusterOf, ref int cid) {
        if (!mesh_.hasAnySelectedEdges()) return;
        const(size_t)[] adjOffset;
        const(uint)[]    adjNeighbors;
        mesh_.vertexAdjacencyCSR(adjOffset, adjNeighbors);
        size_t nV = mesh_.vertices.length;
        // A vert participates iff it is an endpoint of some SELECTED edge; the
        // graph walked is the full vertex adjacency restricted to selected
        // edges. Build a per-(undirected-edge) selected lookup so neighbor
        // traversal can confirm the connecting edge is selected.
        bool[] inSel = new bool[](nV);
        bool[ulong] selEdgeKey;
        ulong edgeKey(uint a, uint b) {
            return a < b ? (cast(ulong)a << 32) | b
                         : (cast(ulong)b << 32) | a;
        }
        foreach (i, edge; mesh_.edges) {
            if (mesh_.isEdgeSelected(i)) {
                inSel[edge[0]] = true;
                inSel[edge[1]] = true;
                selEdgeKey[edgeKey(edge[0], edge[1])] = true;
            }
        }
        foreach (start; 0 .. nV) {
            if (!inSel[start] || clusterOf[start] != -1) continue;
            uint[] queue; queue ~= cast(uint)start;
            clusterOf[start] = cid;
            while (queue.length > 0) {
                uint cur = queue[0]; queue = queue[1 .. $];
                foreach (other; adjNeighbors[adjOffset[cur] .. adjOffset[cur + 1]]) {
                    if (clusterOf[other] != -1) continue;
                    if (edgeKey(cur, other) !in selEdgeKey) continue;
                    clusterOf[other] = cid;
                    queue ~= other;
                }
            }
            cid++;
        }
    }

    void buildVertClusterMembership(ref int[] clusterOf, ref int cid) {
        if (!mesh_.hasAnySelectedVertices()) return;
        const(size_t)[] adjOffset;
        const(uint)[]    adjNeighbors;
        mesh_.vertexAdjacencyCSR(adjOffset, adjNeighbors);
        size_t nV = mesh_.vertices.length;
        foreach (start; 0 .. nV) {
            if (!mesh_.isVertexSelected(start)) continue;
            if (clusterOf[start] != -1) continue;
            uint[] queue; queue ~= cast(uint)start;
            clusterOf[start] = cid;
            while (queue.length > 0) {
                uint cur = queue[0]; queue = queue[1 .. $];
                foreach (other; adjNeighbors[adjOffset[cur] .. adjOffset[cur + 1]]) {
                    if (clusterOf[other] != -1) continue;
                    if (!mesh_.isVertexSelected(other)) continue;
                    clusterOf[other] = cid;
                    queue ~= other;
                }
            }
            cid++;
        }
    }

    // Element mode: average of per-element centroids of the selected
    // elements (NOT the bbox of all their vertices). Differs from
    // Select sub-mode=Center for face/edge selection — here we treat
    // each selected face / edge as one logical "element" and average
    // its own centroid. With a single face selected this gives the
    // face centroid ("click on a polygon → center to its centroid").
    // Vertex mode collapses to per-vertex average,
    // which equals the regular selection centroid.
    Vec3 elementCenter() const {
        if (mesh_ is null) return Vec3(0, 0, 0);
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        final switch (*editMode_) {
            case EditMode.Vertices: {
                bool any = mesh_.hasAnySelectedVertices();
                foreach (i, v; mesh_.vertices) {
                    if (!any || mesh_.isVertexSelected(i)) {
                        sum += v;
                        count++;
                    }
                }
                break;
            }
            case EditMode.Edges: {
                bool any = mesh_.hasAnySelectedEdges();
                foreach (i, edge; mesh_.edges) {
                    if (any && !mesh_.isEdgeSelected(i)) continue;
                    Vec3 mid = (mesh_.vertices[edge[0]] + mesh_.vertices[edge[1]]) * 0.5f;
                    sum += mid;
                    count++;
                }
                break;
            }
            case EditMode.Polygons: {
                bool any = mesh_.hasAnySelectedFaces();
                foreach (i, face; mesh_.faces) {
                    if (any && !mesh_.isFaceSelected(i)) continue;
                    Vec3 c = Vec3(0, 0, 0);
                    foreach (vi; face) c += mesh_.vertices[vi];
                    if (face.length > 0) c = c / cast(float)face.length;
                    sum += c;
                    count++;
                }
                break;
            }
        }
        return count > 0 ? sum / cast(float)count : Vec3(0, 0, 0);
    }

    // Screen mode: cast a ray from the camera's eye through the screen
    // center pixel and intersect with the workplane plane. The action
    // center and axis are based on the frame of the viewport (screen
    // space) — picture-plane center projected to the
    // construction plane. If the workplane is parallel to the camera
    // ray the projection degenerates; fall back to the camera focus
    // point so we never publish a NaN center.
    Vec3 screenCenter() const {
        // No view captured yet (stage just constructed) — use the
        // workplane center as a sane default.
        if (lastView_.width == 0 || lastView_.height == 0)
            return lastWpCenter_;
        Vec3 acOrig, ray;
        screenPointToRay(cast(float)(lastView_.width  / 2),
                         cast(float)(lastView_.height / 2),
                         lastView_, acOrig, ray);
        Vec3 hit;
        if (rayPlaneIntersect(acOrig, ray,
                              lastWpCenter_, lastWpNormal_, hit))
            return hit;
        // Degenerate (ray ⟂ plane normal). Fall back to camera focus.
        // In practice this hits when the camera looks along the
        // workplane plane edge-on; use the perpendicular projection of
        // eye onto the workplane.
        Vec3 d = lastView_.eye - lastWpCenter_;
        float h = d.x * lastWpNormal_.x + d.y * lastWpNormal_.y + d.z * lastWpNormal_.z;
        return lastView_.eye - lastWpNormal_ * h;
    }

    // Auto mode: selection centroid if any selection, else geometry-bbox
    // centroid (handles at center of selection / geometry).
    //
    // Phase 2 of the action-center parity plan: this returns the BBOX
    // CENTER of the selected verts, not the per-vertex average. The
    // empirical drag-derived pivot for actr.select / .selectauto / .auto
    // / .border is bbox center (rather than the "average vertex position"
    // form). For symmetric selections (default cube, single full face)
    // bbox == avg, so existing unit tests are unaffected.
    Vec3 centroidWithGeometryFallback() const {
        if (mesh_ is null) return Vec3(0, 0, 0);
        // mesh.selectionBBoxCenter* falls back to the whole geometry
        // when no selection bits are set ("no selection ⇒ all geometry").
        final switch (*editMode_) {
            case EditMode.Vertices: return mesh_.selectionBBoxCenterVertices();
            case EditMode.Edges:    return mesh_.selectionBBoxCenterEdges();
            case EditMode.Polygons: return mesh_.selectionBBoxCenterFaces();
        }
    }

    // Phase 7.6 (BaseSide gizmo): centroid of the current selection
    // restricted to base-side verts. Used to keep the gizmo on the
    // user-clicked half when 7.6c auto-adds the mirror counterpart
    // (raw centroid would sit on the plane otherwise).
    //
    // Returns false when there are no base-side verts in the active
    // selection — caller leaves the original centroid in place.
    bool baseSideCentroid(const ref SymmetryPacket sp, out Vec3 result) const
    {
        if (mesh_ is null || editMode_ is null) return false;
        if (sp.vertSign.length != mesh_.vertices.length) return false;

        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        bool[] visited = new bool[](mesh_.vertices.length);

        void touch(uint vi) {
            if (vi >= visited.length || visited[vi]) return;
            visited[vi] = true;
            if (sp.vertSign[vi] != sp.baseSide) return;
            sum   = sum + mesh_.vertices[vi];
            count += 1;
        }

        final switch (*editMode_) {
            case EditMode.Vertices:
                foreach (vi; 0 .. mesh_.vertices.length)
                    if (mesh_.isVertexSelected(vi))
                        touch(cast(uint)vi);
                break;
            case EditMode.Edges:
                foreach (ei; 0 .. mesh_.edges.length)
                    if (mesh_.isEdgeSelected(ei))
                        foreach (vi; mesh_.edges[ei]) touch(vi);
                break;
            case EditMode.Polygons:
                foreach (fi; 0 .. mesh_.faces.length)
                    if (mesh_.isFaceSelected(fi))
                        foreach (vi; mesh_.faces[fi]) touch(vi);
                break;
        }
        if (count == 0) return false;
        result = sum * (1.0f / cast(float)count);
        return true;
    }

    // Strict selection centroid — falls back to all-geometry only if
    // there genuinely is no selection AND no geometry (empty mesh).
    // Sub-mode picks one of the 7 bbox positions in WORLD axis-aligned
    // space, decision per phase7_2_plan.md §1 (resolved).
    Vec3 selectionCentroid(int sub) const {
        if (mesh_ is null) return Vec3(0, 0, 0);
        if (sub == SelectSubMode.Center)
            return centroidWithGeometryFallback();
        // For non-center sub-modes, walk the same vert set as the
        // centroid path and track per-axis min/max.
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool any = false;
        void touch(Vec3 v) {
            if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
            if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
            if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
            any = true;
        }
        // Determine which verts contribute (matches selectionCentroid* logic).
        bool hasSelV = mesh_.hasAnySelectedVertices();
        bool hasSelE = mesh_.hasAnySelectedEdges();
        bool hasSelF = mesh_.hasAnySelectedFaces();
        bool[] visited = new bool[](mesh_.vertices.length);
        final switch (*editMode_) {
            case EditMode.Vertices:
                foreach (i, v; mesh_.vertices) {
                    if (!hasSelV || mesh_.isVertexSelected(i)) touch(v);
                }
                break;
            case EditMode.Edges:
                foreach (i, edge; mesh_.edges) {
                    if (hasSelE && !mesh_.isEdgeSelected(i)) continue;
                    foreach (vi; edge)
                        if (!visited[vi]) { touch(mesh_.vertices[vi]); visited[vi] = true; }
                }
                break;
            case EditMode.Polygons:
                foreach (i, face; mesh_.faces) {
                    if (hasSelF && !mesh_.isFaceSelected(i)) continue;
                    foreach (vi; face)
                        if (!visited[vi]) { touch(mesh_.vertices[vi]); visited[vi] = true; }
                }
                break;
        }
        if (!any) return Vec3(0, 0, 0);
        Vec3 cen = (mn + mx) * 0.5f;
        final switch (cast(SelectSubMode)sub) {
            case SelectSubMode.Center: return cen;
            case SelectSubMode.Top:    return Vec3(cen.x, mx.y, cen.z);
            case SelectSubMode.Bottom: return Vec3(cen.x, mn.y, cen.z);
            case SelectSubMode.Back:   return Vec3(cen.x, cen.y, mn.z);
            case SelectSubMode.Front:  return Vec3(cen.x, cen.y, mx.z);
            case SelectSubMode.Left:   return Vec3(mn.x, cen.y, cen.z);
            case SelectSubMode.Right:  return Vec3(mx.x, cen.y, cen.z);
        }
    }

    bool applySetAttr(string name, string value) {
        switch (name) {
            case "mode": {
                // 12-token WIRE universe (incl `manual`, which has no panel
                // entry — see modeEntriesFull's doc above).
                int v;
                if (!valueForWireTag(modeEntriesFull, value, v)) return false;
                // Switching mode (including Auto→Auto re-pick) clears the
                // Auto-userPlaced sub-state, as a popup re-click does, and the
                // display settle (a new mode recomputes the center afresh).
                mode = cast(Mode)v;
                userPin.placed = false;   // preserves the pre-R5 shape: stale
                                           // center left in place, see resetAuto()
                elementVerts_  = null;
                softPin        = Pin.init;
                return true;
            }
            case "cenX": case "cenY": case "cenZ": {
                import std.conv : to;
                float v;
                try v = value.to!float;
                catch (Exception) return false;
                if      (name == "cenX") manualCenter.x = v;
                else if (name == "cenY") manualCenter.y = v;
                else                     manualCenter.z = v;
                // Setting a coord component implies the user wants a
                // sticky pin — promote to Manual unless already there.
                if (mode != Mode.Manual) mode = Mode.Manual;
                return true;
            }
            case "userPlacedCenter": {
                // Vec3 convenience: "x,y,z" pushes all three components
                // + sets userPlaced=true in one HTTP call. Routed through
                // setUserPlaced() so it stages the in-session-cancel pin
                // baseline exactly like the real click-pick / click-away
                // relocate does — this is the headless counterpart of that
                // mouse-down relocate and tests rely on it staging.
                import std.string : split, strip;
                import std.conv   : to;
                auto parts = value.split(",");
                if (parts.length != 3) return false;
                Vec3 hit;
                try {
                    hit.x = parts[0].strip.to!float;
                    hit.y = parts[1].strip.to!float;
                    hit.z = parts[2].strip.to!float;
                } catch (Exception) { return false; }
                setUserPlaced(hit);
                return true;
            }
            case "userPlacedX": case "userPlacedY": case "userPlacedZ": {
                // Sticky click-outside / click-pick pin. Sets
                // userPlaced=true and the matching component without
                // switching mode — Auto / None / Screen / Element all
                // read userPlaced first when set. This is the HTTP
                // counterpart to setUserPlaced() and is what tests
                // use to simulate the post-click state for the Element
                // falloff pivot path without a real GPU-hover-driven
                // click.
                import std.conv : to;
                float v;
                try v = value.to!float;
                catch (Exception) return false;
                if      (name == "userPlacedX") userPin.center.x = v;
                else if (name == "userPlacedY") userPin.center.y = v;
                else                            userPin.center.z = v;
                userPin.placed = true;
                return true;
            }
            case "selectSubMode": {
                int v;
                if (!valueForWireTag(selectSubModeEntries, value, v)) return false;
                selectSubMode = v;
                return true;
            }
            default: return false;
        }
    }

    // Table-backed stringifiers reading the single-sourced tables declared
    // near `enum Mode` / `enum SelectSubMode` above (task 0184 / audit-2 C2).
    // `modeLabel` reads the 12-entry FULL table (not the 11-entry panel
    // table) since the wire format must round-trip `manual` too.
    string modeLabel() const {
        return wireTagForValue(modeEntriesFull, cast(int)mode);
    }

    string selectSubModeLabel() const {
        return wireTagForValue(selectSubModeEntries, selectSubMode);
    }

    void publishState() {
        setStatePath("actionCenter/mode", modeLabel());
        setStatePath("actionCenter/userPlaced", userPin.placed ? "true" : "false");
        setStatePath("actionCenter/selectSubMode", selectSubModeLabel());
    }
}

// ---------------------------------------------------------------------------
// params() snapshot — module-level so `dub test --config=modeling` runs it.
// A unittest in tests/ would be silently skipped (sourcePaths is "source/").
// ActionCenterStage ctor is not parameterless; params() only reads `mode`,
// never derefs the mesh, so a throwaway delegate + EditMode suffice.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    Mesh cube = makeCube();
    Mesh* meshPtr = &cube;
    EditMode em = EditMode.Vertices;
    auto acs = new ActionCenterStage(() => meshPtr, &em);
    // Default mode == None → whole section hidden.
    assert(acs.params().length == 0, "None: expected 0 params");
    // Any non-None mode → mode dropdown visible.
    acs.mode = ActionCenterStage.Mode.Auto;
    assert(acs.params().length == 1, "Auto: expected 1 param");
    assert(acs.params()[0].name == "mode");
    acs.mode = ActionCenterStage.Mode.Select;
    assert(acs.params().length == 1, "Select: expected 1 param");
    // Back to None → hidden again.
    acs.mode = ActionCenterStage.Mode.None;
    assert(acs.params().length == 0, "None (reset): expected 0 params");
}

// ---------------------------------------------------------------------------
// Task 0184 / audit-2 C2 — ActionCenterStage enforcement unittest, replacing
// the retired "KEEP IN SYNC with the applySetAttr switch and listAttrs()"
// comment on knownAttrs(). ACEN's setAttr/listAttrs/knownAttrs stay
// hand-written overrides (the attr set is genuinely asymmetric: `cenX/Y/Z`
// READ != the `manualCenter` they WRITE, `clusterCount` is read-only,
// `userPlacedCenter` is write-only, and `mode` accepts a parse-only alias
// `manual` with no panel entry) — so instead of a base-derivation assert
// (OBJ-4, which only applies to a symmetric stage like Constrain), this pins
// every MANDATORY behaviour by construction: every writable attr name
// actually round-trips through setAttr, both enum tokens round-trip via
// their tables, the `manual` / `userPlacedCenter` asymmetric paths work, the
// panel table is a subset of the wire table, negative asserts hold, and both
// tables are exhaustive over their enums.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import params : tableCoversEnum;

    Mesh cube = makeCube();
    Mesh* meshPtr = &cube;
    EditMode em = EditMode.Vertices;
    auto acs = new ActionCenterStage(() => meshPtr, &em);

    // --- Every WRITABLE name round-trips through setAttr --------------------
    // knownAttrs() ∪ the writable subset of listAttrs() (excluding read-only
    // `clusterCount`) — `userPlacedCenter` is knownAttrs()-only (write-only,
    // absent from listAttrs()); the rest overlap.
    assert(acs.setAttr("mode", "auto"));
    assert(acs.setAttr("cenX", "1"));
    assert(acs.setAttr("cenY", "2"));
    assert(acs.setAttr("cenZ", "3"));
    assert(acs.setAttr("userPlacedCenter", "4,5,6"));
    assert(acs.setAttr("userPlacedX", "7"));
    assert(acs.setAttr("userPlacedY", "8"));
    assert(acs.setAttr("userPlacedZ", "9"));
    assert(acs.setAttr("selectSubMode", "top"));
    foreach (name; acs.knownAttrs())
        assert(name == "mode" || name == "cenX" || name == "cenY" || name == "cenZ"
            || name == "userPlacedCenter" || name == "userPlacedX"
            || name == "userPlacedY" || name == "userPlacedZ"
            || name == "selectSubMode",
            "unexpected knownAttrs() entry: " ~ name);

    // --- Round-trip every `mode` + `selectSubMode` wireTag -------------------
    foreach (tag; ["auto", "select", "selectauto", "element", "local", "origin",
                   "screen", "border", "manual", "none", "pivot", "parent"]) {
        assert(acs.setAttr("mode", tag), "mode " ~ tag ~ " rejected");
        assert(acs.modeLabel() == tag, "mode " ~ tag ~ " did not round-trip");
    }
    foreach (tag; ["center", "top", "bottom", "back", "front", "left", "right"]) {
        assert(acs.setAttr("selectSubMode", tag), "selectSubMode " ~ tag ~ " rejected");
        assert(acs.selectSubModeLabel() == tag);
    }

    // --- `manual` mode token (parse-only, not in the 11-entry panel table) -
    assert(acs.setAttr("mode", "manual"));
    assert(acs.modeLabel() == "manual");
    bool manualInPanel = false;
    foreach (e; ActionCenterStage.modeEntries)
        if (e.wireTag == "manual") manualInPanel = true;
    assert(!manualInPanel, "'manual' must NOT appear in the panel mode table");

    // --- `userPlacedCenter` write-only path (sets all 3 comps + userPlaced) -
    assert(acs.setAttr("userPlacedCenter", "1.5,2.5,3.5"));
    assert(acs.isUserPlaced());
    auto attrs = acs.listAttrs();
    bool sawUX = false, sawUY = false, sawUZ = false;
    foreach (kv; attrs) {
        if (kv[0] == "userPlacedX") { assert(kv[1] == "1.5"); sawUX = true; }
        if (kv[0] == "userPlacedY") { assert(kv[1] == "2.5"); sawUY = true; }
        if (kv[0] == "userPlacedZ") { assert(kv[1] == "3.5"); sawUZ = true; }
    }
    assert(sawUX && sawUY && sawUZ);

    // --- Panel table (11) ⊆ full wire table (12) -----------------------------
    assert(ActionCenterStage.modeEntries.length == 11);
    assert(ActionCenterStage.modeEntriesFull.length == 12);
    foreach (e; ActionCenterStage.modeEntries) {
        int v;
        assert(valueForWireTag(ActionCenterStage.modeEntriesFull, e.wireTag, v),
            "panel entry '" ~ e.wireTag ~ "' missing from the full wire table");
        assert(v == e.value);
    }

    // --- (a) NEGATIVE: bogus tokens are rejected -----------------------------
    assert(!acs.setAttr("mode", "bogus"));
    assert(!acs.setAttr("selectSubMode", "bogus"));

    // --- (b) TABLE-COMPLETENESS: every enum member has a table entry --------
    assert(tableCoversEnum(ActionCenterStage.modeEntriesFull, [
        cast(int)ActionCenterStage.Mode.Auto, cast(int)ActionCenterStage.Mode.Select,
        cast(int)ActionCenterStage.Mode.SelectAuto, cast(int)ActionCenterStage.Mode.Element,
        cast(int)ActionCenterStage.Mode.Local, cast(int)ActionCenterStage.Mode.Origin,
        cast(int)ActionCenterStage.Mode.Screen, cast(int)ActionCenterStage.Mode.Border,
        cast(int)ActionCenterStage.Mode.Manual, cast(int)ActionCenterStage.Mode.None,
        cast(int)ActionCenterStage.Mode.Pivot, cast(int)ActionCenterStage.Mode.Parent,
    ]));
    assert(tableCoversEnum(ActionCenterStage.selectSubModeEntries, [
        cast(int)ActionCenterStage.SelectSubMode.Center, cast(int)ActionCenterStage.SelectSubMode.Top,
        cast(int)ActionCenterStage.SelectSubMode.Bottom, cast(int)ActionCenterStage.SelectSubMode.Back,
        cast(int)ActionCenterStage.SelectSubMode.Front, cast(int)ActionCenterStage.SelectSubMode.Left,
        cast(int)ActionCenterStage.SelectSubMode.Right,
    ]));
}

// ---------------------------------------------------------------------------
// M9 load-bearing aliasing proof: the Local-mode cluster cache (_clusterKey)
// must NOT alias two distinct Mesh instances that happen to share a
// mutationVersion. mesh_ is a live delegate that can be repointed at a
// different primary mid-session (a real layer switch), so the danger is
// real: without the address term, `a` and `b` below have an EQUAL (mutVer,
// editMode, selSig) key and the cache would wrongly serve `a`'s stale
// partition back for `b`.
//
// `a` is a 4-cycle 0-1-2-3-0 with ALL 4 verts selected: fully connected —
// exactly 1 cluster. `b` is two disjoint edges 0-1 / 2-3 with the SAME
// selection (all 4 verts): two separate components — exactly 2 clusters.
// Both meshes are hand-forced to mutationVersion == 7 — the exact aliasing
// hazard M9 closes.
// ---------------------------------------------------------------------------
unittest {
    import mesh : Mesh;

    Mesh a;
    a.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    a.resetSelection();
    a.addEdge(0, 1); a.addEdge(1, 2); a.addEdge(2, 3); a.addEdge(3, 0);
    a.selectVertex(0); a.selectVertex(1); a.selectVertex(2); a.selectVertex(3);
    a.mutationVersion = 7;

    Mesh b;
    b.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    b.resetSelection();
    b.addEdge(0, 1); b.addEdge(2, 3);
    b.selectVertex(0); b.selectVertex(1); b.selectVertex(2); b.selectVertex(3);
    b.mutationVersion = 7;   // hand-forced EQUAL to a — the aliasing hazard

    EditMode em = EditMode.Vertices;
    Mesh* meshPtr = &a;
    auto acs = new ActionCenterStage(() => meshPtr, &em);

    Vec3[] centersA; int[] clusterOfA;
    acs.computeLocalClustersFull(centersA, clusterOfA);
    assert(acs._cachedClusterCnt == 1,
        "a: a 4-cycle with all verts selected must form exactly 1 cluster");

    // Repoint mesh_ at b — SAME mutationVersion and editMode, and the SAME
    // selection signature (all 4 verts selected in both) as a. Only the
    // connectivity differs.
    meshPtr = &b;
    Vec3[] centersB; int[] clusterOfB;
    acs.computeLocalClustersFull(centersB, clusterOfB);
    assert(acs._cachedClusterCnt == 2,
        "b: two disjoint edges must form exactly 2 clusters. If this reads 1 "
        ~ "(a's value), the address term was dropped from the cache key and "
        ~ "b wrongly reused a's cached partition.");
}

// ---------------------------------------------------------------------------
// D1 (task 0188) byte-identity oracle: after the dedup, `computeCenter()`
// (the display path — GET /api/toolpipe -> listAttrs -> currentCenter, and
// the 4 other main-thread callers) and `localCenterAndClustersCached()` (the
// evaluate() path) MUST return the exact same Local-mode center, because
// they now share ONE BFS body. Uses a cube with two OPPOSITE, disconnected
// selected faces (indices 4 and 5 — the y=+0.5 and y=-0.5 faces; opposite
// faces of a cube never share an edge) so cluster-0's average centroid is a
// DISCRIMINATING value (0, 0.5, 0), not merely a count — a seed-order or
// cluster-0-identity regression would return face 5's centroid (0, -0.5, 0)
// instead and this would catch it, whereas a same-count check would not.
// ---------------------------------------------------------------------------
unittest {
    import mesh     : makeCube;
    import std.math : fabs;

    bool vecEq(Vec3 a, Vec3 b) {
        return fabs(a.x - b.x) < 1e-6f && fabs(a.y - b.y) < 1e-6f
            && fabs(a.z - b.z) < 1e-6f;
    }

    Mesh cube = makeCube();
    cube.resetSelection();   // size the selection arrays to the geometry
    cube.selectFace(4);   // y=+0.5 face, centroid (0, 0.5, 0) — lowest-index
                          // selected face, so this is cluster 0.
    cube.selectFace(5);   // y=-0.5 face, centroid (0, -0.5, 0) — a second,
                          // disconnected island (cluster 1).
    Mesh* meshPtr = &cube;
    EditMode em = EditMode.Polygons;
    auto acs = new ActionCenterStage(() => meshPtr, &em);
    acs.mode = ActionCenterStage.Mode.Local;

    immutable Vec3 cluster0Centroid = Vec3(0, 0.5f, 0);   // face 4's own centroid

    // Display path: computeCenter() via the public currentCenter() wrapper —
    // this is the const arm the D5 rewrite casts through.
    Vec3 displayCenter = acs.currentCenter();

    // Evaluate path: the cached BFS directly.
    Vec3[] cc; int[] co;
    Vec3 evalCenter = acs.localCenterAndClustersCached(cc, co);

    assert(acs._cachedClusterCnt == 2,
        "two disconnected opposite faces must form exactly 2 clusters");
    assert(vecEq(displayCenter, evalCenter),
        "display path (computeCenter) and evaluate path "
        ~ "(localCenterAndClustersCached) must return a byte-identical "
        ~ "Local center post-dedup");
    assert(vecEq(displayCenter, cluster0Centroid),
        "the returned center must be cluster-0's (lowest-index island, "
        ~ "face 4) centroid, NOT the whole-selection centroid nor face 5's — "
        ~ "this is what discriminates BFS seed-order / cluster-0 identity");
}

// ---------------------------------------------------------------------------
// Task 0187 (B3) Stage-0 characterization — the pin-precedence hoist
// byte-identity oracle. `computeCenter` used to repeat an
// `if (userPlaced) …; if (softPlaced) …;` ladder across most mode arms; B3
// collapses that into ONE pre-switch check gated by `relocateAllowed(mode)` /
// `settlePinHonored()`. This unittest pins every mode's result across three
// pin states (no pin / userPlaced set / softPlaced set, driven by DIRECT
// field writes — same-module private access — so states the public setters
// can't reach simultaneously, e.g. userPlaced+softPlaced both true, are still
// reachable for the precedence check).
//
// Every mode's result here is byte-identical to the pre-hoist ladder, EXCEPT
// Pivot/Parent's userPlaced case — task 0187's deliberate change (relocate
// pin now honored; softPlaced stays ignored, see the settle discriminator
// below). Each assert that differs from the naive "no pin ever read" table
// carries its own comment; Origin/Manual/Local (pins never read) and
// Select/SelectAuto/Border (userPlaced never read, softPlaced read) are the
// discriminators the single-gesture drag suite is blind to (BUG-1's fixture
// coverage only reaches Auto/None/Screen + a live drag settle).
// ---------------------------------------------------------------------------
unittest {
    import mesh     : makeCube;
    import std.math : fabs;
    import std.conv : to;

    bool vecEq(Vec3 a, Vec3 b) {
        return fabs(a.x - b.x) < 1e-4 && fabs(a.y - b.y) < 1e-4
            && fabs(a.z - b.z) < 1e-4;
    }

    Mesh cube = makeCube();       // symmetric ±0.5 cube, no selection ⇒ every
    Mesh* meshPtr = &cube;        // centroid/element/local fallback = (0,0,0)
    EditMode em = EditMode.Vertices;

    // Pivot/Parent need a primary item (+ one parent level) with distinct,
    // non-zero pivots so the mode-specific fallback is never confusable with
    // (0,0,0) or the pin points below.
    auto parentLayer = new Layer();
    parentLayer.xform.pivot = Vec3(3, 4, 5);      // parent world pivot pos
    auto primaryLayer = new Layer();
    primaryLayer.xform.pivot = Vec3(1, 2, 3);     // primary world pivot pos
    primaryLayer.parent = parentLayer;
    Layer primaryRef = primaryLayer;

    auto acs = new ActionCenterStage(() => meshPtr, &em, () => primaryRef);
    acs.manualCenter = Vec3(7, 8, 9);             // Mode.Manual fixed center

    immutable Vec3 zero    = Vec3(0, 0, 0);
    immutable Vec3 userPt  = Vec3(10, 20, 30);
    immutable Vec3 softPt  = Vec3(-10, -20, -30);
    immutable Vec3 pivotWorld  = Vec3(1, 2, 3);   // primaryLayer pos+pivot
    immutable Vec3 parentWorld = Vec3(3, 4, 5);   // parentLayer pos+pivot

    // (userPlaced, softPlaced) driven directly — bypasses setUserPlaced() /
    // setSoftPlaced()'s mutual-clear side effects so every combination in the
    // ground-truth table (incl. BOTH set, to prove precedence order) is
    // reachable.
    void setPins(bool up, bool sp) {
        acs.userPin.placed = up;
        acs.userPin.center = up ? userPt : zero;
        acs.softPin.placed = sp;
        acs.softPin.center = sp ? softPt : zero;
    }

    alias Mode = ActionCenterStage.Mode;

    // --- Auto / Screen / None: relocateAllowed T, settlePinHonored T --------
    // userPlaced 1st, softPlaced 2nd, else centroid fallback. Unchanged.
    foreach (m; [Mode.Auto, Mode.Screen, Mode.None]) {
        acs.mode = m;
        setPins(false, false); assert(vecEq(acs.currentCenter(), zero),
            m.to!string ~ ": no-pin must fall back to the centroid");
        setPins(false, true);  assert(vecEq(acs.currentCenter(), softPt),
            m.to!string ~ ": softPlaced must be honored (2nd)");
        setPins(true, false);  assert(vecEq(acs.currentCenter(), userPt),
            m.to!string ~ ": userPlaced must be honored (1st)");
        setPins(true, true);   assert(vecEq(acs.currentCenter(), userPt),
            m.to!string ~ ": userPlaced must WIN over softPlaced when both set");
    }

    // --- Select / SelectAuto: relocateAllowed F, settlePinHonored T ---------
    // userPlaced must stay IGNORED (discriminator); softPlaced honored.
    foreach (m; [Mode.Select, Mode.SelectAuto]) {
        acs.mode = m;
        setPins(false, false); assert(vecEq(acs.currentCenter(), zero),
            m.to!string ~ ": no-pin fallback");
        setPins(true, false);  assert(vecEq(acs.currentCenter(), zero),
            m.to!string ~ " + userPlaced set: must stay on the selection center "
            ~ "(userPlaced ignored) — discriminator for the hoist's narrow "
            ~ "relocateAllowed set");
        setPins(false, true);  assert(vecEq(acs.currentCenter(), softPt),
            m.to!string ~ ": softPlaced must be honored");
        setPins(true, true);   assert(vecEq(acs.currentCenter(), softPt),
            m.to!string ~ ": with userPlaced ignored, softPlaced still wins "
            ~ "over the fallback when both are set");
    }

    // --- Border: relocateAllowed F, settlePinHonored T ----------------------
    acs.mode = Mode.Border;
    setPins(false, false); assert(vecEq(acs.currentCenter(), zero),
        "Border: no-pin fallback");
    setPins(true, false);  assert(vecEq(acs.currentCenter(), zero),
        "Border + userPlaced set: must stay on the border center (ignored) — "
        ~ "discriminator for the hoist's narrow relocateAllowed set");
    setPins(false, true);  assert(vecEq(acs.currentCenter(), softPt),
        "Border: softPlaced must be honored");

    // --- Origin / Manual: relocateAllowed F, settlePinHonored F -------------
    // BOTH pins must stay ignored even when set — this is the case the naive
    // hoist (bare acenSettleAllowed() for softPlaced) would have REGRESSED,
    // since acenSettleAllowed() is true for Origin/Manual (only Element/Local
    // are excluded there).
    acs.mode = Mode.Origin;
    setPins(false, false); assert(vecEq(acs.currentCenter(), zero), "Origin: no-pin");
    setPins(true, false);  assert(vecEq(acs.currentCenter(), zero),
        "Origin + userPlaced set: must stay (0,0,0) (ignored)");
    setPins(false, true);  assert(vecEq(acs.currentCenter(), zero),
        "Origin + softPlaced set: must stay (0,0,0) (ignored) — the case the "
        ~ "naive acenSettleAllowed()-only hoist would have regressed");
    setPins(true, true);   assert(vecEq(acs.currentCenter(), zero),
        "Origin + both pins set: must still stay (0,0,0)");

    acs.mode = Mode.Manual;
    setPins(false, false); assert(vecEq(acs.currentCenter(), acs.manualCenter),
        "Manual: no-pin fallback = manualCenter");
    setPins(true, false);  assert(vecEq(acs.currentCenter(), acs.manualCenter),
        "Manual + userPlaced set: must stay on manualCenter (ignored)");
    setPins(false, true);  assert(vecEq(acs.currentCenter(), acs.manualCenter),
        "Manual + softPlaced set: must stay on manualCenter (ignored) — the "
        ~ "case the naive acenSettleAllowed()-only hoist would have regressed");

    // --- Element: NOT gated by the hoist at all (relocateAllowed F,          -
    // settlePinHonored F since acenSettleAllowed() excludes Element). Keeps   -
    // its own in-arm `liveElementCenter → userPlaced → elementCenter` ladder. -
    acs.mode = Mode.Element;
    setPins(false, false); assert(vecEq(acs.currentCenter(), zero),
        "Element: no pick, no pin → elementCenter() fallback (empty sel ⇒ "
        ~ "whole-mesh average = 0)");
    setPins(true, false);  assert(vecEq(acs.currentCenter(), userPt),
        "Element: no live pick → in-arm userPlaced still honored (below the "
        ~ "live center, unaffected by the hoist)");
    setPins(false, true);  assert(vecEq(acs.currentCenter(), zero),
        "Element: softPlaced is NEVER consulted (no in-arm check, and the "
        ~ "hoisted check is gated off since acenSettleAllowed() excludes "
        ~ "Element) — must fall back to elementCenter()");

    // --- Local: NOT gated by the hoist at all (relocateAllowed F,           -
    // settlePinHonored F since acenSettleAllowed() excludes Local). D5       -
    // deferred — arm unchanged, both pins stay irrelevant.                  -
    acs.mode = Mode.Local;
    setPins(true, true);
    assert(vecEq(acs.currentCenter(), zero),
        "Local: both pins set but empty selection ⇒ 0 clusters ⇒ centroid "
        ~ "fallback (0) — pins never consulted");

    // --- Pivot / Parent: task 0187's DELIBERATE change -----------------------
    // relocateAllowed NOW TRUE (was false pre-0187) → userPlaced honored.
    // settlePinHonored stays FALSE → softPlaced stays ignored (unchanged;
    // Pivot/Parent join Origin/Manual's "settle write, never read" class).
    acs.mode = Mode.Pivot;
    setPins(false, false); assert(vecEq(acs.currentCenter(), pivotWorld),
        "Pivot: no-pin fallback = primary item's pivot world pos (unchanged)");
    setPins(true, false);  assert(vecEq(acs.currentCenter(), userPt),
        "Pivot + userPlaced set: task 0187 flips this — userPlaced now WINS "
        ~ "over the live item pivot (pre-0187 this returned pivotWorld)");
    setPins(false, true);  assert(vecEq(acs.currentCenter(), pivotWorld),
        "Pivot + softPlaced set: must stay on the live item pivot (ignored) "
        ~ "— the settle exclusion is unchanged by 0187");
    setPins(true, true);   assert(vecEq(acs.currentCenter(), userPt),
        "Pivot + both pins set: userPlaced (now relocate-allowed) wins over "
        ~ "the ignored softPlaced");

    acs.mode = Mode.Parent;
    setPins(false, false); assert(vecEq(acs.currentCenter(), parentWorld),
        "Parent: no-pin fallback = parent item's pivot world pos (unchanged)");
    setPins(true, false);  assert(vecEq(acs.currentCenter(), userPt),
        "Parent + userPlaced set: task 0187 flips this — userPlaced now WINS "
        ~ "over the live parent pivot (pre-0187 this returned parentWorld)");
    setPins(false, true);  assert(vecEq(acs.currentCenter(), parentWorld),
        "Parent + softPlaced set: must stay on the live parent pivot "
        ~ "(ignored) — the settle exclusion is unchanged by 0187");
    setPins(true, true);   assert(vecEq(acs.currentCenter(), userPt),
        "Parent + both pins set: userPlaced (now relocate-allowed) wins over "
        ~ "the still-ignored softPlaced");

    // -------------------------------------------------------------------
    // Pivot settle before/after — a gesture settle must NOT freeze the
    // Pivot gizmo. `settleGestureCenter` (xfrm_transform.d) still calls
    // `setSoftPlaced` for Pivot on every drag settle (acenSettleAllowed()
    // is true for Pivot — only Element/Local are excluded there); this
    // proves `computeCenter` never reads that write, so the gizmo keeps
    // tracking the LIVE item pivot across the settle and any subsequent
    // item move (the "next gesture" contract in the task plan).
    // -------------------------------------------------------------------
    acs.mode = Mode.Pivot;
    setPins(false, false);
    assert(vecEq(acs.currentCenter(), pivotWorld),
        "Pivot settle test: pristine center = live item pivot");
    acs.setSoftPlaced(Vec3(99, 99, 99));   // simulates the wrapper's settle write
    assert(acs.isSoftPlaced(), "setSoftPlaced must record the soft pin");
    assert(vecEq(acs.currentCenter(), pivotWorld),
        "Pivot settle test: immediately after the settle write, the center "
        ~ "must STILL read the live item pivot, not the dropped settle point");
    // Move the item between gestures — the gizmo must keep tracking it,
    // proving the stale settle value is genuinely never consulted (not
    // coincidentally equal to the pre-move pivot).
    primaryLayer.xform.pivot = Vec3(6, 6, 6);
    assert(vecEq(acs.currentCenter(), Vec3(6, 6, 6)),
        "Pivot settle test: after an item move following the settle, the "
        ~ "center must follow the NEW live pivot — a settle must never "
        ~ "freeze the Pivot gizmo");
}
