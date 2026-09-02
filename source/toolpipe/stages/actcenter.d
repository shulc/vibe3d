module toolpipe.stages.actcenter;

import std.format : format;

import math    : Vec3, Pin, Viewport, screenRay, screenPointToRay, rayPlaneIntersect, applyAffine,
                 ModelSpace;
import mesh    : Mesh;
import mesh_dirty : MeshDirtyKey, g_topoEpochs;  // task 1906 stage 2d (row 15)
import editmode : EditMode;
import seltype : SelType;
import toolpipe.stage    : Stage, TaskCode, ordAcen, ToolSwitchTransient;
import params           : Param, IntEnumEntry, wireTagForValue, valueForWireTag;
// pipeline imports moved to packet-only — Phase 6 cleanup
import toolpipe.packets  : SymmetryPacket, ActionCenterPacket;
import operator          : Operator, Task, VectorStack, PacketKind;
import popup_state       : setStatePath;
import document          : Layer;

/// How many times `computeLocalClustersFull` has rebuilt the Local-mode
/// cluster MEMBERSHIP partition — the O(V+E) walk, not the per-call centre
/// recompute (task 1906 stage 2d).
///
/// It exists so the NARROWING can be pinned in the direction that costs.
/// `_clusterKey`'s watcher (`mesh_dirty.g_topoEpochs`) deliberately omits
/// `Position`, and the failure mode of getting that wrong is invisible to
/// every value assertion in this file: widen the mask and the partition is
/// still CORRECT, it is merely rebuilt on every step of every drag. Only a
/// rate can see that, so here is the rate. Monotone, never reset;
/// `__gshared` and always-on rather than `debug`, because the unit lane and
/// the suite lane build with different flags.
__gshared ulong g_acenClusterRebuilds;

/// How many times `bboxMembershipCached` has rebuilt the list of vertices
/// that CONTRIBUTE to a selection-derived bounding box — the O(V+E+F) walk,
/// not the per-call bbox recompute over that list (task 2006).
///
/// Same contract, and for the same reason, as `g_acenClusterRebuilds` above:
/// the failure mode of getting the key wrong is invisible to every value
/// assertion in this file. Widen the key with a POSITION term and the list is
/// still CORRECT — it is merely rebuilt on every evaluation of every drag
/// frame, which is precisely the cost this cache exists to remove (measured:
/// 2 evaluations per rendered frame + ~2 per motion event, each an O(mesh)
/// walk, 9.31 ms apiece on a 1M-face grid in Polygons mode). Only a RATE can
/// see that, so here is the rate. Monotone, never reset; `__gshared` and
/// always-on rather than `debug`, because the unit lane and the suite lane
/// build with different flags.
__gshared ulong g_acenBboxMembershipRebuilds;

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
class ActionCenterStage : Stage, Operator, ToolSwitchTransient {
    // Phase 1 of doc/operator_refactor_plan.md: persistent packet for
    // VectorStack publishing. Updated in evaluate(VectorStack) from the
    // ToolState result of the legacy evaluate path.
    private ActionCenterPacket _publishedPacket;

    Task task() const { return Task.Acen; }
    PacketKind[] requiredPackets() const { return [PacketKind.Subject]; }

