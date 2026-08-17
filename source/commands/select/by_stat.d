module commands.select.by_stat;

import command;
import mesh;
import view;
import editmode;
import params   : Param;
import snapshot : SelectionSnapshot;
import std.algorithm : canFind;
import std.conv       : to;

// ---------------------------------------------------------------------------
// select.byStat.{vertex,edge,polygon} — the Statistics tree's "+"/"-" rows,
// expressed as ordinary selection commands over data the mesh already holds:
// dangling points (vertex edgeCount == 0), 1-/2-point polygons (polygon
// vertexCount == 1 | 2), n-gons (polygon vertexCount more 4), open borders
// (edge polygonCount == 1), non-manifold edges (edge polygonCount more 2),
// and material/part tag borders. Task 1061.
//
// ---------------------------------------------------------------------------
// The command surface — ONE spelling, per component type (task 1061 §1)
// ---------------------------------------------------------------------------
// Three commands, one per component type, named parameters only — no
// positional alias, no second id. The measured reference trap is that its
// NAMED spelling of one of these accepts, returns success, and does nothing
// (only its positional form works); we do not build the twin that trap needs.
// Splitting by type makes an illegal (type, row) pair UNREPRESENTABLE rather
// than a runtime check: `EdgeStat` has no `vertexCount` member, so
// `select.byStat.edge test:vertexCount` fails at argument parse, not deep
// inside an `if`. Dispatch is a `final switch` over each type's own D enum,
// so a row added to the enum but not handled in the switch does not compile.
//
// No silently-ignored argument (the OTHER half of the anti-inert design):
// every parameter the caller sets must change the answer or be rejected with
// an exception naming it. `compare != all` requires `value >= 0`;
// `test:weightMap` requires `map` set and `compare`/`value` left at their
// defaults; every other test requires `map` left empty; `materialBoundary`/
// `partBoundary` (fixed boolean predicates, not a numeric comparison) require
// `compare`/`value` left at their defaults for the same reason `weightMap`
// does — nothing on either side of that predicate reads them, so a caller
// who sets them and sees no effect has hit a silently-ignored argument
// unless we reject it. This is why `value`'s default is the sentinel `-1`
// and `compare`'s default is `"all"` rather than `0`/`"equal"`: with `0`
// there is no way to tell "the caller asked for count 0" from "the caller
// said nothing", which is exactly where an ignored argument would hide.
//
// `mode` is `add` (union) / `remove` (set difference) ONLY — measured
// (`g56_measured.json` `plus_minus.law`: "never a replace, never a toggle").
// `select.byTag` carries a `set` mode and that is right THERE (its gesture is
// "click one polygon, get its whole region" — a replace); here the gesture
// is a `+`/`-` column, and a replace is spelled `select.drop <type>` then
// this command — a deliberate narrowing, not an omission.
//
// `value` is count-LIKE but scales NOTHING — it indexes no array, sizes no
// allocation, bounds no loop; it is a pure comparand read once per element
// inside an already-O(V+E+F) pass. So it takes the floor half of the
// two-layer clamp only: `.min(-1).enforceBounds()` (an HTTP-injected value
// below the sentinel is raised to it), and deliberately NO kernel `MAX_…`
// cap — there is no kernel allocation for a cap to back-stop.
//
// ---------------------------------------------------------------------------
// The two boundary laws (task 1061 §3 / task 1050) — DO NOT UNIFY
// ---------------------------------------------------------------------------
// `select.boundary` (source/commands/select/boundary.d) answers relative to
// the ACTIVE polygon set — the current selection, or every polygon when
// nothing is selected. This module's `EdgeStat.polygonCount compare:equal
// value:1` row answers a completely different question: exactly one
// adjacent polygon, over the WHOLE MESH, selection-independent. They
// coincide only when nothing is selected; measured
// (`g56_measured.json`/task 1050's own capture,
// `edge_boundary_tagged_open_cube.identical_with_a_polygon_selected`): with
// one polygon selected the reference's boundary answer is byte-identical to
// the no-selection case, where `select.boundary` would answer that
// polygon's own four edges. See `boundary.d`'s header for the mirror of
// this note and `SelectBoundary.label()`, which states the scope
// distinction at the UI surface.
//
// There is deliberately NO `EdgeStat.geometryBoundary` member — the
// open-border row is spelled as the count it is (`polygonCount equal 1`),
// so there is no second thing in this codebase named "boundary" for a
// future reader to collapse into `select.boundary`. Justified by
// measurement: `edge_by_polygon_count.equal_1` /
// `edge_boundary_nonmanifold.geometry_kind_2` are the identical edge set on
// the same mesh, including the cell with 3- and 4-polygon edges — which is
// what kills the rival "≠ 2" reading of the row.
//
// The cross-asserting discriminator that keeps the two laws apart lives as
// a unittest PAIR — one in this module (imports `SelectBoundary` under
// `version (unittest)`), one in `boundary.d` (imports `SelectByStatEdge`
// under `version (unittest)` and actually constructs + runs it, not merely
// re-asserting `SelectBoundary`'s own behaviour). Deleting either law, or
// routing one through the other in EITHER direction, turns both files red.
//
// ---------------------------------------------------------------------------
// Where the predicates live (task 1100)
// ---------------------------------------------------------------------------
// The three per-element predicates, the `Compare` vocabulary and the three
// `*Stat` row enums are in `source/mesh_stats.d`, which this module
// `public import`s so no external caller changed. They moved because the
// Statistics panel needs to COUNT the rows every frame and a `Command` cannot
// answer a count without mutating the selection; the kernel takes the mesh as
// `const`, which makes "count by running the command" a compile error rather
// than a discipline. This module keeps the argument hygiene, the snapshot,
// the mode composition and the edit-mode promotion — everything that makes
// this a command — and calls the kernel for the mask.
//
// The weight-map predicate's negative arm, the two boundary laws and the tag
// borders' unmeasured extrapolation are documented WITH the predicates now,
// in `mesh_stats.d`; the measured laws about the COMMAND surface stay here.
//
// ---------------------------------------------------------------------------
// The `less` anomaly — measured, NOT reproduced (task 1061 §5)
// ---------------------------------------------------------------------------
// For POLYGONS, the reference's `less` comparator behaves as `more` —
// verified at two sampled values (`poly_by_vertex.more_4 ==
// vertex_more_is_strict-style equal_6`-shaped check; see the plan), and its
// own UI never emits that mode. We implement `less` as strictly-less for
// ALL THREE component types, deliberately not reproducing the anomaly.
// Recorded: `doc/behavior_gap_registry.md` (status `divergence-deliberate`),
// this header, `doc/tasks/work/1061-statistics-selection.md`, and pinned by
// a module unittest below — no fixture case asserts polygon `less` against
// a reference number.
//
// ---------------------------------------------------------------------------
// Scope — PRIMARY layer only (task 1061 §4, `divergence-deliberate`)
// ---------------------------------------------------------------------------
// Measured: rows evaluate over the whole mesh AND EVERY FOREGROUND LAYER
// (`g56_measured.json` `plus_minus.scope`). Ours binds one `Mesh*` at
// construction (`Command`, `source/command.d:413`) and `SelectionSnapshot`
// captures exactly one mesh — multi-mesh would mean a multi-mesh undo
// record and a second `Command` shape, a document-model change, not a
// query. Pinned by the multi-layer module unittest below (two foreground
// layers; the command touches only the primary's selection). Task 1060
// owns the follow-up machinery — its selection-set commands carry the
// identical scope law.
//
// Cross-task note for 1060: `vertex_by_vmap.selection_set_maps_are_excluded`
// is `true` in the capture — when 1060 lands set storage as maps,
// `test:weightMap` must not see them.
//
// Undo: `SelectionSnapshot`, plus the `EditMode` switch (not carried by the
// snapshot), routed back through the same promote hook `select.boundary`
// and `select.fill.insideLoop` use. Always promotes to the command's own
// geometry type — `vibe3d-choice`, unmeasured; asserted only in unittests,
// never claimed as parity in the fixture.
// ---------------------------------------------------------------------------

