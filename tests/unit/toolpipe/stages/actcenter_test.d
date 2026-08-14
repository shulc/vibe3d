// Module unittests for `toolpipe.stages.actcenter`, moved verbatim out of source/toolpipe/stages/actcenter.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.toolpipe.stages.actcenter_test;

import std.format : format;
import math    : Vec3, Pin, Viewport, screenRay, screenPointToRay, rayPlaneIntersect, applyAffine,
                 ModelSpace;
import mesh    : Mesh, MeshCacheKey;
import editmode : EditMode;
import seltype : SelType;
import toolpipe.stage    : Stage, TaskCode, ordAcen;
import params           : Param, IntEnumEntry, wireTagForValue, valueForWireTag;
import toolpipe.packets  : SymmetryPacket, ActionCenterPacket;
import operator          : Operator, Task, VectorStack, PacketKind;
import popup_state       : setStatePath;
import document          : Layer;
import toolpipe.stages.actcenter;

// ---------------------------------------------------------------------------
// params() snapshot — module-level so `dub test --config=tests` runs it.
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
// Item mode 0614, Phase 2 — the ACEN item-center redirect
// (doc/item_mode_transform_plan.md §Q3 / §(a)). Eight selection-derived
// modes (Auto/Select/SelectAuto/Screen/Element/Local/Border/None) redirect
// to the item's world pivot when the subject is SelType.Item; the other
// four (Origin/Manual/Pivot/Parent) are unaffected — subject-independent or
// already item-anchored. Screen joins the redirect set (review should-fix
// 2): its centre body is the byte-identical `centroidWithGeometryFallback()`
// call Auto/None make, so excluding it while including its two siblings had
// no principled basis. `capture-verified` for the redirect's VALUE (L1,
// doc/tasks/0614-evidence/phase0_findings.md case A): the rig below is the
// same discriminator the capture used — geometry displaced to local
// (3,0,0), item pos=pivot=(0,0,0) — so a bbox-centre fallback and the item
// pivot disagree and the test proves which one actually fired.
//
// `currentSel` + the `() => currentSel` ctor delegate stand in for the LIVE
// external selType source app.d wires (review Blocker 2 — computeCenter()
// no longer reads a field cached from evaluate(), so a test drives it via
// the same live-query seam production uses instead of poking a field).
// ---------------------------------------------------------------------------
unittest {
    import mesh     : makeCube;
    import std.math : fabs;
    import std.conv : to;

    bool vecEq(Vec3 a, Vec3 b) {
        return fabs(a.x - b.x) < 1e-6f && fabs(a.y - b.y) < 1e-6f
            && fabs(a.z - b.z) < 1e-6f;
    }

    Mesh cube = makeCube();
    foreach (ref v; cube.vertices) v = v + Vec3(3, 0, 0);   // geometry ~ local (3,0,0)
    cube.resetSelection();
    Mesh* meshPtr = &cube;
    EditMode em = EditMode.Vertices;

    auto parentLayer = new Layer();
    parentLayer.xform.pivot = Vec3(9, 9, 9);
    auto itemLayer = new Layer();
    itemLayer.xform.pos    = Vec3(0, 0, 0);
    itemLayer.xform.pivot  = Vec3(0, 0, 0);
    itemLayer.parent       = parentLayer;
    Layer itemRef = itemLayer;

    SelType currentSel = SelType.Vertex;
    auto acs = new ActionCenterStage(() => meshPtr, &em, () => itemRef,
                                      () => currentSel);
    acs.manualCenter = Vec3(7, 8, 9);

    immutable Vec3 itemPivot     = Vec3(0, 0, 0);   // item's world pivot
    immutable Vec3 geomCentroid  = Vec3(3, 0, 0);   // what the geometry fallback reads
    immutable Vec3 parentPivot   = Vec3(9, 9, 9);

    alias Mode = ActionCenterStage.Mode;

    // The eight redirect modes: same computeCenter() call, only the live
    // selType source differs — geometry-mode is byte-identical to the
    // pre-0614 behaviour (proves the redirect costs nothing when inactive);
    // item-mode reads the item pivot instead of the geometry centroid.
    foreach (m; [Mode.Auto, Mode.Select, Mode.SelectAuto, Mode.Screen,
                 Mode.Element, Mode.Local, Mode.Border, Mode.None]) {
        acs.mode = m;
        currentSel = SelType.Vertex;
        assert(vecEq(acs.currentCenter(), geomCentroid),
            m.to!string ~ ": Vertex subject must read the geometry fallback "
            ~ "unchanged (0614 must not touch existing behaviour)");
        currentSel = SelType.Item;
        assert(vecEq(acs.currentCenter(), itemPivot),
            m.to!string ~ ": Item subject must redirect to the item's world "
            ~ "pivot, not the geometry centroid — §Q3");
    }

    // The four unaffected modes: an Item subject must NOT change their
    // result relative to a Vertex subject.
    acs.mode = Mode.Origin;
    currentSel = SelType.Vertex;
    assert(vecEq(acs.currentCenter(), Vec3(0, 0, 0)));
    currentSel = SelType.Item;
    assert(vecEq(acs.currentCenter(), Vec3(0, 0, 0)),
        "Origin: subject-independent, must ignore item mode entirely");

    acs.mode = Mode.Manual;
    currentSel = SelType.Vertex;
    assert(vecEq(acs.currentCenter(), acs.manualCenter));
    currentSel = SelType.Item;
    assert(vecEq(acs.currentCenter(), acs.manualCenter),
        "Manual: subject-independent, must ignore item mode entirely");

    acs.mode = Mode.Pivot;
    currentSel = SelType.Vertex;
    assert(vecEq(acs.currentCenter(), itemPivot));
    currentSel = SelType.Item;
    assert(vecEq(acs.currentCenter(), itemPivot),
        "Pivot: already item-anchored regardless of subject type");

    acs.mode = Mode.Parent;
    currentSel = SelType.Vertex;
    assert(vecEq(acs.currentCenter(), parentPivot));
    currentSel = SelType.Item;
    assert(vecEq(acs.currentCenter(), parentPivot),
        "Parent: already item-anchored regardless of subject type");
}