    bool evaluate(ref VectorStack vts) {
        if (!pipeEnabled) return false;
        import toolpipe.packets : SubjectPacket, WorkplanePacket,
                                  SymmetryPacket;
        // Cache live viewport + upstream workplane so listAttrs
        // (called outside evaluation) and Screen mode can re-derive
        // the same value the pipeline just produced.
        //
        // Item mode 0614 / review Blocker 2: the subject's SelType is
        // deliberately NOT cached into a field the way lastView_/
        // lastWpCenter_ are. The pipeline is a process-wide singleton
        // (pipeline.d), and different evaluate() callers legitimately
        // publish DIFFERENT, each-correct-for-itself SelTypes in the same
        // process lifetime — command.d's generic base and MeshSelect are
        // always geometry-scoped (Vertex) regardless of what the app's live
        // selection type is; XfrmTransformTool's buildLocalVts tracks the
        // live app state. A cached field would leak whichever evaluate()
        // call ran last into every later reader (falloff_handles.d,
        // listAttrs(), a mid-drag currentCenter() read from an UNRELATED
        // evaluate() that ran in between) — order-dependent, no symptom
        // until two callers disagree. So the decision is a function of
        // THIS packet, at the point of use, right here — `subjType` is a
        // local, not a field.
        SelType subjType = SelType.Vertex;
        if (auto subj = vts.get!SubjectPacket()) {
            lastView_ = subj.viewport;
            subjType  = subj.selType;
        }
        if (auto wp = vts.get!WorkplanePacket()) {
            lastWpCenter_ = wp.center;
            lastWpNormal_ = wp.normal;
        }
        ActionCenterPacket pkt;
        // Local mode's per-frame center comes from the cached cluster
        // partition (see localCenterAndClustersCached) so the O(E·V) BFS is
        // not redone every drag frame. All other modes use the const
        // computeCenter() path (cheap centroid/bbox scans).
        //
        // Item mode 0614: Local is one of the modes computeCenter()
        // redirects to the item's world pivot (§Q3), but that redirect only
        // fires INSIDE computeCenter() — so the BFS must be skipped here too,
        // or it would run (and populate localCenters) despite its result
        // being thrown away below. Skipping it also keeps `localCenters`
        // empty, which is what keeps `pkt.clusterCenters`/`clusterOf` unset
        // a few lines down (the `length >= 2` guard), so
        // `ClusterPivots.active`/`ClusterAxes.active` read false downstream
        // — item mode never has a multi-cluster partition.
        Vec3[] localCenters;
        int[]  localClusterOf;
        if (mode == Mode.Local && mesh_ !is null && subjType != SelType.Item) {
            pkt.center = localCenterAndClustersCached(localCenters, localClusterOf);
        } else {
            pkt.center = computeCenter(subjType);
        }

        // Phase 7.6 (BaseSide gizmo): when symmetry is on and the
        // selection contains BOTH sides of the plane (via 7.6c
        // auto-add or explicit multi-pick), the raw selection
        // centroid sits ON the symmetry plane — the gizmo lands at
        // the axis of symmetry instead of the user's clicked half.
        // Restrict the centroid to base-side verts so the gizmo
        // follows the side the user anchored on.
        //
        // Item mode 0614 (review blocker): this is a SECOND writer of
        // `pkt.center` — the first (computeCenter()/localCenterAndClusters-
        // Cached above) already redirects to the item's world pivot for
        // `itemRedirectMode(mode)` modes, but this block computed a pure
        // vertex-geometry centroid with no awareness of that redirect.
        // With an item subject there is no selected geometry to restrict
        // to a symmetry side of, so this override must not fire at all —
        // `subjType != SelType.Item` closes that gap. The
        // Element/Local/Origin/Manual/Pivot/Parent exclusions are or-
        // thogonal (those modes never want a centroid override, in any
        // subject mode) — and since task 0705 they are not listed here at
        // all: restricting a centroid only makes sense where the published
        // centre IS that centroid, which is exactly
        // `centerIsSelectionCentroid`. The six-mode list used to be written
        // out inline right here AND again in `settlePinHonored`, two
        // hand-maintained spellings of one set.
        if (auto sym = vts.get!SymmetryPacket()) {
            if (sym.enabled
             && sym.vertSign.length == sym.pairOf.length
             && sym.vertSign.length > 0
             && !userPin.placed
             && subjType != SelType.Item
             && centerIsSelectionCentroid(mode))
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

    // Task 1530 — Mode.Element's FROZEN pivot: the world point written on the
    // button-DOWN of a picking click that hit no tool handle
    // (XfrmTransformTool.tryPickElement -> take*). It is a POINT, not a vertex
    // ring: `computeCenter`'s Element arm copies these three numbers and reads
    // no mesh at all, so the pivot cannot be recomputed from the geometry the
    // tool is moving. That recomputation was the defect — a live ring centroid
    // closes the loop `pivot <- geometry <- scale about pivot`, whose fixed
    // point is unstable for |1-s| > 1 (measured on a live drag: two sign flips
    // and an order of magnitude per sample).
    //
    // Lifetime — deliberately NOT "for the gesture". The point survives the
    // whole gesture AND every later gesture, until the next such picking
    // click; a mode switch keeps it; `resetTransient()` (tool.set / tool
    // switch) keeps it; only a full `reset()` (= SceneReset = /api/reset)
    // wipes it.
    //
    // Why its OWN field and not `userPin`: `resetTransient()` destroys
    // `userPin` BEFORE a preset's attributes arrive, so a preserved `userPin`
    // would have to survive the transient reset — and then the NEXT tool,
    // armed in Auto / None / Screen / Pivot / Parent (all of which DO read
    // `userPin` via `honoursPlacedCenter`), would find its gizmo hijacked by
    // a pin the previous tool's element click left behind. A field only the
    // Element arm reads survives the reset harmlessly.
    private Pin elementPin;

    /// Task 0791 — which of this stage's attributes ARE the slot: the MODE
    /// (which centre tool sits in it) and every explicit relocate. See
    /// Stage.attrArmsSlot for why this is a write-counter and not a diff, and
    /// why only command sites bump it.
    ///
    /// `cenX/cenY/cenZ` are in the set because writing one PROMOTES the stage
    /// to Manual — the write is a mode change wearing a coordinate's name.
    override bool attrArmsSlot(string name) const {
        switch (name) {
            case "mode", "userPlacedCenter",
                 "userPlacedX", "userPlacedY", "userPlacedZ",
                 "cenX", "cenY", "cenZ":
                return true;
            default:
                return false;
        }
    }

    Vec3 manualCenter = Vec3(0, 0, 0);      // valid for Mode.Manual
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

    /// The vertex position the ACTION CENTRE aims at — the DRAWN one
    /// (task 1069). `CLAUDE.md` names this stage the single source of truth
    /// for the gizmo pivot, and Phase 0 measured the surface drawing
    /// base+delta under a morph target, so leaving the pivot on the base
    /// would put the gizmo where the user is not looking, while the tool's
    /// run baseline (base + delta, which law L7 forces independently) sits
    /// somewhere else again — three different points for one gesture.
    ///
    /// Identical to `mesh_.vertices[vi]` whenever no morph target is bound,
    /// which is what keeps every existing action-centre fixture unchanged.
    ///
    /// Worth stating because it is the reason objection 8 could not be
    /// closed by the pick test alone: a `/api/pick` assertion passes with
    /// this unrouted (the BVH already follows the draw) while the gizmo sits
    /// on the base. The two need separate assertions.
    private Vec3 acenVertex(size_t vi) const {
        import morph_target : displayPosition;
        return displayPosition(mesh_, vi);
    }

    /// Is a morph preview live on this stage's mesh? Wrapper so the import
    /// sits in one place.
    private bool morphPreviewActive(const Mesh* m) const {
        import morph_target : mtActive = morphPreviewActive;
        return mtActive(m);
    }
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
    // Item mode 0614 / review Blocker 2: the LIVE external source for "what
    // SelType is the CURRENT subject", used only by callers that reach
    // computeCenter() WITHOUT a packet in hand (currentCenter() — listAttrs(),
    // falloff_handles.d, transform.d/xfrm_transform.d's mid-drag
    // currentCenter() reads). Deliberately a delegate queried fresh on every
    // call, not a field cached from the last evaluate() (see evaluate()'s
    // doc comment for why that was wrong) — matches the existing meshSrc_/
    // primarySrc_ pattern below. Null in tests that don't wire item-mode
    // awareness; liveSelType() then falls back to Vertex, matching
    // SubjectPacket's own R4 default.
    SelType delegate() selTypeSrc_;
    private SelType liveSelType() const { return selTypeSrc_ ? selTypeSrc_() : SelType.Vertex; }

    // --- Local-mode cluster cache -----------------------------------------
    // During a transform drag the connected-component partition is INVARIANT
    // (selection frozen, topology frozen — transform tools mutate vertex
    // POSITIONS directly without bumping mesh.mutationVersion, on purpose),
    // so only per-cluster centers need recomputing each frame. The membership
    // partition (`_cachedClusterOf` + count) and the vertex adjacency it was
    // built from are cached and reused while the key holds.
    //
    // Cache key: (address, CONNECTIVITY epoch, editMode, selectionSignature).
    //
    // TASK 1906 STAGE 2d (plan §3.4 row 15) — the mesh half is
    // `mesh_dirty.g_topoEpochs`, a bus watcher whose mask is `Points |
    // Polygons` and DELIBERATELY NOT `Position`. This is the one row of family
    // 4 that NARROWS, and the narrowing is the reason the watcher exists
    // rather than reusing `g_geomEpochs` (which carries Position for the
    // display and BVH families): cluster MEMBERSHIP is a function of
    // connectivity and of the selected set, never of where the vertices are,
    // and the centres below are recomputed from live positions on every call
    // regardless. Keyed on anything that moves during a drag, the O(V+E)
    // membership walk would re-run on every step of every gesture — a
    // regression, not parity, because `mutationVersion` is version-silent
    // through a drag and this partition survives one today.
    //
    // Selection lives in the Marks.Select bit of vertexMarks/edgeMarks/
    // faceMarks and no epoch in this watcher's mask carries it, so the rolling
    // hash of the relevant marks array (`selectionSignature`) is what detects a
    // selection change — as it always was; `mutationVersion` merely also moved.
    // Edit mode picks which cluster variant runs, so it is part of the key too.
    //
    // The ADDRESS term is unchanged in meaning: this cache lives on the STAGE,
    // not on the Mesh, and `mesh_` is a live delegate that can silently
    // retarget to a different primary layer. Two distinct Mesh instances share
    // an epoch trivially — an untracked one reads the table's `evicted_`
    // floor — so the address is what stops one layer's partition being served
    // for another. See mesh_dirty.d's MeshDirtyKey doc comment.
    bool   _cacheValid       = false;
    MeshDirtyKey _clusterKey;
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

    // --- Selection-BBOX MEMBERSHIP cache (task 2006) -----------------------
    //
    // WHICH vertices contribute to the selection-derived bounding box, as a
    // flat index list. Keyed on the same THREE QUANTITIES as `_clusterKey`
    // above — address, connectivity epoch, edit mode, selection — and for
    // exactly the same reason: membership is a function of connectivity and
    // of the selected set, NEVER of where the vertices are. It differs from
    // the cluster key in HOW it reads the selection: `Mesh.marksVersion`, an
    // O(1) counter, rather than the O(V) `selectionSignature()` hash. That is
    // not a style choice — see `bboxMembershipCached`'s doc for the
    // measurement that made the hash cost more than the walk it guarded.
    // The bbox itself is still
    // recomputed from live positions on EVERY call — that is load-bearing, not
    // an oversight. `applyTRS` restores the run baseline over `mesh.vertices`
    // with a raw array write that publishes nothing (xfrm_transform.d's
    // `restoreBaselinePrefix` is `pure nothrow @nogc`), so a cache that
    // memoised the RESULT against a bus epoch would hand a baseline-sampled
    // evaluate the value computed from the previous step's OUTPUT — which is
    // the pivot-drift-under-its-own-output defect `samplePipeFromBaseline`
    // exists to prevent (doc/measured_laws.md §2). Caching membership is
    // immune to that: a silent position write cannot change WHICH vertices are
    // incident to the selected elements.
    //
    // The list reproduces, element for element, the contributing set of
    // `Mesh.selectionBBoxCenterVertices/Edges/Faces` — including the universal
    // "no selection ⇒ all geometry" fallback and the edge/face de-duplication.
    // Order within the list is irrelevant: min/max over a multiset equals
    // min/max over its set, in any order, exactly.
    bool         _bboxCacheValid = false;
    MeshDirtyKey _bboxKey;
    int          _bboxEditMode   = -1;
    // The SELECTION term, and it is `Mesh.marksVersion` rather than the
    // sibling cluster cache's `selectionSignature()` — see
    // `bboxMembershipCached`'s doc comment for the measurement that forced
    // the difference. `ulong.max` rather than 0 so a fresh stage cannot
    // accidentally match a fresh mesh's zero.
    ulong        _bboxMarksVer   = ulong.max;
    // Vertex count the list was built against. Part of the key, mirroring the
    // cluster cache's `_cachedClusterOf.length == mesh_.vertices.length` belt:
    // an untracked vertex-count change would otherwise index out of range.
    size_t       _bboxVertCount  = size_t.max;
    // Grown, never shrunk; only `_bboxVerts[0 .. _bboxCount]` is live.
    uint[]       _bboxVerts;
    size_t       _bboxCount     = 0;
    // De-duplication scratch for the Edges / Polygons walks, kept across
    // rebuilds so the walk allocates nothing in steady state.
    bool[]       _bboxSeen;

public:
    this(Mesh* delegate() meshSrc, EditMode* editMode,
         Layer delegate() primarySrc = null,
         SelType delegate() selTypeSrc = null) {
        this.meshSrc_    = meshSrc;
        this.editMode_   = editMode;
        this.primarySrc_ = primarySrc;
        this.selTypeSrc_ = selTypeSrc;
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
        elementPin       = Pin.init;
        manualCenter     = Vec3(0, 0, 0);
        selectSubMode    = SelectSubMode.Center;
        clusterCount_    = 0;
        userLocked       = false;
        cancelFrozen     = false;
        cancelSnap       = Pin.init;
        cancelElementSnap = Pin.init;
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
        _clusterKey.clear();
        _cachedEditMode = -1;
        _cachedSelSig   = 0;
        // The bbox-membership list rides the same explicit-reset hook (task
        // 2006). Its own key check already catches selection / topology /
        // layer changes mid-session; this is the same belt-and-braces.
        _bboxCacheValid = false;
        _bboxKey.clear();
        _bboxEditMode   = -1;
        _bboxMarksVer   = ulong.max;
        _bboxVertCount  = size_t.max;
        _bboxCount      = 0;
    }

    /// resetTransient: same as reset() but respects userLocked.
    /// Called by resetTransientPipeStages (tool.set / tool switch) so
    /// an explicit `actr.*` user setting survives switching tools.
    ///
    /// Task 1530 — `elementPin` is carried ACROSS this reset. It has to be:
    /// `app.d` runs resetTransientPipeStages BEFORE `preActivate` unrolls a
    /// preset's attributes, so by the time `setAttr("mode","element")` lands
    /// the mode is already None and every pin is already `Pin.init`. Without
    /// the carry, re-arming `xfrm.elementMove` would silently drop the frozen
    /// pivot even though nothing about the pick changed. (A mode armed through
    /// `actr.element` sets `userLocked` and returns above without resetting at
    /// all — so before this carry the two arming routes disagreed. Now both
    /// keep the point.) `reset()` still wipes it: an explicit full reset must.
    override void resetTransient() {
        if (userLocked) return;
        auto keepElementPin = elementPin;
        reset();
        elementPin = keepElementPin;
    }

    /// Set the action-center mode explicitly (called by ActrPresetCommand).
    /// Sets userLocked=true so the mode survives the next tool activation.
    void setUserMode(string modeStr) {
        // Task 0791 — through the FUNNEL, not around it: `setAttr` is where a
        // slot-arming write is counted, and this is the door the action-centre
        // preset command comes in by. Calling `applySetAttr` directly here left
        // that door uncounted and needed a patch at the command instead.
        bool ok = setAttr("mode", modeStr);
        if (ok) {
            userLocked = true;
            publishState();
        }
    }

    override bool setAttrImpl(string name, string value) {
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

    /// Mode.Element: FREEZE the picked element's anchor point (task 1530).
    /// Called from the transform wrapper's click-pick on button-DOWN; from
    /// then on `computeCenter`'s Element arm copies this point and reads no
    /// geometry, so the pivot cannot chase the vertices the tool is moving.
    /// See the `elementPin` field doc for the lifetime.
    ///
    /// A write of the point already held is skipped whole — no re-publish, no
    /// re-stage of the cancel baseline. (The wrapper's `take*` skips the
    /// paired `setUserPlaced` on the same condition; this guard is the
    /// stage-side half so a headless caller cannot slip past it.)
    void setElementPin(Vec3 worldPoint) {
        if (holdsElementPin(worldPoint)) return;
        // Stage the PRIOR element pin for the in-session cancel baseline on
        // the same terms `setUserPlaced` stages `userPin`: only while no
        // session snapshot is frozen. Element picks fire on mouse-DOWN, ahead
        // of the session's beginEdit, so this is what an in-session Ctrl+Z
        // rolls the pivot back to.
        if (!cancelFrozen) cancelElementSnap = elementPin;
        elementPin = Pin(true, worldPoint);
        publishState();
    }

    /// True iff the frozen Element pivot is placed AND sits exactly on
    /// `worldPoint`. Drives the equal-write skip in both `setElementPin` and
    /// the wrapper's `take*`. Exact compare on purpose: the writer re-derives
    /// the same anchor from the same unchanged geometry, so an epsilon would
    /// only widen the skip to points that genuinely differ.
    bool holdsElementPin(Vec3 worldPoint) const {
        return elementPin.placed
            && elementPin.center.x == worldPoint.x
            && elementPin.center.y == worldPoint.y
            && elementPin.center.z == worldPoint.z;
    }

    /// The frozen Element pivot, WHOLE — for the wrapper's undo hooks and the
    /// state dump. `placed == false` means "no picking click yet this scene".
    Pin currentElementPin() const { return elementPin; }

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
    // Task 1530 — the same baseline for the Element pivot. It rides the
    // IDENTICAL lifecycle (stage while not frozen / freeze / restore /
    // discard); it is a separate field only because `elementPin` is separate
    // state, exactly like `cancelSnap` is separate from `softPin`.
    private Pin  cancelElementSnap;

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

    /// Commit-time half of a detached transform boundary. The owner validates
    /// the whole pin before entering install; the fixed popup keys already
    /// exist from construction, so their prepared writes cannot grow the map.
    bool preparedSoftPinMatches(Pin expected) const nothrow @nogc {
        return softPin == expected;
    }

    void installPreparedClearSoftPlaced() nothrow @nogc {
        if (!softPin.placed) return;
        softPin = Pin.init;
    }

    /// True iff a display soft-pin is active. (Used by tests / introspection;
    /// computeCenter reads the field directly.)
    bool isSoftPlaced() const { return softPin.placed; }

    /// The current display soft-pin, WHOLE. Exposed so the transform wrapper
    /// can capture the gesture-START / gesture-END soft state for the Move
    /// undo/redo hooks, mirroring currentUserPin() for the userPlaced pin.
    ///
    /// Returns the `Pin` rather than the bare centre (task 0724 / audit-4 P6).
    /// The old shape was `isSoftPlaced()` + `currentSoftCenter()`, and every
    /// one of the four callers immediately wrote `Pin(a(), b())` — the value
    /// type being re-assembled by hand on the far side of the API it had just
    /// been taken apart to cross. That is the drift `Pin`'s own doc in math.d
    /// exists to warn about, and the API was the thing doing it.
    /// `isSoftPlaced()` stays, for the callers that genuinely want only the
    /// flag (http_providers' state dump, the mode predicates).
    Pin currentSoftPin() const { return softPin; }

    /// Restore the display soft-pin to an explicit (placed, center) endpoint and
    /// publish. Used by the wrapper's Move undo/redo hooks to carry the soft pin
    /// in lockstep with the geometry: revert restores the gesture-START soft state
    /// (typically cleared → the pivot recomputes to the reverted-geometry
    /// centroid), apply restores the gesture-END (settled) soft pin. Independent
    /// of restorePinState (userPlaced) — the two own disjoint state and compose in
    /// one hook closure without clobber.
    ///
    /// Takes the `Pin` whole (task 0724 / audit-4 P6). Note the normalisation
    /// it keeps and `restorePinState` does not: an un-placed soft pin is
    /// stored with a ZEROED centre, so `Pin.init` is the canonical cleared
    /// value and no stale point can survive behind `placed == false`.
    void restoreSoftPlaced(Pin p) {
        softPin = Pin(p.placed, p.placed ? p.center : Vec3(0, 0, 0));
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
        elementPin   = cancelElementSnap;   // task 1530 — same baseline, same restore
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
    // (currentUserPin()) at each gesture's beginEdit. The accessor below
    // exposes the live pin endpoint WHOLE so the wrapper can capture the
    // gesture-START at beginEdit and the gesture-END at commit, and restore
    // either one from a hook.

    /// The current (live) pin endpoint — the gesture-START pin captured at
    /// beginEdit, and the gesture-END pin captured at mouse-up after any
    /// sticky-follow has settled.
    ///
    /// One `Pin`, not a flag beside a point (task 0724 / audit-4 P6): this
    /// used to be `isUserPlaced()` + `currentPinCenter()`, read as a pair at
    /// every site and immediately re-packed into a `Pin`. `isUserPlaced()`
    /// remains — it has readers that want only the flag — but nothing needs
    /// to take the endpoint apart to move it any more.
    Pin currentUserPin() const { return userPin; }

    /// Restore the pin to an explicit (placed, center) endpoint and publish so
    /// the visible gizmo follows. Used by the wrapper's Move undo/redo hooks to
    /// snap the action center to the gesture-START (revert) or gesture-END
    /// (apply) pin in lockstep with the geometry. Does NOT touch the frozen
    /// snapshot — hooks run outside any open session.
    ///
    /// Takes the `Pin` whole (task 0724 / audit-4 P6), and stores it VERBATIM
    /// — deliberately unlike `restoreSoftPlaced`, which zeroes the centre of
    /// an un-placed pin. The user pin's centre is meaningful while unplaced
    /// (it is the point a later re-place would restage), so normalising here
    /// would lose it.
    void restorePinState(Pin p) {
        userPin = p;
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
        cancelSnap        = userPin;
        cancelElementSnap = elementPin;   // task 1530
    }

    // `setManualCenter(Vec3)` lived here — "switch into Manual mode and pin
    // the center". Removed (audit №4): zero callers ever appeared. Manual mode
    // is still fully reachable, just not through a one-shot setter: the mode
    // comes from the ACEN pulldown / `actr.manual` preset and the point from
    // the `cenX`/`cenY`/`cenZ` attrs, which write `manualCenter` directly.

public:
    // Returns the actual Vec3 the next pipeline.evaluate would publish.
    // Used by evaluate() / listAttrs() so the panel's cenX/Y/Z displays
    // the live computed center, and by external consumers
    // (falloff_handles.d's RMB-radius gesture) that need the canonical
    // pivot without walking the full pipeline.
    Vec3 currentCenter() const {
        return computeCenter(liveSelType());
    }

    /// BUG-1 / flex_border_handles_plan.md Phase 3 — the 2-entry "is a gesture
    /// settle (soft-pin) meaningful in this mode?" predicate. The wrapper's
    /// settleGestureCenter() consults it before pinning the drop center, and the
    /// undo-hook splice gates on it too. We EXCLUDE exactly the two modes that
    /// already own a HIGHER-precedence LIVE pivot source which computeCenter
    /// returns ahead of softPlaced — so a single drop-center either can't apply or
    /// can't represent the pivot:
    ///   - Element: the frozen `elementPin` from the picking click wins in
    ///     computeCenter, and it is ALREADY a freeze — a settle drop-centre on
    ///     top of it would overwrite the picked point with wherever the gesture
    ///     happened to end. (Pre-1530 the higher-precedence source here was the
    ///     LIVE ring centroid and the reason read "must keep tracking, not
    ///     freeze"; the exclusion survives the inversion, for the opposite
    ///     reason.)
    ///   - Local:   per-cluster pivots (N centers) — one drop-center can't stand
    ///     in for N clusters.
    /// This is NOT a mode allow-list: every OTHER mode (Auto / None / Screen /
    /// Select / SelectAuto / Border / Origin / Manual) consults softPlaced, so the
    /// freeze generalizes with no `mode==border` branch.
    ///
    /// A `final switch` since task 0705 (audit 4, P5): as an OR-chain, a Mode
    /// added later silently joined the ALLOWED side — the permissive default
    /// for a predicate that exists to withhold permission.
    bool acenSettleAllowed() const { return settleWriteAllowed(mode); }

    private static bool settleWriteAllowed(Mode m) pure nothrow @nogc @safe {
        final switch (m) {
            case Mode.Element:
            case Mode.Local:
                return false;
            case Mode.Auto:
            case Mode.None:
            case Mode.Screen:
            case Mode.Select:
            case Mode.SelectAuto:
            case Mode.Border:
            case Mode.Origin:
            case Mode.Manual:
            case Mode.Pivot:
            case Mode.Parent:
                return true;
        }
    }

    /// The modes whose published centre IS the selection centroid this stage
    /// computes — i.e. no fixed point (Origin, Manual), no live per-element or
    /// per-cluster source (Element, Local) and no live item pivot (Pivot,
    /// Parent) stands in front of it. Equivalently
    /// {Auto, Select, SelectAuto, Screen, Border, None}.
    ///
    /// ONE predicate where task 0705 found TWO spellings of the same six-way
    /// exclusion: `settlePinHonored()` below, and the symmetry base-side
    /// override inside `evaluate()`, which listed the six modes inline. Both
    /// were checked member by member across all twelve modes and were
    /// extensionally equal — but equal by coincidence of maintenance, not by
    /// construction: the `evaluate()` chain was hand-extended when
    /// Pivot/Parent were added, and `settlePinHonored` merely happened to be
    /// written later, already aware of them. The next member would have had to
    /// be added to both by hand, and nothing would have said so.
    ///
    /// The two consumers ask different QUESTIONS of this set ("may a drop
    /// point freeze the centre?" / "may a symmetry base side restrict it?"),
    /// and both reduce to "is the published centre that centroid at all?".
    /// Should they ever need to diverge, splitting this predicate is then a
    /// deliberate act — editing one of two OR-chains was not.
    private static bool centerIsSelectionCentroid(Mode m) pure nothrow @nogc @safe {
        final switch (m) {
            case Mode.Auto:
            case Mode.Select:
            case Mode.SelectAuto:
            case Mode.Screen:
            case Mode.Border:
            case Mode.None:
                return true;
            case Mode.Element:
            case Mode.Local:
            case Mode.Origin:
            case Mode.Manual:
            case Mode.Pivot:
            case Mode.Parent:
                return false;
        }
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
    //
    // A `final switch` since task 0705 (audit 4, P5) — as an OR-chain a new
    // Mode silently landed on the "not relocatable" side, which is the safe
    // default but still an UNDECLARED one; and it is precisely this set that
    // `transform.pressPlacesCenter` was measured to disagree with (see
    // task 0712 and that function's own note).
    private static bool honoursPlacedCenter(Mode m) pure nothrow @nogc @safe {
        final switch (m) {
            case Mode.Auto:
            case Mode.Screen:
            case Mode.None:
            case Mode.Pivot:
            case Mode.Parent:
                return true;
            case Mode.Select:
            case Mode.SelectAuto:
            case Mode.Element:
            case Mode.Local:
            case Mode.Border:
            case Mode.Origin:
            case Mode.Manual:
                return false;
        }
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
    // Element's frozen `elementPin` / Local's per-cluster pivots, which
    // `acenSettleAllowed()` already excludes from the settle write itself).
    //
    // Task 0705: the six exclusions are no longer written out here — this IS
    // `centerIsSelectionCentroid`, and so is the symmetry base-side gate in
    // `evaluate()` that used to spell the same six inline. `acenSettleAllowed()`
    // remains the strictly WIDER write-side predicate (it excludes only
    // Element/Local); the containment `settlePinHonored ⊆ acenSettleAllowed`
    // is now a property of the two tables rather than of this expression, and
    // a unittest below asserts it over every Mode.
    bool settlePinHonored() const {
        return centerIsSelectionCentroid(mode);
    }

    // Item mode 0614 (doc/item_mode_transform_plan.md §Q3 / §(a)). Modes
    // whose center is SELECTION-derived (or the geometry-fallback "nothing
    // selected") — in item mode there is no selected geometry to derive
    // from, so these redirect to the item's world pivot instead.
    // Origin/Manual/Pivot/Parent are excluded: they are either
    // subject-independent (Origin, Manual) or already item-anchored
    // (Pivot/Parent already read the item / its parent).
    //
    // A `final switch` — not the original OR-chain — so a Mode added later
    // MUST be classified here or the file fails to compile (review should-
    // fix: an OR-chain silently defaults an unlisted mode to "not
    // redirected", which is exactly the wrong failure mode for a table that
    // is supposed to be exhaustive).
    //
    // Screen: review should-fix 2. The excluded-list comment this replaced
    // called Screen "already item-anchored" — false. Screen's centre body
    // (below, `case Mode.Screen`) is the literal SAME call as Auto/None
    // (`centroidWithGeometryFallback()`); only its AXIS is camera-derived
    // (AxisStage, unaffected by this stage). There is no principled reason
    // for its CENTRE to sit in a different bucket than Auto/None, so it
    // joins them here.
    //
    // `capture-verified` for None (L1, Phase 0 case A); `capture-inferred`
    // for the rest (only the default was measured) — see the plan's Q3
    // provenance note. Screen's inclusion is inferred from CODE IDENTITY
    // with Auto/None (same function call), not from a separate capture.
    private static bool itemRedirectMode(Mode m) pure nothrow @nogc @safe {
        final switch (m) {
            case Mode.Auto:
            case Mode.Select:
            case Mode.SelectAuto:
            case Mode.Screen:
            case Mode.Element:
            case Mode.Local:
            case Mode.Border:
            case Mode.None:
                return true;
            case Mode.Origin:
            case Mode.Manual:
            case Mode.Pivot:
            case Mode.Parent:
                return false;
        }
    }

    /// The primary item's WORLD PIVOT — `applyAffine(composedMatrix(),
    /// pivot)`, equivalently `pos + pivot` for ANY rot/scl (the local pivot
    /// is a fixed point of `T(pivot)·R·S·T(-pivot)`, document.d:68).
    /// Extracted so the explicit `Mode.Pivot` arm and the item-mode redirect
    /// in `computeCenter()` share ONE implementation. `capture-verified`
    /// (L1, doc/tasks/0614-evidence/phase0_findings.md case A): measured
    /// `(0,0,0)` against geometry sitting at local `(3,0,0)`, and measured
    /// rotation-invariant (case A′, item rotated 45° about Y still read
    /// `(0,0,0)`).
    private Vec3 itemPivotWorld() const {
        auto l = primary_();
        if (l is null) return Vec3(0, 0, 0);
        return applyAffine(l.xform.composedMatrix(), l.xform.pivot);
    }

    /// THE SPACE THIS STAGE PUBLISHES IN (task 0649).
    ///
    /// Every centre this stage hands out is a WORLD point. Four of the twelve
    /// modes always were — `Origin` (the world origin), `Pivot` / `Parent`
    /// (an item's world pivot) and every PIN (`userPin` / `softPin` /
    /// `manualCenter` / `screenCenter`, all of them landed by a cursor ray).
    /// The geometry-derived ones were not: they read raw `mesh_.vertices`,
    /// which are the EDITED LAYER's own coordinates, and published the answer
    /// unconverted. Measured (0648): under an item translated by (5,-2,3) the
    /// reference's `select` centre reads (6.95,-0.9,1.7) and ours read
    /// (1.95,1.1,-1.3) — the item translation, exactly.
    ///
    /// That split is why `origin` printed `(0,0,0)` on both engines and meant
    /// two different points, and why the transform apply path — which reads
    /// EVERY centre as if it were layer-local — moved geometry about the item
    /// origin for `origin` and about `pos` for `pivot`, both wrong and in
    /// opposite directions.
    ///
    /// So the geometry-derived producers carry their points through this
    /// space, per point and BEFORE any min/max (see
    /// `mesh.selectionBBoxCenterVertices` for why the order is load-bearing),
    /// and the consumers that need layer coordinates convert back — one
    /// place, `XfrmTransformTool.applyTRS`.
    ///
    /// SOURCE. `document.primaryModelSpace()` — the space of the mesh this
    /// pipeline edits (`activeMeshRef` == `primary.mesh`), NOT `primary_()`.
    /// The two differ once a mesh-less item holds the item-transform focus,
    /// and there `primary_()` is the right answer for `Mode.Pivot` (the item
    /// the gizmo would move) while THIS is the right answer for "what maps
    /// `mesh_` into the world". Identity when the app resolver is not
    /// installed, which is every stage-level unittest — so those stay
    /// byte-identical.
    private ModelSpace itemSpace() const {
        import document : primaryModelSpace;
        return primaryModelSpace();
    }

private:

    // `subjType` is the subject's SelType AT THE POINT OF USE — the caller's
    // packet (evaluate()) or a freshly-queried live value (currentCenter()),
    // never a field cached from some earlier, possibly unrelated evaluate()
    // call (review Blocker 2 — see evaluate()'s doc comment and
    // `liveSelType()` above).
    Vec3 computeCenter(SelType subjType) const {
        if (honoursPlacedCenter(mode) && userPin.placed) return userPin.center;
        if (settlePinHonored()    && softPin.placed) return softPin.center;
        // Item mode 0614: redirect the selection-derived modes to the
        // item's world pivot BEFORE the geometry-selection switch below —
        // there is no selection to derive a center from when the subject is
        // an item. Sits after the pin-precedence checks above (a
        // user-placed pin keeps winning, unchanged) and before the switch,
        // per §(a) of the plan.
        if (subjType == SelType.Item && itemRedirectMode(mode))
            return itemPivotWorld();
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
                // tracks the selection like Auto does (byte-identical call —
                // which is why item mode redirects it exactly like Auto/
                // None too, see itemRedirectMode() above).
                return centroidWithGeometryFallback();
            case Mode.Element:
                // Task 1530 — the pivot is a FROZEN POINT, and this arm reads
                // NO geometry to produce it. The click-pick
                // (XfrmTransformTool.tryPickElement -> take*) writes it on the
                // button-DOWN of a picking click that hit no tool handle; from
                // then on it is the gizmo pivot AND the falloff sphere anchor
                // (FalloffStage.evaluate reads state.actionCenter.center) for
                // this gesture and every later one, until the next such click.
                //
                // It used to be the LIVE centroid of the picked vertex ring,
                // and that was the defect: the pivot was recomputed each frame
                // from the very vertices the tool was moving, so a scale or a
                // rotate about it closed a feedback loop. Do not restore a
                // geometry read here. A scale cell cannot catch the
                // regression — scaling about its own centre leaves that centre
                // a fixed point — so the detector is a TRANSLATE
                // (tests/test_acen_element_freeze_translate.d).
                //
                // Click-position does not affect the pivot: `take*` anchors at
                // the element CENTROID (vertex pos / edge midpoint / face
                // centroid). Storing the ray-hit point instead is a separate,
                // unmeasured divergence and deliberately not done here.
                //
                // No pick yet → `userPlaced` (an IN-ARM check — Element is
                // excluded from `honoursPlacedCenter`, and this tier is what
                // the headless `userPlacedCenter` attr drives), then the
                // selection-element centroid (whole mesh per the universal
                // "empty selection = all" rule).
                //
                // We have no centre handle of our own (no part id that grabs
                // the action centre), so the click-pick is the ONLY writer of
                // `elementPin`. If such a handle is ever added it must become
                // the only OTHER writer, and the only one that may write
                // mid-gesture.
                if (elementPin.placed) return elementPin.center;
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
                    case EditMode.Polygons: return mesh_.selectionBorderBBoxCenterFaces(itemSpace());
                }
            case Mode.Pivot:
                // center = primary item's pivot world position. See
                // itemPivotWorld() above — shared with the item-mode redirect.
                return itemPivotWorld();
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
        // Membership is invariant while (address, connectivity epoch, editMode,
        // selSig) all hold; only centers (read from live mesh_.vertices) change
        // per frame.
        const int   edMode  = cast(int)(*editMode_);
        const ulong selSig  = selectionSignature();
        // Sampled once; the same sample is what a miss stamps. See the field's
        // comment for why this watcher's mask excludes `Position`.
        const size_t meshAddr  = cast(size_t)mesh_;
        const ulong  meshEpoch = g_topoEpochs.epochFor(meshAddr);
        const bool  hit = _cacheValid
                       && _clusterKey.matches(meshAddr, meshEpoch)
                       && _cachedEditMode == edMode
                       && _cachedSelSig   == selSig
                       && _cachedClusterOf.length == mesh_.vertices.length;

        if (!hit) {
            // Test seam (task 1906 stage 2d). ALWAYS ON, not `debug`: the two
            // gates build with different flags, so a `debug`-only counter is
            // untestable from the suite lane. It counts the MEMBERSHIP walk —
            // the O(V+E) half — not the per-call centre recompute below, which
            // is meant to run every frame.
            ++g_acenClusterRebuilds;
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
            _clusterKey.stamp(meshAddr, meshEpoch);
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
        // CLUSTER 0's BOUNDING-BOX MIDPOINT — not the average (task 0649, D8
        // of the 0648 measurement).
        //
        // This arm used to average: face mode averaged face centroids, vert /
        // edge mode averaged the cluster's verts. On the 0648 stand — an
        // irregular quad, chosen so the two answers differ — the reference's
        // `local` centre reads (1.95, 1.1, -1.3), the bbox mid, and ours read
        // (1.925, 1.1, -1.3), the vertex mean. Measured at the IDENTITY item
        // transform, so this divergence has nothing to do with the space
        // change above; it rides along because it is the same line.
        //
        // It also makes this arm agree with `clusterBBoxCenter`, which the
        // MULTI-cluster path right beside it has always used for the very same
        // clusters (`computeLocalClustersFull`'s doc says "bounding-box
        // midpoints (consistent with Phase 2's bbox-Select choice)") — so the
        // single-cluster centre and cluster 0's published centre used to be
        // two different points on the same partition.
        // `clusterCenters` was filled by the call above and is exactly
        // `clusterBBoxCenter(clusterOf, i)` per cluster; reading [0] rather
        // than recomputing it is what makes "the same point" a fact rather
        // than a claim two call sites have to keep true.
        return clusterCenters.length > 0 ? clusterCenters[0]
                                         : centroidWithGeometryFallback();
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
        const auto ms = itemSpace();   // world, see itemSpace()
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool seen = false;
        foreach (vi, c; clusterOf) {
            if (c != cid) continue;
            Vec3 v = ms.isIdentity ? acenVertex(vi)
                                   : ms.toWorldPoint(acenVertex(vi));
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
        // World, like every other centre this stage publishes — see
        // itemSpace(). Element's LAW is out of 0649's scope; its SPACE is not.
        const auto ms = itemSpace();
        Vec3 vAt(size_t vi) const {
            return ms.isIdentity ? acenVertex(vi)
                                 : ms.toWorldPoint(acenVertex(vi));
        }
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        final switch (*editMode_) {
            case EditMode.Vertices: {
                bool any = mesh_.hasAnySelectedVertices();
                foreach (i; 0 .. mesh_.vertices.length) {
                    if (!any || mesh_.isVertexSelected(i)) {
                        sum += vAt(i);
                        count++;
                    }
                }
                break;
            }
            case EditMode.Edges: {
                bool any = mesh_.hasAnySelectedEdges();
                foreach (i, edge; mesh_.edges) {
                    if (any && !mesh_.isEdgeSelected(i)) continue;
                    Vec3 mid = (vAt(edge[0]) + vAt(edge[1])) * 0.5f;
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
                    foreach (vi; face) c += vAt(vi);
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
        // Task 1069 — the DEFAULT (Auto / Screen / Select) pivot does NOT come
        // from this stage's six direct `mesh_.vertices[vi]` reads: it comes
        // from `Mesh.selectionBBoxCenter*`, inside mesh.d. So routing those six
        // does not route the pivot a user actually sees, which is worth saying
        // plainly because it is easy to believe otherwise.
        //
        // The bbox is recomputed HERE over the drawn positions rather than by
        // routing the mesh method, because `mesh.d` is a core module that must
        // not import the app-level morph target (`morph_target` already
        // imports `mesh`). Semantics reproduced exactly, including the
        // "no selection ⇒ all geometry" fallback and the item-space transform
        // going IN rather than onto the result.
        //
        // TASK 2006 — all three edit modes now share ONE pass, over the cached
        // MEMBERSHIP list (`bboxMembershipCached`). Before this, Edges and
        // Polygons routed to `Mesh.selectionBBoxCenter{Edges,Faces}`, whose
        // walk re-derived the contributing vertex set from scratch on EVERY
        // call: a per-call `new bool[](V)` plus, in Polygons mode, one slice
        // dereference per face into the `uint[][]` face store. Measured on a
        // 1M-face grid with nothing selected (= whole mesh, the universal
        // rule; ldc2 1.42 -O3 -release, `makeGridPlane(1000)`, marks arrays
        // sized): 9.31 ms per evaluation in Polygons mode and 4.03 ms in
        // Edges against 1.35 ms in Vertices, and the stage is evaluated ~2
        // times per rendered frame plus ~2 per motion event. The MEMBERSHIP is
        // the part that does not change between those evaluations; the
        // positions are, so the min/max below still reads them live. After:
        // 1.02 ms in every mode, i.e. the answer no longer depends on which
        // element type is current — 9.1x on Polygons, 3.9x on Edges, 1.3x on
        // Vertices. The full table, and the two design decisions that got it
        // there, are on `bboxMembershipCached`.
        //
        // WHICH ARRAY EACH MODE READS IS PRESERVED EXACTLY, and it is NOT
        // uniform: the morph-preview displacement (`acenVertex`) applies in
        // Vertices mode only. Edges and Polygons read `mesh_.vertices[vi]`
        // even under a live morph preview — that asymmetry is shipped
        // behaviour (it was the difference between this function's own
        // morph arm and the three `Mesh.selectionBBoxCenter*` methods), and
        // reproducing it is the point of the `morph` flag below rather than
        // routing everything through `acenVertex`.
        auto ms = itemSpace();
        const bool morph = morphPreviewActive(mesh_)
                        && *editMode_ == EditMode.Vertices;
        // Logically const: the caller-visible RESULT never depends on cache
        // state, but the cached path fills cross-call membership fields. The
        // cast mirrors an ordinary memoization, exactly as `computeCenter`'s
        // Local arm does for `localCenterAndClustersCached` (see its comment
        // for why the off-main-thread const reader cannot race this fill).
        const(uint)[] verts =
            (cast(ActionCenterStage)this).bboxMembershipCached();
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        // `seen` was set inside the loop before task 2006 and meant exactly
        // "at least one vertex was visited". Over a membership list that is
        // `verts.length > 0`, with no daylight between the two: every entry
        // in the list is visited unconditionally.
        const bool seen = verts.length > 0;

        // TWO LOOPS, AND THE SPLIT IS WORTH 3.2x. In the general body below,
        // `acenVertex` and `ms.toWorldPoint` are opaque to the optimiser, so
        // it may not hoist `mesh_.vertices` (a field reached through a class
        // reference) out of the loop and cannot vectorise the min/max — every
        // iteration reloads the slice's pointer and length. The plain arm
        // hoists the slice into a local and drops both branches, which is what
        // lets LDC turn this into a memory-bound SIMD reduction. Measured on
        // the 1M-face grid (ldc2 1.42 -O3 -release), same rig as the key
        // measurement above: 3.52 ms per evaluation with one branchy loop,
        // 1.10 ms with the split — against a 1.07 ms floor for streaming
        // 12 MB of positions plus 4 MB of indices at this host's bandwidth.
        // The plain arm is not a special case of the geometry: it is the
        // ORDINARY state (no morph preview, layer at the identity), so it is
        // the arm every drag frame takes.
        if (!morph && ms.isIdentity) {
            const(Vec3)[] vp = mesh_.vertices;
            foreach (vi; verts) {
                const Vec3 v = vp[vi];
                if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
                if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
                if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
            }
        } else {
            foreach (vi; verts) {
                Vec3 v = morph ? acenVertex(vi) : mesh_.vertices[vi];
                if (!ms.isIdentity) v = ms.toWorldPoint(v);
                if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
                if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
                if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
            }
        }
        return seen ? (mn + mx) * 0.5f : Vec3(0, 0, 0);
    }

    /// The vertices that CONTRIBUTE to a selection-derived bounding box in the
    /// active edit mode, as a flat index list (task 2006).
    ///
    /// Reproduces, element for element, the contributing set of
    /// `Mesh.selectionBBoxCenterVertices` / `...Edges` / `...Faces`: the
    /// universal "no selection ⇒ all geometry" fallback, and the
    /// de-duplication that makes an edge's or a face's shared vertex count
    /// once. Order is not part of the contract — min/max over a multiset
    /// equals min/max over its set, in any order, exactly — so a caller may
    /// not depend on it.
    ///
    /// Cache key: (address, CONNECTIVITY epoch, editMode, `marksVersion`,
    /// vertex count). The watcher is `mesh_dirty.g_topoEpochs`, whose mask
    /// DELIBERATELY excludes `Position` — see the `_bboxVerts` field comment
    /// for why a position term here would be a behaviour regression and not
    /// merely a slower cache.
    ///
    /// THE SELECTION TERM IS A COUNTER, NOT `selectionSignature()`, AND THAT
    /// IS THE WHOLE PERFORMANCE RESULT OF TASK 2006. The sibling cluster cache
    /// above keys on the FNV hash, which is an O(V) walk over the marks array
    /// — measured on a 1M-face grid, ldc2 1.42 -O3 -release: 2.23 ms in
    /// Vertices / Polygons mode and 4.46 ms in Edges mode (edgeMarks is 2M
    /// entries), against a 1.02 ms bbox pass over the whole membership. Keyed
    /// on the hash this cache COSTS MORE THAN IT SAVES in two of the three
    /// modes. Measured end to end on the stage itself, same rig, ms per
    /// evaluation:
    ///
    ///                     before   hash-keyed   counter-keyed
    ///     Vertices         1.35       3.52          1.02
    ///     Edges            4.03       3.52          1.02
    ///     Polygons         9.31       3.52          1.02
    ///     Polygons/half    3.86       1.76          0.51
    ///
    /// — i.e. the first draft of this cache was a 2.6x REGRESSION on the
    /// commonest mode while being a 2.6x win on Polygons. (The middle column
    /// also carries the branchy single loop; the split into a plain and a
    /// general arm, argued at the loop itself, is what takes 3.52 to 1.02.)
    ///
    /// `Mesh.marksVersion` is the O(1) key that hash exists to be memoised
    /// behind — its own doc states the contract ("bumped whenever anything
    /// `selectionSignature` reads can have changed", never on Position) and
    /// `transform.d`'s `computeSelectionHash` already keys on it for exactly
    /// this reason (there, `selectionSignature` was 21.25 % of a falloff
    /// drag's whole profile). The consequence, stated because it is a real
    /// narrowing: a write straight into `vertexMarks` / `edgeMarks` /
    /// `faceMarks` that does NOT go through `noteSelectionChange` or a
    /// `MeshEditBatch` close no longer invalidates this list. That is the
    /// same contract the transform memo has shipped under, and it is the one
    /// `changeBus.missedPublishers` already gates.
    const(uint)[] bboxMembershipCached() {
        if (mesh_ is null) return null;

        const int    edMode    = cast(int)(*editMode_);
        const size_t meshAddr  = cast(size_t)mesh_;
        const ulong  meshEpoch = g_topoEpochs.epochFor(meshAddr);
        const size_t nV        = mesh_.vertices.length;

        // recorded remainder (1906 §3.6): `marksVersion` owns this memo's
        // SELECTION term, the same way it owns `computeSelectionHash`'s in
        // transform.d, and for the same reason — no watcher carries `Marks`
        // (the geometry and connectivity masks exclude it on purpose, and
        // `DisplayEpochMask` does not list it either), so a `Marks` epoch
        // would be a strictly coarser restatement of a counter that already
        // tracks exactly this class on the mesh itself. Here it replaces an
        // O(V) `selectionSignature()` call that cost more than the walk it
        // was guarding; see the doc comment above for the numbers.
        // (Census shape C: counter into a local, compared four lines down.)
        const ulong  marksVer  = mesh_.marksVersion;
        const bool hit = _bboxCacheValid
                      && _bboxKey.matches(meshAddr, meshEpoch)
                      && _bboxEditMode  == edMode
                      && _bboxMarksVer  == marksVer
                      && _bboxVertCount == nV;
        if (hit) return _bboxVerts[0 .. _bboxCount];

        // Test seam. ALWAYS ON, not `debug` — the two gates build with
        // different flags, so a `debug`-only counter is untestable from the
        // suite lane. It counts the MEMBERSHIP walk, never the per-call bbox
        // recompute above, which is meant to run on every evaluation.
        ++g_acenBboxMembershipRebuilds;

        // Filled into a buffer that is GROWN and never SHRUNK, with a running
        // count, rather than `length = 0` + `~=`: the append path is a runtime
        // call per element that `reserve` does not remove, and a shrink-then-
        // append pattern on a page-backed block is a measured allocation
        // hazard in this codebase. `nV` is the exact worst case for all three
        // arms (a vertex appears at most once), so one growth per mesh size is
        // the whole allocation budget of this cache.
        if (_bboxVerts.length < nV) _bboxVerts.length = nV;
        size_t k = 0;
        final switch (*editMode_) {
            case EditMode.Vertices: {
                const bool any = mesh_.hasAnySelectedVertices();
                foreach (i; 0 .. nV) {
                    if (any && !mesh_.isVertexSelected(i)) continue;
                    _bboxVerts[k++] = cast(uint)i;
                }
                break;
            }
            case EditMode.Edges: {
                const bool any = mesh_.hasAnySelectedEdges();
                if (_bboxSeen.length < nV) _bboxSeen.length = nV;
                _bboxSeen[0 .. nV] = false;
                foreach (i, edge; mesh_.edges) {
                    if (any && !mesh_.isEdgeSelected(i)) continue;
                    foreach (vi; edge) {
                        if (vi >= nV || _bboxSeen[vi]) continue;
                        _bboxSeen[vi] = true;
                        _bboxVerts[k++] = vi;
                    }
                }
                break;
            }
            case EditMode.Polygons: {
                const bool any = mesh_.hasAnySelectedFaces();
                if (_bboxSeen.length < nV) _bboxSeen.length = nV;
                _bboxSeen[0 .. nV] = false;
                foreach (i, face; mesh_.faces) {
                    if (any && !mesh_.isFaceSelected(i)) continue;
                    foreach (vi; face) {
                        if (vi >= nV || _bboxSeen[vi]) continue;
                        _bboxSeen[vi] = true;
                        _bboxVerts[k++] = vi;
                    }
                }
                break;
            }
        }

        _bboxCount      = k;
        _bboxKey.stamp(meshAddr, meshEpoch);
        _bboxEditMode   = edMode;
        _bboxMarksVer   = marksVer;
        _bboxVertCount  = nV;
        _bboxCacheValid = true;
        return _bboxVerts[0 .. _bboxCount];
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

        const auto ms = itemSpace();   // world, see itemSpace()
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        bool[] visited = new bool[](mesh_.vertices.length);

        void touch(uint vi) {
            if (vi >= visited.length || visited[vi]) return;
            visited[vi] = true;
            if (sp.vertSign[vi] != sp.baseSide) return;
            sum   = sum + (ms.isIdentity ? acenVertex(vi)
                                         : ms.toWorldPoint(acenVertex(vi)));
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
        // Every point through the item space BEFORE the min/max — see
        // itemSpace(). The sub-modes name sides of the box (top / left / ...)
        // in WORLD axes, so taking the box in the layer's own coordinates
        // named the wrong side the moment the layer was rotated.
        const auto ms = itemSpace();
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool any = false;
        void touch(Vec3 v0) {
            Vec3 v = ms.isIdentity ? v0 : ms.toWorldPoint(v0);
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
                        if (!visited[vi]) { touch(acenVertex(vi)); visited[vi] = true; }
                }
                break;
            case EditMode.Polygons:
                foreach (i, face; mesh_.faces) {
                    if (hasSelF && !mesh_.isFaceSelected(i)) continue;
                    foreach (vi; face)
                        if (!visited[vi]) { touch(acenVertex(vi)); visited[vi] = true; }
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
                // Task 1530 — `elementPin` deliberately SURVIVES a mode switch
                // (including element -> something -> element). The frozen point
                // is owned by the picking click, and nothing about a mode
                // change says the user un-picked.
                softPin        = Pin.init;
                return true;
            }
            case "cenX": case "cenY": case "cenZ": {
                // Task 3020 — the shared wire gate; a non-finite pivot
                // component makes every later frame NaN, so it is refused
                // rather than written.
                import params : assignWireFloat;
                float v;
                if (!assignWireFloat(value, v)) return false;
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
                // Task 3020 — the shared wire gate, atomic across the three
                // components (nothing is staged unless all three are finite).
                import params : assignWireVec3;
                Vec3 hit;
                if (!assignWireVec3(value, hit)) return false;
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
                import params : assignWireFloat;
                float v;
                if (!assignWireFloat(value, v)) return false;
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
// must NOT alias two distinct Mesh instances that happen to share a freshness
// stamp. mesh_ is a live delegate that can be repointed at a different primary
// mid-session (a real item-selection change), so the danger is real: without
// the address term, `a` and `b` below have an EQUAL (stamp, editMode, selSig)
// key and the cache would wrongly serve `a`'s stale partition back for `b`.
//
// `a` is a 4-cycle 0-1-2-3-0 with ALL 4 verts selected: fully connected —
// exactly 1 cluster. `b` is two disjoint edges 0-1 / 2-3 with the SAME
// selection (all 4 verts): two separate components — exactly 2 clusters.
//
// TASK 1906 STAGE 2d — the stamp is now `mesh_dirty.g_topoEpochs`, so the
// collision is STRUCTURAL rather than hand-forced: neither mesh is owned by a
// `Document`, so neither is in the epoch table and both read its `evicted_`
// floor. Asserted below rather than assumed — if the two ever read different
// epochs, the epoch term refuses first and the address term goes untested.
// Heap-allocated for the reason stage 2c hit in `snap.d`: the table is keyed by
// RAW ADDRESS and a stack local can reuse one a neighbouring block noted.
// ---------------------------------------------------------------------------
unittest {
    import mesh       : Mesh;
    import mesh_dirty : g_topoEpochs;

    Mesh* a = new Mesh;
    a.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    a.resetSelection();
    a.addEdge(0, 1); a.addEdge(1, 2); a.addEdge(2, 3); a.addEdge(3, 0);
    a.selectVertex(0); a.selectVertex(1); a.selectVertex(2); a.selectVertex(3);

    Mesh* b = new Mesh;
    b.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    b.resetSelection();
    b.addEdge(0, 1); b.addEdge(2, 3);
    b.selectVertex(0); b.selectVertex(1); b.selectVertex(2); b.selectVertex(3);

    assert(g_topoEpochs.epochFor(cast(size_t)a)
        == g_topoEpochs.epochFor(cast(size_t)b),
        "setup: the two meshes MUST collide on the connectivity epoch — that "
      ~ "collision IS the hazard, and without it the address term is untested");

    EditMode em = EditMode.Vertices;
    Mesh* meshPtr = a;
    auto acs = new ActionCenterStage(() => meshPtr, &em);

    Vec3[] centersA; int[] clusterOfA;
    acs.computeLocalClustersFull(centersA, clusterOfA);
    assert(acs._cachedClusterCnt == 1,
        "a: a 4-cycle with all verts selected must form exactly 1 cluster");

    // Repoint mesh_ at b — SAME epoch and editMode, and the SAME selection
    // signature (all 4 verts selected in both) as a. Only the connectivity
    // differs.
    meshPtr = b;
    Vec3[] centersB; int[] clusterOfB;
    acs.computeLocalClustersFull(centersB, clusterOfB);
    assert(acs._cachedClusterCnt == 2,
        "b: two disjoint edges must form exactly 2 clusters. If this reads 1 "
        ~ "(a's value), the address term was dropped from the cache key and "
        ~ "b wrongly reused a's cached partition.");
}

// ---------------------------------------------------------------------------
// TASK 1906 STAGE 2d — THE NARROWING, PINNED IN THE DIRECTION THAT COSTS.
//
// `_clusterKey`'s watcher (`g_topoEpochs`) omits `Position` on purpose. Get
// that wrong — reuse `g_geomEpochs`, or widen the mask — and NO value in this
// file changes: the partition is still correct, it is merely rebuilt O(V+E)
// times per gesture instead of once. A count is the only channel that sees it,
// which is what `g_acenClusterRebuilds` is for.
//
// Two halves, and the second is the one that stops the first being vacuous:
//   (A) a run of Position publishes must add exactly ONE rebuild (the first
//       call's cold miss) — this is the property the narrow mask buys;
//   (B) a Polygons publish must add one MORE — without it, half (A) would be
//       satisfied by a watcher that is never fed at all, or by a cache that
//       has stopped keying on the mesh entirely.
//
// THE FIXTURE IS TWO DISJOINT EDGES (0-1 and 2-3), NOT A CHAIN, and that is a
// correction rather than a detail. Half (B) closes with a VALUE assert on the
// rebuilt partition, and over a chain 0-1,1-2,2-3 with all four vertices
// selected the four are ALREADY one component before the closing edge is
// added — so "exactly 1 cluster" held on the stale partition too and the
// assert could not come out any other way. Two components take 2 -> 1 when
// `addEdge(3, 0)` joins them, which is a number the pre-publish cache does not
// have.
// ---------------------------------------------------------------------------
unittest {
    import mesh            : Mesh;
    import mesh_dirty      : noteMeshChange;
    import mesh_edit_delta : MeshEditScope;

    Mesh* m = new Mesh;   // heap — see the M9 block above
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    m.resetSelection();
    m.addEdge(0, 1); m.addEdge(2, 3);   // TWO components — see the header
    m.selectVertex(0); m.selectVertex(1); m.selectVertex(2); m.selectVertex(3);

    EditMode em = EditMode.Vertices;
    Mesh* meshPtr = m;
    auto acs = new ActionCenterStage(() => meshPtr, &em);

    const ulong base = g_acenClusterRebuilds;
    Vec3[] centers; int[] clusterOf;
    acs.computeLocalClustersFull(centers, clusterOf);
    assert(g_acenClusterRebuilds == base + 1,
        "setup: the first call must be a cold miss, or this block counts "
      ~ "nothing");
    assert(acs._cachedClusterCnt == 2,
        "setup: two disjoint edges must partition into 2 clusters. This is the "
      ~ "number the closing assert below has to CHANGE — over a chain the four "
      ~ "vertices are already one component and that assert would hold on the "
      ~ "stale partition too");

    // Eight drag steps: move a vertex and publish `Position`, exactly as an
    // interactive gizmo gesture does (it publishes and bumps no version).
    foreach (step; 0 .. 8) {
        m.vertices[0] = m.vertices[0] + Vec3(0.01f, 0, 0);
        noteMeshChange(cast(size_t)m, MeshEditScope.Position);
        acs.computeLocalClustersFull(centers, clusterOf);
    }
    assert(g_acenClusterRebuilds == base + 1,
        "task 1906 §3.4 row 15: eight Position publishes must add ZERO cluster "
      ~ "rebuilds. Cluster MEMBERSHIP does not depend on where the vertices "
      ~ "are; the centres are recomputed from live positions every call "
      ~ "regardless. A count of base+9 means the watcher's mask picked up "
      ~ "`Position` — correct output, O(V+E) per drag step");

    // ...and the cache is not simply deaf: a connectivity publish MUST rebuild.
    m.addEdge(3, 0);
    noteMeshChange(cast(size_t)m, MeshEditScope.Polygons);
    acs.computeLocalClustersFull(centers, clusterOf);
    assert(g_acenClusterRebuilds == base + 2,
        "anti-vacuity: a Polygons publish MUST rebuild the partition. If this "
      ~ "does not move, the assert above is satisfied by a watcher nobody "
      ~ "feeds and proves nothing");
    assert(acs._cachedClusterCnt == 1,
        "and the rebuilt partition must be the NEW one: the edge just added "
      ~ "joins the two disjoint components, so the count must fall 2 -> 1. A "
      ~ "cache that served the pre-publish partition reads 2 here");
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
// collapses that into ONE pre-switch check gated by `honoursPlacedCenter(mode)` /
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

    // --- Auto / Screen / None: honoursPlacedCenter T, settlePinHonored T ----
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

    // --- Select / SelectAuto: honoursPlacedCenter F, settlePinHonored T -----
    // userPlaced must stay IGNORED (discriminator); softPlaced honored.
    foreach (m; [Mode.Select, Mode.SelectAuto]) {
        acs.mode = m;
        setPins(false, false); assert(vecEq(acs.currentCenter(), zero),
            m.to!string ~ ": no-pin fallback");
        setPins(true, false);  assert(vecEq(acs.currentCenter(), zero),
            m.to!string ~ " + userPlaced set: must stay on the selection center "
            ~ "(userPlaced ignored) — discriminator for the hoist's narrow "
            ~ "honoursPlacedCenter set");
        setPins(false, true);  assert(vecEq(acs.currentCenter(), softPt),
            m.to!string ~ ": softPlaced must be honored");
        setPins(true, true);   assert(vecEq(acs.currentCenter(), softPt),
            m.to!string ~ ": with userPlaced ignored, softPlaced still wins "
            ~ "over the fallback when both are set");
    }

    // --- Border: honoursPlacedCenter F, settlePinHonored T ------------------
    acs.mode = Mode.Border;
    setPins(false, false); assert(vecEq(acs.currentCenter(), zero),
        "Border: no-pin fallback");
    setPins(true, false);  assert(vecEq(acs.currentCenter(), zero),
        "Border + userPlaced set: must stay on the border center (ignored) — "
        ~ "discriminator for the hoist's narrow honoursPlacedCenter set");
    setPins(false, true);  assert(vecEq(acs.currentCenter(), softPt),
        "Border: softPlaced must be honored");

    // --- Origin / Manual: honoursPlacedCenter F, settlePinHonored F ---------
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

    // --- Element: NOT gated by the hoist at all (honoursPlacedCenter F,      -
    // settlePinHonored F since acenSettleAllowed() excludes Element). Keeps   -
    // its own in-arm ladder — which since task 1530 is                        -
    // `elementPin → userPlaced → elementCenter`.                              -
    //                                                                         -
    // THIS BLOCK IS THE RECORD OF THAT LAW. The tier that used to sit on top  -
    // was `liveElementCenter` — the LIVE centroid of the picked vertex ring,  -
    // recomputed from `mesh_.vertices` on every read. It is gone: the top     -
    // tier is now a frozen POINT and the arm reads no geometry at all. The    -
    // three assertions below that a re-introduced ring read would break are   -
    // marked (ring-detector).                                                 -
    acs.mode = Mode.Element;
    acs.elementPin = Pin.init;
    setPins(false, false); assert(vecEq(acs.currentCenter(), zero),
        "Element: no pick, no pin → elementCenter() fallback (empty sel ⇒ "
        ~ "whole-mesh average = 0)");
    setPins(true, false);  assert(vecEq(acs.currentCenter(), userPt),
        "Element: no element pin → in-arm userPlaced still honored (this is "
        ~ "the tier the headless `userPlacedCenter` attr drives)");
    setPins(false, true);  assert(vecEq(acs.currentCenter(), zero),
        "Element: softPlaced is NEVER consulted (no in-arm check, and the "
        ~ "hoisted check is gated off since acenSettleAllowed() excludes "
        ~ "Element) — must fall back to elementCenter()");

    // The frozen pick outranks BOTH other tiers.
    immutable Vec3 pickPt = Vec3(0.5f, 0.5f, 0.5f);   // cube corner v6
    setPins(true, true);
    acs.setElementPin(pickPt);
    assert(vecEq(acs.currentCenter(), pickPt),
        "Element: the frozen element pin outranks userPlaced AND softPlaced");

    // (ring-detector) It is a POINT, not a ring. Move EVERY vertex of the mesh
    // and the centre must not budge by one bit — the live ring centroid would
    // have followed the whole displacement, which is exactly the feedback loop
    // task 1530 removed. A scale cell cannot see this (its own centre is a
    // fixed point of the scale); a translate can, which is why this shoves the
    // whole cube.
    foreach (ref v; cube.vertices) v = v + Vec3(10, 0, 0);
    assert(acs.currentCenter().x == pickPt.x
        && acs.currentCenter().y == pickPt.y
        && acs.currentCenter().z == pickPt.z,
        "Element: the pivot must be BYTE-identical after the whole mesh moved "
        ~ "by (10,0,0) — a geometry read in this arm is the defect");
    foreach (ref v; cube.vertices) v = v - Vec3(10, 0, 0);

    // (ring-detector) It survives a mode round-trip: the picking click owns it,
    // and a mode change is not an un-pick.
    acs.setAttr("mode", "auto");
    acs.setAttr("mode", "element");
    assert(vecEq(acs.currentCenter(), pickPt),
        "Element: a mode round-trip must not lose the frozen pick");

    // (ring-detector) It survives `resetTransient()` (tool.set / tool switch),
    // and does NOT survive `reset()` (= SceneReset = /api/reset). That
    // asymmetry is the whole reason it is its OWN field: a `userPin` carried
    // across the transient reset would hijack the next tool's gizmo in
    // Auto/None/Screen/Pivot/Parent, all of which read `userPin`.
    acs.resetTransient();
    acs.mode = Mode.Element;
    assert(vecEq(acs.currentCenter(), pickPt),
        "Element: the frozen pick must survive resetTransient()");
    acs.reset();
    acs.mode = Mode.Element;
    setPins(false, false);
    assert(vecEq(acs.currentCenter(), zero),
        "Element: reset() MUST wipe the frozen pick — an explicit full reset "
        ~ "erases every pin");
    acs.elementPin = Pin.init;
    acs.manualCenter = Vec3(7, 8, 9);   // reset() cleared it; later arms read it

    // --- Local: NOT gated by the hoist at all (honoursPlacedCenter F,       -
    // settlePinHonored F since acenSettleAllowed() excludes Local). D5       -
    // deferred — arm unchanged, both pins stay irrelevant.                  -
    acs.mode = Mode.Local;
    setPins(true, true);
    assert(vecEq(acs.currentCenter(), zero),
        "Local: both pins set but empty selection ⇒ 0 clusters ⇒ centroid "
        ~ "fallback (0) — pins never consulted");

    // --- Pivot / Parent: task 0187's DELIBERATE change -----------------------
    // honoursPlacedCenter NOW TRUE (was false pre-0187) → userPlaced honored.
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





// task 0678 A4 — status-line coverage: the "Action Center" popup in
// config/statusline.yaml is a hand-maintained mirror of the panel mode table
// (`modeEntries`).  The two drifted once already: actr.pivot / actr.parent
// were registered (task 0082) but never added to the YAML, leaving both modes
// unreachable from the UI — the startup id-validator only checks that listed
// ids RESOLVE, never that the listing is COMPLETE.  Pin SET EQUALITY between
// the popup's direct `actr.<tag>` items and modeEntries' wire tags, so adding
// or removing a mode must touch both.  (The "Center"/"Axis" submenus are
// deliberately curated SUBSETS mirroring the reference's, and are not pinned.)
unittest {
    import std.file : exists;
    import buttonset : loadStatusLine, ActionKind, PopupItemKind;

    enum yamlPath = "config/statusline.yaml";
    // A hard fail beats a silent skip for a gate test — but say what to DO
    // about it (task 0685 T8). The gate (`dub test --config=tests`) already
    // runs from the package root; a bare "config/ missing" only ever confused
    // someone running the unittest binary from elsewhere.
    assert(exists(yamlPath),
           "cannot read " ~ yamlPath ~ " — run this test from the package "
           ~ "root (the directory holding dub.json), e.g. "
           ~ "`dub test --config=tests`");

    // Task 0705 (audit 4, A4-full): the row carries the mode THREE times —
    // the command id `actr.<tag>`, the state query `checked.equals: <tag>`,
    // and the human `label:`. 0679 pinned the first against `modeEntries` and
    // left the other two free to drift. A wrong `checked.equals` silently
    // stops ticking (or ticks the wrong row); a label edited in one of the two
    // places is a UI that names the same mode two ways. All three are pinned
    // now, so the YAML is a *rendering* of the table rather than a second copy
    // of it — which is as close to structural as a static YAML file gets. The
    // renderer-side fix (a `dynamicKind` provider that emits these rows from
    // `modeEntries` and deletes them from the YAML) is filed as 0713.
    struct Row { string label; string checkedEquals; }
    Row[string] got;
    bool sawPopup = false;
    foreach (g; loadStatusLine(yamlPath)) {
        foreach (ref b; g.buttons) {
            if (b.action.kind != ActionKind.popup || b.label != "Action Center")
                continue;
            sawPopup = true;
            foreach (ref pi; b.action.popupItems) {
                if (pi.kind != PopupItemKind.action) continue;  // divider/submenu
                const string id = pi.action.id;
                enum pfx = "actr.";
                if (id.length > pfx.length && id[0 .. pfx.length] == pfx)
                    got[id[pfx.length .. $]] = Row(pi.label, pi.checked.equals_);
            }
        }
    }
    assert(sawPopup, "statusline must carry an 'Action Center' popup");

    foreach (e; ActionCenterStage.modeEntries) {
        auto row = e.wireTag in got;
        assert(row !is null,
               "panel mode '" ~ e.wireTag ~ "' has no actr." ~ e.wireTag
               ~ " item in the statusline Action Center popup");
        assert(row.label == e.userLabel,
               "statusline actr." ~ e.wireTag ~ " is labelled '" ~ row.label
               ~ "' but the panel calls the same mode '" ~ e.userLabel
               ~ "' — one UI, two names for one mode");
        assert(row.checkedEquals == e.wireTag,
               "statusline actr." ~ e.wireTag ~ " ticks on state '"
               ~ row.checkedEquals ~ "' — it would never tick, or would tick "
               ~ "for a different mode");
    }
    foreach (tag, _; got) {
        int v;
        assert(valueForWireTag(ActionCenterStage.modeEntries, tag, v),
               "statusline actr." ~ tag ~ " has no matching panel mode entry");
    }
}
