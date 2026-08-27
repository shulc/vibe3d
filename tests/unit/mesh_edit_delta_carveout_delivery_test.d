// ===========================================================================
// Task 1903 L0.P1 — witness W12: the CLASSES a fast-path revert delivers.
//
// THIS IS THE CONDITION ON THE STEP SHIPPING ALONE. The pixel-tier witness for
// the fast path (W4b in the plan) cannot be written yet — at landing no
// production delta log is index-space stable, so the suite lane has no way to
// drive the fast branch through the app. The plan defers that tier to L0-d and
// requires the CLASS tier to be pinned here instead, because a step that
// deferred both would ship with zero coverage of delivery on the only path it
// changes.
//
// WHY A CLASS AND NOT A COUNTER. The carve-out drops one publish — the
// `commitChange(MeshEditScope.Polygons)` that `rebuildEdges` was making
// incidentally — and re-issues it per kind through `displayTermFor`. Under a
// bug that drops it for `SubpatchDelta`, every version counter, every geometry
// plane and every draw-call census is BYTE-IDENTICAL; the only difference is
// that `Marks` alone is outside `display_sync.DisplayRefreshMask`, so the cage
// never refreshes. The same failure is already measured at `mesh.d`'s
// `setFaceHiddenFrom`, where a Marks-only hide left `/api/gpu/face-vbo`'s
// faceVertCount at 36.
//
// The set is asserted BOTH WAYS — every named class present, no unnamed class
// present — by comparing the whole flag word.
// ===========================================================================
module tests.unit.mesh_edit_delta_carveout_delivery_test;

import std.format : format;

import mesh;
import math : Vec3;
import mesh_edit_delta;
import change_bus : changeBus, SelDomain;

private string flagNames(uint f) {
    string s;
    void bit(uint b, string n) { if (f & b) s ~= (s.length ? "|" : "") ~ n; }
    bit(MeshEditScope.Position,   "Position");
    bit(MeshEditScope.Points,     "Points");
    bit(MeshEditScope.Polygons,   "Polygons");
    bit(MeshEditScope.Marks,      "Marks");
    bit(MeshEditScope.Material,   "Material");
    bit(MeshEditScope.Visibility, "Visibility");
    bit(MeshEditScope.Maps,       "Maps");
    bit(MeshEditScope.MapsDisplay, "MapsDisplay");
    return s.length ? s : "{}";
}

private string domNames(uint d) {
    string s;
    void bit(uint b, string n) { if (d & b) s ~= (s.length ? "|" : "") ~ n; }
    bit(SelDomain.Vertex, "Vertex");
    bit(SelDomain.Edge,   "Edge");
    bit(SelDomain.Face,   "Face");
    bit(SelDomain.Item,   "Item");
    return s.length ? s : "{}";
}

private struct Heard { int calls; uint flags; uint domains; size_t subject; }

/// Run `body` with a listener on BOTH mesh channels and hand back what it
/// heard. Restores the subscriber arrays afterwards — the bus has no
/// unsubscribe in v1, which is the same reason
/// `tests/unit/delivery_after_hide_derive_test.d` saves and restores them.
private Heard listen(scope void delegate() body_) {
    Heard h;
    auto savedMesh = changeBus.meshSubs;
    auto savedSel  = changeBus.selSubs;
    scope (exit) { changeBus.meshSubs = savedMesh; changeBus.selSubs = savedSel; }
    changeBus.onMeshChanged((size_t addr, uint f) {
        ++h.calls; h.flags |= f; h.subject = addr;
    });
    changeBus.onSelectionChanged((uint d) { h.domains |= d; });
    body_();
    return h;
}

private struct Row {
    string           name;
    MeshEditScope    scope_;
    MeshOpEntry.Kind kind;
    uint             wantFlags;
    uint             wantDomains;
}