// ---------------------------------------------------------------------------
// Item mode 0614, Phase 2 — the Local-mode cluster BFS must NOT run when the
// subject is an item (doc/item_mode_transform_plan.md §(a) step 3 / §Q3).
// Drives the REAL evaluate() path (not computeCenter() directly) with a
// selection that forms two disjoint clusters — the same rig the D5 dedup
// unittest above uses — so this exercises the exact early-out that guards
// `localCenterAndClustersCached`, not merely `computeCenter`'s own switch.
// ---------------------------------------------------------------------------
unittest {
    import mesh              : makeCube;
    import operator          : VectorStack;
    import toolpipe.packets  : SubjectPacket;

    Mesh cube = makeCube();
    cube.resetSelection();
    cube.selectFace(4);   // y=+0.5 face — cluster 0
    cube.selectFace(5);   // y=-0.5 face — disconnected, cluster 1
    Mesh* meshPtr = &cube;
    EditMode em = EditMode.Polygons;

    auto itemLayer = new Layer();
    itemLayer.xform.pivot = Vec3(2, 2, 2);
    Layer itemRef = itemLayer;

    auto acs = new ActionCenterStage(() => meshPtr, &em, () => itemRef);
    acs.mode = ActionCenterStage.Mode.Local;

    SubjectPacket subj;
    subj.mesh     = meshPtr;
    subj.editMode = em;
    subj.selType  = SelType.Item;
    VectorStack vts;
    vts.put(&subj);
    assert(acs.evaluate(vts), "evaluate() must succeed");

    auto pkt = vts.get!ActionCenterPacket();
    assert(pkt !is null);
    assert(pkt.clusterCenters.length == 0,
        "item mode: the two-cluster selection must NOT reach the Local "
        ~ "cluster BFS — clusterCenters must stay empty so "
        ~ "ClusterPivots.active reads false downstream");
    assert(pkt.clusterOf.length == 0,
        "item mode: clusterOf must stay empty alongside clusterCenters");
    assert(pkt.center.x == 2 && pkt.center.y == 2 && pkt.center.z == 2,
        "item mode: Local's redirect must still publish the item's world "
        ~ "pivot as the single center, exactly like every other redirect mode");
}

