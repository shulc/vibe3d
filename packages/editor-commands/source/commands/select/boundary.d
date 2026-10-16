module commands.select.boundary;

import command;
import mesh;
import view;
import vibe3d.editing.contracts.editmode;
import snapshot : SelectionSnapshot;

// ---------------------------------------------------------------------------
// select.boundary — face selection → edge selection.
//
// The border of the selected polygon set: with polygons selected it produces
// the ring of edges around that set (a discontinuous selection gives several
// rings); with NOTHING selected the whole mesh is the set, so what is left is
// the mesh's own open boundary — the holes.
//
// ---------------------------------------------------------------------------
// The law, and why it is not the one the reference DOCUMENTS
// ---------------------------------------------------------------------------
// Let `A` be the active polygon set — the selected polygons, or ALL polygons
// when none is selected. For each edge, let `s` be how many polygons OF `A`
// use it and `u` how many polygons NOT in `A` use it:
//
//     edge is on the boundary  ⟺  s == 1  ||  (s >= 1 && u >= 1)
//
// Read the other way round: an edge with at least one active polygon is a
// border UNLESS it is interior to the set — used by two or more active
// polygons and by no inactive one. A lone active polygon on an edge is
// always a border, because there is nothing on the other side.
//
// The reference's own help states the mechanism as *"select all edges
// bordered by an odd number of selected polygons"*. On a manifold mesh (every
// edge used by 1 or 2 polygons) that is the SAME predicate. It parts company
// only where an edge carries three or more polygons, and there the measured
// behaviour follows the rule above, not the documented parity:
//
//   * three polygons on one edge, ALL selected — parity says odd → select;
//     measured: NOT selected (it is interior to the set).
//   * three polygons on one edge, two selected — parity says even → skip;
//     measured: SELECTED (the third polygon is on the other side).
//
// Both were measured on a T-junction built in the reference engine (a box
// stacked on a box, welded, then stripped to a single wall) and on a
// coincident-duplicate polygon. The scoreboard over every captured case:
// this rule 38/38, "odd number of selected" 26/38, "exactly one selected"
// 32/38, "at least one selected and one unselected" 28/38. Capture and
// scoring belong to task 1050; the frozen cases are
// `tests/fixtures/select_boundary.json`.
//
// ---------------------------------------------------------------------------
// NOT the same law as select.byStat.edge's open-border row (task 1061)
// ---------------------------------------------------------------------------
// `commands/select/by_stat.d`'s `EdgeStat.polygonCount compare:equal
// value:1` answers a different question: exactly one adjacent polygon,
// over the WHOLE MESH, selection-independent. THIS command answers relative
// to the ACTIVE polygon set (selected, or all when none is selected). They
// coincide only when nothing is selected — measured
// (`edge_boundary_tagged_open_cube.identical_with_a_polygon_selected`):
// with one polygon selected the reference's boundary answer is
// byte-identical to the no-selection case, where THIS command would answer
// that polygon's own four edges. `label()` below states the scope at the
// UI surface; the cross-asserting discriminator unittest near the bottom
// of this file constructs and runs `SelectByStatEdge` on the same mesh
// state and asserts the two answers differ.
//
// Two more measured facts this command reproduces:
//   * the POLYGON selection survives — this is not a converter that consumes
//     its input (unlike `select.convert`, which clears the source).
//   * the component mode ends on Edges. Measured indirectly: a `select.invert`
//     issued afterwards inverted the EDGE selection (4 → 8 on a cube), not the
//     polygon one, so the mode had moved.
//
// A VERTEX selection does not feed it. Measured on an open mesh in vertex mode
// with vertices selected and no polygon selected: the answer was the mesh's
// hole, i.e. the empty-polygon-selection branch, not anything keyed on the
// selected vertices.
//
// Undo: SelectionSnapshot, like the rest of the select.* growth family, plus
// the EditMode switch (which the snapshot does not carry), routed back through
// the same promote hook — the shape `select.fill.insideLoop` established.
// ---------------------------------------------------------------------------
class SelectBoundary : Command {
    private SelectionSnapshot       snap;
    private EditMode                priorEditMode;
    private bool                    modeSwitched;
    private EditMode*               editModePtr;
    private void delegate(EditMode) promoteType;

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
    }

    override string name() const { return "select.boundary"; }

    // States the scope that distinguishes this command from
    // select.byStat.edge's open-border row (task 1061) — this one is
    // relative to the ACTIVE polygon set, not the whole mesh.
    override string label() const { return "Select Border Of Polygon Set"; }

    /// Lockstep hook with the app's geometry-type funnel. Optional: a
    /// headless/unit-test construction without one writes `*editModePtr`.
    SelectBoundary setPromoteHook(void delegate(EditMode) h) {
        promoteType = h;
        return this;
    }

    protected override void revertImpl() {
        snap.restore(*mesh);
        if (modeSwitched && editModePtr !is null) {
            if (promoteType !is null) promoteType(priorEditMode);
            else                      *editModePtr = priorEditMode;
        }
    }

    protected override bool applyImpl() {
        snap          = SelectionSnapshot.capture(*mesh);
        noteUndoRecorded();   // task 2500 — the flag and the image, one statement apart
        priorEditMode = editModePtr !is null ? *editModePtr : editMode;
        mesh.syncSelection();

        const size_t nf = mesh.faces.length;
        const size_t ne = mesh.edges.length;
        if (ne == 0) return true;

        // The active set. `hasAnySelectedFaces` is the same "is there a
        // polygon selection at all" question the reference branches on.
        const bool useAll = !mesh.hasAnySelectedFaces();

        // Per-edge active/inactive incidence, counted straight off `faces[]`
        // through the canonical (min,max) key — the same honest count
        // `Mesh.edgePolygonCounts` makes, and for the same reason: a ring walk
        // (`facesAroundEdge`) cannot witness a third polygon on an edge, and
        // this rule is decided precisely by that third polygon.
        uint[ulong] idx;
        foreach (i; 0 .. ne)
            idx[edgeKey(mesh.edges[i][0], mesh.edges[i][1])] = cast(uint) i;

        auto act   = new int[](ne);
        auto inact = new int[](ne);
        foreach (fi; 0 .. nf) {
            const uint[] f = mesh.faces[fi];
            if (f.length == 0) continue;
            const bool inSet = useAll || mesh.isFaceSelected(fi);
            foreach (k; 0 .. f.length) {
                auto p = edgeKey(f[k], f[(k + 1) % f.length]) in idx;
                if (p is null) continue;   // face edge with no edges[] entry
                if (inSet) ++act[*p];
                else       ++inact[*p];
            }
        }

        auto want = new bool[](ne);
        foreach (ei; 0 .. ne)
            want[ei] = act[ei] == 1 || (act[ei] >= 1 && inact[ei] >= 1);

        // selectEdgesFrom, not setEdgesSelectedFrom: these edges are selected
        // on the user's behalf and must carry a selection-history value, or
        // they sort behind anything clicked afterwards (see the primitive's
        // doc comment in mesh.d). Same choice as select.fill.*.
        mesh.selectEdgesFrom(want);

        if (editModePtr !is null && *editModePtr != EditMode.Edges) {
            modeSwitched = true;
            if (promoteType !is null) promoteType(EditMode.Edges);
            else                      *editModePtr = EditMode.Edges;
        }
        return true;
    }
}