/// The row vocabulary lives with the predicates it selects between
/// (`source/mesh_stats.d`, task 1100) and is re-exported here so that every
/// caller of `Compare` / `VertexStat` / `EdgeStat` / `PolygonStat` through
/// this module keeps compiling — the `GpuMesh` extract precedent (task 0425).
public import mesh_stats : Compare, VertexStat, EdgeStat, PolygonStat;

import mesh_stats : StatContext, StatNeed, buildStatContext, vertexStatMask,
                    edgeStatMask, polygonStatMask;

/// Shared `mode` vocabulary. No `set` — see the header note.
private enum ApplyMode { add, remove }

// ---------------------------------------------------------------------------
// ByStatBase — the shared spine: compare/value/map/mode params, snapshot +
// EditMode undo/promotion, and the argument-hygiene helpers every subclass
// calls before touching the mesh. Modelled line-for-line on
// `SelectBoundary` (`source/commands/select/boundary.d:66-100`).
// ---------------------------------------------------------------------------
private abstract class ByStatBase : Command {
    protected SelectionSnapshot       snap;
    protected EditMode                priorEditMode;
    protected bool                    modeSwitched;
    protected EditMode*               editModePtr;
    protected void delegate(EditMode) promoteType;

    protected string compare_ = "all";
    protected int    value_   = -1;
    protected string map_     = "";
    protected string mode_    = "add";

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
    }

    /// Lockstep hook with the app's geometry-type funnel — same shape as
    /// `SelectBoundary.setPromoteHook`. Optional: a headless/unit-test
    /// construction without one writes `*editModePtr` directly.
    ByStatBase setPromoteHook(void delegate(EditMode) h) {
        promoteType = h;
        return this;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        if (modeSwitched && editModePtr !is null) {
            if (promoteType !is null) promoteType(priorEditMode);
            else                      *editModePtr = priorEditMode;
        }
        return true;
    }

    /// Parse `compare_`, throwing (naming the value and the legal set) on
    /// anything else. Called even when the Param layer already validated a
    /// `Kind.Enum` write via `injectParamsInto` — a unit test that pokes
    /// `*p.sptr` directly bypasses that layer, so apply() re-checks, same
    /// double-check shape as `select.byTag`'s `type_`/`mode_`.
    protected Compare parseCompare() {
        switch (compare_) {
            case "all":   return Compare.all;
            case "equal": return Compare.equal;
            case "less":  return Compare.less;
            case "more":  return Compare.more;
            default:
                throw new Exception("select.byStat: unknown compare '" ~ compare_
                    ~ "' — expected all, equal, less or more");
        }
    }

    protected ApplyMode parseMode() {
        switch (mode_) {
            case "add":    return ApplyMode.add;
            case "remove": return ApplyMode.remove;
            default:
                throw new Exception("select.byStat: unknown mode '" ~ mode_
                    ~ "' — expected add or remove");
        }
    }

    /// `compare != all` requires `value >= 0` — the sentinel default (-1)
    /// otherwise silently participates in a numeric comparison nobody asked
    /// for. Skipped by the two boolean-predicate tests (materialBoundary /
    /// partBoundary), which reject compare/value outright instead — see
    /// `checkDefaultCompareValue` below.
    ///
    /// The mirror direction: `compare == all` reads nothing off `value` (see
    /// `matchCompare` — the `all` arm ignores its `value` parameter
    /// entirely), so a caller who sets `value` alongside `compare:all` has
    /// hit exactly the silently-ignored-argument case the sentinel default
    /// exists to catch. Proven by probe: `select.byStat.polygon compare:all
    /// value:7` previously raised nothing and returned all six faces.
    protected void checkCompareValue(Compare cmp) {
        if (cmp != Compare.all && value_ < 0)
            throw new Exception("select.byStat: compare '" ~ compare_
                ~ "' requires value >= 0 (got " ~ value_.to!string ~ ")");
        if (cmp == Compare.all && value_ != -1)
            throw new Exception("select.byStat: compare 'all' ignores 'value' "
                ~ "— leave it at the default -1 (got " ~ value_.to!string ~ ")");
    }

    /// For rows that are not a numeric comparison at all (weightMap,
    /// materialBoundary, partBoundary): `compare`/`value` must be left at
    /// their defaults, or the caller has set an argument that silently does
    /// nothing — exactly the class of bug the anti-inert design rejects.
    protected void checkDefaultCompareValue(string test) {
        if (compare_ != "all")
            throw new Exception("select.byStat: test '" ~ test
                ~ "' ignores 'compare' — leave it at the default 'all'");
        if (value_ != -1)
            throw new Exception("select.byStat: test '" ~ test
                ~ "' ignores 'value' — leave it at the default -1");
    }

    protected void checkMapEmpty(string test) {
        if (map_.length != 0)
            throw new Exception("select.byStat: test '" ~ test
                ~ "' does not use 'map' — it is only used by test 'weightMap'");
    }

    /// Promote to `target` through the funnel, mirroring `SelectBoundary`'s
    /// unconditional promotion (even when nothing matched).
    protected void promote(EditMode target) {
        if (editModePtr !is null && *editModePtr != target) {
            modeSwitched = true;
            if (promoteType !is null) promoteType(target);
            else                      *editModePtr = target;
        }
    }
}

