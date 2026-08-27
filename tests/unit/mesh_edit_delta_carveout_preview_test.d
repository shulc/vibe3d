// ===========================================================================
// Task 1903 L0.P1 — witness W4c: the INDUCED cost, per kind.
//
// `topologyVersion` is the subpatch preview's INDEX-SPACE IDENTITY key, not a
// freshness signal: `SubpatchPreview.rebuildIfStale` takes its position-only
// path only while `sourceTopologyVersion == source.topologyVersion`, and
// `app.d`'s upload block picks `refreshPositions` over a full `gpu.upload` on
// the same term. Task 2060 measured what one spurious bump costs while a
// preview is live: 41.9-46.1 ms per undo, split between a full VBO rebuild and
// a full OpenSubdiv stencil rebuild.
//
// So the carve-out's step-10 ruling is not bookkeeping — it decides whether an
// undo rebuilds the preview. THREE ROWS, because the bump reaches
// `topologyVersion` by THREE different routes and one mutation cannot reach
// all three:
//
//   * `SetPos`        — no bump, by design. GREEN under both mutations below;
//                       it is the control that says the harness can read zero.
//   * `SubpatchDelta` — bumped by `commitRestored(scope_ | Polygons)`, i.e. by
//                       `displayTermFor`. Reddens when that arm is deleted.
//   * `HideDelta`     — bumped by the RAW tail `++topologyVersion`, i.e. by
//                       `owesTopologyBump`. Reddens when THAT arm is deleted.
//
// The plan's W4c named two rows and one mutation; splitting them is a
// strengthening, not a change of ruling — with two rows the `displayTermFor`
// mutation and the `owesTopologyBump` mutation are indistinguishable here.
//
// NO GL. The stencil rebuild is CPU (the GPU fan-out is off by default), and
// the VBO half keys on the SAME term this cell reads, so what is asserted here
// is the term itself plus the OSD rebuild it drives. The GL half of task
// 2060's (2b) is not re-measured; it is named.
// ===========================================================================
module tests.unit.mesh_edit_delta_carveout_preview_test;

import std.format : format;

import mesh;
import math : Vec3;
import mesh_edit_delta;
import mesh_dirty : noteMeshChange;

private struct PreviewRow {
    string           name;
    MeshEditScope    scope_;
    MeshOpEntry.Kind kind;
    bool             wantTopoBuild;   // must rebuildIfStale re-lay the stencils?
}

unittest // W4c — the tail bump fires per KIND, and the preview is what feels it
{
    const PreviewRow[] rows = [
        PreviewRow("SetPos", MeshEditScope.Position, MeshOpEntry.Kind.SetPos, false),
        PreviewRow("SubpatchDelta", MeshEditScope.Marks,
                   MeshOpEntry.Kind.SubpatchDelta, true),
        PreviewRow("HideDelta",
                   cast(MeshEditScope)(MeshEditScope.Marks | MeshEditScope.Visibility),
                   MeshOpEntry.Kind.HideDelta, true),
    ];

    foreach (ref r; rows) {
        Mesh cage = makeCube();
        cage.resizeSubpatch();
        cage.resetSelection();
        foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);

        SubpatchPreview preview;
        noteMeshChange(cast(size_t)&cage, cage.undeliveredChanges_);
        preview.rebuildIfStale(cage, 1);
        assert(preview.active, format(
            "%s: stand — the preview must ACTIVATE on a fully-subpatched cube, "
          ~ "or every number below is read off a preview that never existed",
            r.name));

        MeshEditDelta d;
        d.scope_ = r.scope_;
        MeshOpEntry e;
        e.kind = r.kind;
        if (r.kind == MeshOpEntry.Kind.SetPos) {
            e.vIdx      = [0u];
            e.posBefore = [Vec3(3, 4, 5)];
            e.posAfter  = [cage.vertices[0]];
        } else {
            e.markIdx    = [1u];
            e.markBefore = [1u];
            e.markAfter  = [0u];
            if (r.kind == MeshOpEntry.Kind.SubpatchDelta) cage.setSubpatch(1, false);
            if (r.kind == MeshOpEntry.Kind.HideDelta)     cage.setFaceHidden(1, false);
        }
        d.log = [e];

        // Re-settle the preview against whatever the stand's own setup moved,
        // so the delta's revert is the ONLY thing the measurement sees.
        noteMeshChange(cast(size_t)&cage, cage.undeliveredChanges_);
        preview.rebuildIfStale(cage, 1);

        const rebBefore   = g_rebuildEdgesRuns;
        const ulong topoV = cage.topologyVersion;
        const ulong builds = preview.topologyBuilds;

        d.revert(cage);
        assert(g_rebuildEdgesRuns == rebBefore, format(
            "%s: the stand did not take the FAST path (rebuildEdges ran %d "
          ~ "time(s))", r.name, g_rebuildEdgesRuns - rebBefore));

        // Feed the epoch the way `app.d`'s hub would; a unittest binary
        // registers no hub, so the listener body is called by hand (the
        // arrangement `mesh_dirty`'s header documents).
        noteMeshChange(cast(size_t)&cage, MeshEditScope.Position);
        preview.rebuildIfStale(cage, 1);

        const bool bumped = cage.topologyVersion != topoV;
        const bool rebuilt = preview.topologyBuilds > builds;

        assert(bumped == r.wantTopoBuild, format(
            "W4c/%s: topologyVersion %s across a fast-path revert, expected it "
          ~ "%s. For SubpatchDelta the bump must arrive through "
          ~ "`commitRestored(scope_ | Polygons)` — `displayTermFor`'s arm — and "
          ~ "for HideDelta through the raw tail `++topologyVersion` that "
          ~ "`owesTopologyBump` gates; for SetPos it must not arrive at all, "
          ~ "which is the whole point of the carve-out.",
            r.name, bumped ? "MOVED" : "held", r.wantTopoBuild ? "to move" : "to hold"));

        assert(rebuilt == r.wantTopoBuild, format(
            "W4c/%s: the subpatch preview %s its stencil table, expected it %s "
          ~ "(topologyBuilds %d -> %d). This is the 41.9-46.1 ms per undo task "
          ~ "2060 measured. The SetPos row reading FALSE here is what the "
          ~ "carve-out buys; the other two rows reading TRUE is what says the "
          ~ "layout genuinely changed and the preview is right to rebuild.",
            r.name, rebuilt ? "REBUILT" : "reused",
            r.wantTopoBuild ? "to rebuild" : "to reuse",
            builds, preview.topologyBuilds));
    }
}