// ---------------------------------------------------------------------------
// Review Blocker 2 — the item decision must NOT be a field cached from
// whichever evaluate() call ran last. Reproduces the review's concrete
// example: an item-scoped evaluate() (the drag/render path) followed by an
// UNRELATED evaluate() that is deliberately geometry-scoped (mirrors
// source/tools/common/command_wrapper.d's preview tick, which hardcodes
// Vertex edit mode and never sets a selection type) — currentCenter() (the
// path falloff_handles.d / listAttrs() read) must still report the item
// pivot afterward, as long as the LIVE external truth (`selTypeSrc_`) still
// says Item. A field cached from the SECOND (geometry-scoped) evaluate()
// call would wrongly clobber it back to the geometry fallback here —
// order-dependent, exactly the "no symptom until two callers disagree" bug
// the review names.
// ---------------------------------------------------------------------------
unittest {
    import mesh              : makeCube;
    import operator          : VectorStack;
    import toolpipe.packets  : SubjectPacket;
    import std.math          : fabs;
    import std.conv          : to;

    bool vecEq(Vec3 a, Vec3 b) {
        return fabs(a.x - b.x) < 1e-6f && fabs(a.y - b.y) < 1e-6f
            && fabs(a.z - b.z) < 1e-6f;
    }

    Mesh cube = makeCube();
    foreach (ref v; cube.vertices) v = v + Vec3(5, 0, 0);   // geometry ~ (5,0,0)
    cube.resetSelection();
    Mesh* meshPtr = &cube;
    EditMode em = EditMode.Vertices;

    auto itemLayer = new Layer();
    itemLayer.xform.pos = Vec3(9, 0, 0);
    Layer itemRef = itemLayer;

    // The live app-state truth: item is current — wired exactly like app.d
    // wires ActionCenterStage to `() => currentSelType(selTypeOrder)`.
    SelType liveTruth = SelType.Item;
    auto acs = new ActionCenterStage(() => meshPtr, &em, () => itemRef,
                                      () => liveTruth);
    acs.mode = ActionCenterStage.Mode.Auto;

    immutable Vec3 itemPivot    = Vec3(9, 0, 0);
    immutable Vec3 geomCentroid = Vec3(5, 0, 0);

    // Step 1: the real drag/render evaluate() — subject correctly Item.
    SubjectPacket subjItem;
    subjItem.mesh = meshPtr; subjItem.editMode = em; subjItem.selType = SelType.Item;
    VectorStack vtsItem;
    vtsItem.put(&subjItem);
    assert(acs.evaluate(vtsItem), "evaluate() must succeed (item subject)");
    assert(vecEq(acs.currentCenter(), itemPivot),
        "sanity: item-scoped evaluate() must publish the item pivot");

    // Step 2: an UNRELATED evaluate() call — mirrors command_wrapper.d's
    // preview tick, which hardcodes Vertex and never sets selType (left at
    // its packet default). This must NOT poison any later reader.
    SubjectPacket subjPreview;
    subjPreview.mesh = meshPtr; subjPreview.editMode = em;
    VectorStack vtsPreview;
    vtsPreview.put(&subjPreview);
    assert(acs.evaluate(vtsPreview), "evaluate() must succeed (preview subject)");

    // Step 3: currentCenter() must STILL report the item pivot — the live
    // external truth is still Item, and it must be consulted FRESH here,
    // not read off a field the preview tick's evaluate() call clobbered.
    assert(vecEq(acs.currentCenter(), itemPivot),
        "currentCenter() must reflect the LIVE current subject, not "
        ~ "whichever evaluate() call happened to run last — review Blocker 2. "
        ~ "Got " ~ acs.currentCenter().x.to!string ~ "," ~ acs.currentCenter().y.to!string
        ~ "," ~ acs.currentCenter().z.to!string ~ " (geometry fallback would "
        ~ "be " ~ geomCentroid.x.to!string ~ "," ~ geomCentroid.y.to!string
        ~ "," ~ geomCentroid.z.to!string ~ ")");
}