// ---------------------------------------------------------------------------
// select.byStat.vertex
// ---------------------------------------------------------------------------
final class SelectByStatVertex : ByStatBase {
    private string test_ = "edgeCount";

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode, editModePtr);
    }

    override string name()  const { return "select.byStat.vertex"; }
    override string label() const { return "Select By Statistic (Vertex)"; }

    override Param[] params() {
        return [
            Param.enum_("test", "Test", &test_, [
                ["edgeCount",    "Edge Count"],
                ["polygonCount", "Polygon Count"],
                ["weightMap",    "Weight Map"],
            ], "edgeCount"),
            Param.enum_("compare", "Compare", &compare_, [
                ["all", "All"], ["equal", "Equal"], ["less", "Less"], ["more", "More"],
            ], "all"),
            Param.int_("value", "Value", &value_, -1).min(-1).enforceBounds(),
            Param.string_("map", "Map", &map_, ""),
            Param.enum_("mode", "Mode", &mode_, [
                ["add", "Add"], ["remove", "Remove"],
            ], "add"),
        ];
    }

    private VertexStat parseTest() {
        switch (test_) {
            case "edgeCount":    return VertexStat.edgeCount;
            case "polygonCount": return VertexStat.polygonCount;
            case "weightMap":    return VertexStat.weightMap;
            default:
                throw new Exception("select.byStat.vertex: unknown test '" ~ test_
                    ~ "' — expected edgeCount, polygonCount or weightMap");
        }
    }

    override bool apply() {
        auto t   = parseTest();
        auto cmp = parseCompare();
        auto md  = parseMode();

        if (t == VertexStat.weightMap) {
            if (map_.length == 0)
                throw new Exception(
                    "select.byStat.vertex: test 'weightMap' requires 'map' to name a weight map");
            // Reject an unknown map name HERE, before the snapshot/sync below
            // — same reject-before-you-touch ordering every other rejection
            // in this file follows. It used to fire from inside the `final
            // switch` below, after the snapshot was already captured and
            // selection already synced; nothing was corrupted by that (a
            // thrown exception still unwinds before `mesh.selectVerticesFrom`
            // runs), but it broke the file's own ordering rule for no reason.
            if (!mesh.weightMapNames().canFind(map_))
                throw new Exception(
                    "select.byStat.vertex: no such weight map '" ~ map_ ~ "'");
            checkDefaultCompareValue("weightMap");
        } else {
            checkMapEmpty(test_);
            checkCompareValue(cmp);
        }

        snap          = SelectionSnapshot.capture(*mesh);
        priorEditMode = editModePtr !is null ? *editModePtr : editMode;
        mesh.syncSelection();

        const size_t n = mesh.vertices.length;
        if (n == 0) return true;

        // The predicate is the kernel's, called through its mask driver — one
        // implementation, shared with the panel's count driver (task 1100).
        //
        // The context is built for THIS test only. Asking for the whole thing
        // would make a vertex-count selection pay for a per-edge adjacency it
        // never reads — measured at tens of milliseconds on a 100k-face mesh,
        // and a regression this extraction would otherwise have introduced.
        const need = t == VertexStat.edgeCount    ? StatNeed.vertEdge
                   : t == VertexStat.polygonCount ? StatNeed.vertPoly
                                                  : StatNeed.none;
        StatContext ctx = buildStatContext(*mesh, need);
        auto want = vertexStatMask(ctx, t, cmp, value_, map_);

        final switch (md) {
            case ApplyMode.add:
                foreach (vi; 0 .. n) want[vi] = want[vi] || mesh.isVertexSelected(vi);
                break;
            case ApplyMode.remove:
                foreach (vi; 0 .. n) want[vi] = !want[vi] && mesh.isVertexSelected(vi);
                break;
        }

        mesh.selectVerticesFrom(want);
        promote(EditMode.Vertices);
        return true;
    }
}