unittest // W12 — one delivery per fast-path revert, and the EXACT class set
{
    const Row[] rows = [
        Row("SetPos",         MeshEditScope.Position,   MeshOpEntry.Kind.SetPos,
            MeshEditScope.Position, 0),
        Row("MaterialDelta",  MeshEditScope.Material,   MeshOpEntry.Kind.MaterialDelta,
            MeshEditScope.Material, 0),
        Row("HideDelta",
            cast(MeshEditScope)(MeshEditScope.Marks | MeshEditScope.Visibility),
            MeshOpEntry.Kind.HideDelta,
            MeshEditScope.Marks | MeshEditScope.Visibility, 0),
        Row("SubpatchDelta",  MeshEditScope.Marks,      MeshOpEntry.Kind.SubpatchDelta,
            MeshEditScope.Marks | MeshEditScope.Polygons, 0),
        Row("SelectionDelta", MeshEditScope.Marks,      MeshOpEntry.Kind.SelectionDelta,
            MeshEditScope.Marks, SelDomain.Face),
    ];

    foreach (ref r; rows) {
        Mesh m = makeGridPlane(3);
        m.resetSelection();
        m.buildLoops();

        MeshEditDelta d;
        d.scope_ = r.scope_;
        MeshOpEntry e;
        e.kind = r.kind;
        if (r.kind == MeshOpEntry.Kind.SetPos) {
            e.vIdx      = [0u];
            e.posBefore = [Vec3(3, 4, 5)];
            e.posAfter  = [m.vertices[0]];
        } else {
            // Every mark-shaped kind carries the same sparse triple. Face 1,
            // and a REAL flip — `owesTopologyBump`'s guard refuses a
            // `before == after` entry, which would make the SubpatchDelta row
            // read a different topologyVersion for an unrelated reason.
            e.selDomain  = MeshOpEntry.SelDomain.Face;
            e.markIdx    = [1u];
            e.markBefore = [1u];
            e.markAfter  = [0u];
            if (r.kind == MeshOpEntry.Kind.SubpatchDelta) m.setSubpatch(1, false);
            if (r.kind == MeshOpEntry.Kind.HideDelta)     m.setFaceHidden(1, false);
        }
        d.log = [e];

        const rebBefore = g_rebuildEdgesRuns;
        auto h = listen({ d.revert(m); });
        assert(g_rebuildEdgesRuns == rebBefore, format(
            "%s: the stand did not take the FAST path (rebuildEdges ran %d "
          ~ "time(s)) — every expectation below is then about the old path",
            r.name, g_rebuildEdgesRuns - rebBefore));

        assert(h.calls == 1, format(
            "W12/%s: expected exactly ONE delivery from a fast-path revert, "
          ~ "got %d. Zero means `commitRestored` was skipped: nothing on the "
          ~ "bus re-derives, and CLAUDE.md's law that every mutationVersion "
          ~ "bump on a live mesh goes through the funnel is broken with it. "
          ~ "More than one means a step published on its own.", r.name, h.calls));
        assert(h.subject == cast(size_t)&m, format(
            "W12/%s: the delivery named %x, not the mesh that changed (%x)",
            r.name, h.subject, cast(size_t)&m));
        assert(h.flags == r.wantFlags, format(
            "W12/%s: the delivered CLASS SET is wrong.\n   expected  %s\n"
          ~ "   measured  %s\n"
          ~ "For SubpatchDelta the missing class is `Polygons`, which "
          ~ "`displayTermFor` re-issues in place of the rebuild's own publish: "
          ~ "the surviving scope_ is `Marks` alone, `Marks` is deliberately "
          ~ "outside display_sync.DisplayRefreshMask, and undoing a subpatch "
          ~ "toggle would therefore leave the cage on screen at the old "
          ~ "geometry. Every counter and every geometry plane is identical "
          ~ "under that bug.",
            r.name, flagNames(r.wantFlags), flagNames(h.flags)));
        assert(h.domains == r.wantDomains, format(
            "W12/%s: the delivered selection DOMAIN is wrong.\n   expected  %s"
          ~ "\n   measured  %s\n"
          ~ "`patchSelection` writes Select marks RAW; until L0.P1 it noted no "
          ~ "domain at all and the incidental full `Polygons` re-upload "
          ~ "repainted the highlight by brute force. The carve-out drops that "
          ~ "publish, so the domain note is what a selection consumer has left "
          ~ "to key on.",
            r.name, domNames(r.wantDomains), domNames(h.domains)));
    }
}

unittest // W12b — a no-op SelectionDelta must publish NO domain (compare-before-set)
{
    Mesh m = makeGridPlane(3);
    m.resetSelection();
    m.buildLoops();

    // A representable entry whose values do not move: the recorders guard only
    // `idx.length == 0`. Without compare-before-set in `setSelectBit` this
    // would publish a domain for an edit that did not happen — the same shape
    // that made a paint stroke deliver 280 times for 42 added vertices.
    MeshEditDelta d;
    d.scope_ = MeshEditScope.Marks;
    MeshOpEntry e;
    e.kind       = MeshOpEntry.Kind.SelectionDelta;
    e.selDomain  = MeshOpEntry.SelDomain.Face;
    e.markIdx    = [1u];
    e.markBefore = [0u];
    e.markAfter  = [0u];
    d.log = [e];

    auto h = listen({ d.revert(m); });
    assert(h.domains == 0, format(
        "W12b: a SelectionDelta whose restore flipped no word still published "
      ~ "the selection domain %s. `setSelectBit` must report whether the word "
      ~ "actually changed and `patchSelection` must note the domain only then.",
        domNames(h.domains)));
    assert(h.calls == 1 && h.flags == MeshEditScope.Marks, format(
        "W12b POTENCY: the revert must still deliver its own scope once "
      ~ "(%d call(s), %s). If this reads zero the block above is vacuous — it "
      ~ "would see no domain because it saw no delivery at all.",
        h.calls, flagNames(h.flags)));
}