// ---------------------------------------------------------------------------
// Item mode 0614 review BLOCKER — a second writer of `pkt.center`. The
// symmetry base-side override (evaluate(), the block right after the
// computeCenter()/localCenterAndClustersCached() call above) restricts the
// centroid to base-side verts whenever symmetry is on and the selection
// straddles the plane. It used to run for six of the eight
// `itemRedirectMode()` modes (everything except Element/Local, which it was
// ALREADY excluding for an unrelated reason), silently clobbering the item
// pivot the first writer had just published — including Mode.Auto, the
// default. `currentCenter()` (the listAttrs()/display path,
// GET /api/toolpipe) never runs this override at all, so the two readers of
// "the action center" split: the evaluate()-published packet
// (GET /api/toolpipe/eval) read the geometry base-side centroid while the
// display path kept reporting the item pivot, for the SAME frame.
//
// Reproduces the review's repro almost verbatim: item world pivot at
// x=2 (pos=(2,0,0), pivot=0), symmetry on (X axis, plane at x=0), ALL cube
// vertices selected (both sides of the plane, so `baseSideCentroid` finds
// base-side verts and actually overrides — count==0 would silently no-op
// and defeat the test). The four selected +X-side vertices average to
// (0.5,0,0) — discriminates from the item pivot (2,0,0), so a clobber is
// observable, not coincidentally masked.
//
// This must hold across every one of the eight redirect modes, not just the
// default: the pre-fix exclusion list was itself mode-specific (it happened
// to already exclude Element/Local), so a single-mode assertion could not
// tell "fixed for all six exposed modes" from "fixed for the one mode
// tested".
// ---------------------------------------------------------------------------
unittest {
    import mesh              : makeCube;
    import operator          : VectorStack;
    import toolpipe.packets  : SubjectPacket, SymmetryPacket;
    import std.math          : fabs;
    import std.conv          : to;

    bool vecEq(Vec3 a, Vec3 b) {
        return fabs(a.x - b.x) < 1e-6f && fabs(a.y - b.y) < 1e-6f
            && fabs(a.z - b.z) < 1e-6f;
    }

    Mesh cube = makeCube();               // symmetric ±0.5 corners about x=0
    cube.resetSelection();
    foreach (i; 0 .. cube.vertices.length)
        cube.selectVertex(cast(int)i);    // ALL verts — both sides of the plane
    Mesh* meshPtr = &cube;
    EditMode em = EditMode.Vertices;

    auto itemLayer = new Layer();
    itemLayer.xform.pos = Vec3(2, 0, 0);  // world pivot = pos+pivot = (2,0,0)
    Layer itemRef = itemLayer;

    SelType liveTruth = SelType.Item;
    auto acs = new ActionCenterStage(() => meshPtr, &em, () => itemRef,
                                      () => liveTruth);

    immutable Vec3 itemPivot     = Vec3(2, 0, 0);
    // The base-side (+X) centroid of the 4 selected x=+0.5 corners — what
    // the pre-fix override would wrongly publish instead of itemPivot.
    immutable Vec3 baseSideCen   = Vec3(0.5f, 0, 0);
    assert(!vecEq(itemPivot, baseSideCen),
        "test rig must discriminate the item pivot from the base-side "
        ~ "centroid, or a clobber would be invisible");

    SymmetryPacket sym;
    sym.enabled   = true;
    sym.axisIndex = 0;                    // X
    sym.baseSide  = 1;                    // +X is the anchored side
    sym.vertSign.length = cube.vertices.length;
    foreach (i, v; cube.vertices) sym.vertSign[i] = (v.x >= 0) ? 1 : -1;
    sym.pairOf.length = cube.vertices.length;
    foreach (ref p; sym.pairOf) p = -1;   // unused by baseSideCentroid; only
                                          // the length-match gate cares.

    alias Mode = ActionCenterStage.Mode;
    // The eight redirect modes (itemRedirectMode() == true) — same universe
    // the earlier item-redirect unittest exercises.
    foreach (m; [Mode.Auto, Mode.Select, Mode.SelectAuto, Mode.Screen,
                 Mode.Element, Mode.Local, Mode.Border, Mode.None]) {
        acs.mode = m;

        SubjectPacket subj;
        subj.mesh = meshPtr; subj.editMode = em; subj.selType = SelType.Item;
        VectorStack vts;
        vts.put(&subj);
        vts.put(&sym);
        assert(acs.evaluate(vts), m.to!string ~ ": evaluate() must succeed");

        auto pkt = vts.get!ActionCenterPacket();
        assert(pkt !is null);

        Vec3 published = pkt.center;
        Vec3 displayed = acs.currentCenter();

        assert(vecEq(published, itemPivot),
            m.to!string ~ ": symmetry-on item mode must publish the item "
            ~ "pivot, not a geometry base-side centroid — got "
            ~ published.x.to!string ~ "," ~ published.y.to!string ~ ","
            ~ published.z.to!string);
        assert(vecEq(published, displayed),
            m.to!string ~ ": the evaluate()-published center and the "
            ~ "listAttrs()/currentCenter() display center must AGREE for "
            ~ "the same frame — published=" ~ published.x.to!string ~ ","
            ~ published.y.to!string ~ "," ~ published.z.to!string
            ~ " displayed=" ~ displayed.x.to!string ~ ","
            ~ displayed.y.to!string ~ "," ~ displayed.z.to!string);
    }
}