// ---------------------------------------------------------------------------
// select.byStat.edge
// ---------------------------------------------------------------------------
final class SelectByStatEdge : ByStatBase {
    private string test_ = "polygonCount";

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode, editModePtr);
    }

    override string name()  const { return "select.byStat.edge"; }
    override string label() const { return "Select By Statistic (Edge)"; }

    override Param[] params() {
        return [
            Param.enum_("test", "Test", &test_, [
                ["polygonCount",     "Polygon Count"],
                ["materialBoundary", "Material Boundary"],
                ["partBoundary",     "Part Boundary"],
            ], "polygonCount"),
            Param.enum_("compare", "Compare", &compare_, [
                ["all", "All"], ["equal", "Equal"], ["less", "Less"], ["more", "More"],
            ], "all"),
            Param.int_("value", "Value", &value_, -1).min(-1).enforceBounds(),
            // No `map` Param here — every `EdgeStat` row rejects it
            // (`checkMapEmpty` in `apply()` below), so publishing it would
            // put a settable string on the registry/form surface whose only
            // possible effect is an exception. `map` is published by
            // `SelectByStatVertex` only, the one command that has a row
            // (`weightMap`) that can legally use it.
            Param.enum_("mode", "Mode", &mode_, [
                ["add", "Add"], ["remove", "Remove"],
            ], "add"),
        ];
    }

    private EdgeStat parseTest() {
        switch (test_) {
            case "polygonCount":     return EdgeStat.polygonCount;
            case "materialBoundary": return EdgeStat.materialBoundary;
            case "partBoundary":     return EdgeStat.partBoundary;
            default:
                throw new Exception("select.byStat.edge: unknown test '" ~ test_
                    ~ "' — expected polygonCount, materialBoundary or partBoundary");
        }
    }

    override bool apply() {
        auto t   = parseTest();
        auto cmp = parseCompare();
        auto md  = parseMode();

        checkMapEmpty(test_);
        final switch (t) {
            case EdgeStat.polygonCount:
                checkCompareValue(cmp);
                break;
            case EdgeStat.materialBoundary:
                checkDefaultCompareValue("materialBoundary");
                break;
            case EdgeStat.partBoundary:
                checkDefaultCompareValue("partBoundary");
                break;
        }

        snap          = SelectionSnapshot.capture(*mesh);
        priorEditMode = editModePtr !is null ? *editModePtr : editMode;
        mesh.syncSelection();

        const size_t ne = mesh.edges.length;
        if (ne == 0) return true;

        const need = t == EdgeStat.polygonCount ? StatNeed.edgePoly
                                                 : StatNeed.edgeFaces;
        StatContext ctx = buildStatContext(*mesh, need);
        auto want = edgeStatMask(ctx, t, cmp, value_);

        final switch (md) {
            case ApplyMode.add:
                foreach (ei; 0 .. ne) want[ei] = want[ei] || mesh.isEdgeSelected(ei);
                break;
            case ApplyMode.remove:
                foreach (ei; 0 .. ne) want[ei] = !want[ei] && mesh.isEdgeSelected(ei);
                break;
        }

        mesh.selectEdgesFrom(want);
        promote(EditMode.Edges);
        return true;
    }
}

