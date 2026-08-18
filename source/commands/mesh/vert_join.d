module commands.mesh.vert_join;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import selection_product : repointToNothing;
import view;
import editmode;
import math : Vec3;
import snapshot : MeshSnapshot;
import params : Param;

/// Tier 1.2: `vert.join`. Collapses the selected vertices to a single point —
/// the centroid (`average=true`) or the SURVIVOR's position (`average=false`)
/// — then welds them.
///
/// THREE MEASURED LAWS live here (task 1210, dogfood ledger rows 11 + 21,
/// frozen in `tests/fixtures/vert_join_survivor.json` and
/// `tests/fixtures/vert_join_degenerate.json`):
///
///   1. THE SURVIVOR IS THE LAST-SELECTED VERTEX, not the lowest-indexed one.
///      Select (0,0,0) then (2,0,0) on a 2x1 plate and the reference keeps
///      (2,0,0); we used to keep (0,0,0). The DISCRIMINATOR is the same pair in
///      the opposite order — there "last selected" and "lowest index" name the
///      same vertex, the two engines agree, and that agreement is what rules
///      out the rival reading "highest index". Confirmed again on three
///      vertices of a valence-6 pole. The order comes from
///      `Mesh.selectedVerticesBySelectionOrder` (a stamp every user-reachable
///      selection path maintains); with `average=true` the survivor's IDENTITY
///      still decides which vertex's per-vertex data (weight maps, morph
///      deltas, set membership) the join carries forward, even though the
///      POSITION is the centroid either way.
///
///   2. THE JOINED VERTEX IS NEVER SWEPT AWAY. Collapsing every vertex of a
///      plate drops every face, and the tail compaction used to take the mesh
///      to EMPTY; the reference leaves ONE FREE VERTEX at the join point. This
///      is `vert.join`'s own rule and not a general "welds keep orphans" one —
///      the same capture CUTS every face of that plate and is left with zero
///      vertices.
///
///   3. `keep` IS HONOURED. It keeps the polygons the join leaves with two
///      distinct corners: joining a fan's hub to one of its ring vertices
///      leaves the reference 8 faces, two of them TWO-POINT polygons, where we
///      left 6. The previous comment here said "`keep` is recognized but not
///      yet honored" — that admission is now a measurement.
///
/// The post-command selection is CLEARED (`repointToNothing`): the reference
/// leaves nothing selected after a join, the same answer the vertex split gave
/// in task 1180's selection-product port.
class MeshVertJoin : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private bool average_ = true;
    private bool keep_    = false;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "vert.join"; }
    override string label() const { return "Join Vertices"; }

    override Param[] params() {
        // The `keep` label is kept verbatim, but what was MEASURED is that the
        // flag preserves TWO-point polygons; no cell shows a ONE-point polygon
        // surviving, so the arity floor it lowers stops at 2. If a capture ever
        // produces a one-corner remnant, that is the measurement that would
        // move `JoinWeldPolicy.keepTwoPointFaces` down another step.
        return [
            Param.bool_("average", "Average", &average_, true),
            Param.bool_("keep",    "Keep 1-Vertex Polygons", &keep_, false),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (!mesh.hasAnySelectedVertices()) return false;

        // Law 1: the SURVIVOR is the last-selected vertex. The ordered read is
        // shared with mesh.makePolygon so the tie-breaks cannot drift.
        const ordered = mesh.selectedVerticesBySelectionOrder();
        if (ordered.length < 2) return false;     // single vert — no-op

        Vec3 sum = Vec3(0, 0, 0);
        foreach (vi; ordered) sum = sum + mesh.vertices[vi];
        const int survivor = cast(int) ordered[$ - 1];

        Vec3 target = average_
            ? Vec3(sum.x / ordered.length, sum.y / ordered.length,
                   sum.z / ordered.length)
            : mesh.vertices[survivor];

        snap = MeshSnapshot.capture(*mesh);
        auto selMask = mesh.selectedVertices;   // materialise once
        mesh.collapseVerticesByMask(selMask, target);
        // Weld the now-coincident verts. Tiny eps is enough since
        // collapseVerticesByMask sets exact equality. The policy carries laws
        // 1-3: keep `survivor` as the cluster head, pin it so a join that
        // consumed every face still leaves it behind, and honour `keep`.
        JoinWeldPolicy policy;
        policy.survivor           = survivor;
        policy.keepOrphanSurvivor = true;
        policy.keepTwoPointFaces  = keep_;
        size_t welded = mesh.weldVerticesByMask(selMask, 1e-12, false, policy);
        if (welded == 0) {
            // Verts didn't actually weld (selection not contiguous?) —
            // restore and fail.
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            return false;
        }
        // The reference leaves NOTHING selected after a join (task 1210).
        repointToNothing(mesh);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