// ---------------------------------------------------------------------------
// Task 0705 (audit 4, wave 2, P5) — the mode classifiers are now `final
// switch`, so the COMPILER refuses a thirteenth `Mode` that nobody classified.
// What the compiler still cannot see is the RELATION between two of the
// tables, so that is pinned here.
//
// This test is deliberately NOT a copy of the tables. Restating the six
// members of `centerIsSelectionCentroid` here would be the sixth spelling of
// the set this task went and removed. It asserts the two things that are
// properties OF the tables and cannot be read off either one alone.
unittest {
    import std.traits : EnumMembers;
    alias M = ActionCenterStage.Mode;

    // (1) Containment. `acenSettleAllowed()` is the WRITE side (may a gesture
    // settle store a drop point?) and `settlePinHonored()` is the READ side
    // (may `computeCenter` return it?). A mode that reads a pin it was never
    // allowed to write is a pin that can never fire; the write side must
    // therefore be the wider of the two, in every mode.
    Mesh mesh;
    Mesh* meshPtr = &mesh;
    EditMode em = EditMode.Vertices;
    auto st = new ActionCenterStage(() => meshPtr, &em);
    foreach (m; EnumMembers!M) {
        st.mode = m;
        if (st.settlePinHonored())
            assert(st.acenSettleAllowed(),
                "ACEN mode is honored on read but refused on write — the "
                ~ "settle pin can never fire in it");
    }

    // (2) The two spellings this task merged were extensionally equal, and
    // the merge must not have quietly changed either answer. `settlePinHonored`
    // excludes exactly the modes with a fixed centre (Origin, Manual), a live
    // per-element/per-cluster centre (Element, Local) or a live item pivot
    // (Pivot, Parent) — six in, six out, on a twelve-member enum.
    int honored = 0;
    foreach (m; EnumMembers!M) {
        st.mode = m;
        if (st.settlePinHonored()) ++honored;
    }
    assert(honored == 6,
        "the settle-honored set changed size — if that is intended, say which "
        ~ "mode moved and why, because `evaluate()`'s symmetry base-side "
        ~ "override reads the SAME predicate");

    // (3) Element and Local are the two the write side itself refuses; they
    // are the reason `acenSettleAllowed` exists as a separate, wider table.
    st.mode = M.Element; assert(!st.acenSettleAllowed());
    st.mode = M.Local;   assert(!st.acenSettleAllowed());
    st.mode = M.Origin;  assert(st.acenSettleAllowed() && !st.settlePinHonored(),
        "Origin is the shape that needs two tables: it may be WRITTEN and must "
        ~ "not be READ");
}