// ---------------------------------------------------------------------------
// select.byStat.polygon
// ---------------------------------------------------------------------------
final class SelectByStatPolygon : ByStatBase {
    private string test_ = "vertexCount";

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode, editModePtr);
    }

    override string name()  const { return "select.byStat.polygon"; }
    override string label() const { return "Select By Statistic (Polygon)"; }

    override Param[] params() {
        return [
            Param.enum_("test", "Test", &test_, [
                ["vertexCount", "Vertex Count"],
            ], "vertexCount"),
            Param.enum_("compare", "Compare", &compare_, [
                ["all", "All"], ["equal", "Equal"], ["less", "Less"], ["more", "More"],
            ], "all"),
            Param.int_("value", "Value", &value_, -1).min(-1).enforceBounds(),
            // No `map` Param here — see `SelectByStatEdge.params()`'s note;
            // `PolygonStat.vertexCount` also rejects `map` outright.
            Param.enum_("mode", "Mode", &mode_, [
                ["add", "Add"], ["remove", "Remove"],
            ], "add"),
        ];
    }

    private PolygonStat parseTest() {
        switch (test_) {
            case "vertexCount": return PolygonStat.vertexCount;
            default:
                throw new Exception("select.byStat.polygon: unknown test '" ~ test_
                    ~ "' — expected vertexCount");
        }
    }

    override bool apply() {
        auto t   = parseTest();
        auto cmp = parseCompare();
        auto md  = parseMode();

        checkMapEmpty(test_);
        checkCompareValue(cmp);

        snap          = SelectionSnapshot.capture(*mesh);
        priorEditMode = editModePtr !is null ? *editModePtr : editMode;
        mesh.syncSelection();

        const size_t nf = mesh.faces.length;
        if (nf == 0) return true;

        // Polygon arity is read off `faces` directly — no derived array.
        StatContext ctx = buildStatContext(*mesh, StatNeed.none);
        auto want = polygonStatMask(ctx, t, cmp, value_);

        final switch (md) {
            case ApplyMode.add:
                foreach (fi; 0 .. nf) want[fi] = want[fi] || mesh.isFaceSelected(fi);
                break;
            case ApplyMode.remove:
                foreach (fi; 0 .. nf) want[fi] = !want[fi] && mesh.isFaceSelected(fi);
                break;
        }

        mesh.selectFacesFrom(want);
        promote(EditMode.Polygons);
        return true;
    }
}

// ---------------------------------------------------------------------------
// Module unittests (task 1061 §6/Phase 1-3).
// ---------------------------------------------------------------------------
version (unittest) {
    import std.algorithm : sort;
    import math      : Vec3;
    import document  : Document, Layer;
    import seltype   : SelMode;
    // The boundary-law discriminator (§3): this module reaches INTO
    // boundary.d for the unittest only — a direction that does not exist
    // outside version(unittest). Legal in D for class references; no
    // `static this()` is added to either module (a circular import with
    // module constructors throws `ModuleCtorError` at startup).
    import commands.select.boundary : SelectBoundary;

    private View freshView() { return new View(0, 0, 1, 1); }

    private uint[2][] selectedEdgePairs(Mesh* m) {
        uint[2][] outp;
        foreach (ei; 0 .. m.edges.length) {
            if (!m.isEdgeSelected(ei)) continue;
            uint a = m.edges[ei][0], b = m.edges[ei][1];
            outp ~= a < b ? [a, b] : [b, a];
        }
        outp.sort();
        return outp;
    }

    private size_t[] selectedVertexIdx(Mesh* m) {
        size_t[] outp;
        foreach (vi; 0 .. m.vertices.length) if (m.isVertexSelected(vi)) outp ~= vi;
        return outp;
    }

    private size_t[] selectedFaceIdx(Mesh* m) {
        size_t[] outp;
        foreach (fi; 0 .. m.faces.length) if (m.isFaceSelected(fi)) outp ~= fi;
        return outp;
    }

    private void setParam(Command c, string name, string val) {
        foreach (ref p; c.params()) if (p.name == name) *p.sptr = val;
    }
    private void setParamI(Command c, string name, int val) {
        foreach (ref p; c.params()) if (p.name == name) *p.iptr = val;
    }

    // Open unit box (the +Y face missing) — same shape `boundary.d`'s
    // `openBox()` uses, reproduced here so this module does not need a
    // non-unittest import of that private helper.
    private Mesh* openBox() {
        auto m = new Mesh;
        m.vertices = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3( 0.5f, -0.5f, -0.5f),
            Vec3( 0.5f, -0.5f,  0.5f), Vec3(-0.5f, -0.5f,  0.5f),
            Vec3(-0.5f,  0.5f, -0.5f), Vec3( 0.5f,  0.5f, -0.5f),
            Vec3( 0.5f,  0.5f,  0.5f), Vec3(-0.5f,  0.5f,  0.5f),
        ];
        m.faces = [[0, 3, 2, 1], [0, 1, 5, 4], [1, 2, 6, 5],
                   [2, 3, 7, 6], [3, 0, 4, 7]];     // no top (4,5,6,7)
        m.rebuildEdges();
        m.syncSelection();
        return m;
    }
}

// 1. Non-manifold stacked-cube cell — the cell that kills the open-border
// row's rival "!= 2" reading, and cannot go through HTTP (mesh.cleanup
// would unifyFaces the coincident duplicate away). Reconstructed exactly
// from edge_by_polygon_count + edge_boundary_nonmanifold: lower unit cube
// (6 quads) + the upper cube's bottom quad (coincident with the lower
// cube's top) + the upper cube's -Z wall (y in [0.5,1.5]).
unittest {
    auto m = new Mesh;
    *m = makeCube();       // lower cube, 6 quads, verts 0..7
    m.vertices ~= [
        Vec3(-0.5f, 1.5f, -0.5f), Vec3(0.5f, 1.5f, -0.5f),   // 8, 9
        Vec3(0.5f, 1.5f, 0.5f),   Vec3(-0.5f, 1.5f, 0.5f),   // 10, 11
    ];
    // upper cube's bottom quad == lower cube's top quad (3,7,6,2), duplicated
    m.addFace([3, 7, 6, 2]);
    // upper cube's -Z wall: (3,2 at y=0.5) up to (8,9 at y=1.5)
    m.addFace([3, 2, 9, 8]);
    m.buildLoops();
    m.syncSelection();

    // Each call clears the prior edge selection first — mode:add (the
    // default) unions with whatever is already selected, and successive
    // calls in this test must not accumulate into each other.
    uint[2][] runEq(int val) {
        m.clearEdgeSelection();
        View v = freshView();
        auto c = new SelectByStatEdge(m, v, EditMode.Vertices, null);
        setParam(c, "test", "polygonCount");
        setParam(c, "compare", "equal");
        setParamI(c, "value", val);
        c.apply();
        return selectedEdgePairs(m);
    }
    uint[2][] runMore(int val) {
        m.clearEdgeSelection();
        View v = freshView();
        auto c = new SelectByStatEdge(m, v, EditMode.Vertices, null);
        setParam(c, "test", "polygonCount");
        setParam(c, "compare", "more");
        setParamI(c, "value", val);
        c.apply();
        return selectedEdgePairs(m);
    }

    auto eq1 = runEq(1);
    assert(eq1.length == 3, "the wall's 3 free edges have exactly 1 adjacent polygon, got "
        ~ eq1.length.to!string);

    auto eq3 = runEq(3);
    assert(eq3.length == 3, "the 3 top-ring edges (excluding the doubled edge) have "
        ~ "exactly 3 adjacent polygons, got " ~ eq3.length.to!string);

    auto more2 = runMore(2);
    assert(more2.length == 4, "more 2 (strict) must include the eq3 edges plus the "
        ~ "shared top edge (4 polygons) — a '!= 2' reading would answer differently, got "
        ~ more2.length.to!string);
}

// 2. The boundary-law discriminator (§3). BOTH directions asserted, and
// this module's half constructs+runs SelectBoundary, not merely its own
// command — a one-sided mirror (only re-testing SelectByStatEdge) would
// catch nothing about the "unify the two laws" mutation.
unittest {
    auto m = openBox();
    m.selectFace(3);   // the +Z wall: ring 2,3,7,6 (boundary.d's own fixture)

    View v1 = freshView();
    auto stat = new SelectByStatEdge(m, v1, EditMode.Edges, null);
    setParam(stat, "test", "polygonCount");
    setParam(stat, "compare", "equal");
    setParamI(stat, "value", 1);
    stat.apply();
    auto holeAnswer = selectedEdgePairs(m);

    // Re-select the wall (the stat command replaced the edge selection but
    // left the face selection alone) and run SelectBoundary on the SAME
    // mesh state.
    m.clearEdgeSelection();
    EditMode mode = EditMode.Polygons;
    View v2 = freshView();
    auto bnd = new SelectBoundary(m, v2, mode, &mode);
    bnd.apply();
    auto wallAnswer = selectedEdgePairs(m);

    assert(holeAnswer.length == 4, "the mesh's own hole has exactly 4 one-polygon edges");
    assert(wallAnswer.length == 4, "select.boundary on one selected wall returns its 4 edges");
    assert(holeAnswer != wallAnswer,
        "the two laws must disagree here — select.byStat.edge answers the mesh's hole "
        ~ "regardless of selection, select.boundary answers the SELECTED wall; "
        ~ "identical answers means the two laws were unified");
}

// 3. Tag borders: the tagged face's own open edge is excluded. A naive
// "differs from anything, or has <2 faces" rule would include it.
unittest {
    auto m = openBox();
    m.faceMaterial.length = m.faces.length;
    m.faceMaterial[2] = 1;   // face index 2 = [1,2,6,5], the +X wall

    View v = freshView();
    auto c = new SelectByStatEdge(m, v, EditMode.Vertices, null);
    setParam(c, "test", "materialBoundary");
    c.apply();
    auto got = selectedEdgePairs(m);
    assert(got.length == 3,
        "3 boundary edges, the tagged face's own open edge excluded, got "
        ~ got.length.to!string);
    // edge (5,6) is the +X wall's edge bordering the (missing +Y) hole —
    // only 1 adjacent polygon — and must NOT be selected. The wall's other
    // 3 edges (1,2)/(2,6)/(5,1) each border a differently-tagged neighbour
    // and must all be selected.
    bool openEdgeIn = false;
    foreach (e; got) if (e[0] == 5 && e[1] == 6) openEdgeIn = true;
    assert(!openEdgeIn, "the tagged face's own open edge leaked into the boundary");
}

// 4. Weight map: non-zero, not entry presence; clearing a subset partitions
// correctly.
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();
    auto wm = m.addWeightMap("W");
    assert(wm !is null);
    foreach (vi; 0 .. m.vertices.length) m.setVertexWeight("W", vi, 1.0f);
    // Clear the +X vertices only (1, 2, 5, 6 in makeCube()'s layout).
    foreach (vi; [1, 2, 5, 6]) m.setVertexWeight("W", vi, 0.0f);

    View v = freshView();
    auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
    setParam(c, "test", "weightMap");
    setParam(c, "map", "W");
    c.apply();
    auto got = selectedVertexIdx(m);
    assert(got == [0UL, 3UL, 4UL, 7UL],
        "only the -X vertices (never cleared) must come back, got " ~ got.to!string);
}

// 4b. Weight map: a NEGATIVE value also selects. Every measured cell in the
// capture is 0.0, 0.5 or 1.0 — this arm is an unmeasured extrapolation from
// `!= 0.0f`, spelled out in the header note above. Mutation that reddens
// this: `!= 0.0f` narrowed to `> 0.0f` (verified — that swap left the whole
// test suite green with test 4 alone, which is exactly why this case exists).
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();
    auto wm = m.addWeightMap("W");
    assert(wm !is null);
    foreach (vi; 0 .. m.vertices.length) m.setVertexWeight("W", vi, 0.0f);
    m.setVertexWeight("W", 0, -1.0f);

    View v = freshView();
    auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
    setParam(c, "test", "weightMap");
    setParam(c, "map", "W");
    c.apply();
    auto got = selectedVertexIdx(m);
    assert(got == [0UL],
        "a negative weight must select ('!= 0.0f', not '> 0.0f'), got " ~ got.to!string);
}

// 4c. Weight map: naming a map that does not exist is rejected, not
// silently treated as an all-zero map. Mutation that reddens this: deleting
// (or short-circuiting) the `weightMapNames().canFind` guard — apply() then
// runs to completion instead of throwing, so `collectExceptionMsg` below
// returns an empty string and the `canFind("NoSuchMap")` assert fails.
unittest {
    import std.exception : collectExceptionMsg;

    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();

    View v = freshView();
    auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
    setParam(c, "test", "weightMap");
    setParam(c, "map", "NoSuchMap");
    auto msg = collectExceptionMsg(c.apply());
    assert(msg.canFind("NoSuchMap"), "must name the missing map: " ~ msg);
}

// 5. Polygon `less` is strictly-less — the anomaly is NOT reproduced.
// Mutation that reddens this: implementing `less` as `more` for polygons.
unittest {
    auto m = new Mesh;
    // 5 quads + 2 tris (any positions — vertexCount is winding-arity only).
    foreach (i; 0 .. 20)
        m.addVertex(Vec3(cast(float) i, 0, 0));
    m.addFace([0u, 1u, 2u]);            // tri
    m.addFace([3u, 4u, 5u]);            // tri
    m.addFace([6u, 7u, 8u, 9u]);        // quad
    m.addFace([10u, 11u, 12u, 13u]);    // quad
    m.addFace([14u, 15u, 16u, 17u]);    // quad
    m.buildLoops();
    m.syncSelection();

    View v = freshView();
    auto c = new SelectByStatPolygon(m, v, EditMode.Polygons, null);
    setParam(c, "test", "vertexCount");
    setParam(c, "compare", "less");
    setParamI(c, "value", 4);
    c.apply();
    auto got = selectedFaceIdx(m);
    assert(got == [0UL, 1UL],
        "'less 4' (strict) must return only the 2 triangles — the reference's "
        ~ "anomaly (less behaving as more) would return NOTHING instead on this "
        ~ "stand (max arity here is 4, so 'more 4' strictly selects no polygon "
        ~ "at all, not the quads), got " ~ got.to!string);
}

// 6. Argument hygiene: each rejection throws and names the offending
// argument.
unittest {
    import std.exception : collectExceptionMsg;

    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();

    // compare != all requires value >= 0.
    {
        View v = freshView();
        auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
        setParam(c, "test", "edgeCount");
        setParam(c, "compare", "equal");
        // value left at its default sentinel -1.
        auto msg = collectExceptionMsg(c.apply());
        assert(msg.canFind("value"), "must name 'value': " ~ msg);
    }
    // compare == all ignores value — the mirror direction of the check
    // above. Proven by probe before this fix existed: `select.byStat.polygon
    // compare:all value:7` raised nothing and returned all six faces.
    {
        View v = freshView();
        auto c = new SelectByStatPolygon(m, v, EditMode.Polygons, null);
        setParam(c, "test", "vertexCount");
        setParam(c, "compare", "all");
        setParamI(c, "value", 7);
        auto msg = collectExceptionMsg(c.apply());
        assert(msg.canFind("value"), "must name 'value': " ~ msg);
    }
    // test:weightMap requires map set.
    {
        View v = freshView();
        auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
        setParam(c, "test", "weightMap");
        auto msg = collectExceptionMsg(c.apply());
        assert(msg.canFind("map"), "must name 'map': " ~ msg);
    }
    // every other test requires map == "".
    {
        View v = freshView();
        auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
        setParam(c, "test", "edgeCount");
        setParam(c, "map", "W");
        auto msg = collectExceptionMsg(c.apply());
        assert(msg.canFind("map"), "must name 'map': " ~ msg);
    }
    // materialBoundary rejects a non-default compare/value.
    {
        View v = freshView();
        auto c = new SelectByStatEdge(m, v, EditMode.Edges, null);
        setParam(c, "test", "materialBoundary");
        setParam(c, "compare", "equal");
        setParamI(c, "value", 2);
        auto msg = collectExceptionMsg(c.apply());
        assert(msg.canFind("compare"), "must name 'compare': " ~ msg);
    }
    // unparsable test / compare / mode throw, quoting the value.
    {
        View v = freshView();
        auto c = new SelectByStatPolygon(m, v, EditMode.Polygons, null);
        setParam(c, "compare", "bogus");
        auto msg = collectExceptionMsg(c.apply());
        assert(msg.canFind("bogus"), "must quote the bad value: " ~ msg);
    }
}

// 7. mode:remove subtracts, and compare:all takes everything (union +
// difference both directions, the anti-inert core of §6).
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();

    View v1 = freshView();
    auto add = new SelectByStatPolygon(m, v1, EditMode.Polygons, null);
    setParam(add, "test", "vertexCount");
    setParam(add, "compare", "all");
    add.apply();
    assert(selectedFaceIdx(m).length == 6, "compare:all must select every polygon");

    View v2 = freshView();
    auto rm = new SelectByStatPolygon(m, v2, EditMode.Polygons, null);
    setParam(rm, "test", "vertexCount");
    setParam(rm, "compare", "all");
    setParam(rm, "mode", "remove");
    rm.apply();
    assert(selectedFaceIdx(m).length == 0,
        "mode:remove with compare:all must subtract everything");
}

// 8. Undo restores the exact prior selection AND the prior EditMode.
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();
    m.selectFace(1);

    EditMode mode = EditMode.Polygons;
    View v = freshView();
    auto c = new SelectByStatEdge(m, v, mode, &mode);
    setParam(c, "test", "polygonCount");
    setParam(c, "compare", "all");
    c.apply();
    assert(mode == EditMode.Edges, "setup: the command promotes to Edges");
    assert(c.revert(), "revert must report success");
    assert(mode == EditMode.Polygons, "undo must restore the prior EditMode");
    assert(selectedFaceIdx(m) == [1UL], "undo must restore the prior face selection");
    assert(selectedEdgePairs(m).length == 0, "undo must clear the edge selection it made");
}

// 9. Multi-layer scope (§4.1): two foreground layers, both with real
// geometry and a real edge selection; the command must empty the
// PRIMARY's selection and leave the second layer's untouched. Pins the
// `divergence-deliberate` row that nothing pinned before task 1061.
unittest {
    Mesh a = makeCube();
    auto doc = Document.bootstrap(a);          // layer "Layer 1" == A, primary
    auto b = new Layer;
    b.name = "B";
    b.meshRef() = makeCube();
    doc.layers ~= b;

    // Select every edge on BOTH meshes (through their own selection state —
    // Document does not itself carry selection, each Mesh does).
    auto aMesh = doc.primary.meshOrNull();
    aMesh.syncSelection();
    foreach (ei; 0 .. aMesh.edges.length) aMesh.selectEdge(cast(int) ei);
    auto bMesh = b.meshOrNull();
    bMesh.syncSelection();
    foreach (ei; 0 .. bMesh.edges.length) bMesh.selectEdge(cast(int) ei);

    doc.selectItem(b, SelMode.Add);            // both layers foreground; A stays primary
    assert(doc.primary is doc.layers[0], "setup: A is still primary");
    // The two premises this test's own comparison silently relies on: if B
    // were NOT foreground, or had no edges, "B's selection count == B's edge
    // count" would read 0 == 0 and the scope assertion below would pass for
    // the wrong reason — proving nothing about scope at all.
    assert(doc.foreground(b), "setup: B must be foreground for this to test scope");
    assert(bMesh.edges.length > 0, "setup: B must have real geometry for this to test scope");

    // Construct against the PRIMARY's mesh only — never a non-primary layer.
    View v = freshView();
    auto c = new SelectByStatEdge(doc.primary.meshOrNull(), v, EditMode.Edges, null);
    setParam(c, "test", "polygonCount");
    setParam(c, "compare", "all");
    setParam(c, "mode", "remove");
    c.apply();

    assert(selectedEdgePairs(aMesh).length == 0,
        "the anti-inert half: A's edge selection must be emptied");
    size_t bSelected = 0;
    foreach (ei; 0 .. bMesh.edges.length) if (bMesh.isEdgeSelected(ei)) ++bSelected;
    assert(bSelected == bMesh.edges.length,
        "the scope half: B's edge selection must be UNTOUCHED — a command widened to "
        ~ "every foreground layer would empty it too");
}
